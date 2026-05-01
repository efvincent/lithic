module Compiler.TypeChecker where

import Data.Text (Text)
import GHC.Generics (Generic)
import Data.Generics.Labels ()
import Data.IntMap.Strict (IntMap)
import qualified Data.IntMap.Strict as IM
import qualified Data.Text as T

import Bluefin.Eff ((:>), Eff)
import Bluefin.Exception (Exception, throw)
import Bluefin.Reader (Reader, ask, runReader)
import Bluefin.State (State, get, modify)

import Compiler.AST (Expr(..), Type(..), SourceSpan, getTypeSpan)
import Lens.Micro ((.~), (%~))
import Data.Function ((&))

--------------------------------
-- Type definitions
--------------------------------

-- | Unification state holding the substitution map and a counter for fresh IDs.
data TCState = MkTCState
  { nextMeta :: !Int
  , subst    :: !(IntMap Type)
  } deriving (Show, Eq, Generic)

-- | The typing environment mapping term variables to their types
data Env = MkEnv
  { bindings :: ![(Text, Type)]
  } deriving (Show, Eq, Generic)

-- | Localized type errors utilizing parsed SourceSpans
data TypeError = MkTypeError
  { msg :: !Text
  , span :: !SourceSpan
  } deriving (Show, Eq, Generic)

--------------------------------
-- Helper functions
--------------------------------

-- | Generate a fresh meta-variable
freshMeta 
  :: forall st es. (st :> es) 
  => SourceSpan -> State TCState st -> Eff es Type
freshMeta sp st = do
  curSt <- get st
  let mId = curSt.nextMeta
  modify st (#nextMeta .~ (mId + 1))
  pure $ TMeta sp mId

-- | Helper to push a new binding onto the lexical environment
extendEnv :: Text -> Type -> Env -> Env
extendEnv x ty env = MkEnv ((x, ty) : env.bindings)

-- | Extract a span from an Expr to attach to localized errors.
getSpan :: Expr -> SourceSpan
getSpan = \case
  Var sp _     -> sp
  Lit sp _     -> sp
  Lam sp _ _ _ -> sp
  App sp _ _   -> sp
  Let sp _ _ _ -> sp
  Ann sp _ _   -> sp

--------------------------------
-- Typechecker implementation
--------------------------------

-- | Synthesize a type for an expression (Inference Phase)
infer
  :: forall st r ex es. (st :> es, r :> es, ex :> es)
  => State TCState st -> Reader Env r -> Exception TypeError ex -> Expr -> Eff es Type
infer st env ex expr = 
  case expr of
    Lit sp _ -> pure $ TInt sp

    Var sp x -> do
      currentEnv <- ask env
      case lookup x currentEnv.bindings of
        Just ty -> pure ty
        Nothing -> throw ex $ MkTypeError ("Unbound variable: " <> x) sp

    -- 3. Lambdas (Both Annotated and Unannotated)
    Lam sp param mAnn body -> do
      -- Determine the parameter type: use annotation if present, otherwise guess via TMeta
      paramTy <- case mAnn of
        Just ty -> pure ty
        Nothing -> freshMeta sp st
      
      -- Create the new extended environment value
      currentEnv <- ask env
      let newEnv = MkEnv ((param, paramTy) : currentEnv.bindings)
      
      -- Run a strictly scoped local Reader effect for the body
      bodyTy <- runReader newEnv \newEnvHandle ->
        infer st newEnvHandle ex body
        
      pure $ TArrow sp paramTy bodyTy

    -- 4. Function Application
    App sp f arg -> do
      -- Infer the function and deeply resolve it to clear any substitutions
      rawTyF <- infer st env ex f
      tyF <- force st rawTyF 
      
      case tyF of
        -- Standard case: it is already known to be a function
        TArrow _ domain range -> do
          check st env ex arg domain
          pure range
          
        -- Unification case: the function is currently an unknown meta-variable
        TMeta _ mId -> do
          -- Guess the domain and range
          domain <- freshMeta sp st
          range <- freshMeta sp st
          
          -- Constrain the unknown function to be an arrow type
          bindMeta st ex mId (TArrow sp domain range) sp
          
          -- Check the argument against our guessed domain
          check st env ex arg domain
          pure range

        -- Failure case
        _ -> throw ex $ MkTypeError "Attempted to apply a non-function" sp

    -- 5. Explicit Type Annotations (The bridge to checking)
    Ann _ e expectedTy -> do
      -- We know the expected type, so we push it down into the checking phase
      check st env ex e expectedTy
      pure expectedTy

    -- 6. Let Bindings
    Let _ name val body -> do
      -- 1. Infer the type of the value being bound
      valTy <- infer st env ex val
      
      -- 2. Extend the environment
      e <- ask env
      let newEnv = MkEnv ((name, valTy) : e.bindings)
      
      -- 3. Infer the body in the strictly scoped new environment
      runReader newEnv \newEnvHandle ->
        infer st newEnvHandle ex body

-- | Check that an expression satisfies an expected type.
check 
  :: forall st env ex es. (st :> es, env :> es, ex :> es) 
  => State TCState st 
  -> Reader Env env 
  -> Exception TypeError ex 
  -> Expr 
  -> Type 
  -> Eff es ()
check st envHandle ex expr expectedTy = do
  -- 1. ALWAYS force the expected type to look through any substitutions
  forcedTy <- force st expectedTy
  
  case (expr, forcedTy) of
    -- 2. Checking a Lambda against a known Arrow Type
    (Lam _ param mAnn body, TArrow _ domain range) -> do
      -- 1. Enforce the annotation against the expected domain if present
      case mAnn of
        -- FIX: Use the specific span of the annotation for precise error reporting
        Just annTy -> unify st ex annTy domain (getTypeSpan annTy)
        Nothing -> pure ()
        
      env <- ask envHandle
      let newEnv = MkEnv ((param, domain) : env.bindings)
      runReader newEnv \newEnvHandle ->
        check st newEnvHandle ex body range
        
    -- 3. Checking a Lambda against an unbound Meta-variable
    (Lam sp param mAnn body, TMeta _ mId) -> do
      -- 1. If annotated, use the annotation as the domain. Otherwise, guess.
      domain <- case mAnn of
        Just annTy -> pure annTy
        Nothing -> freshMeta sp st
        
      range <- freshMeta sp st
      
      -- Constrain the meta-variable to the arrow type
      bindMeta st ex mId (TArrow sp domain range) sp
      
      env <- ask envHandle
      let newEnv = MkEnv ((param, domain) : env.bindings)
      runReader newEnv \newEnvHandle ->
        check st newEnvHandle ex body range

    -- 4. Checking a Lambda against anything else is a hard error
    (Lam sp _ _ _, _) -> 
      throw ex $ MkTypeError "Type mismatch: Expected a non-function type, but got a lambda." sp

    -- 5. The Bridge: If no specific checking rules match, fall back to Synthesis + Unification
    _ -> do
      inferredTy <- infer st envHandle ex expr
      unify st ex inferredTy forcedTy (getSpan expr)

-- | Verify that the inferred type subsumes the expected type.
subsumes
  :: forall st ex es. (st :> es, ex :> es)
  => State TCState st -> Exception TypeError ex -> Type -> Type -> SourceSpan -> Eff es ()
subsumes st ex inferred expected sp = unify st ex inferred expected sp

-- | Shallow resolution: Follows TMeta chains until it hits a concrete type or an unbound TMeta.
-- It does NOT deeply walk into TArrows.
force
  :: forall st es. (st :> es) 
  => State TCState st -> Type -> Eff es Type 
force st ty = 
  case ty of
    TMeta _ mId -> do
      curSt <- get st
      case IM.lookup mId curSt.subst of
        Just resolvedTy -> do
          -- Recursively follow the chain
          fullyResolved <-  force st resolvedTy
          -- Path compression
          modify st (\s -> s & #subst %~ IM.insert mId fullyResolved)
          pure fullyResolved
        Nothing -> pure ty
    _ -> pure ty

-- | Deep resolution: fully instantiates a type for display or finalization.
zonk 
  :: forall st es. (st :> es)
  => State TCState st -> Type  -> Eff es Type
zonk st ty = do
  forcedTy <- force st ty
  case forcedTy of
    TArrow sp p r -> TArrow sp <$> zonk st p <*> zonk st r
    -- (TODO: TForall handling goes here)
    _ -> pure forcedTy

-- | Unify tow types, updating the substitution state if necessary.
unify
  :: forall st ex es. (st :> es, ex :> es)
  => State TCState st -> Exception TypeError ex -> Type -> Type -> SourceSpan -> Eff es ()
unify st ex t1 t2 sp = do
  ty1 <- force st t1
  ty2 <- force st t2
  case (ty1, ty2) of
    -- Both are the same meta-variable
    (TMeta _ m1, TMeta _ m2) | m1 == m2 -> pure ()

    -- Mind meta-variable to a type
    (TMeta _ m, _) -> bindMeta st ex  m ty2 sp
    (_, TMeta _ m) -> bindMeta st ex  m ty1 sp

    (TInt _, TInt _) -> pure ()
    (TArrow _ p1 r1, TArrow _ p2 r2) -> do
      unify st ex p1 p2 sp
      unify st ex r1 r2 sp

    (TVar _ a, TVar _ b) | a == b -> pure ()
    
    _ -> throw ex $
      MkTypeError ("Cannot unify " <> T.pack (show ty1) <> " with " <> T.pack (show ty2)) sp

-- | Bind a meta-variable, ensuring it doesn't create infinite types (occurs check).
bindMeta
  :: forall st ex es. (st :> es, ex :> es) 
  => State TCState st -> Exception TypeError ex -> Int -> Type -> SourceSpan -> Eff es ()
bindMeta st ex mId ty sp = do
  -- Execute the effectful occurs check
  hasCycle <- occurs st mId ty
  if hasCycle 
  then throw ex $ MkTypeError "Infinite type detected (occurs check failed)" sp
  else modify st (\s -> s & #subst %~ IM.insert mId ty)

-- | Effectful occurs check that resolves meta-variables as it walks
occurs
  :: forall st es. (st :> es)
  => State TCState st -> Int -> Type -> Eff es Bool
occurs st mId ty = do
  -- Zonk the type first to look through any existing substitutions
  resolvedTy <- force st ty
  case resolvedTy of
    TMeta _ m -> pure $ m == mId
    TArrow _ p r -> do
      pOccurs <- occurs st mId p
      if pOccurs then pure True else occurs st mId r
    _ -> pure False
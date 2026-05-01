module Compiler.TypeChecker where

import Data.Text (Text)
import GHC.Generics (Generic)
import Data.Generics.Labels ()
import Data.IntMap.Strict (IntMap)
import qualified Data.IntMap.Strict as IM
import qualified Data.Text as T

import Bluefin.Eff ((:>), Eff)
import Bluefin.Exception (Exception, throw)
import Bluefin.Reader (Reader, ask, local)
import Bluefin.State (State, get, modify)

import Compiler.AST (Expr(..), Type(..), SourceSpan)
import Lens.Micro ((.~), (%~))
import Data.Function ((&))

--------------------------------
-- Type definitions
--------------------------------

-- | Unificationstate holding the substitution map and a counter for fresh IDs.
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

    Ann _ e ty -> do
      check st env ex e ty
      pure ty

    App _ f x -> do
      -- Synthesize the function's type
      fTy <- infer st env ex f
      case fTy of
        TArrow _ paramTy retTy -> do
          -- Push the known parameter type down to the argument
          check st env ex x paramTy
          pure retTy
        _ -> throw ex $ MkTypeError "Expected a function in application" (getSpan f)
    
    Lam sp x mTy body ->
      case mTy of
        Just paramTy -> do
          -- With an explicit annotation, we can synthesize the lambda type
          bodyTy <- local env (extendEnv x paramTy) (infer st env ex body)
          pure $ TArrow sp paramTy bodyTy
        Nothing ->
          throw ex $ MkTypeError "Cannot infer type of unannotated lambda. Add an annotation or use it in a checking context." sp

    Let _ x val body -> do
      -- Koka-style FBIP relies on explicit let-bindings.
      -- We strictly synthesize the bound value first.
      valTy <- infer st env ex val
      local env (extendEnv x valTy) (infer st env ex body)

-- | Verify that an expression satisfies a given type (Checking phase).
check 
  :: forall st r ex es. (st :> es, r :> es, ex :> es)
  => State TCState st -> Reader Env r -> Exception TypeError ex -> Expr -> Type -> Eff es ()
check st env ex expr expectedTy = 
  case (expr, expectedTy) of
    -- Unannotated lambdas can be checked against known function types
    (Lam _ x Nothing body, TArrow _ paramTy retTy) -> do
      local env (extendEnv x paramTy) (check st env ex body retTy)

    -- Catch invalid checking contexts for unannotated lambdas before falling back
    (Lam sp _ Nothing _, _) ->
      throw ex $ MkTypeError "Type mismatch: Expected a non-function type, but got a lambda." sp
      
    -- Fallback: Synthesize the type and verify subsumption/unification
    _ -> do
      inferredTy <- infer st env ex expr
      subsumes st ex inferredTy expectedTy (getSpan expr)

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
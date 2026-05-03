module Compiler.TypeChecker where

import Data.Text (Text)
import GHC.Generics (Generic)
import Data.Generics.Labels ()
import Data.IntSet (IntSet)
import Data.IntMap.Strict (IntMap)
import Data.Map.Strict (Map)
import qualified Data.IntSet as IS
import qualified Data.IntMap.Strict as IM
import qualified Data.Map.Strict as Map
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
        -- Use the effectful instantiate to unpack TForall if present
        Just ty -> instantiate st ty
        Nothing -> throw ex $ MkTypeError ("Unbound variable: " <> x) sp

    -- Lambdas (Both Annotated and Unannotated)
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

    -- Function Application
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

    -- Explicit Type Annotations (The bridge to checking)
    Ann _ e expectedTy -> do
      -- We know the expected type, so we push it down into the checking phase
      check st env ex e expectedTy
      pure expectedTy

    -- Let Bindings
    Let _ name val body -> do
      -- 1. Infer the type of the value being bound
      rawValTy <- infer st env ex val
      
      -- 2. Deeply resolve it
      zonkedValTy <- zonk st rawValTy
      e <- ask env
      polyTy <- generalize st e zonkedValTy

      -- 3. Extend the environment with the generalized polymorphic type
      let newEnv = MkEnv ((name, polyTy) : e.bindings)
      
      -- 4. Infer the body in the strictly scoped new environment
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

    -- 5. The Bridge Fallback: Infer the actual type and use the subsumption bridge
    _ -> do
      actualTy <- infer st envHandle ex expr
      subsumes st ex actualTy expectedTy (getSpan expr)     

-- | Verify that the inferred type subsumes the expected type.
subsumes
  :: forall st ex es. (st :> es, ex :> es)
  => State TCState st -> Exception TypeError ex -> Type -> Type -> SourceSpan -> Eff es ()
subsumes st ex inferred expected sp = do
  infForced <- force st inferred
  expForced <- force st expected
  case (infForced, expForced) of
    -- Rule 1: Expected is polymorphic -> Skolemize with rigid constants
    (_, TForall{}) -> do
      skolemizedExp <- skolemize st expForced
      subsumes st ex infForced skolemizedExp sp
    -- Rule 2: Inferred is polymorphic -> Instantiate with flexible metas
    (TForall{}, _) -> do
      instantiatedInf <- instantiate st infForced
      subsumes st ex instantiatedInf expForced sp
    -- Rule 3: Arrow Subsumption (Contravariant Domain, Covariant Range)
    (TArrow _ d1 r1, TArrow _ d2 r2) -> do
      subsumes st ex d2 d1 sp -- Note the flip! Expected domain must subsume inferred domain.
      subsumes st ex r1 r2 sp 
    -- Fallback: standard unification
    _ -> unify st ex infForced expForced sp

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
    TForall sp vars inner -> TForall sp vars <$> zonk st inner
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

    -- Skolems only unify with the exact same Skolem
    (TSkolem _ s1 _, TSkolem _ s2 _) | s1 == s2 -> pure ()

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

-- | instantiates a polymorphic type by replaceing its quantified variables
-- with fresh metavariables
instantiate
  :: forall st es. (st :> es)
  => State TCState st -> Type -> Eff es Type
instantiate st ty = 
  case ty of
    TForall _ vars innerTy -> do
      -- Generate a fresh meta-variable for each bound name
      subst <- traverse (\v -> (v,) <$> freshMeta (getTypeSpan innerTy) st) vars
      let substMap = Map.fromList subst
      pure $ subBound substMap innerTy
    _ -> pure ty

-- | Generalize a type over its free meta-variables
generalize
  :: forall st es. (st :> es)
  => State TCState st -> Env -> Type -> Eff es Type
generalize st env ty = do
  envFtv <- ftvEnv st env
  tyFtv <- ftvType st ty  
  let unboundMetas = IS.toList (IS.difference tyFtv envFtv)
  if null unboundMetas
  then pure ty
  else do
    -- '$' guarantees no collision with user annotations since TokIdent requires isAlpha
    let nameMap = IM.fromList [ (mId, "$" <> T.pack (show mId)) | mId <- unboundMetas ]
    let genTy = replaceMetas nameMap ty
    pure $ TForall (getTypeSpan ty) (IM.elems nameMap) genTy

-- | Purely replace meta-variables with concrete type variables
replaceMetas :: IntMap Text -> Type -> Type
replaceMetas nameMap ty =
  case ty of
    TMeta sp mId -> 
      case IM.lookup mId nameMap of
        Just name -> TVar sp name
        Nothing   -> ty
    TArrow sp p r -> TArrow sp (replaceMetas nameMap p) (replaceMetas nameMap r)
    TForall sp vars inner -> TForall sp vars (replaceMetas nameMap inner)
    _ -> ty

-- | replaces bound type variables (TVar) with their instantiated concrete types.
subBound :: Map Text Type -> Type -> Type
subBound subMap ty =
  case ty of
    TVar _ v -> case Map.lookup v subMap of
      Just replacement -> replacement
      Nothing -> ty
    TInt _ -> ty
    TArrow sp p r -> TArrow sp (subBound subMap p) (subBound subMap r)
    TForall sp vars innerTy ->
      -- If a nested forall shadows a variable, remove it from the active substitution map
      let subMap' = foldr Map.delete subMap vars
      in TForall sp vars (subBound subMap' innerTy)
    _ -> ty -- Catches TMeta and TSkolem
    
-- | Generate a fresh rigit skolem constant
freshSkolem
  :: forall st es. (st :> es) 
  => SourceSpan -> Text -> State TCState st -> Eff es Type
freshSkolem sp name st = do
  curSt <- get st
  let sId = curSt.nextMeta
  modify st (#nextMeta .~ (sId + 1))
  pure $ TSkolem sp sId name

-- | Skolemize a polymorphic type by replacing its quantified variables with rigid skolems
skolemize 
  :: forall st es. (st :> es)
  => State TCState st -> Type -> Eff es Type
skolemize st ty =
  case ty of
    TForall _ vars innerTy -> do
      subst <- traverse (\v -> (v,) <$> freshSkolem (getTypeSpan innerTy) v st) vars
      let substMap = Map.fromList subst
      pure $ subBound substMap innerTy
    _ -> pure ty

-- | Collects all unbound meta-variable IDs in a type.
ftvType
  :: forall st es. (st :> es)
  => State TCState st -> Type -> Eff es IntSet
ftvType st ty = do
  forced <- force st ty
  case forced of
    TMeta _ mId -> pure $ IS.singleton mId
    TArrow _ p r -> do
      pVars <- ftvType st p
      rVars <- ftvType st r 
      pure $ IS.union pVars rVars
    TForall _ _ inner -> ftvType st inner
    _ -> pure IS.empty

-- | Collects all unbound meta-variable IDs across the entire lexical environment
ftvEnv
  :: forall st es. (st :> es)
  => State TCState st -> Env -> Eff es IntSet
ftvEnv st env = do
  sets <- traverse (\(_, t) -> ftvType st t) env.bindings
  pure $ IS.unions sets

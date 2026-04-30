module Compiler.TypeChecker where

import Data.Text (Text)
import GHC.Generics (Generic)
import Data.Generics.Labels ()

import Bluefin.Eff ((:>), Eff)
import Bluefin.Exception (Exception, throw)
import Bluefin.Reader (Reader, ask, local)

import Compiler.AST (Expr(..), Type(..), SourceSpan)

-- | The typing environment mapping term variables to their types
data Env = MkEnv
  { bindings :: ![(Text, Type)]
  } deriving (Show, Eq, Generic)

-- | Helper to push a new binding onto the lexical environment
extendEnv :: Text -> Type -> Env -> Env
extendEnv x ty env = MkEnv ((x, ty) : env.bindings)

-- | Localized type errors utilizing parsed SourceSpans
data TypeError = MkTypeError
  { msg :: !Text
  , span :: !SourceSpan
  } deriving (Show, Eq, Generic)

-- | Extract a span from an Expr to attach to localized errors.
getSpan :: Expr -> SourceSpan
getSpan = \case
  Var sp _     -> sp
  Lit sp _     -> sp
  Lam sp _ _ _ -> sp
  App sp _ _   -> sp
  Let sp _ _ _ -> sp
  Ann sp _ _   -> sp

-- | Synthesize a type for an expression (Inference Phase)
infer
  :: forall r ex es. (r :> es, ex :> es)
  => Reader Env r -> Exception TypeError ex -> Expr -> Eff es Type
infer env ex expr = 
  case expr of
    Lit sp _ -> pure $ TInt sp

    Var sp x -> do
      currentEnv <- ask env
      case lookup x currentEnv.bindings of
        Just ty -> pure ty
        Nothing -> throw ex $ MkTypeError ("Unbound variable: " <> x) sp

    Ann _ e ty -> do
      check env ex e ty
      pure ty

    App _ f x -> do
      -- Synthesize the function's type
      fTy <- infer env ex f
      case fTy of
        TArrow _ paramTy retTy -> do
          -- Push the known parameter type down to the argument
          check env ex x paramTy
          pure retTy
        _ -> throw ex $ MkTypeError "Expected a function in application" (getSpan f)
    
    Lam sp x mTy body ->
      case mTy of
        Just paramTy -> do
          -- With an explicit annotation, we can synthesize the lambda type
          bodyTy <- local env (extendEnv x paramTy) (infer env ex body)
          pure $ TArrow sp paramTy bodyTy
        Nothing ->
          throw ex $ MkTypeError "Cannot infer type of unannotated lambda. Add an annotation or use it in a checking context." sp

    Let _ x val body -> do
      -- Koka-style FBIP relies on explicit let-bindings.
      -- We strictly synthesize the bound value first.
      valTy <- infer env ex val
      local env (extendEnv x valTy) (infer env ex body)

-- | Verify that an expression satisfies a given type (Checking phase).
check 
  :: forall r ex es. (r :> es, ex :> es)
  => Reader Env r -> Exception TypeError ex -> Expr -> Type -> Eff es ()
check env ex expr expectedTy = 
  case (expr, expectedTy) of
    -- Unannotated lambdas can be checked against known function types
    (Lam _ x Nothing body, TArrow _ paramTy retTy) -> do
      local env (extendEnv x paramTy) (check env ex body retTy)

    -- Catch invalid checking contexts for unannotated lambdas before falling back
    (Lam sp _ Nothing _, _) ->
      throw ex $ MkTypeError "Type mismatch: Expected a non-function type, but got a lambda." sp
      
    -- Fallback: Synthesize the type and verify subsumption/unification
    _ -> do
      inferredTy <- infer env ex expr
      subsumes ex inferredTy expectedTy (getSpan expr)

-- | Verify that the inferred type subsumes the expected type.
subsumes
  :: forall ex es. (ex :> es)
  => Exception TypeError ex -> Type -> Type -> SourceSpan -> Eff es ()
subsumes ex inferred expected sp =
  -- Placeholder structural equality.
  -- This is the bottleneck where unification logic and Rank-2 skolemization
  -- will be inserted in a future phase.
  if typesMatch inferred expected
  then pure ()
  else throw ex $ MkTypeError "Type mismatch" sp

-- | Simplistic structural type equality, ignoring AST source spans.
typesMatch :: Type -> Type -> Bool
typesMatch t1 t2 = case (t1,t2) of
  (TInt _, TInt _) -> True
  (TVar _ a, TVar _ b) -> a == b
  (TArrow _ p1 r1, TArrow _ p2 r2) -> typesMatch p1 p2 && typesMatch r1 r2
  _ -> False
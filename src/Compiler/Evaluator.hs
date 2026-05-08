module Compiler.Evaluator
  ( Value(..)
  , EvalError(..)
  , evalCore
  ) where

import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import GHC.Generics (Generic)

import Bluefin.Eff ((:>), Eff, runPureEff)
import Bluefin.Exception (Exception, throw, try)
import Bluefin.Reader (Reader, ask, runReader)

import Compiler.AST (Literal, SourceSpan)
import Compiler.AST.Core

type Env = Map Text Value
type EvalRes a = Either EvalError a

-- | Runtime value model for the initial evaluator slice.
data Value
  = VLit Literal
  | VClosure Env CorePattern CoreExpr
  | VVariant Text Value
  | VRecord [(Text, Value)]
  deriving (Show, Eq, Generic)

-- | Evaluator error model for initial evaluator slice.
data EvalError
  = EvalUnboundVar SourceSpan Text
  | EvalNonFunctionApp SourceSpan Value
  | EvalPatternMismatch SourceSpan CorePattern Value
  | EvalNonExhaustiveCase SourceSpan Value
  | EvalMissingField SourceSpan Text Value
  | EvalNotImplemented SourceSpan Text
  deriving (Show, Eq, Generic)

-- | Evaluate a Core expression from an empty environment
evalCore :: CoreExpr -> Either EvalError Value
evalCore expr =
  runPureEff $ try \ex ->
  runReader Map.empty \env ->
  evalIn env ex expr

evalIn 
  :: forall r ex es. (r :> es, ex :> es) 
  => Reader Env r -> Exception EvalError ex -> CoreExpr -> Eff es Value
evalIn env ex expr  = 
  case expr of
    CVar sp name -> do
      rho <- ask env
      case Map.lookup name rho of
        Just value -> pure value
        Nothing -> throw ex (EvalUnboundVar sp name)
    
    CLit _ lit ->
      pure (VLit lit)

    CLam _ pat body -> do
      rho <- ask env
      pure (VClosure rho pat body)

    CApp sp fn arg -> do
      fnVal <- evalIn env ex fn
      argVal <- evalIn env ex arg
      case fnVal of
        VClosure closureEnv pat body ->
          case matchPattern sp pat argVal of
            Left err -> throw ex err
            Right binds ->
              runReader (Map.union binds closureEnv) \envBody ->
                evalIn envBody ex body
        nonFn ->
          throw ex (EvalNonFunctionApp sp nonFn)
    
    CLet sp pat rhs body -> do
      rhsVal <- evalIn env ex rhs
      case matchPattern sp pat rhsVal of
        Left err -> throw ex err
        Right binds -> do
          rho <- ask env
          runReader (Map.union binds rho) \envBody ->
            evalIn envBody ex body

    CCase sp scrutinee branches -> do
      scrutVal <- evalIn env ex scrutinee
      evalCaseBranches env ex sp scrutVal branches

    CVariant _ label payload -> do
      payloadVal <- evalIn env ex payload
      pure (VVariant label payloadVal)

    CRecord _ fields -> do
      fieldVals <- traverse (\(label, e) -> (label,) <$> evalIn env ex e) fields
      pure (VRecord fieldVals)

    CSelect sp record label -> do
      recVal <- evalIn env ex record
      case recVal of
        VRecord kvs ->
          case lookup label kvs of
            Just v -> pure v
            Nothing -> throw ex (EvalMissingField sp label recVal)
        _notRecord ->
          throw ex (EvalNotImplemented sp ("CSelect on non-record value: " <> label))

-- | Evaluate case branches in source order using first-match semantics
evalCaseBranches 
  :: forall r ex es. (r :> es, ex :> es)
  => Reader Env r -> Exception EvalError ex -> SourceSpan -> Value -> [(CorePattern, CoreExpr)] -> Eff es Value
evalCaseBranches env ex caseSp scrutVal branches =
  go branches
  where
    go [] = throw ex (EvalNonExhaustiveCase caseSp scrutVal)
    go ((pat, body) : rest) =
      case matchPattern caseSp pat scrutVal of
        Left _  -> go rest
        Right binds -> do
          rho <- ask env
          runReader (Map.union binds rho) \envBranch ->
            evalIn envBranch ex body

matchPattern :: SourceSpan -> CorePattern -> Value -> EvalRes Env
matchPattern appSpan pat value = 
  case pat of
    CPVar _ name -> Right (Map.singleton name value)

    CPWildcard _ -> Right (Map.empty)

    CPLit _ lit ->
      case value of
        VLit lit'
          | lit == lit' -> Right Map.empty
          | otherwise -> Left (EvalPatternMismatch appSpan pat value)
        _ ->
          Left (EvalPatternMismatch appSpan pat value)

    CPVariant _ label inner ->
      case value of
        VVariant label' payload
          | label == label' -> matchPattern appSpan inner payload
          | otherwise -> Left (EvalPatternMismatch appSpan pat value)
        _ ->
          Left (EvalPatternMismatch  appSpan pat value)

    CPRecord _ fields ->
      case value of
        VRecord kvs -> do
          let recordMap = Map.fromList kvs
          subBinds <- traverse (matchRecordField appSpan recordMap) fields
          pure (Map.unions subBinds)
        _ ->
          Left (EvalPatternMismatch appSpan pat value)

matchRecordField :: SourceSpan -> Env -> (Text, CorePattern) -> EvalRes Env
matchRecordField appSpan recordMap (label, pat) =
  case Map.lookup label recordMap of
    Nothing ->
      Left (EvalPatternMismatch appSpan (CPRecord appSpan [(label, pat)]) (VRecord (Map.toList recordMap)))
    Just fieldVal ->
      matchPattern appSpan pat fieldVal

        
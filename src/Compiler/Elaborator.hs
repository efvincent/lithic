{-# OPTIONS_GHC -Wno-incomplete-patterns #-}
module Compiler.Elaborator where

import Data.Text (Text)
import GHC.Generics (Generic)

import Compiler.AST
import Compiler.AST.Core

-- | Elaboration errors when translating surface AST to Core AST
data ElabError = MkElabError
  { msg :: !Text
  , span :: !SourceSpan
  } deriving (Show, Eq, Generic)

-- | Elaborate a surface expression into a core expression
elabExpr :: Expr -> Either ElabError CoreExpr
elabExpr = \case
  Var sp name -> Right (CVar sp name)
  Lit sp lit -> Right (CLit sp lit)
  Lam sp pat _ body -> do
    cpat <- elabPattern pat
    cbody <- elabExpr body
    Right (CLam sp cpat cbody)
  App sp fn arg -> do
    cfn <- elabExpr fn
    carg <- elabExpr arg
    Right (CApp sp cfn carg)
  Let sp pat rhs body -> do
    cpat <- elabPattern pat
    crhs <- elabExpr rhs
    cbody <- elabExpr body
    Right (CLet sp cpat crhs cbody)
  Case sp scrutinee branches -> do
    cscrut <- elabExpr scrutinee
    cbranches <- traverse elabBranch branches
    Right (CCase sp cscrut cbranches)
  Variant sp label payload -> do
    cpayload <- elabExpr payload
    Right (CVariant sp label cpayload)
  RecEmpty sp -> Right (CRecord sp [])
  expr@(RecExtend sp _ _ _ ) -> do
    fields <- collectRecordFields expr
    cfields <- traverse (\(label, e) -> (label, ) <$> elabExpr e) fields
    Right (CRecord sp cfields) 
  RecSelect sp recExpr label -> do
    crec <- elabExpr recExpr
    Right (CSelect sp crec label)
  Ann _ inner _ -> elabExpr inner
  RecUpdate sp _ _ _ _ ->
    elabFail sp "RecUpdate is out of scope for the initial Core subset."
  Unary sp _ _ ->
    elabFail sp "Unary operations are not yet in the initial Core subset."
  Binary sp _ _ _ ->
    elabFail sp "Binary operations are not yet in the initial Core subset."

-- | Elaborate a surface pattern into a core pattern
elabPattern :: Pattern -> Either ElabError CorePattern
elabPattern = \case
  PVar sp name -> Right (CPVar sp name)
  PWildcard sp -> Right (CPWildcard sp)
  PLit sp lit -> Right (CPLit sp lit)
  PVariant sp label inner -> do
    cinner <- elabPattern inner
    Right $ CPVariant sp label cinner
  PRecord sp fields -> do
    cfields <- traverse (\(label, p) -> (label,) <$> elabPattern p) fields
    Right $ CPRecord sp cfields

elabBranch :: (Pattern, Expr) -> Either ElabError (CorePattern, CoreExpr)
elabBranch (pat, body) = do
  cpat <- elabPattern pat 
  cbody <- elabExpr body
  Right (cpat, cbody)

collectRecordFields :: Expr -> Either ElabError ([(Text, Expr)])
collectRecordFields = go []
  where
    go :: [(Text, Expr)] -> Expr -> Either ElabError ([(Text, Expr)])
    go acc e =
      case e of
        RecEmpty _ -> Right (reverse acc)
        RecExtend _ label field rest -> go ((label, field) : acc) rest
        _ -> elabFail (getSpan e) "Record core lowering expects a closed literal ending in {}."

-- | construct a typed elaboration failure
elabFail :: forall a. SourceSpan -> Text -> Either ElabError a
elabFail sp message = Left (MkElabError message sp)
-- | Surface-to-Core elaboration entry points.
-- Includes expression elaboration plus Phase 9H top-level declaration routing.
module Compiler.Elaborator where

import Data.Text (Text)
import GHC.Generics (Generic)

import Compiler.AST
import Compiler.AST.Core

-- | Elaboration errors when translating surface AST to Core AST
data ElabError = MkElabError
  { msg :: !Text
  , span :: !Span
  } deriving (Show, Eq, Generic)

-- | Elaborate a surface top-level node into a core top-level node
elabTopLevel :: TopLevel -> Either ElabError CoreTopLevel
elabTopLevel = \case
  TExpr e -> CTExpr <$> elabExpr e
  TDecl d -> CTDecl <$> elabDecl d

-- | Elaborate a surface declaration into a core declaration.
-- Phase 9H first slice supports named definitions and signatures.
elabDecl :: Decl -> Either ElabError CoreDecl
elabDecl = \case
  DeclSig sp name ty ->
    Right (CDeclSig sp name ty)
  DeclDef sp pat rhs ->
    case pat of
      PVar _ name -> do
        crhs <- elabExpr rhs
        Right (CDeclDef sp name crhs)
      _ ->
        elabFail (getPatternSpan pat)
          "Top-level declaration elaboration currently requires a named binder."
    

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
  Unary sp UMinus e -> do
    ce <- elabExpr e
    Right (CNeg sp ce)
  Binary sp op e1 e2 -> do
    ce1 <- elabExpr e1
    ce2 <- elabExpr e2
    Right (CBinOp sp (toArithOp op) ce1 ce2)

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

-- | Elaborate one case branch pair.
elabBranch :: (Pattern, Expr) -> Either ElabError (CorePattern, CoreExpr)
elabBranch (pat, body) = do
  cpat <- elabPattern pat 
  cbody <- elabExpr body
  Right (cpat, cbody)

-- | Collect fields from nested record extensions, requiring a closed empty-record tail.
collectRecordFields :: Expr -> Either ElabError ([(Text, Expr)])
collectRecordFields = go []
  where
    go :: [(Text, Expr)] -> Expr -> Either ElabError ([(Text, Expr)])
    go acc e =
      case e of
        RecEmpty _ -> Right (reverse acc)
        RecExtend _ label field rest -> go ((label, field) : acc) rest
        _ -> elabFail (getSpan e) "Record core lowering expects a closed literal ending in {}."

-- | Convert a surface binary operator to a Core arithmetic operator.
toArithOp :: BinOp -> ArithOp
toArithOp = \case
  OpAdd -> AAdd
  OpSub -> ASub
  OpMul -> AMul
  OpDiv -> ADiv

-- | construct a typed elaboration failure
elabFail :: forall a. Span -> Text -> Either ElabError a
elabFail sp message = Left (MkElabError message sp)
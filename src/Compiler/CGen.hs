-- | Phase 10 C backend scaffold.
-- Provides a minimal declaration-level entry point for C code emission
module Compiler.CGen
  ( cgenProgram
  ) where

import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Lazy as TL
import qualified Data.Text.Lazy.Builder as TB
import Data.Char (isAlphaNum)

import Compiler.AST (Literal(..))
import Compiler.AST.Core (CoreDecl(..), CoreExpr(..), CorePattern(..))

-- | Emit a C translation-unit scaffold for a list of core declarations.
--
-- This uses a "best-balance" structure:
-- 1. one static prelude block as a chunk
-- 2. dynamic declaration fragments appended via Builder
cgenProgram :: [CoreDecl] -> Text
cgenProgram decls =
  TL.toStrict $
  TB.toLazyText $
  cPreludeChunk
    <> cDeclCountComment decls
    <> cDeclarationSection decls

-- | Static C prelude kept as one chunk for readability.
cPreludeChunk :: TB.Builder
cPreludeChunk = TB.fromText cPreludeText

-- | Raw prelude text for generated C output.
cPreludeText :: Text
cPreludeText =
  "#include <stdint.h>\n\
  \#include <stdbool.h>\n\
  \#include <stdlib.h>\n\
  \#include <stdio.h>\n\
  \\n\
  \/* Lithic Phase 10 C backend scaffold */\n\
  \\n"

-- | Emit a declaration-count comment
cDeclCountComment :: [CoreDecl] -> TB.Builder
cDeclCountComment decls =
  TB.fromText $
  "/* declarations: " <> T.pack (show (length decls)) <> " */\n\n"

-- | Emit all declaration fragments separated by one blank line.
cDeclarationSection :: [CoreDecl] -> TB.Builder
cDeclarationSection decls =
  intercalateBuilders (TB.fromText "\n") (map cgenDecl decls)

-- | Emit a placeholder C fragment for one top-level core declaration
cgenDecl :: CoreDecl -> TB.Builder
cgenDecl = \case
  CDeclSig _ name _ ->
    TB.fromText $
    "/* signature (not yet emitted): " <> name <> " */\n"
  CDeclDef _ name rhs ->
    case collectLamArity rhs of
      Just (arity, body) ->
        TB.fromText $
        "/* definition: " <> name <> " */\n"
        <> "/* rhs: CLam */\n"
        <> "static void " <> cFunctionName name <> "(void) {\n"
        <> "  /* arity: " <> tshow arity <> " */\n"
        <> cgenFunctionBody body
        <> "}\n"
      Nothing ->
        TB.fromText $
        "/* definition: " <> name <> " */\n"
        <> "/* rhs: " <> cgenExprTag rhs <> " */\n"
        <> "/* unsupported(phase10-c2): expected top-level lambda */\n"

-- | Collect lambda arity from a top-level declaration RHS.
-- Returns arity and terminal body expression.
collectLamArity :: CoreExpr -> Maybe (Int, CoreExpr)
collectLamArity expr = go 0 expr
  where
    go n (CLam _ _ body) = go (n + 1) body
    go 0 _ = Nothing
    go n body = Just (n, body)

-- | Convert a declaration name into a C-safe function identifier.
cFunctionName :: Text -> Text
cFunctionName name = "lithic_" <> T.map normalize name
  where
    normalize ch
      | isAlphaNum ch || ch == '_' = ch
      | otherwise = '_'

-- | Compact show helper.
tshow :: forall a. Show a => a -> Text
tshow = T.pack . show

-- | Return a compact constructor tag for scaffold diagnostics / comments.
cgenExprTag :: CoreExpr -> Text
cgenExprTag = \case
  CVar{}     -> "CVar"
  CLit{}     -> "CLit"
  CLam{}     -> "CLam"
  CApp{}     -> "CApp"
  CLet{}     -> "CLet"
  CCase{}    -> "CCase"
  CVariant{} -> "CVariant"
  CRecord{}  -> "CRecord"
  CSelect{}  -> "CSelect"

-- | Emit the current Phase-10 C2 function-body scaffold.
-- Supports explicit first-pass call-shape placeholders and a uniform unsupported fallback.
cgenFunctionBody :: CoreExpr -> Text
cgenFunctionBody = \case
  CLit _ lit ->
    "  /* emit literal: " <> cgenLiteralTag lit <> " */\n"
    <> "  return;\n"
  CVar _ varName ->
    "  /* variable terminal: " <> varName <> " */\n"
    <> "  return;\n"
  CLet _ pat rhs body ->
    "  /* let binding: " <> cgenPatternTag pat <> " */\n"
    <> "  /* let rhs: " <> cgenExprTag rhs <> " */\n"
    <> cgenFunctionBody body
  CApp _ fn arg ->
    "  /* app fn: " <> cgenExprTag fn <> " */\n"
    <> "  /* app arg: " <> cgenExprTag arg <> " */\n"
    <> "  " <> cgenCallTarget fn <> "(" <> cgenCallArg arg <>");\n"
    <> "  return;\n"
  CCase _ scrut branches ->
    "  /* case scrut: " <> cgenExprTag scrut <> " */\n"
    <> "  /* case branches: " <> tshow (length branches) <> " */\n"
    <> "  switch (0) {\n"
    <> cgenCaseBranchStubs branches
    <> "    default:\n"
    <> "      break;\n"
    <> "  }\n"
    <> "  return;\n"
  CVariant _ ctor payload ->
    "  /* variant ctor: " <> ctor <> " */\n"
    <> "  /* variant payload: " <> cgenExprTag payload <> " */\n"
    <> "  lithic_variant_make(" <> cgenVariantTag ctor <> ", " <> cgenCallArg payload <> ");\n"
    <> "  return;\n"
  CRecord _ fields ->
    "  /* record field count: " <> tshow (length fields) <> " */\n"
    <> "  lithic_record_make(" <> tshow (length fields) <> ");\n"
    <> "  return;\n"
  CSelect _ recordExpr fieldName ->
    "  /* select record: " <> cgenExprTag recordExpr <> " */\n"
    <> "  /* select field: " <> fieldName <> " */\n"
    <> "  lithic_record_select(" <> cgenCallArg recordExpr <> ", " <> cgenFieldTag fieldName <> ");\n"
    <> "  return;\n"
  other ->
    cgenUnsupportedBody other

-- | Emit a compact pattern tag for placeholder let-binding comments.
cgenPatternTag :: CorePattern -> Text
cgenPatternTag = \case
  CPVar{}      -> "CPVar"
  CPWildcard{} -> "CPWildcard"
  CPLit{}      -> "CPLit"
  CPVariant{}  -> "CPVariant"
  CPRecord{}   -> "CPRecord"

-- | Emit a compact literal kind tag for placeholder body comments.
cgenLiteralTag :: Literal -> Text
cgenLiteralTag = \case
  LInt{}    -> "Int"
  LFloat{}  -> "Float"
  LString{} -> "String"
  LBool{}   -> "Bool"

-- | Emit a first-pass call target for CApp lowering.
-- Variable function heads become C symbols; other heads stay explicit placeholders.
cgenCallTarget :: CoreExpr -> Text
cgenCallTarget = \case
  CVar _ fnName -> cFunctionName fnName
  other -> "/* unsupported-call-target:" <> cgenExprTag other <> " */ lithic_unsupported_fn"

-- | Emit a first-pass call argument placeholder.
-- Variable and literal args get simple emitted forms; all others stay explicit placeholders.
cgenCallArg :: CoreExpr -> Text
cgenCallArg = \case
  CVar _ argName -> argName
  CLit _ lit -> "/* lit:" <> cgenLiteralTag lit <> " */ 0"
  other -> "/* unsupported-call-arg:" <> cgenExprTag other <> " */ 0"

-- | Emit a first-pass variant tag placeholder for constructor names.
cgenVariantTag :: Text -> Text
cgenVariantTag ctor = "/* ctor:" <> ctor <> " */ 0"

-- | Emit a first-pass field tag placeholder for record selection.
cgenFieldTag :: Text -> Text
cgenFieldTag fieldName = "/* field:" <> fieldName <> " */ 0"

-- | Emit a normalized unsupported marker for body forms not yet lowered.
cgenUnsupportedBody :: CoreExpr -> Text
cgenUnsupportedBody expr =
  "  /* unsupported(phase10-c2): body form " <> cgenExprTag expr <> " */\n"

-- | Emit a first-pass switch skeleton for case branches.
-- Branch patterns/bodies are surfaced as comments to keep generation explicit and compilable.
cgenCaseBranchStubs :: [(CorePattern, CoreExpr)] -> Text
cgenCaseBranchStubs branches =
  T.concat (zipWith emit [0 :: Int ..] branches)
  where
    emit ix (pat, body) =
      "    case " <> tshow ix <> ":\n\
      \      /* pattern: " <> cgenPatternTag pat <> " */\n\
      \      /* body: " <> cgenExprTag body <> " */\n\
      \      break;\n"

-- | Build equiv of intercalation for generated chunks.
intercalateBuilders :: TB.Builder -> [TB.Builder] -> TB.Builder
intercalateBuilders _ [] = mempty
intercalateBuilders _ [x] = x
intercalateBuilders sep (x:xs) = x <> sep <> intercalateBuilders sep xs



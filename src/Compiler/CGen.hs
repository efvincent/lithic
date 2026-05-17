-- | Phase 10 C backend scaffold.
-- Provides a minimal declaration-level entry point for C code emission
module Compiler.CGen
  ( cgenProgram
  ) where

import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Lazy as TL
import qualified Data.Text.Lazy.Builder as TB

import Compiler.AST.Core (CoreDecl(..), CoreExpr(..))

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
  \#inclde <stdbool.h>\n\
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
    TB.fromText $
    "/* definition: " <> name <> " */\n"
    <> "/* rhs: " <> cgenExprTag rhs <> " */\n"
    <> "/* TODO(phase10-c2): lower declaration body */\n"

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

-- | Build equiv of intercalation for generated chunks.
intercalateBuilders :: TB.Builder -> [TB.Builder] -> TB.Builder
intercalateBuilders _ [] = mempty
intercalateBuilders _ [x] = x
intercalateBuilders sep (x:xs) = x <> sep <> intercalateBuilders sep xs



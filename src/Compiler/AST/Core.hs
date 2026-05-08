module Compiler.AST.Core where

import Data.Text (Text)
import GHC.Generics (Generic)

import Compiler.AST (Literal, SourceSpan)

-- | Core patterns for the Phase 8 evaluator subset
data CorePattern
  = CPVar      SourceSpan Text
  | CPWildcard SourceSpan
  | CPLit      SourceSpan Literal
  | CPVariant  SourceSpan Text CorePattern
  | CPRecord   SourceSpan [(Text, CorePattern)]
  deriving (Show, Eq, Generic)

-- | Core expressions for the Phase 8 evaluator subset.
data CoreExpr
  = CVar     SourceSpan Text
  | CLit     SourceSpan Literal
  | CLam     SourceSpan CorePattern CoreExpr
  | CApp     SourceSpan CoreExpr CoreExpr
  | CLet     SourceSpan CorePattern CoreExpr CoreExpr
  | CCase    SourceSpan CoreExpr [(CorePattern, CoreExpr)]
  | CVariant SourceSpan Text CoreExpr
  | CRecord  SourceSpan [(Text, CoreExpr)]
  | CSelect  SourceSpan CoreExpr Text
  deriving (Show, Eq, Generic)

getCorePatternSpan :: CorePattern -> SourceSpan
getCorePatternSpan = \case
    CPVar sp _       -> sp
    CPWildcard sp    -> sp
    CPLit sp _       -> sp
    CPVariant sp _ _ -> sp
    CPRecord sp _    -> sp

getCoreSpan :: CoreExpr -> SourceSpan
getCoreSpan = \case
  CVar sp _       -> sp
  CLit sp _       -> sp
  CLam sp _ _     -> sp
  CApp sp _ _     -> sp
  CLet sp _ _ _   -> sp
  CCase sp _ _    -> sp
  CVariant sp _ _ -> sp
  CRecord sp _    -> sp
  CSelect sp _ _  -> sp
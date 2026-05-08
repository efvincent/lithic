module Compiler.AST.Core where

import Data.Text (Text)
import GHC.Generics (Generic)

import Compiler.AST (Literal, Span)

-- | Core patterns for the Phase 8 evaluator subset
data CorePattern
  = CPVar      Span Text
  | CPWildcard Span
  | CPLit      Span Literal
  | CPVariant  Span Text CorePattern
  | CPRecord   Span [(Text, CorePattern)]
  deriving (Show, Eq, Generic)

-- | Core expressions for the Phase 8 evaluator subset.
data CoreExpr
  = CVar     Span Text
  | CLit     Span Literal
  | CLam     Span CorePattern CoreExpr
  | CApp     Span CoreExpr CoreExpr
  | CLet     Span CorePattern CoreExpr CoreExpr
  | CCase    Span CoreExpr [(CorePattern, CoreExpr)]
  | CVariant Span Text CoreExpr
  | CRecord  Span [(Text, CoreExpr)]
  | CSelect  Span CoreExpr Text
  deriving (Show, Eq, Generic)

getCorePatternSpan :: CorePattern -> Span
getCorePatternSpan = \case
    CPVar sp _       -> sp
    CPWildcard sp    -> sp
    CPLit sp _       -> sp
    CPVariant sp _ _ -> sp
    CPRecord sp _    -> sp

getCoreSpan :: CoreExpr -> Span
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
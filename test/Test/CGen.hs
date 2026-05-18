-- | Unit tests for Phase 10 C code generation scaffold behavior.
module Test.CGen
  ( cgenUnitTests
  ) where

import qualified Data.Text as T
import Data.List (isPrefixOf, tails)

import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (testCase, (@?))

import Compiler.AST (Span(..), Type(..))
import Compiler.AST.Core (CoreDecl(..), CoreExpr(..), CorePattern(..))
import Compiler.CGen (cgenProgram)

-- | Stable placeholder span used by synthetic Core values in tests.
sp0 :: Span
sp0 = MkSpan 1 1 1 1

cgenUnitTests :: TestTree
cgenUnitTests =
  testGroup "CGen Unit Tests"
    [ testCase "prelude includes required standard headers" $
        let out = cgenProgram []
         in do
          T.isInfixOf "#include <stdint.h>" out @? "missing stdint include"
          T.isInfixOf "#include <stdbool.h>" out @? "missing stdbool include"
          T.isInfixOf "#include <stdlib.h>" out @? "missing stdlib include"
          T.isInfixOf "#include <stdio.h>" out @? "missing stdio include"

    , testCase "declaration count comment reflects input size" $
        let out = cgenProgram [sigDecl, defDecl]
         in T.isInfixOf "/* declarations: 2 */" out
              @? "declaration count comment should match declaration list size"

    , testCase "signature and non-lambda definition placeholders are emitted" $
        let out = cgenProgram [sigDecl, defDecl]
         in do
          T.isInfixOf "/* signature (not yet emitted): id */" out
            @? "signature placeholder comment missing"
          T.isInfixOf "/* definition: id */" out
            @? "definition placeholder comment missing"
          T.isInfixOf "/* rhs: CVar */" out
            @? "definition should include rhs constructor tag"
          T.isInfixOf "/* unsupported(phase10-c2): expected top-level lambda */" out
            @? "non-lambda top-level definitions should stay explicit"

    , testCase "lambda definition emits function skeleton and app placeholder shape" $
        let out = cgenProgram [defAppDecl]
         in do
          T.isInfixOf "static void lithic_applyFn(void) {" out
            @? "lambda definition should emit a named C function"
          T.isInfixOf "/* arity: 1 */" out
            @? "single lambda parameter should report arity 1"
          T.isInfixOf "lithic_unsupported_fn(0);" out
            @? "application body should emit compile-safe placeholder call"

    , testCase "case bodies emit switch skeleton" $
        let out = cgenProgram [defCaseDecl]
         in do
          T.isInfixOf "switch (0) {" out
            @? "case body should emit switch scaffold"
          T.isInfixOf "case 0:" out
            @? "first branch stub should be present"
          T.isInfixOf "/* pattern: CPVar */" out
            @? "branch pattern tag should be surfaced"
          T.isInfixOf "/* body: CVar */" out
            @? "branch body tag should be surfaced"

    , testCase "variant, record, and select bodies emit runtime call placeholders" $
        let out = cgenProgram [defVariantDecl, defRecordDecl, defSelectDecl]
         in do
          T.isInfixOf "lithic_variant_make(" out
            @? "variant body should emit variant constructor call placeholder"
          T.isInfixOf "lithic_record_make(0);" out
            @? "record body should emit record constructor call placeholder"
          T.isInfixOf "lithic_record_select(" out
            @? "select body should emit field selection call placeholder"

    , testCase "declarations are emitted in input order" $
        let out = cgenProgram [defADecl, defBDecl]
            posA = firstIndex "/* definition: a */" out
            posB = firstIndex "/* definition: b */" out
         in do
          T.isInfixOf "/* definition: a */" out @? "definition a missing"
          T.isInfixOf "/* definition: b */" out @? "definition b missing"
          (posA >= 0 && posB >= 0 && posA < posB) @? "definitions should preserve input order"

    , testCase "adjacent declarations have a single blank-line separator" $
        let out = cgenProgram [sigDecl, defDecl]
         in T.isInfixOf
              "/* signature (not yet emitted): id */\n\n/* definition: id */"
              out
              @? "expected exactly one blank line between adjacent declarations"
    ]
  where
    sigDecl = CDeclSig sp0 "id" (TInt sp0)
    defDecl = CDeclDef sp0 "id" (CVar sp0 "id")
    defADecl = CDeclDef sp0 "a" (CVar sp0 "a")
    defBDecl = CDeclDef sp0 "b" (CVar sp0 "b")
    defAppDecl =
      CDeclDef sp0 "applyFn"
        (CLam sp0 (CPVar sp0 "x") (CApp sp0 (CVar sp0 "f") (CVar sp0 "x")))
    defCaseDecl =
      CDeclDef sp0 "caseFn"
        (CLam sp0 (CPVar sp0 "x")
          (CCase sp0 (CVar sp0 "x")
            [(CPVar sp0 "y", CVar sp0 "y")]))
    defVariantDecl =
      CDeclDef sp0 "mkOk"
        (CLam sp0 (CPVar sp0 "x") (CVariant sp0 "Ok" (CVar sp0 "x")))
    defRecordDecl =
      CDeclDef sp0 "mkRec"
        (CLam sp0 (CPVar sp0 "x") (CRecord sp0 []))
    defSelectDecl =
      CDeclDef sp0 "selRec"
        (CLam sp0 (CPVar sp0 "r") (CSelect sp0 (CVar sp0 "r") "x") )

    firstIndex needle txt =
      let n = T.unpack needle
          hay = T.unpack txt
          matches = [i | (i, s) <- zip [0 :: Int ..] (tails hay), n `isPrefixOf` s]
       in case matches of
            [] -> -1
            i : _ -> i

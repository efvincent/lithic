-- | Unit tests for Phase 10 C code generation — C2.1 emission.
-- Covers: typed function signatures, primitive literal emission, variable
-- terminals, let-to-stack-local lowering, and the monomorphism guard.
module Test.CGen
  ( cgenUnitTests
  ) where

import qualified Data.Text as T
import Data.List (isPrefixOf, tails)

import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (testCase, (@?))

import Compiler.AST (Span(..), Type(..))
import Compiler.AST.Core (CoreDecl(..), CoreExpr(..), CorePattern(..))
import Compiler.AST (Literal(..))
import Compiler.CGen (cgenProgram)

-- | Stable placeholder span used by synthetic Core values in tests.
sp0 :: Span
sp0 = MkSpan 1 1 1 1

cgenUnitTests :: TestTree
cgenUnitTests =
  testGroup "CGen Unit Tests"
    [ -- ── Scaffold contracts (unchanged from C2 scaffold) ─────────────────
      testCase "prelude includes required standard headers" $
        let out = cgenProgram []
         in do
          T.isInfixOf "#include <stdint.h>" out @? "missing stdint include"
          T.isInfixOf "#include <stdbool.h>" out @? "missing stdbool include"
          T.isInfixOf "#include <stdlib.h>" out @? "missing stdlib include"
          T.isInfixOf "#include <stdio.h>" out @? "missing stdio include"

    , testCase "declaration count comment reflects input size" $
        let out = cgenProgram [(sigDecl, Nothing), (defDecl, Nothing)]
         in T.isInfixOf "/* declarations: 2 */" out
              @? "declaration count comment should match declaration list size"

    , testCase "signature placeholder and non-lambda constant are emitted" $
        let out = cgenProgram [(sigDecl, Nothing), (defDecl, Nothing)]
         in do
          T.isInfixOf "/* signature (not yet emitted): id */" out
            @? "signature placeholder comment missing"
          T.isInfixOf "/* definition: id */" out
            @? "definition placeholder comment missing"
          -- non-lambda def is now a global constant declaration (C2.1)
          T.isInfixOf "intptr_t lithic_id =" out
            @? "non-lambda definition should emit as global constant"

    , testCase "lambda definition emits typed function skeleton" $
        let out = cgenProgram [(defAppDecl, Nothing)]
         in do
          -- C2.1: parameters are typed; no type supplied so intptr_t is used
          T.isInfixOf "intptr_t lithic_applyFn(intptr_t x) {" out
            @? "lambda definition should emit typed named C function"
          T.isInfixOf "lithic_unsupported_fn(0);" out
            @? "application body should emit compile-safe placeholder call"

    , testCase "lambda definition with known type emits precise C signature" $
        let out = cgenProgram [(defLitBodyDecl, Just (TArrow sp0 (TInt sp0) (TInt sp0)))]
         in do
          T.isInfixOf "int64_t lithic_constFortyTwo(int64_t x) {" out
            @? "Int->Int type should yield int64_t signature"
          T.isInfixOf "return (int64_t)(int64_t)42;" out
            @? "Int literal body should emit typed return"

    , testCase "case bodies emit switch skeleton" $
        let out = cgenProgram [(defCaseDecl, Nothing)]
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
        let out = cgenProgram
              [ (defVariantDecl, Nothing)
              , (defRecordDecl,  Nothing)
              , (defSelectDecl,  Nothing)
              ]
         in do
          T.isInfixOf "lithic_variant_make(" out
            @? "variant body should emit variant constructor call placeholder"
          T.isInfixOf "lithic_record_make(0);" out
            @? "record body should emit record constructor call placeholder"
          T.isInfixOf "lithic_record_select(" out
            @? "select body should emit field selection call placeholder"

    , testCase "declarations are emitted in input order" $
        let out = cgenProgram [(defADecl, Nothing), (defBDecl, Nothing)]
            posA = firstIndex "/* definition: a */" out
            posB = firstIndex "/* definition: b */" out
         in do
          T.isInfixOf "/* definition: a */" out @? "definition a missing"
          T.isInfixOf "/* definition: b */" out @? "definition b missing"
          (posA >= 0 && posB >= 0 && posA < posB) @? "definitions should preserve input order"

    , testCase "adjacent declarations have at least one newline boundary" $
        let out = cgenProgram [(sigDecl, Nothing), (defDecl, Nothing)]
            sigNeedle = "/* signature (not yet emitted): id */"
            defNeedle = "/* definition: id */"
            (_, afterSigRaw) = T.breakOn sigNeedle out
            afterSig = T.drop (T.length sigNeedle) afterSigRaw
            (between, _) = T.breakOn defNeedle afterSig
         in ((sigNeedle `T.isInfixOf` out)
              && (defNeedle `T.isInfixOf` out)
              && T.any (== '\n') between)
              @? "expected at least one newline boundary between adjacent declarations"

    -- ── C2.1: actual emission tests ────────────────────────────────────────

    , testCase "Int literal body emits typed return statement" $
        let out = cgenProgram [(defLitBodyDecl, Nothing)]
          in T.isInfixOf "return (intptr_t)(int64_t)42;" out
            @? "Int literal body should emit return with intptr_t fallback coercion"

    , testCase "Bool True literal emits return 1" $
        let out = cgenProgram [(defTrueDecl, Nothing)]
          in T.isInfixOf "return (intptr_t)1;" out
            @? "True literal should emit return with intptr_t fallback coercion"

    , testCase "Bool False literal emits return 0" $
        let out = cgenProgram [(defFalseDecl, Nothing)]
          in T.isInfixOf "return (intptr_t)0;" out
            @? "False literal should emit return with intptr_t fallback coercion"

    , testCase "variable terminal emits return varname" $
        let out = cgenProgram [(defIdDecl, Nothing)]
         in T.isInfixOf "return x;" out
              @? "variable terminal should emit return <varName>;"

    , testCase "let CPVar binding emits stack local and recurses to body" $
        let out = cgenProgram [(defLetDecl, Nothing)]
         in do
          T.isInfixOf "intptr_t y = (intptr_t)(int64_t)1;" out
            @? "let CPVar binding should emit intptr_t local with explicit coercion"
          T.isInfixOf "return y;" out
            @? "let body (variable terminal) should be emitted after local"

    , testCase "polymorphic type triggers monomorphism guard" $
        let polyTy = TForall sp0 ["a"] (TArrow sp0 (TVar sp0 "a") (TVar sp0 "a"))
            out    = cgenProgram [(defIdDecl, Just polyTy)]
       in T.isInfixOf "codegen error: program is not fully monomorphic" out
              @? "TForall type should trigger the monomorphism guard"

    , testCase "unresolved meta type triggers monomorphism guard" $
        let metaTy = TArrow sp0 (TMeta sp0 0) (TMeta sp0 0)
            out    = cgenProgram [(defIdDecl, Just metaTy)]
       in T.isInfixOf "codegen error: program is not fully monomorphic" out
              @? "TMeta type should trigger the monomorphism guard"

    , testCase "Float literal body emits double return" $
        let out = cgenProgram [(defFloatDecl, Nothing)]
          in T.isInfixOf "return (intptr_t)(double)" out
            @? "Float literal body should emit return with intptr_t fallback coercion"

    , testCase "String literal body emits quoted string return" $
        let out = cgenProgram [(defStringDecl, Nothing)]
          in T.isInfixOf "return (intptr_t)\"hello\";" out
            @? "String literal body should emit return with intptr_t fallback coercion"
    ]
  where
    -- ── Shared synthetic declarations ──────────────────────────────────────
    sigDecl  = CDeclSig sp0 "id" (TInt sp0)
    defDecl  = CDeclDef sp0 "id" (CVar sp0 "id")
    defADecl = CDeclDef sp0 "a" (CVar sp0 "a")
    defBDecl = CDeclDef sp0 "b" (CVar sp0 "b")

    -- Single-param lambda with an application body (no type info)
    defAppDecl =
      CDeclDef sp0 "applyFn"
        (CLam sp0 (CPVar sp0 "x") (CApp sp0 (CVar sp0 "f") (CVar sp0 "x")))

    -- Single-param lambda with an Int literal body (used for typed-sig tests)
    defLitBodyDecl =
      CDeclDef sp0 "constFortyTwo"
        (CLam sp0 (CPVar sp0 "x") (CLit sp0 (LInt 42)))

    -- Single-param lambdas for Bool literal tests
    defTrueDecl  =
      CDeclDef sp0 "alwaysTrue"
        (CLam sp0 (CPVar sp0 "x") (CLit sp0 (LBool True)))
    defFalseDecl =
      CDeclDef sp0 "alwaysFalse"
        (CLam sp0 (CPVar sp0 "x") (CLit sp0 (LBool False)))

    -- Identity function: single-param lambda returning the parameter
    defIdDecl =
      CDeclDef sp0 "idFn"
        (CLam sp0 (CPVar sp0 "x") (CVar sp0 "x"))

    -- Let-binding: \x -> let y = 1 in y
    defLetDecl =
      CDeclDef sp0 "withLet"
        (CLam sp0 (CPVar sp0 "x")
          (CLet sp0 (CPVar sp0 "y") (CLit sp0 (LInt 1)) (CVar sp0 "y")))

    -- Float and String literal bodies
    defFloatDecl =
      CDeclDef sp0 "pi"
        (CLam sp0 (CPVar sp0 "x") (CLit sp0 (LFloat 3.14)))
    defStringDecl =
      CDeclDef sp0 "greeting"
        (CLam sp0 (CPVar sp0 "x") (CLit sp0 (LString "hello")))

    -- Case, variant, record, select (scaffold contract tests)
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
        (CLam sp0 (CPVar sp0 "r") (CSelect sp0 (CVar sp0 "r") "x"))

    -- | Find the first occurrence index of a needle in a Text, or -1 if absent.
    firstIndex needle txt =
      let n = T.unpack needle
          hay = T.unpack txt
          matches = [i | (i, s) <- zip [0 :: Int ..] (tails hay), n `isPrefixOf` s]
       in case matches of
            []    -> -1
            i : _ -> i

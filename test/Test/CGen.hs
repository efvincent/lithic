-- | Unit tests for Phase 10 C code generation.
-- Current focus: C3.5 case-expression and expression-value lowering on top of
-- the earlier emission contracts, monomorphism guard, and runtime helper ABI
-- checks.
module Test.CGen
  ( cgenUnitTests
  ) where

import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import Data.List (isPrefixOf, tails)
import Control.Exception (bracket)
import System.Directory (doesFileExist, removeFile)
import System.Exit (ExitCode(..))
import System.IO (hClose, openTempFile)
import System.Process (readProcessWithExitCode)

import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertFailure, testCase, (@?))

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
          T.isInfixOf "intptr_t lithic_id(void) {" out
            @? "non-lambda definition should emit as a zero-arg helper-backed function when it is not a static initializer"

    , testCase "lambda definition emits typed function with call lowering" $
        let out = cgenProgram [(defAppDecl, Nothing)]
         in do
          -- C2.1: parameters are typed; no type supplied so intptr_t is used
          T.isInfixOf "intptr_t lithic_applyFn(intptr_t x) {" out
            @? "lambda definition should emit typed named C function"
          T.isInfixOf "return (intptr_t)f(x);" out
            @? "supported var-call form should emit direct C call return"
          not (T.isInfixOf "lithic_unsupported_fn(0);" out)
            @? "supported var-call form should not use unsupported placeholder"

    , testCase "lambda definition with known type emits precise C signature" $
        let out = cgenProgram [(defLitBodyDecl, Just (TArrow sp0 (TInt sp0) (TInt sp0)))]
         in do
          T.isInfixOf "int64_t lithic_constFortyTwo(int64_t x) {" out
            @? "Int->Int type should yield int64_t signature"
          T.isInfixOf "return (int64_t)(int64_t)42;" out
            @? "Int literal body should emit typed return"

    , testCase "literal case lowering uses scrutinee value and preserves branch order" $
        let out = cgenProgram [(defCaseLitDecl, Nothing)]
            p0 = firstIndex "/* case branch 0 */" out
            p1 = firstIndex "/* case branch 1 */" out
         in do
          T.isInfixOf "int64_t lithic_case_scrut =" out
            @? "literal case should materialize an int scrutinee temporary"
          T.isInfixOf "if (lithic_case_scrut == (int64_t)1)" out
            @? "first literal branch should lower to concrete equality guard"
          T.isInfixOf "else if (lithic_case_scrut == (int64_t)2)" out
            @? "second literal branch should lower to concrete equality guard"
          (p0 >= 0 && p1 >= 0 && p0 < p1)
            @? "branch marker order should follow source branch order"
          not (T.isInfixOf "switch (0) {" out)
            @? "literal case lowering should not retain switch(0) placeholder"

    , testCase "variant and select lower through explicit temporaries" $
        let out = cgenProgram
              [ (defVariantDecl, Nothing)
              , (defSelectDecl,  Nothing)
              ]
         in do
          T.isInfixOf "intptr_t lithic_variant_payload_tmp = x;" out
            @? "variant lowering should materialize a payload temporary"
          T.isInfixOf "lithic_variant_make(" out
            @? "variant lowering should still call runtime helper"
          T.isInfixOf "intptr_t lithic_select_record_tmp = r;" out
            @? "select lowering should materialize a record temporary"
          T.isInfixOf "intptr_t lithic_select_field_tmp =" out
            @? "select lowering should materialize a field-tag temporary"
          T.isInfixOf "lithic_record_select(lithic_select_record_tmp, lithic_select_field_tmp);" out
            @? "select lowering should call helper with explicit temporaries"

    , testCase "record body remains explicit runtime helper placeholder" $
        let out = cgenProgram [(defRecordDecl, Nothing)]
         in do
          T.isInfixOf "lithic_variant_make(" out
            @? "variant helper should exist in prelude"
          T.isInfixOf "lithic_record_make(0);" out
            @? "record body should emit record constructor call placeholder"

    , testCase "unsupported call target emits explicit fallback marker" $
        let out = cgenProgram [(defUnsupportedCallTargetDecl, Nothing)]
         in do
          T.isInfixOf "unsupported-call-target: CLit" out
            @? "unsupported app target should emit explicit call-target diagnostic marker"
          T.isInfixOf "return (intptr_t)0;" out
            @? "unsupported app target should keep compile-safe placeholder return"

    , testCase "variant-headed case branches take precedence over literal-like dispatch" $
        let out = cgenProgram [(defUnsupportedCasePatternDecl, Nothing)]
         in do
          T.isInfixOf "intptr_t lithic_case_variant_tag = lithic_variant_tag(lithic_case_variant_scrut);" out
            @? "variant-headed branch sets should route through variant tag dispatch"
          not (T.isInfixOf "unsupported-case-scrutinee" out)
            @? "variant-headed branch sets should not fall back to unsupported-case-scrutinee"

    , testCase "variant case lowering uses runtime tag and payload helpers" $
        let out = cgenProgram [(defVariantCaseDecl, Nothing)]
         in do
          T.isInfixOf "intptr_t lithic_case_variant_tag = lithic_variant_tag(lithic_case_variant_scrut);" out
            @? "variant case lowering should compute a variant tag temp"
          T.isInfixOf "if (lithic_case_variant_tag ==" out
            @? "variant case lowering should emit guarded tag comparison branches"
          T.isInfixOf "intptr_t x = lithic_variant_payload(lithic_case_variant_scrut);" out
            @? "variant case lowering should bind payload for CPVar payload patterns"

    , testCase "bool variable case lowering emits concrete true/false guards" $
        let out = cgenProgram [(defCaseBoolVarDecl, Nothing)]
         in do
          T.isInfixOf "if (lithic_case_scrut != (intptr_t)0)" out
            @? "True branch should lower to non-zero guard"
          T.isInfixOf "else if (lithic_case_scrut == (intptr_t)0)" out
            @? "False branch should lower to zero guard"
          not (T.isInfixOf "unsupported-case-scrutinee" out)
            @? "bool variable scrutinee should not hit unsupported-case-scrutinee"

    , testCase "let-local direct call uses mangled callee name and compiles" $
        let out = cgenProgram [(defIdDecl, Nothing), (defLetCallDecl, Nothing)]
         in do
          T.isInfixOf "intptr_t y = (intptr_t)lithic_idFn(x);" out
            @? "let-local call RHS should lower via inline direct call expression with the generated C symbol"
          assertCompilesWithGcc "let-local-direct-call" out

    , testCase "let-local select uses inline expression-value record_select lowering" $
        let out = cgenProgram [(defLetSelectDecl, Nothing)]
         in T.isInfixOf "intptr_t y = (intptr_t)lithic_record_select(r," out
              @? "let-local select RHS should lower via inline record_select expression"

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

    -- ── C4.2 validation + C3 ABI-prep contracts ───────────────────────────

    , testCase "generated C for monomorphic identity compiles with gcc -c" $
        let out = cgenProgram
              [(defIdDecl, Just (TArrow sp0 (TInt sp0) (TInt sp0)))]
         in assertCompilesWithGcc "id-int" out

    , testCase "generated C for variant helper path compiles with gcc -c" $
        let out = cgenProgram
              [(defVariantDecl, Just (TArrow sp0 (TInt sp0) (TInt sp0)))]
         in assertCompilesWithGcc "variant-helper" out

    , testCase "generated C for record helper path compiles with gcc -c" $
        let out = cgenProgram
              [(defRecordDecl, Just (TArrow sp0 (TInt sp0) (TInt sp0)))]
         in assertCompilesWithGcc "record-helper" out

    , testCase "generated C for select helper path compiles with gcc -c" $
        let out = cgenProgram
              [(defSelectDecl, Just (TArrow sp0 (TInt sp0) (TInt sp0)))]
         in assertCompilesWithGcc "select-helper" out

    , testCase "unused lambda parameter emits explicit void-use marker" $
        let out = cgenProgram
              [(defUnusedParamDecl, Just (TArrow sp0 (TInt sp0) (TInt sp0)))]
         in do
          T.isInfixOf "(void)x;" out
            @? "unused parameter should be marked as used to satisfy -Werror"
          assertCompilesWithGcc "unused-param" out

    , testCase "runtime helper ABI uses value-returning signatures" $
        let out = cgenProgram []
         in do
          T.isInfixOf "static inline intptr_t lithic_variant_make(" out
            @? "variant helper should return intptr_t for value-context calls"
          T.isInfixOf "static inline intptr_t lithic_record_make(" out
            @? "record helper should return intptr_t for value-context calls"
          T.isInfixOf "static inline intptr_t lithic_record_select(" out
            @? "select helper should return intptr_t for value-context calls"

    , testCase "runtime prelude includes helper-contract guards for tag/key/count" $
        let out = cgenProgram []
         in do
          T.isInfixOf "lithic_tag_is_valid" out
            @? "prelude should enforce positive tag assumptions"
          T.isInfixOf "lithic_record_key_is_valid" out
            @? "prelude should enforce positive key assumptions"
          T.isInfixOf "lithic_record_count_is_valid" out
            @? "prelude should enforce overflow-safe record count assumptions"

    -- ── C4.4 narrow compile/link/run sanity gate ─────────────────────────

    , testCase "generated C for monomorphic identity links and runs with gcc" $
        let out = cgenProgram
              [(defIdDecl, Just (TArrow sp0 (TInt sp0) (TInt sp0)))]
            harness = T.unlines
              [ "#include <stdint.h>"
              , "extern int64_t lithic_idFn(int64_t x);"
              , "int main(void) {"
              , "  return lithic_idFn((int64_t)7) == (int64_t)7 ? 0 : 1;"
              , "}"
              ]
         in assertCompilesLinksAndRunsWithGcc "id-int-run" out harness

    , testCase "generated C for variant helper path links and runs with gcc" $
        let out = cgenProgram
              [(defVariantDecl, Nothing)]
            harness = T.unlines
              [ "#include <stdint.h>"
              , "extern intptr_t lithic_mkOk(intptr_t x);"
              , "int main(void) {"
              , "  return lithic_mkOk((intptr_t)7) != (intptr_t)0 ? 0 : 1;"
              , "}"
              ]
         in assertCompilesLinksAndRunsWithGcc "variant-run" out harness

    , testCase "generated C record init/select path links and runs with gcc" $
        let out = cgenProgram
              [ (defRecordWithFieldDecl, Nothing)
              , (defSelectDecl, Nothing)
              ]
            harness = T.unlines
              [ "#include <stdint.h>"
              , "extern intptr_t lithic_mkRecWithX(void);"
              , "extern intptr_t lithic_selRec(intptr_t r);"
              , "int main(void) {"
              , "  intptr_t r = lithic_mkRecWithX();"
              , "  intptr_t v = lithic_selRec(r);"
              , "  return v == (intptr_t)42 ? 0 : 1;"
              , "}"
              ]
         in assertCompilesLinksAndRunsWithGcc "record-select-run" out harness

    , testCase "generated C duplicate record field path updates and selects latest value" $
        let out = cgenProgram
              [ (defRecordOverwriteFieldDecl, Nothing)
              , (defSelectDecl, Nothing)
              ]
            harness = T.unlines
              [ "#include <stdint.h>"
              , "extern intptr_t lithic_mkRecWithXOverwrite(void);"
              , "extern intptr_t lithic_selRec(intptr_t r);"
              , "int main(void) {"
              , "  intptr_t r = lithic_mkRecWithXOverwrite();"
              , "  intptr_t v = lithic_selRec(r);"
              , "  return v == (intptr_t)42 ? 0 : 1;"
              , "}"
              ]
         in assertCompilesLinksAndRunsWithGcc "record-overwrite-select-run" out harness

    , testCase "generated C long field name remains selectable under positive key guard" $
        let out = cgenProgram
              [ (defRecordWithLongFieldDecl, Nothing)
              , (defSelectLongFieldDecl, Nothing)
              ]
            harness = T.unlines
              [ "#include <stdint.h>"
              , "extern intptr_t lithic_mkRecWithLongField(void);"
              , "extern intptr_t lithic_selRecLongField(intptr_t r);"
              , "int main(void) {"
              , "  intptr_t r = lithic_mkRecWithLongField();"
              , "  intptr_t v = lithic_selRecLongField(r);"
              , "  return v == (intptr_t)42 ? 0 : 1;"
              , "}"
              ]
         in assertCompilesLinksAndRunsWithGcc "record-long-field-select-run" out harness

    , testCase "generated C variant-case path links and runs with gcc" $
        let out = cgenProgram
              [ (defVariantDecl, Nothing)
              , (defVariantCaseDecl, Nothing)
              ]
            harness = T.unlines
              [ "#include <stdint.h>"
              , "extern intptr_t lithic_mkOk(intptr_t x);"
              , "extern intptr_t lithic_caseVariantFn(intptr_t v);"
              , "int main(void) {"
              , "  intptr_t v = lithic_mkOk((intptr_t)42);"
              , "  intptr_t r = lithic_caseVariantFn(v);"
              , "  return r == (intptr_t)42 ? 0 : 1;"
              , "}"
              ]
         in assertCompilesLinksAndRunsWithGcc "variant-case-run" out harness

    , testCase "generated C bool variable case links and runs with gcc" $
        let out = cgenProgram
              [ (defCaseBoolVarDecl, Nothing)
              ]
            harness = T.unlines
              [ "#include <stdint.h>"
              , "extern intptr_t lithic_checkBool(intptr_t b);"
              , "int main(void) {"
              , "  intptr_t t = lithic_checkBool((intptr_t)1);"
              , "  intptr_t f = lithic_checkBool((intptr_t)0);"
              , "  return (t == (intptr_t)1 && f == (intptr_t)0) ? 0 : 1;"
              , "}"
              ]
         in assertCompilesLinksAndRunsWithGcc "bool-case-run" out harness

    , testCase "generated C unmatched variant-case falls back to default return 0" $
        let out = cgenProgram
              [ (defVariantDecl, Nothing)
              , (defVariantNoMatchDecl, Nothing)
              ]
            harness = T.unlines
              [ "#include <stdint.h>"
              , "extern intptr_t lithic_mkOk(intptr_t x);"
              , "extern intptr_t lithic_caseVariantNoMatchFn(intptr_t v);"
              , "int main(void) {"
              , "  intptr_t v = lithic_mkOk((intptr_t)42);"
              , "  intptr_t r = lithic_caseVariantNoMatchFn(v);"
              , "  return r == (intptr_t)0 ? 0 : 1;"
              , "}"
              ]
         in assertCompilesLinksAndRunsWithGcc "variant-case-no-match-run" out harness

    , testCase "generated C variant-case on wrong-kind input returns fallback 0" $
        let out = cgenProgram
              [ (defRecordWithFieldDecl, Nothing)
              , (defVariantCaseDecl, Nothing)
              ]
            harness = T.unlines
              [ "#include <stdint.h>"
              , "extern intptr_t lithic_mkRecWithX(void);"
              , "extern intptr_t lithic_caseVariantFn(intptr_t v);"
              , "int main(void) {"
              , "  intptr_t notVariant = lithic_mkRecWithX();"
              , "  intptr_t r = lithic_caseVariantFn(notVariant);"
              , "  return r == (intptr_t)0 ? 0 : 1;"
              , "}"
              ]
         in assertCompilesLinksAndRunsWithGcc "variant-case-wrong-kind-run" out harness

    , testCase "generated C record select on wrong-kind input returns fallback 0" $
        let out = cgenProgram
              [ (defVariantDecl, Nothing)
              , (defSelectDecl, Nothing)
              ]
            harness = T.unlines
              [ "#include <stdint.h>"
              , "extern intptr_t lithic_mkOk(intptr_t x);"
              , "extern intptr_t lithic_selRec(intptr_t r);"
              , "int main(void) {"
              , "  intptr_t notRecord = lithic_mkOk((intptr_t)42);"
              , "  intptr_t r = lithic_selRec(notRecord);"
              , "  return r == (intptr_t)0 ? 0 : 1;"
              , "}"
              ]
         in assertCompilesLinksAndRunsWithGcc "record-select-wrong-kind-run" out harness

    , testCase "generated C record select on null handle returns fallback 0" $
        let out = cgenProgram
              [ (defSelectDecl, Nothing)
              ]
            harness = T.unlines
              [ "#include <stdint.h>"
              , "extern intptr_t lithic_selRec(intptr_t r);"
              , "int main(void) {"
              , "  intptr_t r = lithic_selRec((intptr_t)0);"
              , "  return r == (intptr_t)0 ? 0 : 1;"
              , "}"
              ]
         in assertCompilesLinksAndRunsWithGcc "record-select-null-run" out harness

    , testCase "generated C variant-case on malformed non-zero handle returns fallback 0" $
        let out = cgenProgram
              [ (defVariantCaseDecl, Nothing)
              ]
            harness = T.unlines
              [ "#include <stdint.h>"
              , "extern intptr_t lithic_caseVariantFn(intptr_t v);"
              , "int main(void) {"
              , "  intptr_t r = lithic_caseVariantFn((intptr_t)7);"
              , "  return r == (intptr_t)0 ? 0 : 1;"
              , "}"
              ]
         in assertCompilesLinksAndRunsWithGcc "variant-case-malformed-handle-run" out harness

    , testCase "generated C record select on malformed non-zero handle returns fallback 0" $
        let out = cgenProgram
              [ (defSelectDecl, Nothing)
              ]
            harness = T.unlines
              [ "#include <stdint.h>"
              , "extern intptr_t lithic_selRec(intptr_t r);"
              , "int main(void) {"
              , "  intptr_t r = lithic_selRec((intptr_t)7);"
              , "  return r == (intptr_t)0 ? 0 : 1;"
              , "}"
              ]
         in assertCompilesLinksAndRunsWithGcc "record-select-malformed-handle-run" out harness
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

    defLetCallDecl =
      CDeclDef sp0 "callInLet"
        (CLam sp0 (CPVar sp0 "x")
          (CLet sp0 (CPVar sp0 "y")
            (CApp sp0 (CVar sp0 "idFn") (CVar sp0 "x"))
            (CVar sp0 "y")))

    defLetSelectDecl =
      CDeclDef sp0 "selectInLet"
        (CLam sp0 (CPVar sp0 "r")
          (CLet sp0 (CPVar sp0 "y")
            (CSelect sp0 (CVar sp0 "r") "x")
            (CVar sp0 "y")))

    -- Float and String literal bodies
    defFloatDecl =
      CDeclDef sp0 "pi"
        (CLam sp0 (CPVar sp0 "x") (CLit sp0 (LFloat 3.14)))
    defStringDecl =
      CDeclDef sp0 "greeting"
        (CLam sp0 (CPVar sp0 "x") (CLit sp0 (LString "hello")))

    -- Case, variant, record, select
    defCaseLitDecl =
      CDeclDef sp0 "caseLitFn"
        (CLam sp0 (CPVar sp0 "x")
          (CCase sp0 (CLit sp0 (LInt 2))
            [ (CPLit sp0 (LInt 1), CLit sp0 (LInt 10))
            , (CPLit sp0 (LInt 2), CLit sp0 (LInt 20))
            , (CPWildcard sp0, CLit sp0 (LInt 99))
            ]))
    defCaseBoolVarDecl =
      CDeclDef sp0 "checkBool"
        (CLam sp0 (CPVar sp0 "b")
          (CCase sp0 (CVar sp0 "b")
            [ (CPLit sp0 (LBool True), CLit sp0 (LInt 1))
            , (CPLit sp0 (LBool False), CLit sp0 (LInt 0))
            ]))
    defVariantCaseDecl =
      CDeclDef sp0 "caseVariantFn"
        (CLam sp0 (CPVar sp0 "v")
          (CCase sp0 (CVar sp0 "v")
            [ (CPVariant sp0 "Ok" (CPVar sp0 "x"), CVar sp0 "x")
            , (CPWildcard sp0, CLit sp0 (LInt 0))
            ]))
    defVariantNoMatchDecl =
      CDeclDef sp0 "caseVariantNoMatchFn"
        (CLam sp0 (CPVar sp0 "v")
          (CCase sp0 (CVar sp0 "v")
            [ (CPVariant sp0 "Err" (CPVar sp0 "x"), CVar sp0 "x")
            ]))
    defVariantDecl =
      CDeclDef sp0 "mkOk"
        (CLam sp0 (CPVar sp0 "x") (CVariant sp0 "Ok" (CVar sp0 "x")))
    defRecordDecl =
      CDeclDef sp0 "mkRec"
        (CLam sp0 (CPVar sp0 "x") (CRecord sp0 []))
    defRecordWithFieldDecl =
      CDeclDef sp0 "mkRecWithX"
        (CLam sp0 (CPWildcard sp0)
          (CRecord sp0 [("x", CLit sp0 (LInt 42))]))
    defRecordOverwriteFieldDecl =
      CDeclDef sp0 "mkRecWithXOverwrite"
        (CLam sp0 (CPWildcard sp0)
          (CRecord sp0
            [ ("x", CLit sp0 (LInt 7))
            , ("x", CLit sp0 (LInt 42))
            ]))
    defSelectDecl =
      CDeclDef sp0 "selRec"
        (CLam sp0 (CPVar sp0 "r") (CSelect sp0 (CVar sp0 "r") "x"))

    -- | A field name whose polynomial rolling hash overflows Int into a
    -- non-positive value under the old affine mapping (raw*2+1 on Int).
    -- Confirms that the fixed nameToTagNonZero keeps keys strictly positive.
    longFieldName = "fieldfieldfield"

    defRecordWithLongFieldDecl =
      CDeclDef sp0 "mkRecWithLongField"
        (CLam sp0 (CPWildcard sp0)
          (CRecord sp0 [(longFieldName, CLit sp0 (LInt 42))]))

    defSelectLongFieldDecl =
      CDeclDef sp0 "selRecLongField"
        (CLam sp0 (CPVar sp0 "r") (CSelect sp0 (CVar sp0 "r") longFieldName))

    defUnusedParamDecl =
      CDeclDef sp0 "ignoreArg"
        (CLam sp0 (CPVar sp0 "x") (CLit sp0 (LInt 7)))

    defUnsupportedCallTargetDecl =
      CDeclDef sp0 "badCall"
        (CLam sp0 (CPVar sp0 "x") (CApp sp0 (CLit sp0 (LInt 7)) (CVar sp0 "x")))

    defUnsupportedCasePatternDecl =
      CDeclDef sp0 "badCase"
        (CLam sp0 (CPVar sp0 "x")
          (CCase sp0 (CLit sp0 (LInt 1))
            [ (CPVariant sp0 "Ok" (CPVar sp0 "y"), CVar sp0 "y")
            , (CPWildcard sp0, CLit sp0 (LInt 0))
            ]))

    -- | Find the first occurrence index of a needle in a Text, or -1 if absent.
    firstIndex needle txt =
      let n = T.unpack needle
          hay = T.unpack txt
          matches = [i | (i, s) <- zip [0 :: Int ..] (tails hay), n `isPrefixOf` s]
       in case matches of
            []    -> -1
            i : _ -> i

-- | Compile generated C in a one-shot gcc syntax/object check.
-- This keeps Phase 10 backend validation local to CGen tests.
assertCompilesWithGcc :: String -> T.Text -> IO ()
assertCompilesWithGcc tag cSrc =
  withTempArtifact tag ".c" \cPath ->
    withTempArtifact tag ".o" \oPath -> do
      TIO.writeFile cPath cSrc
      (exitCode, stdOut, stdErr) <- readProcessWithExitCode
        "gcc"
        ["-std=c11", "-Wall", "-Wextra", "-Werror", "-c", cPath, "-o", oPath]
        ""
      case exitCode of
        ExitSuccess -> pure ()
        ExitFailure _ ->
          assertFailure
            (unlines
              [ "Expected generated C to compile with gcc, but compilation failed."
              , "Source file: " <> cPath
              , "stdout:"
              , stdOut
              , "stderr:"
              , stdErr
              ])

-- | Compile generated C, link with a tiny harness, and execute the binary.
-- This provides a narrow C4.4 runtime sanity gate beyond object-only checks.
assertCompilesLinksAndRunsWithGcc :: String -> T.Text -> T.Text -> IO ()
assertCompilesLinksAndRunsWithGcc tag cSrc harnessSrc =
  withTempArtifact tag ".c" \cPath ->
    withTempArtifact (tag <> "-harness") ".c" \harnessPath ->
      withTempArtifact tag ".out" \exePath -> do
        TIO.writeFile cPath cSrc
        TIO.writeFile harnessPath harnessSrc
        -- Remove the pre-created temp executable path before linking.
        -- This avoids occasional ETXTBSY races on some filesystems/toolchains
        -- when gcc rewrites an existing just-created output file.
        exeExists <- doesFileExist exePath
        if exeExists then removeFile exePath else pure ()
        (compileEc, compileOut, compileErr) <- readProcessWithExitCode
          "gcc"
          [ "-std=c11"
          , "-Wall"
          , "-Wextra"
          , "-Werror"
          , cPath
          , harnessPath
          , "-o"
          , exePath
          ]
          ""
        case compileEc of
          ExitSuccess -> pure ()
          ExitFailure _ ->
            assertFailure
              (unlines
                [ "Expected generated C + harness to compile/link with gcc, but it failed."
                , "Generated source: " <> cPath
                , "Harness source: " <> harnessPath
                , "stdout:"
                , compileOut
                , "stderr:"
                , compileErr
                ])

        (runEc, runOut, runErr) <- readProcessWithExitCode exePath [] ""
        case runEc of
          ExitSuccess -> pure ()
          ExitFailure _ ->
            assertFailure
              (unlines
                [ "Expected linked runtime sanity binary to exit 0, but it failed."
                , "Executable: " <> exePath
                , "stdout:"
                , runOut
                , "stderr:"
                , runErr
                ])

-- | Create a unique temporary artifact path and remove it after use.
withTempArtifact :: String -> String -> (FilePath -> IO a) -> IO a
withTempArtifact tag ext = bracket create cleanup
  where
    create = do
      (path, handle) <- openTempFile "/tmp" ("lithic-cgen-" <> tag <> "-XXXXXX" <> ext)
      hClose handle
      pure path
    cleanup path = do
      exists <- doesFileExist path
      if exists then removeFile path else pure ()

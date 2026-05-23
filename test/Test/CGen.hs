-- | Unit tests for Phase 10 C code generation.
-- Current focus: C2.2 call/case/variant/select lowering contracts on top of
-- C2.1 typed signatures, literal/variable terminals, let lowering, and the
-- monomorphism guard.
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
          -- non-lambda def is now a global constant declaration (C2.1)
          T.isInfixOf "intptr_t lithic_id =" out
            @? "non-lambda definition should emit as global constant"

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
          T.isInfixOf "int64_t lithic_case_scrut = (int64_t)2;" out
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

    , testCase "unsupported case pattern emits explicit fallback marker" $
        let out = cgenProgram [(defUnsupportedCasePatternDecl, Nothing)]
         in do
          T.isInfixOf "unsupported-case-pattern: CPVariant" out
            @? "unsupported case pattern should emit explicit case diagnostic marker"
          T.isInfixOf "return (intptr_t)0;" out
            @? "unsupported case pattern path should keep compile-safe placeholder return"

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

    -- Case, variant, record, select
    defCaseLitDecl =
      CDeclDef sp0 "caseLitFn"
        (CLam sp0 (CPVar sp0 "x")
          (CCase sp0 (CLit sp0 (LInt 2))
            [ (CPLit sp0 (LInt 1), CLit sp0 (LInt 10))
            , (CPLit sp0 (LInt 2), CLit sp0 (LInt 20))
            , (CPWildcard sp0, CLit sp0 (LInt 99))
            ]))
    defVariantDecl =
      CDeclDef sp0 "mkOk"
        (CLam sp0 (CPVar sp0 "x") (CVariant sp0 "Ok" (CVar sp0 "x")))
    defRecordDecl =
      CDeclDef sp0 "mkRec"
        (CLam sp0 (CPVar sp0 "x") (CRecord sp0 []))
    defSelectDecl =
      CDeclDef sp0 "selRec"
        (CLam sp0 (CPVar sp0 "r") (CSelect sp0 (CVar sp0 "r") "x"))

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

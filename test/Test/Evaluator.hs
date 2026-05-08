module Test.Evaluator
  ( evaluatorUnitTests
  ) where

import Data.Map.Strict qualified as Map

import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (Assertion, assertFailure, testCase)

import Compiler.AST (Literal(..), Span(..))
import Compiler.AST.Core
import Compiler.Evaluator (EvalError(..), Value(..), evalCore)

-- | Unit tests for the Phase-8 evaluator slice.
evaluatorUnitTests :: TestTree
evaluatorUnitTests =
  testGroup "Evaluator Unit Tests"
    [ testCase "literal evaluates to runtime literal" $
        expectValue (CLit sp (LInt 42)) (VLit (LInt 42))

    , testCase "unbound variable reports EvalUnboundVar" $
        case evalCore (CVar sp "x") of
          Left (EvalUnboundVar errSp name) -> do
            errSp `shouldBe` sp
            name `shouldBe` "x"
          other ->
            assertFailure ("Expected EvalUnboundVar, got: " <> show other)

    , testCase "lambda evaluates to closure capturing current environment" $
        expectValue
          (CLam sp (CPVar sp "x") (CVar sp "x"))
          (VClosure Map.empty (CPVar sp "x") (CVar sp "x"))

    , testCase "application evaluates closure body with matched argument" $
        expectValue
          (CApp sp (CLam sp (CPVar sp "x") (CVar sp "x")) (CLit sp (LInt 1)))
          (VLit (LInt 1))

    , testCase "application of non-function reports EvalNonFunctionApp" $
        case evalCore (CApp sp (CLit sp (LInt 0)) (CLit sp (LInt 1))) of
          Left (EvalNonFunctionApp errSp value) -> do
            errSp `shouldBe` sp
            value `shouldBe` VLit (LInt 0)
          other ->
            assertFailure ("Expected EvalNonFunctionApp, got: " <> show other)

    , testCase "application pattern mismatch reports EvalPatternMismatch" $
        case evalCore (CApp sp (CLam sp (CPLit sp (LInt 0)) (CLit sp (LInt 9))) (CLit sp (LInt 1))) of
          Left (EvalPatternMismatch errSp _ _) ->
            errSp `shouldBe` sp
          other ->
            assertFailure ("Expected EvalPatternMismatch, got: " <> show other)

    , testCase "let evaluates body under extended environment" $
        expectValue
          (CLet sp (CPVar sp "x") (CLit sp (LInt 1)) (CVar sp "x"))
          (VLit (LInt 1))

    , testCase "let binding shadows outer closure environment binding" $
        expectValue
          (CApp sp
            (CLam sp (CPVar sp "x")
              (CLet sp (CPVar sp "x") (CLit sp (LInt 2)) (CVar sp "x")))
            (CLit sp (LInt 1)))
          (VLit (LInt 2))

    , testCase "let pattern mismatch reports EvalPatternMismatch" $
        case evalCore (CLet sp (CPLit sp (LInt 0)) (CLit sp (LInt 1)) (CLit sp (LInt 9))) of
          Left (EvalPatternMismatch errSp _ _) ->
            errSp `shouldBe` sp
          other ->
            assertFailure ("Expected EvalPatternMismatch, got: " <> show other)

    , testCase "case selects first matching branch" $
        expectValue
          (CCase sp (CLit sp (LInt 1))
            [ (CPLit sp (LInt 1), CLit sp (LInt 10))
            , (CPWildcard sp, CLit sp (LInt 20))
            ])
          (VLit (LInt 10))

    , testCase "case falls through to later matching branch" $
        expectValue
          (CCase sp (CLit sp (LInt 2))
            [ (CPLit sp (LInt 1), CLit sp (LInt 10))
            , (CPWildcard sp, CLit sp (LInt 20))
            ])
          (VLit (LInt 20))

    , testCase "case branch pattern binds scrutinee into branch body" $
        expectValue
          (CCase sp (CLit sp (LInt 7))
            [ (CPVar sp "x", CVar sp "x")
            ])
          (VLit (LInt 7))

    , testCase "non-exhaustive case reports EvalNonExhaustiveCase" $
        case evalCore (CCase sp (CLit sp (LInt 2)) [(CPLit sp (LInt 1), CLit sp (LInt 10))]) of
          Left (EvalNonExhaustiveCase errSp value) -> do
            errSp `shouldBe` sp
            value `shouldBe` VLit (LInt 2)
          other ->
            assertFailure ("Expected EvalNonExhaustiveCase, got: " <> show other)

    , testCase "variant wraps evaluated payload into VVariant" $
        expectValue
          (CVariant sp "Ok" (CLit sp (LInt 42)))
          (VVariant "Ok" (VLit (LInt 42)))

    , testCase "variant payload is strictly evaluated before constructing VVariant" $
        expectValue
          (CVariant sp "Some"
            (CApp sp (CLam sp (CPVar sp "x") (CVar sp "x")) (CLit sp (LInt 7))))
          (VVariant "Some" (VLit (LInt 7)))

    , testCase "nested variant constructs inner then outer" $
        expectValue
          (CVariant sp "Outer" (CVariant sp "Inner" (CLit sp (LInt 0))))
          (VVariant "Outer" (VVariant "Inner" (VLit (LInt 0))))

    , testCase "record evaluates all fields to VRecord" $
        expectValue
          (CRecord sp [("x", CLit sp (LInt 1)), ("y", CLit sp (LInt 2))])
          (VRecord [("x", VLit (LInt 1)), ("y", VLit (LInt 2))])

    , testCase "record fields are strictly evaluated" $
        expectValue
          (CRecord sp
            [ ("a", CApp sp (CLam sp (CPVar sp "v") (CVar sp "v")) (CLit sp (LInt 3)))
            ])
          (VRecord [("a", VLit (LInt 3))])

    , testCase "field selection returns value of named field" $
        expectValue
          (CSelect sp (CRecord sp [("x", CLit sp (LInt 42))]) "x")
          (VLit (LInt 42))

    , testCase "field selection on missing field reports EvalMissingField" $
        case evalCore (CSelect sp (CRecord sp [("x", CLit sp (LInt 1))]) "y") of
          Left (EvalMissingField errSp label _) -> do
            errSp `shouldBe` sp
            label `shouldBe` "y"
          other ->
            assertFailure ("Expected EvalMissingField, got: " <> show other)

    , testCase "field selection threads through nested record" $
        expectValue
          (CSelect sp
            (CRecord sp [("inner", CRecord sp [("z", CLit sp (LInt 99))])])
            "inner")
          (VRecord [("z", VLit (LInt 99))])
    ]

-- | Assert that a core expression evaluates to an expected runtime value.
expectValue :: CoreExpr -> Value -> Assertion
expectValue expr expected =
  case evalCore expr of
    Right value -> value `shouldBe` expected
    Left err ->
      assertFailure ("Expected successful evaluation, got error: " <> show err)

-- | Lightweight assertion helper to keep test code readable.
shouldBe :: (Eq a, Show a) => a -> a -> Assertion
shouldBe actual expected
  | actual == expected = pure ()
  | otherwise = assertFailure ("Expected: " <> show expected <> "\nBut got:  " <> show actual)

sp :: Span
sp = MkSpan 1 1 1 1
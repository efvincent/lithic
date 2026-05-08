module Test.PatternCoverage
  ( patternCoverageUnitTests
  ) where

import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertFailure, testCase, (@?=))

import Compiler.AST
import Compiler.PatternMatch (CoverageError(..), checkCasePatterns)

-- | Unit tests covering exhaustiveness and redundancy behavior in the
-- pattern coverage checker.
patternCoverageUnitTests :: TestTree
patternCoverageUnitTests =
  testGroup "Pattern Coverage Unit Tests"
    [ testCase "bool case exhaustive" $
        checkCasePatterns tBool [pTrue, pFalse] @?= Right ()

    , testCase "bool case non-exhaustive reports missing False" $
        case checkCasePatterns tBool [pTrue] of
          Left (NonExhaustive (PLit _ (LBool False) : _)) -> pure ()
          other -> assertFailure ("Expected missing False witness, got: " <> show other)

    , testCase "wildcard branch makes following branch redundant" $
        case checkCasePatterns tBool [pWild, pTrue] of
          Left (Redundant _) -> pure ()
          other -> assertFailure ("Expected Redundant error, got: " <> show other)

    , testCase "closed variant non-exhaustive reports missing constructor" $
        case checkCasePatterns tResult [pOkAny] of
          Left (NonExhaustive (PVariant _ "Err" _ : _)) -> pure ()
          other -> assertFailure ("Expected missing Err witness, got: " <> show other)

    , testCase "nested variant witness points to missing nested constructor" $
        case checkCasePatterns tNested [pOkAAny, pErrAny] of
          Left (NonExhaustive (PVariant _ "Ok" (PVariant _ "B" _) : _)) -> pure ()
          other -> assertFailure ("Expected missing Ok (B _) witness, got: " <> show other)

    , testCase "open variant wildcard then constructor is redundant" $
        case checkCasePatterns tOpenResult [pWild, pOkAny] of
          Left (Redundant _) -> pure ()
          other -> assertFailure ("Expected Redundant error for open variant, got: " <> show other)

    , testCase "open variant literal refinement keeps next constructor useful" $
        checkCasePatterns tOpenResult [pOkSuccess, pOkAny, pErrAny, pWild] @?= Right ()
    ]

sp :: Span
sp = MkSpan 1 1 1 1

pWild :: Pattern
pWild = PWildcard sp

pTrue :: Pattern
pTrue = PLit sp (LBool True)

pFalse :: Pattern
pFalse = PLit sp (LBool False)

pOkAny :: Pattern
pOkAny = PVariant sp "Ok" pWild

pErrAny :: Pattern
pErrAny = PVariant sp "Err" pWild

pOkAAny :: Pattern
pOkAAny = PVariant sp "Ok" (PVariant sp "A" pWild)

tBool :: Type
tBool = TBool sp

tUnitRec :: Type
tUnitRec = TRowEmpty sp

tResult :: Type
tResult =
  TVariant sp
    (TRowExtend sp "Ok" (TInt sp)
      (TRowExtend sp "Err" tUnitRec (TRowEmpty sp)))

tInnerNested :: Type
tInnerNested =
  TVariant sp
    (TRowExtend sp "A" (TInt sp)
      (TRowExtend sp "B" (TInt sp) (TRowEmpty sp)))

tNested :: Type
tNested =
  TVariant sp
    (TRowExtend sp "Ok" tInnerNested
      (TRowExtend sp "Err" tUnitRec (TRowEmpty sp)))

pOkSuccess :: Pattern
pOkSuccess = PVariant sp "Ok" (PLit sp (LString "success"))

tOpenResult :: Type
tOpenResult =
  TVariant sp
    (TRowExtend sp "Ok" (TString sp)
      (TRowExtend sp "Err" tUnitRec (TVar sp "r")))
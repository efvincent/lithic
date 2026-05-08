module Test.Elaborator
  ( elaboratorUnitTests
  ) where

import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertFailure, testCase, (@?=))

import Compiler.AST
import Compiler.AST.Core
import Compiler.Elaborator (ElabError(..), elabExpr)

-- | Unit tests for the Surface-to-Core elaboration pass.
elaboratorUnitTests :: TestTree
elaboratorUnitTests =
  testGroup "Elaborator Unit Tests"
    [ testCase "variable elaborates to core variable" $
        elabExpr (Var sp "x")
          @?= Right (CVar sp "x")

    , testCase "annotation is erased during elaboration" $
        elabExpr (Ann sp (Lit sp (LInt 42)) (TInt sp))
          @?= Right (CLit sp (LInt 42))

    , testCase "lambda elaborates with core pattern and body" $
        elabExpr (Lam sp (PVar sp "x") Nothing (Var sp "x"))
          @?= Right (CLam sp (CPVar sp "x") (CVar sp "x"))

    , testCase "application elaborates to core application" $
        elabExpr (App sp (Var sp "f") (Lit sp (LInt 1)))
          @?= Right (CApp sp (CVar sp "f") (CLit sp (LInt 1)))

    , testCase "let elaborates to core let" $
        elabExpr (Let sp (PVar sp "x") (Lit sp (LInt 1)) (Var sp "x"))
          @?= Right (CLet sp (CPVar sp "x") (CLit sp (LInt 1)) (CVar sp "x"))

    , testCase "case elaborates branches in order" $
        elabExpr caseExpr
          @?= Right
            (CCase sp (CVar sp "v")
              [ (CPVariant sp "Ok" (CPVar sp "x"), CVar sp "x")
              , (CPVariant sp "Err" (CPWildcard sp), CLit sp (LInt 0))
              ])

    , testCase "variant elaborates payload" $
        elabExpr (Variant sp "Ok" (Lit sp (LInt 42)))
          @?= Right (CVariant sp "Ok" (CLit sp (LInt 42)))

    , testCase "closed record literal elaborates to canonical core record" $
        elabExpr recordExpr
          @?= Right (CRecord sp [("x", CLit sp (LInt 1)), ("y", CLit sp (LInt 2))])

    , testCase "record selection elaborates to core select" $
        elabExpr (RecSelect sp (Var sp "r") "x")
          @?= Right (CSelect sp (CVar sp "r") "x")

    , testCase "record elaboration preserves outer record span" $
        elabExpr recordWithDistinctSpans
          @?= Right (CRecord outerRecordSp [("x", CLit fieldLitSp (LInt 1))])

    , testCase "record update is explicitly out of initial core scope" $
        case elabExpr recUpdateExpr of
          Left (MkElabError msg errSpan) -> do
            errSpan @?= sp
            msg @?= "RecUpdate is out of scope for the initial Core subset."
          Right other ->
            assertFailure ("Expected elaboration failure, got: " <> show other)

    , testCase "unary operations are explicitly out of initial core scope" $
        case elabExpr (Unary sp UMinus (Lit sp (LInt 1))) of
          Left (MkElabError msg errSpan) -> do
            errSpan @?= sp
            msg @?= "Unary operations are not yet in the initial Core subset."
          Right other ->
            assertFailure ("Expected elaboration failure, got: " <> show other)

    , testCase "binary operations are explicitly out of initial core scope" $
        case elabExpr (Binary sp OpSub (Lit sp (LInt 2)) (Lit sp (LInt 1))) of
          Left (MkElabError msg errSpan) -> do
            errSpan @?= sp
            msg @?= "Binary operations are not yet in the initial Core subset."
          Right other ->
            assertFailure ("Expected elaboration failure, got: " <> show other)
    ]
  where
    caseExpr =
      Case sp (Var sp "v")
        [ (PVariant sp "Ok" (PVar sp "x"), Var sp "x")
        , (PVariant sp "Err" (PWildcard sp), Lit sp (LInt 0))
        ]

    recordExpr =
      RecExtend sp "x" (Lit sp (LInt 1))
        (RecExtend sp "y" (Lit sp (LInt 2)) (RecEmpty sp))

    recordWithDistinctSpans =
      RecExtend outerRecordSp "x" (Lit fieldLitSp (LInt 1)) (RecEmpty closingBraceSp)

    recUpdateExpr =
      RecUpdate sp
        (Var sp "r")
        [PathField "x"]
        OpSet
        (Lit sp (LInt 1))

sp :: Span
sp = MkSpan 1 1 1 1

outerRecordSp :: Span
outerRecordSp = MkSpan 10 1 10 7

fieldLitSp :: Span
fieldLitSp = MkSpan 10 5 10 5

closingBraceSp :: Span
closingBraceSp = MkSpan 10 7 10 7
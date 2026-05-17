-- | Unit tests for Phase 9H scaffold work.
-- Covers declaration-aware elaboration entry points (@elabTopLevel@, @elabDecl@)
-- added in H1, and type-environment persistence mechanics validated in H2.
module Test.Phase9HScaffold
  ( phase9HScaffoldUnitTests
  ) where

import qualified Data.IntMap.Strict as IM
import qualified Data.Text as T

import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (Assertion, assertFailure, testCase)

import Bluefin.Eff (runPureEff)
import Bluefin.Exception (try)
import Bluefin.Reader (runReader)
import Bluefin.State (evalState)

import Compiler.AST
import Compiler.AST.Core
import Compiler.Elaborator (ElabError(..), elabTopLevel)
import Compiler.TypeChecker
  ( Env(..), TCState(..), TypeError(..)
  , generalize, infer, zonk
  )

-- | A placeholder source span used to construct synthetic AST nodes in tests.
sp0 :: Span
sp0 = MkSpan 1 1 1 1

-- | Run type inference in a minimal pure effect stack.
-- Equivalent to the check path inside @handleDeclSubmission@ but without
-- the Brick/IO handles, so it is safe to call from pure unit tests.
runTC :: Env -> Expr -> Either TypeError Type
runTC env expr = runPureEff $
  evalState (MkTCState 0 IM.empty) $ \st ->
    try $ \ex ->
      runReader env $ \envHandle ->
        infer st envHandle ex expr

phase9HScaffoldUnitTests :: TestTree
phase9HScaffoldUnitTests =
  testGroup "Phase 9H: Core Decl Groups + Elaboration"
    [ testGroup "H1: elabTopLevel"
        [ testCase "elaborates expression via expression path (no regression)" $
            expectCoreShape
              (TExpr (Lit sp0 (LInt 1)))
              (\case CTExpr (CLit _ (LInt 1)) -> True; _ -> False)
              "CTExpr (CLit _ (LInt 1))"

        , testCase "elaborates signature declaration to CDeclSig" $
            expectCoreShape
              (TDecl (DeclSig sp0 "id" (TInt sp0)))
              (\case CTDecl (CDeclSig _ "id" (TInt _)) -> True; _ -> False)
              "CTDecl (CDeclSig _ \"id\" (TInt _))"

        , testCase "elaborates named definition declaration to CDeclDef" $
            expectCoreShape
              (TDecl (DeclDef sp0 (PVar sp0 "id") (Var sp0 "id")))
              (\case CTDecl (CDeclDef _ "id" (CVar _ "id")) -> True; _ -> False)
              "CTDecl (CDeclDef _ \"id\" (CVar _ \"id\"))"

        , testCase "rejects non-variable top-level binder with diagnostic" $
            expectCoreFailure
              "requires a named binder"
              (TDecl (DeclDef sp0 (PWildcard sp0) (Lit sp0 (LInt 1))))

        , testCase "elaborates lambda body inside named definition" $
            expectCoreShape
              (TDecl (DeclDef sp0
                        (PVar sp0 "f")
                        (Lam sp0 (PVar sp0 "x") Nothing (Var sp0 "x"))))
              (\case
                CTDecl (CDeclDef _ "f" (CLam _ (CPVar _ "x") (CVar _ "x"))) -> True
                _ -> False)
              "CTDecl (CDeclDef _ \"f\" (CLam ...))"
        ]

    , testGroup "H2: REPL type environment"
        [ testCase "variable bound in Env resolves to its declared type" $
            case runTC (MkEnv [("x", TInt sp0)]) (Var sp0 "x") of
              Right (TInt _) -> pure ()
              other -> assertFailure ("Expected TInt, got: " <> show other)

        , testCase "unbound variable in empty Env produces TypeError" $
            case runTC (MkEnv []) (Var sp0 "y") of
              Left _err -> pure ()
              Right ty  -> assertFailure ("Expected TypeError, got type: " <> show ty)

        , testCase "identity lambda generalizes to a forall type" $ do
            let idLam = Lam sp0 (PVar sp0 "x") Nothing (Var sp0 "x")
            let result = runPureEff $
                  evalState (MkTCState 0 IM.empty) $ \st ->
                    try @TypeError $ \ex ->
                      runReader (MkEnv []) $ \envHandle -> do
                        rawTy  <- infer st envHandle ex idLam
                        monoTy <- zonk st rawTy
                        generalize st (MkEnv []) monoTy
            case result of
              Right (TForall _ _ _) -> pure ()
              Right other -> assertFailure ("Expected forall type, got: " <> show other)
              Left  err   -> assertFailure ("Expected success, got TypeError: " <> show err)

        , testCase "binding persisted in Env enables application to type-check" $
            let idTy  = TArrow sp0 (TInt sp0) (TInt sp0)
                env   = MkEnv [("id", idTy)]
                expr  = App sp0 (Var sp0 "id") (Lit sp0 (LInt 1))
            in case runTC env expr of
                 Right (TInt _) -> pure ()
                 other -> assertFailure ("Expected TInt, got: " <> show other)
        ]
    ]

-- | Assert that elaboration succeeds and the resulting 'CoreTopLevel' satisfies a predicate.
expectCoreShape :: TopLevel -> (CoreTopLevel -> Bool) -> String -> Assertion
expectCoreShape tl predicate description =
  case elabTopLevel tl of
    Left err ->
      assertFailure ("Expected elaboration success, got error: " <> show err)
    Right coreTl ->
      if predicate coreTl
        then pure ()
        else assertFailure
          ("Expected shape: " <> description <> "; got: " <> show coreTl)

-- | Assert that elaboration fails and the error message contains the expected substring.
expectCoreFailure :: T.Text -> TopLevel -> Assertion
expectCoreFailure expected tl =
  case elabTopLevel tl of
    Left err ->
      if expected `T.isInfixOf` err.msg
        then pure ()
        else assertFailure
          ("Expected error containing '" <> T.unpack expected <> "', got: " <> show err)
    Right coreTl ->
      assertFailure ("Expected elaboration failure, got: " <> show coreTl)
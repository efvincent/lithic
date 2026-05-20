-- | Unit tests for Phase 9H scaffold work.
-- Covers declaration-aware elaboration entry points (@elabTopLevel@, @elabDecl@)
-- added in H1, and type-environment persistence mechanics validated in H2.
module Test.Phase9HScaffold
  ( phase9HScaffoldUnitTests
  ) where

import qualified Data.Text as T

import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (Assertion, assertFailure, testCase)

import qualified Data.IntMap.Strict as IM

import Bluefin.Eff (runPureEff)
import Bluefin.Eff ((:>))
import Bluefin.State (State, evalState, get, modify, put, runState)

import Compiler.AST
import Compiler.AST.Core
import Compiler.Elaborator (ElabError(..), elabTopLevel)
import Compiler.REPL (Terminal(..), replLoop)
import Compiler.TypeChecker (TCState(..))

-- | A placeholder source span used to construct synthetic AST nodes in tests.
sp0 :: Span
sp0 = MkSpan 1 1 1 1

-- | Run a scripted REPL session and capture output lines in order.
runReplSession :: [T.Text] -> [T.Text]
runReplSession inputs =
  runPureEff $
    fmap snd $
      runState [] $ \outputSt ->
        evalState inputs $ \inputSt ->
          evalState (MkTCState 0 IM.empty) $ \tcSt ->
            replLoop (scriptedTerminal inputSt outputSt) tcSt

-- | A pure terminal used to exercise the real REPL loop in tests.
scriptedTerminal :: (ins :> es, outs :> es) => State [T.Text] ins -> State [T.Text] outs -> Terminal es
scriptedTerminal inputSt outputSt = MkTerminal
  { prompt = \_ -> do
      pending <- get inputSt
      case pending of
        [] -> pure Nothing
        next : rest -> do
          put inputSt rest
          pure (Just next)
  , output = \msg ->
      modify outputSt (<> [msg])
  }

-- | Assert that each expected substring appears in order across the output log.
expectOutputContainsInOrder :: [T.Text] -> [T.Text] -> Assertion
expectOutputContainsInOrder expected outputs =
  go expected outputs
  where
    go [] _ = pure ()
    go _ [] =
      assertFailure
        ("Expected output sequence not found. Remaining needles: " <> show expected
          <> "; full output: " <> show outputs)
    go needles@(needle : rest) (line : remaining)
      | needle `T.isInfixOf` line = go rest remaining
      | otherwise = go needles remaining

-- | Assert that one substring appears somewhere in the full output log.
expectOutputContains :: T.Text -> [T.Text] -> Assertion
expectOutputContains needle outputs =
  if needle `T.isInfixOf` T.intercalate "\n" outputs
    then pure ()
    else assertFailure
      ("Expected output to contain: " <> show needle <> "; full output: " <> show outputs)

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

    , testGroup "H2: REPL session behavior"
        [ testCase "definition submission is visible to the next expression" $
            expectOutputContainsInOrder
              [ "[Decl] id"
              , "[Type] TForall"
              , "[AST]"
              , "[Type] TInt"
              ]
              (runReplSession ["id x = x", "id 1", ":quit"])

        , testCase "parse error does not corrupt a previously accepted binding" $
            expectOutputContainsInOrder
              [ "[Decl] id"
              , "Parse Error:"
              , "[AST]"
              , "[Type] TInt"
              ]
              (runReplSession ["id x = x", "let x = 1", "id 1", ":quit"])

        , testCase "type error does not corrupt a previously accepted binding" $
            expectOutputContainsInOrder
              [ "[Decl] id"
              , "Type Error:"
              , "[AST]"
              , "[Type] TInt"
              ]
              (runReplSession ["id x = x", "bad y = 1 - True", "id 1", ":quit"])

        , testCase "signature-only declaration is acknowledged but not persisted" $
            expectOutputContainsInOrder
              [ "[Decl] id (signature accepted; persistence deferred in this slice)"
              , "[AST]"
              , "Type Error: Unbound variable: id"
              ]
              (runReplSession ["id : Int", "id", ":quit"])

        , testCase "literal scrutinee case with matching branch is accepted" $
            expectOutputContainsInOrder
              [ "[AST]"
              , "[Type] TInt"
              ]
              (runReplSession ["case True of True => 1", ":quit"])

        , testCase "literal scrutinee case with no matching branch still fails" $
            expectOutputContainsInOrder
              [ "[AST]"
              , "Type Error: Unreachable pattern branch"
              ]
              (runReplSession ["case True of False => 1", ":quit"])

        , testCase "expression success emits explicit expression-codegen status" $
            expectOutputContainsInOrder
              [ "[AST]"
              , "[Type] TInt"
              , "[C] (expression codegen not yet supported in REPL; declaration-only for now)"
              ]
              (runReplSession ["1", ":quit"])

        , testCase "declaration success emits generated C scaffold" $
            let outputs = runReplSession ["id x = x", ":quit"]
             in do
              expectOutputContainsInOrder
                [ "[Decl] id"
                , "[Type] TForall"
                ]
                outputs
              expectOutputContains "[C]" outputs
              expectOutputContains "codegen error: program is not fully monomorphic" outputs
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
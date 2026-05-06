module Main where

import Test.Tasty (defaultMain, testGroup, TestTree)
import Test.Tasty.Golden (findByExtension, goldenVsString)
import Test.Tasty.HUnit (assertFailure, testCase, (@?=))
import System.FilePath ((</>), takeBaseName)

import qualified Data.ByteString.Lazy.Char8 as BSL
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import qualified Data.IntMap.Strict as IM

import Bluefin.Eff (runPureEff)
import Bluefin.Exception (try)
import Bluefin.State (evalState)
import Bluefin.Reader (runReader)

import Compiler.Lexer (runLexer, LexError(..))
import Compiler.Parser (runParser, ParseError(..))
import Compiler.TypeChecker (infer, Env(..), TCState(..), zonk, TypeError(..))
import Compiler.AST
import Compiler.PatternMatch (CoverageError(..), checkCasePatterns)

main :: IO ()
main = do
  goldenTests <- discoverGoldenTests
  defaultMain $ testGroup "Lithic Compiler Tests"
    [ goldenTests
    , patternCoverageUnitTests
    ]

discoverGoldenTests :: IO TestTree
discoverGoldenTests = do
  -- Auto find all .lithic files in the fixtures directory
  lfiles <- findByExtension [".lithic"] "test/fixtures"
  pure $ testGroup "Golden Tests" (map mkGoldenTest lfiles)


mkGoldenTest :: FilePath -> TestTree
mkGoldenTest p =
  let n = takeBaseName p
      goldenPath = "test" </> "golden" </> n <> ".golden"
  in goldenVsString n goldenPath (runCompilerPipeline p)

runCompilerPipeline :: FilePath -> IO BSL.ByteString
runCompilerPipeline path = do
  source <- TIO.readFile path
  let resultText = case runLexer source of 
        Left lexErr -> "Lex Error: " <> lexErr.msg
        Right toks -> case  runParser toks of
          Left parseErr -> "Parse Error: " <> parseErr.msg
          Right ast ->
            -- Run the bidirectional typechecker purely
            let tcResult = runPureEff $                     -- run the effects purely
                  evalState (MkTCState 0 IM.empty) \st -> do    -- create the state effect handle st
                    try \ex ->                                  -- create the exception effect handle ex
                      runReader (MkEnv []) \env -> do           -- create the reader effect handle env
                        rawTy <- infer st env ex ast
                        zonk st rawTy
            in case tcResult of
              Left tcErr -> "Type Error: " <> tcErr.msg <> " at " <> T.pack (show tcErr.span)
              Right ty -> "[AST] " <> T.pack (show ast) <> "\n[Type] " <> T.pack (show ty)
  pure $ BSL.pack (T.unpack resultText <> "\n") 

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
    ]

sp :: SourceSpan
sp = MkSourceSpan 1 1 1 1

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
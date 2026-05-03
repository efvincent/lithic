module Main where

import Test.Tasty (defaultMain, testGroup, TestTree)
import Test.Tasty.Golden (findByExtension, goldenVsString)
import System.FilePath (replaceExtension, takeBaseName)

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

main :: IO ()
main = do
  goldenTests <- discoverGoldenTests
  defaultMain $ testGroup "Lithic Compiler Tests"
    [ goldenTests
    -- We will add a testGroup for Unit Tests (HUnit) here later
    ]

discoverGoldenTests :: IO TestTree
discoverGoldenTests = do
  -- Auto find all .lithic files in the golden directory
  lfiles <- findByExtension [".lithic"] "test/golden"
  pure $ testGroup "Golden Tests" (map mkGoldenTest lfiles)


mkGoldenTest :: FilePath -> TestTree
mkGoldenTest p =
  let n = takeBaseName p
      goldenPath = replaceExtension p ".golden"
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

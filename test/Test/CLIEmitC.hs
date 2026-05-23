-- | Integration tests for the --emit-c CLI path.
module Test.CLIEmitC
  ( cliEmitCTests
  ) where

import Control.Exception (bracket)
import Data.Char (isSpace)
import Data.List (isInfixOf)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import System.Directory (doesFileExist, removeFile)
import System.Exit (ExitCode(..))
import System.FilePath (replaceExtension)
import System.IO (hClose, openTempFile)
import System.Process (readProcessWithExitCode)

import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (Assertion, assertBool, assertFailure, testCase)

cliEmitCTests :: TestTree
cliEmitCTests =
  testGroup "CLI --emit-c Integration"
    [ testCase "writes default .c output path for declaration input" $
      withTempLithicSource "def one = 1\n" \srcPath -> do
          let outPath = replaceExtension srcPath ".c"
          (ec, stdOut, stdErr) <- runEmitC ["--emit-c", srcPath]
          case ec of
            ExitSuccess -> pure ()
            ExitFailure _ ->
              assertFailure $
                unlines
                  [ "Expected --emit-c to succeed on declaration input"
                  , "stdout: " <> stdOut
                  , "stderr: " <> stdErr
                  ]
          exists <- doesFileExist outPath
          assertBool "default emit-c output file should be created" exists
          out <- TIO.readFile outPath
          assertBool "generated C should contain declaration marker"
            (T.isInfixOf "/* definition: one */" out)

    , testCase "writes requested output path with -o" $
      withTempLithicSource "def one = 1\n" \srcPath ->
          withTempOutputPath \outPath -> do
            (ec, stdOut, stdErr) <- runEmitC ["--emit-c", srcPath, "-o", outPath]
            case ec of
              ExitSuccess -> pure ()
              ExitFailure _ ->
                assertFailure $
                  unlines
                    [ "Expected --emit-c -o to succeed on declaration input"
                    , "stdout: " <> stdOut
                    , "stderr: " <> stdErr
                    ]
            exists <- doesFileExist outPath
            assertBool "requested emit-c output file should be created" exists

    , testCase "rejects bare top-level expressions" $
        withTempLithicSource "1\n" \srcPath -> do
          (ec, stdOut, stdErr) <- runEmitC ["--emit-c", srcPath]
          case ec of
            ExitSuccess ->
              assertFailure "Expected --emit-c to fail on bare expression input"
            ExitFailure _ -> do
              let msg = stdOut <> stdErr
              assertBool "failure should mention bare expression rejection"
                ("requires a top-level declaration" `elemIn` msg)
    ]

runEmitC :: [String] -> IO (ExitCode, String, String)
runEmitC args = do
  cliPath <- resolveCliPath
  readProcessWithExitCode cliPath args ""

resolveCliPath :: IO FilePath
resolveCliPath = do
  (ec, stdOut, stdErr) <- readProcessWithExitCode "cabal" ["list-bin", "exe:lithic-cli"] ""
  case ec of
    ExitSuccess -> pure (rstrip stdOut)
    ExitFailure _ ->
      assertFailure
        (unlines
          [ "Failed to resolve executable path via cabal list-bin exe:lithic-cli"
          , "stdout: " <> stdOut
          , "stderr: " <> stdErr
          ])

withTempLithicSource :: T.Text -> (FilePath -> Assertion) -> Assertion
withTempLithicSource source =
  bracket create cleanup
  where
    create = do
      (path, handle) <- openTempFile "/tmp" "lithic-cli-emit-XXXXXX.lithic"
      TIO.hPutStr handle source
      hClose handle
      pure path
    cleanup path = do
      safeRemove path
      safeRemove (replaceExtension path ".c")

withTempOutputPath :: (FilePath -> Assertion) -> Assertion
withTempOutputPath =
  bracket create safeRemove
  where
    create = do
      (path, handle) <- openTempFile "/tmp" "lithic-cli-out-XXXXXX.c"
      hClose handle
      safeRemove path
      pure path

safeRemove :: FilePath -> IO ()
safeRemove path = do
  exists <- doesFileExist path
  if exists then removeFile path else pure ()

rstrip :: String -> String
rstrip = reverse . dropWhile isSpace . reverse

elemIn :: String -> String -> Bool
elemIn = isInfixOf
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

import Test.Tasty (TestTree, testGroup, withResource)
import Test.Tasty.HUnit (Assertion, assertBool, assertFailure, testCase)

cliEmitCTests :: TestTree
cliEmitCTests =
  withResource resolveCliPath (const (pure ())) $ \getCliPath ->
    testGroup "CLI --emit-c Integration"
      [ testCase "writes default .c output path for declaration input" $ do
          cliPath <- getCliPath
          withTempLithicSource "def one = 1\n" \srcPath -> do
            let outPath = replaceExtension srcPath ".c"
            (ec, stdOut, stdErr) <- runEmitC cliPath ["--emit-c", srcPath]
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

      , testCase "writes requested output path with -o" $ do
          cliPath <- getCliPath
          withTempLithicSource "def one = 1\n" \srcPath ->
            withTempOutputPath \outPath -> do
              (ec, stdOut, stdErr) <- runEmitC cliPath ["--emit-c", srcPath, "-o", outPath]
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

      , testCase "rejects bare top-level expressions" $ do
          cliPath <- getCliPath
          withTempLithicSource "1\n" \srcPath -> do
            (ec, stdOut, stdErr) <- runEmitC cliPath ["--emit-c", srcPath]
            case ec of
              ExitSuccess ->
                assertFailure "Expected --emit-c to fail on bare expression input"
              ExitFailure _ -> do
                let msg = stdOut <> stdErr
                assertBool "failure should mention bare expression rejection"
                  ("requires a top-level declaration" `elemIn` msg)

      , testCase "fixture decl-signature-equation emits C and compiles with gcc -c" $ do
          cliPath <- getCliPath
          withTempOutputPath \outPath -> do
            let srcPath = "test/fixtures/decl-signature-equation.lithic"
            (ec, stdOut, stdErr) <- runEmitC cliPath ["--emit-c", srcPath, "-o", outPath]
            case ec of
              ExitSuccess -> pure ()
              ExitFailure _ ->
                assertFailure $
                  unlines
                    [ "Expected fixture emit-c to succeed"
                    , "fixture: " <> srcPath
                    , "stdout: " <> stdOut
                    , "stderr: " <> stdErr
                    ]
            out <- TIO.readFile outPath
            assertBool "generated C should include fixture declaration marker"
              (T.isInfixOf "/* definition: id */" out)
            assertCompilesWithGcc outPath

      , testCase "fixture emitc-record-select emits helper call and compiles with gcc -c" $ do
          cliPath <- getCliPath
          withTempOutputPath \outPath -> do
            let srcPath = "test/fixtures/emitc-record-select.lithic"
            (ec, stdOut, stdErr) <- runEmitC cliPath ["--emit-c", srcPath, "-o", outPath]
            case ec of
              ExitSuccess -> pure ()
              ExitFailure _ ->
                assertFailure $
                  unlines
                    [ "Expected record/select fixture emit-c to succeed"
                    , "fixture: " <> srcPath
                    , "stdout: " <> stdOut
                    , "stderr: " <> stdErr
                    ]
            out <- TIO.readFile outPath
            assertBool "generated C should include record-select helper call"
              (T.isInfixOf "lithic_record_select(" out)
            assertCompilesWithGcc outPath

      , testCase "fixture emitc-variant emits helper call and compiles with gcc -c" $ do
          cliPath <- getCliPath
          withTempOutputPath \outPath -> do
            let srcPath = "test/fixtures/emitc-variant.lithic"
            (ec, stdOut, stdErr) <- runEmitC cliPath ["--emit-c", srcPath, "-o", outPath]
            case ec of
              ExitSuccess -> pure ()
              ExitFailure _ ->
                assertFailure $
                  unlines
                    [ "Expected variant fixture emit-c to succeed"
                    , "fixture: " <> srcPath
                    , "stdout: " <> stdOut
                    , "stderr: " <> stdErr
                    ]
            out <- TIO.readFile outPath
            assertBool "generated C should include variant helper call"
              (T.isInfixOf "lithic_variant_make(" out)
            assertCompilesWithGcc outPath

      , testCase "fixture emitc-long-field-select emits helper call and compiles with gcc -c" $ do
          cliPath <- getCliPath
          withTempOutputPath \outPath -> do
            let srcPath = "test/fixtures/emitc-long-field-select.lithic"
            (ec, stdOut, stdErr) <- runEmitC cliPath ["--emit-c", srcPath, "-o", outPath]
            case ec of
              ExitSuccess -> pure ()
              ExitFailure _ ->
                assertFailure $
                  unlines
                    [ "Expected long-field record-select fixture emit-c to succeed"
                    , "fixture: " <> srcPath
                    , "stdout: " <> stdOut
                    , "stderr: " <> stdErr
                    ]
            out <- TIO.readFile outPath
            assertBool "generated C should include record-select helper call"
              (T.isInfixOf "lithic_record_select(" out)
            assertCompilesWithGcc outPath

      , testCase "fixture emitc-bool-case emits concrete guards and compiles with gcc -c" $ do
          cliPath <- getCliPath
          withTempOutputPath \outPath -> do
            let srcPath = "test/fixtures/emitc-bool-case.lithic"
            (ec, stdOut, stdErr) <- runEmitC cliPath ["--emit-c", srcPath, "-o", outPath]
            case ec of
              ExitSuccess -> pure ()
              ExitFailure _ ->
                assertFailure $
                  unlines
                    [ "Expected bool-case fixture emit-c to succeed"
                    , "fixture: " <> srcPath
                    , "stdout: " <> stdOut
                    , "stderr: " <> stdErr
                    ]
            out <- TIO.readFile outPath
            assertBool "generated C should include bool case guards"
              (T.isInfixOf "lithic_case_scrut" out)
            assertCompilesWithGcc outPath

      , testCase "terminal IO builtins emit C main wrapper and helper calls" $ do
          cliPath <- getCliPath
          withTempLithicSource "def main = print readLn\n" \srcPath ->
            withTempOutputPath \outPath -> do
              (ec, stdOut, stdErr) <- runEmitC cliPath ["--emit-c", srcPath, "-o", outPath]
              case ec of
                ExitSuccess -> pure ()
                ExitFailure _ ->
                  assertFailure $
                    unlines
                      [ "Expected terminal IO fixture emit-c to succeed"
                      , "stdout: " <> stdOut
                      , "stderr: " <> stdErr
                      ]
              out <- TIO.readFile outPath
              assertBool "generated C should include C main wrapper"
                (T.isInfixOf "int main(void)" out)
              assertBool "generated C should call print helper"
                (T.isInfixOf "lithic_builtin_print" out)
              assertBool "generated C should call readLn helper"
                (T.isInfixOf "lithic_builtin_readln()" out)
              assertCompilesWithGcc outPath

      , testCase "--emit-c rejects declarations that shadow reserved builtins" $ do
          cliPath <- getCliPath
          withTempLithicSource "def print = 1\n" \srcPath -> do
            (ec, stdOut, stdErr) <- runEmitC cliPath ["--emit-c", srcPath]
            case ec of
              ExitSuccess ->
                assertFailure "Expected --emit-c to reject a declaration named print"
              ExitFailure _ -> do
                let msg = stdOut <> stdErr
                assertBool "failure should mention reserved builtin name"
                  ("reserved builtin name" `elemIn` msg)
      ]

runEmitC :: FilePath -> [String] -> IO (ExitCode, String, String)
runEmitC cliPath args =
  readProcessWithExitCode cliPath args ""

resolveCliPath :: IO FilePath
resolveCliPath = do
  (buildEc, buildOut, buildErr) <- readProcessWithExitCode "cabal" ["build", "exe:lithic-cli"] ""
  case buildEc of
    ExitSuccess -> pure ()
    ExitFailure _ ->
      assertFailure $
        unlines
          [ "Failed to build executable via cabal build exe:lithic-cli"
          , "stdout: " <> buildOut
          , "stderr: " <> buildErr
          ]

  (ec, stdOut, stdErr) <- readProcessWithExitCode "cabal" ["list-bin", "exe:lithic-cli"] ""
  case ec of
    ExitSuccess -> do
      let cliPath = rstrip stdOut
      exists <- doesFileExist cliPath
      if exists
        then pure cliPath
        else do
          assertFailure $
            unlines
              [ "Resolved CLI path does not exist"
              , "path: " <> cliPath
              ]
          error "unreachable"
    ExitFailure _ -> do
      let msg =
            unlines
              [ "Failed to resolve executable path via cabal list-bin exe:lithic-cli"
              , "stdout: " <> stdOut
              , "stderr: " <> stdErr
              ]
      assertFailure msg
      error "unreachable"

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

assertCompilesWithGcc :: FilePath -> Assertion
assertCompilesWithGcc cPath =
  withTempOutputPath \oPath -> do
    (ec, stdOut, stdErr) <- readProcessWithExitCode
      "gcc"
      ["-std=c11", "-Wall", "-Wextra", "-Werror", "-c", cPath, "-o", oPath]
      ""
    case ec of
      ExitSuccess -> pure ()
      ExitFailure _ ->
        assertFailure $
          unlines
            [ "Expected emitted C to compile with gcc -c"
            , "source: " <> cPath
            , "stdout:"
            , stdOut
            , "stderr:"
            , stdErr
            ]
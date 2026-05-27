module Main where

import System.Environment (getArgs)
import System.Exit (exitFailure)
import System.FilePath (replaceExtension)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import qualified Data.IntMap.Strict as IM

import Data.Generics.Labels ()

import Bluefin.Eff (runEff, runPureEff)
import Bluefin.IO (effIO)
import Bluefin.State (evalState)
import Bluefin.Exception (try)
import Bluefin.Reader (runReader)
import Brick.BChan (newBChan, writeBChan)
import Control.Concurrent (forkIO)
import Control.Concurrent.MVar (newEmptyMVar)

import Compiler.AST (Decl(..), Pattern(..), TopLevel(..))
import Compiler.AST.Core
import Compiler.CGen (cgenProgram)
import Compiler.Elaborator (ElabError(..), elabTopLevel)
import Compiler.Lexer (runLexer, LexError(..))
import Compiler.Parser (parseTopLevel, ParseError(..))
import Compiler.REPL (replLoop, runTerminalBrick)
import Compiler.TUI (runTUI, TUIEvent(..))
import Compiler.TypeChecker (TCState(..), TypeError(..), builtinEnv, infer, zonk)
import Compiler.TypeChecker ()

main :: IO ()
main = do
  args <- getArgs
  case args of 
    ["--emit-c", srcPath] -> runEmitC srcPath (replaceExtension srcPath ".c")
    ["--emit-c", srcPath, "-o", out] -> runEmitC srcPath out
    _ -> runInteractive

-- | Launch the Brick/TUI REPL as before
runInteractive :: IO ()
runInteractive = do
  eventChan <- newBChan 10
  inputMVar <- newEmptyMVar
  _ <- forkIO $ runEff \io -> do
    evalState (MkTCState 0 IM.empty) \st -> do
      let term = runTerminalBrick eventChan inputMVar io
      replLoop term st
    effIO io $ writeBChan eventChan TUIQuit
  runTUI eventChan inputMVar

-- | Run the full pipeline on @srcPath@ and write generated C to @outPath@.
-- Exit with a non-zero code and a diagnostic message on any pipeline error
runEmitC :: FilePath -> FilePath -> IO ()
runEmitC srcPath outPath = do
  source <- TIO.readFile srcPath
  case runLexer source of
    Left lexErr -> do
      TIO.putStrLn $ "Lex error: " <> lexErr.msg
      exitFailure
    Right toks ->
      case parseTopLevel toks of 
        Left parseErr -> do
          TIO.putStrLn $ "Parse error: " <> parseErr.msg
          exitFailure
        Right topLevel ->
          case topLevel of
            TExpr _ -> do
              TIO.putStrLn "--emit-c requires a top-level declaration, not a bare expression."
              exitFailure
            TDecl decl ->
              case decl of 
                DeclDef _ (PVar _ _name) rhs -> do
                  -- Typecheck the declaration in a pure Bluefin context.
                  let tcResult =
                        runPureEff $ evalState (MkTCState 0 IM.empty) \st -> 
                        try                                           \ex -> 
                        runReader builtinEnv                          \env -> do
                          rawTy <- infer st env ex rhs
                          zonk st rawTy
                  case tcResult of
                    Left tcErr -> do
                      TIO.putStrLn $ "Type error: " <> tcErr.msg
                      exitFailure
                    Right monoTy ->
                      case elabTopLevel (TDecl decl) of
                        Left elabErr -> do
                          TIO.putStrLn $ "Elaboration error: " <> elabErr.msg
                          exitFailure
                        Right coreTop ->
                          case coreTop of
                            -- elabTopLevel on a TDecl always produces CTDecl, but
                            -- pattern match kept explicit for exhaustivness safety.
                            Compiler.AST.Core.CTDecl coreDecl -> do
                              let cText = cgenProgram [(coreDecl, Just monoTy)]
                              TIO.writeFile outPath cText
                              TIO.putStrLn $ "C output written to " <> T.pack outPath
                            Compiler.AST.Core.CTExpr _ -> do
                              TIO.putStrLn "Internal error: expected CTDecl, got CTExpr."
                              exitFailure
                _ -> do
                  TIO.putStrLn "--emit-c current supports only named function declarations (f x = ...)."
                  exitFailure
                    


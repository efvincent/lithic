module Compiler.REPL where

import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import System.IO (stdout, hFlush)
import GHC.Generics (Generic)
import Data.Generics.Labels ()
import Control.Concurrent.MVar (MVar, takeMVar)

import Brick.BChan (BChan, writeBChan)
import Bluefin.Eff ((:>), Eff, runPureEff)
import Bluefin.Exception (try)
import Bluefin.Reader (runReader)
import Bluefin.IO (IOE, effIO)

import Compiler.TUI (TUIEvent(..))
import Compiler.Lexer (runLexer, LexError(..))
import Compiler.Parser (runParser, ParseError(..))
import Compiler.TypeChecker (infer, Env(..), TypeError(..))

-- | The Terminal effect handle.
-- Abstracts the UI so we can swap between basic IO and a `brick` TUI seamlessly.
data Terminal es = MkTerminal
  { prompt :: Text -> Eff es (Maybe Text)
  , output :: Text -> Eff es () 
  } deriving (Generic)

-- | The core REPL loop. It depends strictly on the abstract Terminal effect.
replLoop :: Terminal es -> Eff es ()
replLoop term = do
  mInput <- term.prompt "lithic> "
  case mInput of
    Nothing -> term.output "Goodbye!"
    Just input -> do
      if T.strip input == ":quit"
      then term.output "Goodbye!"
      else do
        case runLexer input of
          Left err -> term.output $ "Lex Error: " <> err.msg
          Right toks -> case runParser toks of
            Left pErr -> term.output $ "Parse Error: " <> pErr.msg
            Right ast -> do 
              term.output $ "[AST]" <> T.pack (show ast)
              -- Isoloate the typechecker effects purely
              let tcResult = runPureEff $
                    try \ex ->
                      runReader (MkEnv []) \env ->
                        infer env ex ast
              case tcResult of
                Left err -> term.output $ "Type Error: " <> err.msg <> " at " <> T.pack (show err.span)
                Right ty -> term.output $ "[Type] " <> T.pack (show ty)

        replLoop term

-- | A basic IO implementation of the Terminal effect to get us started
runTerminalIO :: forall io es. (io :> es) => IOE io -> Terminal es
runTerminalIO io = MkTerminal
  { prompt = \p -> effIO io $ do
      TIO.putStr p
      hFlush stdout -- Ensure the prompt prints before blocking for input
      input <- TIO.getLine
      pure $ Just input
  , output = \msg -> effIO io $ TIO.putStrLn msg
  }

-- | A Brick TUI implementation of the Terminal effect.
runTerminalBrick 
  :: forall io es. (io :> es) 
  => BChan TUIEvent 
  -> MVar (Maybe Text) 
  -> IOE io 
  -> Terminal es
runTerminalBrick eventChan inputMVar io = MkTerminal
  { prompt = \p -> effIO io $ do
      writeBChan eventChan (TUIPrompt p)
      -- Block this green thread until Brick's event loop fills the MVar
      takeMVar inputMVar
  , output = \msg -> effIO io $ writeBChan eventChan (TUIOutput msg)
  }
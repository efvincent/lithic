module Compiler.REPL where

import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import System.IO (stdout, hFlush)
import GHC.Generics (Generic)
import Data.Generics.Labels ()
import Control.Concurrent.MVar (MVar, takeMVar)

import Brick.BChan (BChan, writeBChan)
import Bluefin.State (State)
import Bluefin.Eff ((:>), Eff)
import Bluefin.Exception (try)
import Bluefin.Reader (runReader)
import Bluefin.IO (IOE, effIO)

import Compiler.AST.Core (CoreTopLevel(..))
import Compiler.AST (Decl(..), Pattern(..), TopLevel(..))
import Compiler.TUI (TUIEvent(..))
import Compiler.Lexer (runLexer, LexError(..))
import Compiler.Parser (ParseError(..), parseTopLevel)
import Compiler.TypeChecker (infer, generalize, Env(..), TypeError(..), TCState (..), zonk)
import Compiler.Elaborator (elabTopLevel, ElabError(..))
import Compiler.CGen (cgenProgram)

-- | The Terminal effect handle.
-- Abstracts the UI so we can swap between basic IO and a `brick` TUI seamlessly.
data Terminal es = MkTerminal
  { prompt :: Text -> Eff es (Maybe Text)
  , output :: Text -> Eff es () 
  } deriving (Generic)

-- | The core REPL loop.
-- Maintains persistent type environment across submissions while sharing the
-- same persistent unification state handle.
replLoop :: forall st es. (st :> es) => Terminal es -> State TCState st -> Eff es ()
replLoop term st = go (MkEnv [])
  where
    go :: Env -> Eff es ()
    go currentEnv = do
      mInput <- term.prompt "lithic> "
      case mInput of
        Nothing -> term.output "Goodbye!"
        Just input ->
          if T.strip input == ":quit"
            then term.output "Goodbye!"
            else do
              nextEnv <-
                case runLexer input of
                  Left err -> do
                    term.output $ "Lex Error: " <> err.msg
                    pure currentEnv

                  Right toks ->
                    case parseTopLevel toks of
                      Left pErr -> do
                        term.output $ "Parse Error: " <> pErr.msg
                        pure currentEnv

                      Right topLevel ->
                        handleTopLevel currentEnv topLevel

              go nextEnv

    emitCodeGen :: TopLevel -> Eff es ()
    emitCodeGen topLevel =
      case elabTopLevel topLevel of
        Left (MkElabError elabMsg _) ->
          term.output $ "[CGen Error] " <> elabMsg
        Right coreTop ->
          case coreTop of
            CTDecl coreDecl ->
              term.output $ "[C]\n" <> cgenProgram [coreDecl]
            CTExpr _ ->
              term.output "[C] (expression codegen not yet supported in REPL; declaration-only for now)"

    -- Keep expression and declaration handling isolated so declaration
    -- persistence does not leak into parse/lex error paths.
    handleTopLevel :: Env -> TopLevel -> Eff es Env
    handleTopLevel env = \case
      TExpr ast -> do
        term.output $ "[AST] " <> T.pack (show ast)
        tcResult <- try \ex ->
          runReader env \envHandle -> do
            rawTy <- infer st envHandle ex ast
            zonk st rawTy

        case tcResult of
          Left err -> do
            term.output $ "Type Error: " <> err.msg <> " at " <> T.pack (show err.span)
            pure env
          Right ty -> do
            term.output $ "[Type] " <> T.pack (show ty)
            emitCodeGen (TExpr ast)
            pure env

      TDecl decl ->
        handleDeclSubmission env decl

    -- First H2 slice:
    -- - Persist named definitions.
    -- - Keep signature-only declarations parse-visible but non-persistent.
    handleDeclSubmission :: Env -> Decl -> Eff es Env
    handleDeclSubmission env decl =
      case decl of
        DeclSig _ name _ -> do
          term.output $
            "[Decl] " <> name <> " (signature accepted; persistence deferred in this slice)"
          emitCodeGen (TDecl decl)
          pure env

        DeclDef _ pat rhs ->
          case pat of
            PVar _ name -> do
              tcResult <- try \ex ->
                runReader env \envHandle -> do
                  rawTy <- infer st envHandle ex rhs
                  monoTy <- zonk st rawTy
                  generalize st env monoTy

              case tcResult of
                Left err -> do
                  term.output $ "Type Error: " <> err.msg <> " at " <> T.pack (show err.span)
                  pure env
                Right polyTy -> do
                  let updatedEnv = MkEnv ((name, polyTy) : env.bindings)
                  term.output $ "[Decl] " <> name
                  term.output $ "[Type] " <> T.pack (show polyTy)
                  emitCodeGen (TDecl decl)
                  pure updatedEnv

            _ -> do
              term.output "Error: top-level declaration currently requires a variable binder."
              pure env

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
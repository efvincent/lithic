module Compiler.Lexer where

import Data.Char (isSpace, isAlpha, isAlphaNum)
import Data.Function ((&))
import Data.Text (Text)
import Lens.Micro ((.~))
import qualified Data.Text as T
import GHC.Generics (Generic)
import Data.Generics.Labels ()
import Compiler.AST (SourceSpan(..))
import Bluefin.Eff ((:>), Eff, runPureEff)
import Bluefin.State (State, get, runState, put)
import Bluefin.Exception (Exception, throw, try)

-- | The fundamental categories of syntax in Lithic
data TokenClass
  = TokIdent Text -- ^ Variables names (e.g., "x", "myFunc")
  | TokLet        -- ^ The `let` keyword
  | TokIn         -- ^ The `in` keyword
  | TokLam        -- ^ The `\` or `fn` keyword for lambdas
  | TokArrow      -- ^ The `->` operator
  | TokAssign     -- ^ The `=` operator
  | TokLParen 
  | TokRParen
  | TokEOF
  deriving (Show, Eq, Generic)

-- | A complete token, pairing its syntactic class with its exact source location
data Token = MkToken
  { cls :: !TokenClass 
  , span :: !SourceSpan
  } deriving (Show, Eq, Generic)

-- | A custom error type for lexical failures
data LexError = MkLexError
  { msg :: Text
  , line :: Int
  , col :: Int
  } deriving (Show, Eq, Generic)

-- | The internal state of our scanner
data ScannerState = MkScannerState
  { txt  :: !Text
  , line :: !Int
  , col  :: !Int
  } deriving (Show, Eq, Generic) 

-- | The core scanning loop. Takes handles for State and Exceptionsshared, returns a list of tokens
scanTokens
  :: forall st ex es. (st :> es, ex :> es)
  => State ScannerState st
  -> Exception LexError ex
  -> Eff es [Token]
scanTokens st ex = loop []
  where
    loop acc = do
      skipWhitespace st
      startSt <- get st

      if T.null startSt.txt
      then do
        -- Append EOF token using the final position
        let eofSpan = MkSourceSpan startSt.line startSt.col startSt.line startSt.col
        pure $ reverse (MkToken TokEOF eofSpan : acc)
      else do
        mc <- advance st
        case mc of 
          -- Single character operators
          Just '\\' -> emit TokLam startSt acc
          Just '='  -> emit TokAssign startSt acc
          Just '('  -> emit TokLParen startSt acc
          Just ')'  -> emit TokRParen startSt acc

          -- Two character operator `->` requires a lookahead
          Just '-' -> do
            next <- peek st
            case next of 
              Just '>' -> do
                _ <- advance st
                emit TokArrow startSt acc
              _ -> throw ex (MkLexError ("Unexpected character '-'. Did you mean '->'?") startSt.line startSt.col)
          
          -- Identifiers and keywords
          Just c | isAlpha c -> do
            -- We already consumed `c`, so we grab the rest
            rest <- consumeWhile isAlphaNum st
            let ident = T.singleton c <> rest

            -- Keyword routing
            case ident of
              "let" -> emit TokLet startSt acc
              "in"  -> emit TokIn startSt acc
              "fn"  -> emit TokLam startSt acc    -- 'fn' as an alternative to '\'
              _     -> emit (TokIdent ident) startSt acc

          -- Fallback for unhandled characters
          Just c -> throw ex (MkLexError ("Unexpected character: " <> T.singleton c) startSt.line startSt.col)
          Nothing -> loop acc

    -- | Helper to construct the token with its span and continue the loop
    emit :: TokenClass -> ScannerState -> [Token] -> Eff es [Token]
    emit cls startSt acc = do
      endSt <- get st
      -- We subtract 1 from the end column because `advance` moves the cursor past the token.
      -- This gives us an inclusive end position for the span.
      let sp = MkSourceSpan startSt.line startSt.col endSt.line (endSt.col - 1)
      loop (MkToken cls sp : acc)

-- | Looks at the next character without consuming it
peek :: forall st es. (st :> es) => State ScannerState st -> Eff es (Maybe Char)
peek st = do
  curSt <- get st
  pure $ fst <$> (T.uncons curSt.txt)

-- | Consumes the next character and updates the line/column state.
advance :: forall st es. (st :> es) => State ScannerState st -> Eff es (Maybe Char)
advance st = do
  curSt <- get st
  case T.uncons curSt.txt of
    Nothing -> pure Nothing
    Just (c, rest) -> do
      let newLine = if c == '\n' then curSt.line + 1 else curSt.line
          newCol  = if c == '\n' then 1 else curSt.col + 1
      put st $ curSt & #txt .~ rest & #line .~ newLine & #col .~ newCol
      pure $ Just c

-- | Advance the scanner past any whitespace characters
skipWhitespace :: forall st es. (st :> es) => State ScannerState st -> Eff es ()
skipWhitespace st = do
  mc <- peek st
  case mc of
    Just c | isSpace c -> do 
      _ <- advance st
      skipWhitespace st
    _ -> pure ()

-- | Consumes characters as long as they match the given predicate
consumeWhile :: forall st es. (st :> es) => (Char -> Bool) -> State ScannerState st -> Eff es Text
consumeWhile predicate st = T.pack . reverse <$> loop []
  where
    loop acc = do
      mc <- peek st
      case mc of 
        Just c | predicate c -> do
          _ <- advance st
          loop (c : acc)
        _ -> pure acc

-- | The pure entry point for the lexter.
-- This completely encapsulates the Bluefin effectrs so the rest of the compiler
-- just sees a function from Text -> Either LexError [Token]
runLexer :: Text -> Either LexError [Token]
runLexer input =
  runPureEff $
    fmap fst $
      runState (MkScannerState input 1 1) \st ->
        try $ \ex -> 
          scanTokens st ex

module Compiler.Parser where

import Data.Text (Text)
import qualified Data.Text as T
import GHC.Generics (Generic)
import Data.Function ((&))
import Lens.Micro ((.~), (%~))
import Data.Generics.Labels ()

import Bluefin.Eff ((:>), Eff, runPureEff)
import Bluefin.State (State, get, put, runState)
import Bluefin.Exception (Exception, throw, try)

import Compiler.AST (Expr(..), SourceSpan(..))
import Compiler.Lexer (Token(..), TokenClass(..))

-- | Precedence levels for lithic operators, from loosest to tightest binding
data Precedence
  = PrecLowest
  | PrecBind    -- let x = ... in ...
  | PrecArrow   -- \x -> ...
  | PrecApp     -- Function application (f x)
  deriving (Eq, Ord, Show, Generic)

-- | Helper to map Precedence to an integer for Pratt comparison logic
precVal :: Precedence -> Int
precVal = \case
  PrecLowest -> 0
  PrecBind   -> 10
  PrecArrow  -> 20
  PrecApp    -> 30

data ParseError = MkParseError
  { msg   :: !Text
  , span  :: !SourceSpan
  } deriving (Show, Eq, Generic)

data ParserState = MkParserState
  { tokens :: ![Token]
  } deriving (Show, Eq, Generic)

-- | Look at the current token without consuming it
peek :: forall st es. (st :> es) => State ParserState st -> Eff es (Maybe Token)
peek st = do
  curSt <- get st
  case curSt.tokens of
    [] -> pure Nothing
    (t:_) -> pure (Just t)

-- | Consume and return the current token
advance :: forall st es. (st :> es) => State ParserState st -> Eff es (Maybe Token)
advance st = do
  curSt <- get st
  case curSt.tokens of
    [] -> pure Nothing
    (t:ts) -> do
      put st $ curSt & #tokens .~ ts
      pure (Just t)

-- | Extracts the source span from any AST node
getSpan :: Expr -> SourceSpan
getSpan = \case
  Var sp _     -> sp
  Lam sp _ _   -> sp
  App sp _ _   -> sp
  Let sp _ _ _ -> sp

-- | Creates a bounding box spanning from the start of the first to the end of the second.
mergeSpan :: SourceSpan -> SourceSpan -> SourceSpan
mergeSpan (MkSourceSpan sl sc _ _) (MkSourceSpan _ _ el ec) =
  MkSourceSpan sl sc el ec

-- | Checks the precedence of the upcoming token without consuming it.
peekPrecedence :: forall st es. (st :> es) => State ParserState st -> Eff es Int
peekPrecedence st = do
  mTok <- peek st
  pure case mTok of
    Nothing -> precVal PrecLowest
    Just tok -> case tok.cls of
      -- These tokens can start an expression, meaning they act as
      -- implicit application operators if they appear next to an existing expression.
      TokIdent _ -> precVal PrecApp
      TokLParen  -> precVal PrecApp
      TokLet     -> precVal PrecApp
      TokLam     -> precVal PrecApp
      _          -> precVal PrecLowest

-- | Pushes a token back onto the front of the stream.
pushBack :: forall st es. (st :> es) => Token -> State ParserState st -> Eff es ()
pushBack tok st = do
  curSt <- get st
  put st $ curSt & #tokens %~ (tok :)

-- | The core Pratt parsing loop.
parseExpr 
  :: forall st ex es. (st :> es, ex :> es)
  => Int
  -> State ParserState st
  -> Exception ParseError ex
  -> Eff es Expr
parseExpr rbp st ex = do
  mTok <- advance st
  left <- case mTok of
    Nothing -> throw ex (MkParseError "Unexpected EOF" (MkSourceSpan 0 0 0 0))
    Just tok -> parseNud tok st ex

  loop rbp left
  where
    loop currentPower left' = do
      nextPower <- peekPrecedence st
      if currentPower < nextPower
      then do
        mNext <- advance st
        case mNext of
          Just nextTok -> do
            newLeft <- parseLed left' nextTok st ex
            loop currentPower newLeft
          Nothing -> pure left'
      else pure left'

-- | Consumes a specific token or throws a parse error.
expect 
  :: forall st ex es. (st :> es, ex :> es) 
  => TokenClass 
  -> State ParserState st 
  -> Exception ParseError ex 
  -> Eff es ()
expect cls st ex = do
  mTok <- advance st
  case mTok of
    Just tok | tok.cls == cls -> pure ()
             | otherwise      -> throw ex (MkParseError ("Expected " <> T.pack (show cls)) tok.span)
    Nothing -> throw ex (MkParseError "Unexpected EOF" (MkSourceSpan 0 0 0 0))

-- | Consumes an identifier token and extracts its text.
expectIdent
  :: forall st ex es. (st :> es, ex :> es)
  => State ParserState st
  -> Exception ParseError ex
  -> Eff es Text
expectIdent st ex = do
  mTok <- advance st
  case mTok of
    Just tok -> case tok.cls of
      TokIdent x -> pure x
      _          -> throw ex (MkParseError "Expected identifier" tok.span)
    Nothing -> throw ex (MkParseError "Unexpected EOF" (MkSourceSpan 0 0 0 0))

-- | Parses tokens that do not depend on a left-hand context (Prefix / Variables)
parseNud
  :: forall st ex es. (st :> es, ex :> es)
  => Token
  -> State ParserState st
  -> Exception ParseError ex
  -> Eff es Expr
parseNud tok st ex = 
  case tok.cls of
    TokIdent x -> pure $ Var tok.span x

    TokLParen -> do
      expr <- parseExpr (precVal PrecLowest) st ex
      expect TokRParen st ex
      -- We can override the span to include the parens if we want strict CST tracking, 
      -- but returning the inner expr is standard for an AST.
      pure expr
    
    TokLam -> do
      xTok <- expectIdent st ex
      expect TokArrow st ex
      body <- parseExpr (precVal PrecLowest) st ex
      pure $ Lam (mergeSpan tok.span (getSpan body)) xTok body

    TokLet -> do
      xTok <- expectIdent st ex
      expect TokAssign st ex
      val <- parseExpr (precVal PrecBind) st ex
      expect TokIn st ex
      body <- parseExpr (precVal PrecLowest) st ex
      pure $ Let (mergeSpan tok.span (getSpan body)) xTok val body
      
    _ -> throw ex (MkParseError ("Unexpected token in expression position: " <> T.pack (show tok.cls)) tok.span)

-- | Parses tokens that operate on the expression immediately to their left (Infix/Application).
parseLed 
  :: forall st ex es. (st :> es, ex :> es) 
  => Expr 
  -> Token 
  -> State ParserState st 
  -> Exception ParseError ex 
  -> Eff es Expr
parseLed left tok st ex = case tok.cls of
  -- If we see a token that starts an expression, it is an implicit application.
  -- We push it back so `parseExpr` can consume it naturally as a NUD.
  cls | isAppStarter cls -> do
    pushBack tok st
    right <- parseExpr (precVal PrecApp) st ex
    pure $ App (mergeSpan (getSpan left) (getSpan right)) left right
    
  _ -> throw ex (MkParseError "Unexpected token in operator position" tok.span)
  where
    isAppStarter = \case
      TokIdent _ -> True
      TokLParen  -> True
      TokLet     -> True
      TokLam     -> True
      _          -> False

-- | Pure entry point for the Parser.
runParser :: [Token] -> Either ParseError Expr
runParser toks = 
  runPureEff $
    fmap fst $
      runState (MkParserState toks) \st ->
        try \ex -> do
          expr <- parseExpr (precVal PrecLowest) st ex
          -- Ensure the entire token stream was consumed
          expect TokEOF st ex
          pure expr
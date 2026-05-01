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

import Compiler.AST (Expr(..), SourceSpan(..), Type (..), getTypeSpan, getSpan)
import Compiler.Lexer (Token(..), TokenClass(..))

-- | Precedence levels for lithic operators, from loosest to tightest binding
data Precedence
  = PrecLowest
  | PrecAnn     -- expr : Type
  | PrecApp     -- Function application (f x)
  deriving (Eq, Ord, Show, Generic)

-- | Helper to map Precedence to an integer for Pratt comparison logic
precVal :: Precedence -> Int
precVal = \case
  PrecLowest -> 0
  PrecAnn    -> 5
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
      TokIdent _  -> precVal PrecApp
      TokUIdent _ -> precVal PrecApp
      TokInt _    -> precVal PrecApp
      TokLParen   -> precVal PrecApp
      TokLet      -> precVal PrecApp
      TokLam      -> precVal PrecApp
      TokColon    -> precVal PrecAnn
      _           -> precVal PrecLowest

-- | Pushes a token back onto the front of the stream.
pushBack :: forall st es. (st :> es) => Token -> State ParserState st -> Eff es ()
pushBack tok st = do
  curSt <- get st
  put st $ curSt & #tokens %~ (tok :)

-- | Consumes a sequence of lowercase identifiers until it hits a specific token
consumeTypeVars 
  :: forall st ex es. (st :> es, ex :> es)
  => State ParserState st -> Exception ParseError ex -> Eff es [Text]
consumeTypeVars st ex = loop []
  where
    loop acc = do
      next <- peek st
      case next of
        Just t | t.cls == TokDot -> pure (reverse acc)
        _ -> do
          v <- expectIdent st ex
          loop (v : acc)  

-- | Parses a Type signature
-- Type have a simple right-associative grammar, so a direct recursive descent parser
-- is sufficient.
parseType 
  :: forall st ex es. (st :> es, ex :> es)
  => State ParserState st -> Exception ParseError ex -> Eff es Type
parseType st ex = do
  mTok <- advance st
  leftTyp <- case mTok of
    Just tok -> case tok.cls of
      TokIdent x  -> pure $ TVar tok.span x
      TokUIdent x ->
        if x == "Int"
        then pure $ TInt tok.span
        else pure $ TVar tok.span x
      TokForall -> do
        vars <- consumeTypeVars st ex
        expect TokDot st ex
        innerTy <- parseType st ex
        pure $ TForall (mergeSpan tok.span (getTypeSpan innerTy)) vars innerTy
      TokLParen   -> do
        inner <- parseType st ex
        expect TokRParen st ex
        pure inner
      _ -> throw ex (MkParseError "Expected type" tok.span)
    Nothing ->
      throw ex (MkParseError "Unexpected EOF" (MkSourceSpan 0 0 0 0))
  -- Lookahead for the right-associative  `->`
  nextTok <- peek st
  case nextTok of
    Just t | t.cls == TokArrow -> do
      _ <- advance st
      rightTyp <- parseType st ex
      pure $ TArrow (mergeSpan (getTypeSpan leftTyp) (getTypeSpan rightTyp)) leftTyp rightTyp
    _ -> pure leftTyp

-- | The core Pratt parsing loop.
parseExpr 
  :: forall st ex es. (st :> es, ex :> es)
  => Int -> State ParserState st -> Exception ParseError ex -> Eff es Expr
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
  => TokenClass -> State ParserState st -> Exception ParseError ex -> Eff es ()
expect cls st ex = do
  mTok <- advance st
  case mTok of
    Just tok | tok.cls == cls -> pure ()
             | otherwise      -> throw ex (MkParseError ("Expected " <> T.pack (show cls)) tok.span)
    Nothing -> throw ex (MkParseError "Unexpected EOF" (MkSourceSpan 0 0 0 0))

-- | Consumes an identifier token and extracts its text.
expectIdent
  :: forall st ex es. (st :> es, ex :> es)
  => State ParserState st -> Exception ParseError ex -> Eff es Text
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
  => Token -> State ParserState st -> Exception ParseError ex -> Eff es Expr
parseNud tok st ex = 
  case tok.cls of
    TokIdent x -> pure $ Var tok.span x

    TokUIdent x -> pure $ Var tok.span x

    TokInt val -> pure $ Lit tok.span val

    TokLParen -> do
      expr <- parseExpr (precVal PrecLowest) st ex
      expect TokRParen st ex
      -- We can override the span to include the parens if we want strict CST tracking, 
      -- but returning the inner expr is standard for an AST.
      pure expr
    
    TokLam -> do
      xTok <- expectIdent st ex

      -- Check for optional type annotation (e.g. `\x : Int => ...`)
      next <- peek st
      mTy <- case next of
        Just t | t.cls == TokColon -> do
          _ <- advance st
          ty <- parseType st ex
          pure (Just ty)
        _ -> pure Nothing
      
      -- Enforce the Lean4/Rust style term delimiter
      expect TokFatArrow st ex
      body <- parseExpr (precVal PrecLowest) st ex
      pure $ Lam (mergeSpan tok.span (getSpan body)) xTok mTy body

    TokLet -> do
      xTok <- expectIdent st ex
      expect TokAssign st ex
      -- Lowered from PrecBind to PrecLowest to allow type annotations
      val <- parseExpr (precVal PrecLowest) st ex
      expect TokIn st ex
      body <- parseExpr (precVal PrecLowest) st ex
      pure $ Let (mergeSpan tok.span (getSpan body)) xTok val body
      
    _ -> 
      throw ex (MkParseError ("Unexpected token in expression position: " 
      <> T.pack (show tok.cls)) tok.span)

-- | Parses tokens that operate on the expression immediately to their left (Infix/Application).
parseLed 
  :: forall st ex es. (st :> es, ex :> es) 
  => Expr -> Token -> State ParserState st -> Exception ParseError ex -> Eff es Expr
parseLed left tok st ex = case tok.cls of
  TokColon -> do
    ty <- parseType st ex
    pure $ Ann (mergeSpan (getSpan left) (getTypeSpan ty)) left ty

  -- If we see a token that starts an expression, it is an implicit application.
  -- We push it back so `parseExpr` can consume it naturally as a NUD.
  cls | isAppStarter cls -> do
    pushBack tok st
    right <- parseExpr (precVal PrecApp) st ex
    pure $ App (mergeSpan (getSpan left) (getSpan right)) left right
    
  _ -> throw ex (MkParseError "Unexpected token in operator position" tok.span)
  where
    isAppStarter = \case
      TokIdent _  -> True
      TokUIdent _ -> True
      TokInt _    -> True
      TokLParen   -> True
      TokLet      -> True
      TokLam      -> True
      _           -> False

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
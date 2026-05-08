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

import Compiler.AST 
import Compiler.Lexer (Token(..), TokenClass(..))

-- | Defines the binding power (precedence) of operators and expressions 
-- during Pratt parsing. Higher values bind more tightly.
data Precedence
  = PrecLowest   -- ^ Base precedence for standard expressions
  | PrecAnn      -- ^ Type annotations (e.g., @expr : Type@)
  | PrecAdd      -- ^ Addition / subtraction
  | PrecApp      -- ^ Function application (e.g., @f x@)
  | PrecPrefix   -- ^ Unary prefix operations (e.g., @-x@)
  | PrecSelect   -- ^ Record field selection (e.g., @record.x@)
  deriving (Eq, Ord, Show, Generic)

-- | Helper to map Precedence to an integer for Pratt comparison logic
precVal :: Precedence -> Int
precVal = \case
  PrecLowest -> 0
  PrecAnn    -> 5
  PrecAdd    -> 10
  PrecApp    -> 30
  PrecPrefix -> 35
  PrecSelect -> 40

data ParseError = MkParseError
  { msg   :: !Text
  , span  :: !Span
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
mergeSpan :: Span -> Span -> Span
mergeSpan (MkSpan sl sc _ _) (MkSpan _ _ el ec) =
  MkSpan sl sc el ec

-- | Single source of truth for Pratt binding power by token class.
-- Keep implicit application routing centralized here to avoid drift.
tokenPrecedence :: TokenClass -> Int
tokenPrecedence = \case
  cls | isAppStarter cls -> precVal PrecApp
  TokDot                 -> precVal PrecSelect
  TokMinus               -> precVal PrecAdd
  _                      -> precVal PrecLowest

-- | Checks the precedence of the upcoming token without consuming it.
peekPrecedence :: forall st es. (st :> es) => State ParserState st -> Eff es Int
peekPrecedence st = do
  mTok <- peek st
  pure case mTok of
    Nothing -> precVal PrecLowest
    Just tok -> tokenPrecedence tok.cls

-- | Parse top-level input: either a declaration or an expression.
-- Parses `def p = e` as a declaration; otherwise parses a plain expression.
-- In both cases, input must end at EOF.
parseTopLevel :: [Token] -> Either ParseError TopLevel
parseTopLevel toks =
  runPureEff $
    fmap fst $
      runState (MkParserState toks) \st ->
      try \ex -> do
        eTok <- peek st
        case eTok of
          Just t | t.cls == TokDef -> do
            _ <- advance st
            pat <- parsePattern st ex
            expect TokAssign st ex
            rhs <-  parseExpr (precVal PrecLowest) st ex
            let declSpan = mergeSpan t.span (getSpan rhs)
            mNext <- peek st
            case mNext of
              Just t' | t'.cls == TokEOF -> pure (TDecl (DeclDef declSpan pat rhs))
              Just t' -> throw ex (MkParseError "Expected EOF after declaration" t'.span)
              Nothing -> throw ex (MkParseError "Unexpected EOF after declaration" declSpan)

          Just t | TokIdent name <- t.cls -> do
            _ <- advance st 
            mNext <- peek st
            case mNext of
              Just t' | t'.cls == TokColon -> do
                _ <- advance st
                sigTy <- parseType st ex
                let sigSpan = mergeSpan t.span (getTypeSpan sigTy)
                mEnd <- peek st
                case mEnd of
                  Just e | e.cls == TokEOF -> pure (TDecl (DeclSig sigSpan name sigTy))
                  Just e -> throw ex (MkParseError "Expected EOF after declaration" e.span)
                  Nothing -> throw ex (MkParseError "Unexpected EOF after declaration" sigSpan)
              _ -> do
                pushBack t st
                expr <- parseExpr (precVal PrecLowest) st ex
                mEnd <- peek st
                case mEnd of
                  Just e | e.cls == TokEOF -> pure (TExpr expr)
                  Just e -> throw ex (MkParseError "Expected EOF after expression" e.span)
                  Nothing -> throw ex (MkParseError "Unexpected EOF after expression" (getSpan expr))
                  
          _ -> do
            expr <- parseExpr (precVal PrecLowest) st ex
            mNext <- peek st
            case mNext of
              Just t' | t'.cls == TokEOF -> pure (TExpr expr)
              Just t' -> throw ex (MkParseError "Expected EOF after expression" t'.span)
              Nothing -> throw ex (MkParseError "Unexpected EOF after declaration" (getSpan expr))
              
-- | Recursively parses the interior fields of a record definition
-- Handles standard fields separated by commas, and row extensions 
-- indicated by a pipe.
--
-- For example, parses: {x = 1, y = 2 | rest}
-- and correctly merges `Span` boundaries as it builds the AST.
parseRecordFields
  :: forall st ex es. (st :> es, ex :> es)
  => Span -> State ParserState st -> Exception ParseError ex -> Eff es Expr
parseRecordFields startSpan st ex = do
  label <- expectIdent st ex
  expect TokAssign st ex
  val <- parseExpr (precVal PrecLowest) st ex
  mNext <- advance st
  case mNext of
    -- Another field
    Just t | t.cls == TokComma -> do
      rest <- parseRecordFields startSpan st ex
      pure $ RecExtend (mergeSpan startSpan (getSpan rest)) label val rest
    -- Row extension
    Just t | t.cls == TokPipe -> do
      rest <- parseExpr (precVal PrecLowest) st ex
      endTok <- advance st
      case endTok of
        Just e | e.cls == TokRBrace ->
          pure $ RecExtend (mergeSpan startSpan e.span) label val rest
        _ -> throw ex (MkParseError "Expected '}' after row extension" startSpan)
    -- End of record
    Just t | t.cls == TokRBrace -> do
      let emptyRec = RecEmpty t.span
      pure $ RecExtend (mergeSpan startSpan t.span) label val emptyRec

    _ -> throw ex (MkParseError "Expected comma (,) pipe (|) or right brace (}) in record" startSpan)

-- | Parses a dot-separated list of path segments for deep record updates
parsePathSegments
  :: forall st ex es. (st :> es, ex :> es)
  => State ParserState st -> Exception ParseError ex -> Eff es [PathSegment]
parsePathSegments st ex = do
  -- currently only PathField is supported, so we expect an identifier
  label <- expectIdent st ex
  let segment = PathField label
  next <- peek st
  case next of
    Just t | t.cls == TokDot -> do
      _ <- advance st -- Consume the dot
      rest <- parsePathSegments st ex
      pure (segment : rest)
    _ -> pure [segment]
    
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

-- | Parses the interior of a structural row type: { x:Int, y:Bool | rest }
parseRowType
  :: forall st ex es. (st :> es, ex :> es)
  => Span -> State ParserState st -> Exception ParseError ex ->Eff es Type
parseRowType startSpan st ex = do
  next <- peek st
  case next of
    Just t | t.cls == TokRBrace -> do
      _ <- advance st
      pure $ TRowEmpty (mergeSpan startSpan t.span)
    _ -> do
      -- Labels can be lowercase (records) or uppercase (variants)
      labelTok <- advance st
      label <- case labelTok of
        Just t | TokIdent x <- t.cls -> pure x
        Just t | TokUIdent x <- t.cls -> pure x
        Just bad -> throw ex (MkParseError "Expected label identifier" bad.span)
        Nothing -> throw ex (MkParseError "Unexpected EOF in row type" startSpan)
      
      expect TokColon st ex
      ty <- parseType st ex
      mNext <- advance st
      case mNext of
        Just t | t.cls == TokComma -> do
          rest <- parseRowType startSpan st ex
          pure $ TRowExtend (mergeSpan startSpan (getTypeSpan rest)) label ty rest
        Just t | t.cls == TokPipe -> do
          rest <- parseType st ex
          endTok <- advance st
          case endTok of
            Just e | e.cls == TokRBrace ->
              pure $ TRowExtend (mergeSpan startSpan e.span) label ty rest
            _ -> throw ex (MkParseError "Expected '}' after row extension" startSpan)
        Just t | t.cls == TokRBrace -> do
          let emptyRow = TRowEmpty t.span
          pure $ TRowExtend (mergeSpan startSpan t.span) label ty emptyRow
        _ -> throw ex (MkParseError "Expceted ',', '|', or '}' in row type" startSpan)


-- | Parses a single type atom or a type constructor application.
parseTypeAtom 
  :: forall st ex es. (st :> es, ex :> es)
  => State ParserState st -> Exception ParseError ex -> Eff es Type
parseTypeAtom st ex = do
  mTok <- advance st
  case mTok of
    Just tok -> case tok.cls of
      TokIdent x  -> pure $ TVar tok.span x
      TokUIdent x -> 
        case x of
          "Int"     -> pure $ TInt tok.span
          "Float"   -> pure $ TFloat tok.span
          "String"  -> pure $ TString tok.span
          "Bool"    -> pure $ TBool tok.span
          "Variant" -> do
            -- We call parseTypeAtom here so it doesn't swallow arrows
            innerTy <- parseTypeAtom st ex
            pure $ TVariant (mergeSpan tok.span (getTypeSpan innerTy)) innerTy
          "Record"  -> do
            innerTy <- parseTypeAtom st ex
            pure $ TRecord (mergeSpan tok.span (getTypeSpan innerTy)) innerTy
          _         -> pure $ TNominal tok.span x   

      -- Routes the { token to the row parser
      TokLBrace -> parseRowType tok.span st ex

      TokForall -> do
        vars <- consumeTypeVars st ex
        expect TokDot st ex
        -- The body of forall goes all the way to the end, so full parseType is needed
        innerTy <- parseType st ex
        pure $ TForall (mergeSpan tok.span (getTypeSpan innerTy)) vars innerTy
      
      TokLParen   -> do
        inner <- parseType st ex
        expect TokRParen st ex
        pure inner
      
      _ -> throw ex (MkParseError "Expected type" tok.span)
    
    Nothing ->
      throw ex (MkParseError "Unexpected EOF" (MkSpan 0 0 0 0))

-- | Parses a Type Signature (handles right-associative arrows)
parseType
  :: forall st ex es. (st :> es, ex :> es)
  => State ParserState st -> Exception ParseError ex -> Eff es Type
parseType st ex = do
  -- First parse the left-hand side as an atom
  leftTyp <- parseTypeAtom st ex
  -- Lookahead for the right-associative `->`
  nextTok <- peek st
  case nextTok of
    Just t | t.cls == TokArrow -> do
      _ <- advance st
      rightTyp <- parseType st ex
      pure $ TArrow (mergeSpan (getTypeSpan leftTyp) (getTypeSpan rightTyp)) leftTyp rightTyp
    _ -> pure leftTyp

-- | Parses a pattern for use in bindings (Lambdas, Lets, Cases)
parsePattern
  :: forall st ex es. (st :> es, ex :> es)
  => State ParserState st -> Exception ParseError ex -> Eff es Pattern
parsePattern st ex = do
  mTok <- advance st
  case mTok of 
    Just tok -> case tok.cls of
      TokWildcard   -> pure $ PWildcard tok.span
      TokIdent x    -> pure $ PVar tok.span x
      TokInt val    -> pure $ PLit tok.span (LInt val)
      TokFloat val  -> pure $ PLit tok.span (LFloat val)
      TokString val -> pure $ PLit tok.span (LString val)
      TokTrue       -> pure $ PLit tok.span (LBool True)
      TokFalse      -> pure $ PLit tok.span (LBool False)
      TokUIdent x   -> do
        -- Variant pattern: `Ok p`
        -- We expect a payload pattern immediately following the constructor
        payload <- parsePattern st ex
        pure $ PVariant (mergeSpan tok.span (getPatternSpan payload)) x payload

        -- TODO: Add TokLBrace here later to support `\{x, y} => ...` record pattern
      _ -> throw ex (MkParseError "Expected a pattern (variable, wildcard, literal, or variant)" tok.span)
    Nothing -> throw ex (MkParseError "Unexpected EOF while parsing pattern" (MkSpan 0 0 0 0))

-- | The core Pratt parsing loop.
parseExpr 
  :: forall st ex es. (st :> es, ex :> es)
  => Int -> State ParserState st -> Exception ParseError ex -> Eff es Expr
parseExpr rbp st ex = do
  mTok <- advance st
  left <- case mTok of
    Nothing -> throw ex (MkParseError "Unexpected EOF" (MkSpan 0 0 0 0))
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
    Nothing -> throw ex (MkParseError "Unexpected EOF" (MkSpan 0 0 0 0))

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
    Nothing -> throw ex (MkParseError "Unexpected EOF" (MkSpan 0 0 0 0))

-- | Parses tokens that do not depend on a left-hand context (Prefix / Variables)
parseNud
  :: forall st ex es. (st :> es, ex :> es)
  => Token -> State ParserState st -> Exception ParseError ex -> Eff es Expr
parseNud tok st ex = 
  case tok.cls of

    TokIdent x    -> pure $ Var tok.span x
    TokInt val    -> pure $ Lit tok.span (LInt val)
    TokFloat val  -> pure $ Lit tok.span (LFloat val)
    TokString val -> pure $ Lit tok.span (LString val)
    TokTrue       -> pure $ Lit tok.span (LBool True)
    TokFalse      -> pure $ Lit tok.span (LBool False)

    TokMinus -> do
      -- Parse the inner expression at prefix precedence to tightly bind `-`
      right <- parseExpr (precVal PrecPrefix) st ex
      pure $ Unary (mergeSpan tok.span (getSpan right)) UMinus right

    TokLParen -> do
      expr <- parseExpr (precVal PrecLowest) st ex
      expect TokRParen st ex
      -- We can override the span to include the parens if we want strict CST tracking, 
      -- but returning the inner expr is standard for an AST.
      pure expr
    
    -- | Parses record construction. Handles both empty records `{}`
    -- and populated records `{x = 1}`.
    TokLBrace -> do
      next <- peek st
      case next of
        Just t | t.cls == TokRBrace -> do
          _ <- advance st   -- consume `}`
          pure $ RecEmpty (mergeSpan tok.span t.span)
        _ -> parseRecordFields tok.span st ex

    TokLam -> do
      pat <- parsePattern st ex

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
      pure $ Lam (mergeSpan tok.span (getSpan body)) pat mTy body

    TokLet -> do
      pat <- parsePattern st ex
      -- Check for optional type annotation
      next <- peek st
      mTy <- case next of
        Just t | t.cls == TokColon -> do
          _ <- advance st
          ty <- parseType st ex
          pure (Just ty)
        _ -> pure Nothing
      expect TokAssign st ex
      val <- parseExpr (precVal PrecLowest) st ex
      expect TokIn st ex
      body <- parseExpr (precVal PrecLowest) st ex
      -- Desugar the annotation onto the value expression
      let finalVal = case mTy of
            Just ty -> Ann (mergeSpan (getTypeSpan ty) (getSpan val)) val ty
            Nothing -> val
      pure $ Let (mergeSpan tok.span (getSpan body)) pat finalVal body
      
    TokCase -> do
      scrutinee <- parseExpr (precVal PrecLowest) st ex
      expect TokOf st ex
      -- Recursively parse `| pattern => Expression`
      let parseBranches branches = do
            next <- peek st
            case next of
              Just t | t.cls == TokPipe -> do
                _ <- advance st -- Consume `|`
                pat <- parsePattern st ex
                expect TokFatArrow st ex 
                body <- parseExpr (precVal PrecLowest) st ex
                parseBranches (branches ++ [(pat, body)])
              _ -> pure branches
      branches <- parseBranches []
      if null branches
      then throw ex $ MkParseError "Case expression must have at least one branch" tok.span
      else pure $ Case (mergeSpan tok.span (getSpan (snd (last branches)))) scrutinee branches

    TokUIdent x -> do
      -- We parse the payload expression at Application precedence
      payload <- parseExpr (precVal PrecApp) st ex
      pure $ Variant (mergeSpan tok.span (getSpan payload)) x payload

    _ -> 
      throw ex (MkParseError ("Unexpected token in expression position: " 
      <> T.pack (show tok.cls)) tok.span)

-- | Parses tokens that operate on the expression immediately to their 
-- left (Infix/Application).
parseLed 
  :: forall st ex es. (st :> es, ex :> es) 
  => Expr -> Token -> State ParserState st -> Exception ParseError ex -> Eff es Expr
parseLed left tok st ex = case tok.cls of
  
  TokColon -> do
    ty <- parseType st ex
    pure $ Ann (mergeSpan (getSpan left) (getTypeSpan ty)) left ty

  TokMinus -> do
    -- Parse the right-hand side at addition/subtraction precedence
    right <- parseExpr (precVal PrecAdd) st ex
    pure $ Binary (mergeSpan (getSpan left) (getSpan right)) OpSub left right

  -- | Parses record selection (record.x) OR deep updates (record.{ x.y := 42 })
  TokDot -> do
    nextTok <- advance st
    case nextTok of
      -- 1. Standard Record Selection
      Just t | TokIdent label <- t.cls ->
        pure $ RecSelect (mergeSpan (getSpan left) t.span) left label
      
      -- 2. Native Lens Deep update
      Just t | t.cls == TokLBrace -> do
        -- Parse the target path
        path <- parsePathSegments st ex
        -- Parse the operator
        opTok <- advance st
        updateOp <- case opTok of
          Just o | o.cls == TokLensSet -> pure OpSet
          Just o | o.cls == TokLensMod -> pure OpModify
          Just badOp -> throw ex $ MkParseError "Expected ':=' or '%=' after lens path" badOp.span
          Nothing -> throw ex $ MkParseError "Unexpected EOF in lens update" (getSpan left)
        -- Parse the new value / modifier function
        val <- parseExpr (precVal PrecLowest) st ex
        -- Consume the closing brace
        rbraceTok <- advance st
        case rbraceTok of
          Just endT | endT.cls == TokRBrace -> 
            pure $ RecUpdate (mergeSpan (getSpan left) endT.span) left path updateOp val
          Just badEnd -> throw ex $ MkParseError "Expected '}' to close lens update block" badEnd.span
          Nothing -> throw ex $ MkParseError "Unexpected EOF looking for '}'" (getSpan left)
      Just badTok -> throw ex $ MkParseError "Expected identifier or '{' after '.'" badTok.span
      Nothing -> throw ex $ MkParseError "Unexpected EOF after '.'" (getSpan left)
  
  -- If token precedence is application-level, route through implicit application.
  -- This stays in lockstep with `peekPrecedence` via `tokenPrecedence`.
  cls | tokenPrecedence cls == precVal PrecApp -> do
    pushBack tok st
    right <- parseExpr (precVal PrecApp) st ex
    pure $ App (mergeSpan (getSpan left) (getSpan right)) left right
    
  _ -> throw ex (MkParseError "Unexpected token in operator position" tok.span)

isAppStarter :: TokenClass -> Bool
isAppStarter = \case
  TokInt _    -> True
  TokFloat _  -> True
  TokString _ -> True
  TokTrue     -> True
  TokFalse    -> True
  TokIdent _  -> True
  TokUIdent _ -> True
  TokLParen   -> True
  TokLet      -> True
  TokLam      -> True
  TokLBrace   -> True
  TokCase     -> True
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
          -- Look at the remaining token instead of a blind expect
          mNext <- peek st
          case mNext of
            Just t | t.cls == TokEOF -> pure expr
            Just t ->
              throw ex $ MkParseError
                ("Expected EOF, but parser stopped early at token: " <> T.pack (show t.cls)) t.span
            Nothing -> pure expr 

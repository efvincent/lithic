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
import Compiler.Lexer (Token(..), TokenClass(..), runLayout)

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

-- | Structured parse failure carrying user-facing message and precise span.
data ParseError = MkParseError
  { msg   :: !Text
  , span  :: !Span
  } deriving (Show, Eq, Generic)

-- | Internal parser cursor state over the layout-processed token stream.
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

-- | Parse top-level input as either a declaration or an expression.
-- Supports declaration forms:
--   1) `def p = e`
--   2) `ident : Type`
--   3) `ident : Type` followed by `ident = expr` (same name), lowered to `DeclDef`
--      with an annotated RHS.
-- Disambiguation rule:
-- - At top level, bare `ident : Type` is parsed as a declaration signature.
-- - `ident : Type` followed by same-name equation is parsed as one declaration form.
-- In all branches, input must end at EOF.
parseTopLevel :: [Token] -> Either ParseError TopLevel
parseTopLevel toks =
  runPureEff $
    fmap fst $
      runState (MkParserState $ runLayout toks) \st ->
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
            startState <- get st
            _ <- advance st
            mNext <- peek st
            case mNext of
              Just t' | t'.cls == TokColon -> do
                _ <- advance st
                sigTy <- parseType st ex
                let sigSpan = mergeSpan t.span (getTypeSpan sigTy)

                consumeVirtualSemis st
                mEnd <- peek st
                case mEnd of
                  Just e | e.cls == TokEOF ->
                    pure (TDecl (DeclSig sigSpan name sigTy))
                  Just e | TokIdent eqName <- e.cls ->
                    if eqName == name then do
                      _ <- advance st
                      expect TokAssign st ex
                      rhs <- parseExpr (precVal PrecLowest) st ex
                      let rhsAnn = Ann (mergeSpan (getTypeSpan sigTy) (getSpan rhs)) rhs sigTy
                          pat    = PVar e.span name
                          defSp  = mergeSpan t.span (getSpan rhsAnn)
                      consumeVirtualSemis st
                      mAfter <- peek st
                      case mAfter of
                        Just endTok | endTok.cls == TokEOF ->
                          pure (TDecl (DeclDef defSp pat rhsAnn))
                        Just badTok ->
                          throw ex (MkParseError "Expected EOF after declaration" badTok.span)
                        Nothing ->
                          throw ex (MkParseError "Unexpected EOF after declaration" defSp)
                    else
                      throw ex (MkParseError "Signature/equation name mismatch" e.span)
                  Just e ->
                    throw ex (MkParseError "Expected EOF after declaration" e.span)
                  Nothing ->
                    throw ex (MkParseError "Unexpected EOF after declaration" sigSpan)

              _ -> do
                mFirst <- tryParseClauseTail st ex
                case mFirst of
                  Just firstClause -> do
                    moreClauses <- gatherAdditionalClauses name st ex
                    topLevel <- lowerEquationClauses t name (firstClause : moreClauses) ex
                    topLevel' <- parseOptionalWhere topLevel st ex
                    mEnd <- peek st
                    case mEnd of
                      Just e | e.cls == TokEOF -> pure topLevel'
                      Just e -> throw ex (MkParseError "Expected EOF after declaration" e.span)
                      Nothing -> throw ex (MkParseError "Unexpected EOF after declaration" t.span)
                  Nothing -> do
                    put st startState
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

-- | Try to parse the tail of a single function-equation clause:
-- One or more patterns followed by @=@ and a RHS expression.
-- Returns @Nothing@ (restoring parser state) when the lookahead does not look
-- like an equation clause. Does NOT consume EOF.
tryParseClauseTail
  :: forall st ex es. (st :> es, ex :> es)
  => State ParserState st -> Exception ParseError ex -> Eff es (Maybe ([Pattern], Expr))
tryParseClauseTail st ex = do
  startState <- get st
  mNext <- peek st
  case mNext of 
    Just tok | isPatternStarter tok.cls -> do
      firstPat <- parsePattern st ex
      mPats <- gatherPats [firstPat] startState
      case mPats of
        Nothing -> pure Nothing
        Just pats -> do
          expect TokAssign st ex
          rhs <- parseExpr (precVal PrecLowest) st ex
          pure (Just (pats, rhs))
    _ -> do
      put st startState
      pure Nothing
  where
    gatherPats acc saved = do
      mTok <- peek st
      case mTok of
        Just tok | tok.cls == TokAssign -> pure . Just . reverse $ acc
        Just tok | isPatternStarter tok.cls -> do
          pat <- parsePattern st ex
          gatherPats (pat : acc) saved
        _ -> do
          put st saved
          pure Nothing

-- | After parsing a first equation clause, greedily consume additional
-- clauses that begin with the same function name
gatherAdditionalClauses 
  :: forall st ex es. (st :> es, ex :> es)
  => Text -> State ParserState st -> Exception ParseError ex -> Eff es [([Pattern], Expr)]
gatherAdditionalClauses name st ex = go []
  where
    go acc = do
      skipClauseSeparators
      mTok <- peek st
      case mTok of 
        Just t | TokIdent n <- t.cls, n == name -> do
          saved <- get st
          _ <- advance st
          mClause <- tryParseClauseTail st ex
          case mClause of
            Just clause -> go (clause : acc)
            Nothing     -> do
              put st saved
              pure (reverse acc)
        _ -> pure (reverse acc)

    skipClauseSeparators :: Eff es ()
    skipClauseSeparators = do
      mTok <- peek st
      case mTok of
        Just t | t.cls == TokVirtSemi -> do
          _ <- advance st
          skipClauseSeparators
        _ -> pure ()

-- | Lower a list of same-name equation clauses to a single @DeclDef@
-- 
-- Single clause: preserves the existing @foldr mkLam@ lowering so that
-- golden snapshots for @decl-equation-single-clause@ remain stable.
--
-- Multi-clause (arity 1): wraps in a lambda over a fresh @$arg0@ variable
-- and inserts a @case@ dispatch. All clause patterns must have arity 1;
-- other arities produce a clear parse error.
lowerEquationClauses
  :: forall ex es. (ex :> es)
  => Token -- ^ name token (span source for synthetic nodes)
  -> Text -- ^ function name (used in diagnostics)
  -> [([Pattern], Expr)] -- ^ clauses: (patterns, rhs); non-empty by construction
  -> Exception ParseError ex
  -> Eff es TopLevel
lowerEquationClauses nameTok name clauses ex =
  case clauses of
    [] ->
      throw ex $ MkParseError
        ("Internal parser error: empty equation clause group for '" <> name <> "'")
        nameTok.span
    [(pats, rhs)] ->
      -- Single-clause: identical lowering to the previous tryParseEquationDecl.
      let lamBody  =
            foldr
              (\pat body -> Lam (mergeSpan (getPatternSpan pat) (getSpan body)) pat Nothing body)
              rhs
              pats
          declPat  = PVar nameTok.span name
          declSpan = mergeSpan nameTok.span (getSpan lamBody)
      in pure $ TDecl (DeclDef declSpan declPat lamBody)
    (firstClause : restClauses) -> do
      -- Multi-clause: check arity consistency without partial list functions.
      let arity = length (fst firstClause)
          allClauses = firstClause : restClauses
      case filter (\(pats, _) -> length pats /= arity) restClauses of
        (_:_) ->
          throw ex $ MkParseError
            ("Clauses for '" <> name <> "' have inconsistent arity")
            nameTok.span
        [] -> pure ()
      case arity of
        1 -> do
          let argSpan = nameTok.span
              argName = "$arg0"
              argVar  = Var argSpan argName
              toBranch (pats, rhs) = case pats of
                [p] -> Right (p, rhs)
                _   -> Left ()
          case traverse toBranch allClauses of
            Left _ ->
              throw ex $ MkParseError
                ("Internal parser error: arity check/destructure mismatch for '" <> name <> "'")
                nameTok.span
            Right branches ->
              case reverse branches of
                [] ->
                  throw ex $ MkParseError
                    ("Internal parser error: empty branch set for '" <> name <> "'")
                    nameTok.span
                (_, lastRhs) : _ -> do
                  let caseSpan = mergeSpan argSpan (getSpan lastRhs)
                      body     = Case caseSpan argVar branches
                      lamSpan  = mergeSpan argSpan (getSpan body)
                      lamExpr  = Lam lamSpan (PVar argSpan argName) Nothing body
                      declSpan = mergeSpan nameTok.span (getSpan lamExpr)
                  pure $ TDecl (DeclDef declSpan (PVar nameTok.span name) lamExpr)
        _ ->
          throw ex $ MkParseError
            ("Multi-argument multi-clause equations are not yet supported; \
             \use a single argument or a case expression")
            nameTok.span

-- | If the next token is `TokWhere`, parse the where block and desugar its
-- bindings into nested `Let` nodes wrapping the declaration's body.
-- Only applies to `DeclDef` nodes; other top-level forms are returned unchanged.
parseOptionalWhere
  :: forall st ex es. (st :> es, ex :> es)
  => TopLevel -> State ParserState st -> Exception ParseError ex -> Eff es TopLevel
parseOptionalWhere topLevel st ex = do
  mTok <- peek st
  case mTok of
    Just t | t.cls == TokWhere -> do
      _ <- advance st
      bindings <- parseWhereBindings st ex
      pure (applyWhereToTopLevel topLevel bindings)
    _ -> pure topLevel

-- | Parse a layout-delimited sequence of `pat = expr` bindings in a `where` block.
-- Entries are separated by `TokVirtSemi` and the block is closed by `TokVirtRBrace`.
parseWhereBindings
  :: forall st ex es. (st :> es, ex :> es)
  => State ParserState st -> Exception ParseError ex -> Eff es [(Pattern, Expr, Span)]
parseWhereBindings st ex = do
  firstBinding <- parseOneBinding
  restBindings <- parseMoreBindings []
  mClose <- peek st
  case mClose of
    Just t | t.cls == TokVirtRBrace -> do
      _ <- advance st
      pure ()
    _ -> pure ()
  pure (firstBinding : restBindings)
  where
    parseOneBinding = do
      pat <- parsePattern st ex
      let startSp = getPatternSpan pat
      mTok <- peek st
      mTy <- case mTok of 
        Just t | t.cls == TokColon -> do
          _ <- advance st
          ty <- parseType st ex
          pure (Just ty)
        _ -> pure Nothing
      expect TokAssign st ex
      rhs <- parseExpr (precVal PrecLowest) st ex
      let finalRhs = case mTy of
            Just ty -> Ann (mergeSpan (getTypeSpan ty) (getSpan rhs)) rhs ty
            Nothing -> rhs
      pure (pat, finalRhs, mergeSpan startSp (getSpan finalRhs))
    
    parseMoreBindings acc = do
      mSep <- peek st
      case mSep of
        Just t | t.cls == TokVirtSemi -> do
          _ <- advance st
          binding <- parseOneBinding
          parseMoreBindings (binding : acc)
        _ -> pure (reverse acc)

-- | Apply a list of where-bindings to a `DeclDef` by wrapping its body in
-- nested `Let` nodes. The first binding becomes the outermost `let`.
applyWhereToTopLevel :: TopLevel -> [(Pattern, Expr, Span)] -> TopLevel
applyWhereToTopLevel (TDecl (DeclDef sp lhsPat body)) bindings =
  let body' = wrapBodyWithWhere body bindings
      sp'   = mergeSpan sp (getSpan body')
  in TDecl (DeclDef sp' lhsPat body')
applyWhereToTopLevel tl _ = tl

-- | Recursively descend through `Lam` nodes to find the innermost body,
-- then wrap it with `Let` nodes for each where-binding.
wrapBodyWithWhere :: Expr -> [(Pattern, Expr, Span)] -> Expr
wrapBodyWithWhere expr bindings = case expr of
  Lam sp pat mTy inner ->
    let inner' = wrapBodyWithWhere inner bindings
    in Lam (mergeSpan sp (getSpan inner')) pat mTy inner'
  _ -> foldr (\(pat, rhs, clSp) acc -> Let clSp pat rhs acc) expr bindings

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
      firstClause <- parseLetClause tok.span
      restClauses <- parseLetClauses []
      mClose <- peek st
      case mClose of
        Just t | t.cls == TokVirtRBrace -> do
          _ <- advance st
          pure ()
        _ -> pure ()
      expect TokIn st ex
      body <- parseExpr (precVal PrecLowest) st ex
      -- Consume the TokVirtRBrace that closeAll inserts for same-line `in`
      -- (multiline `in` already consumed it before the expect above)
      mLetClose <- peek st
      case mLetClose of
        Just t | t.cls == TokVirtRBrace -> do
          _ <- advance st
          pure ()
        _ -> pure ()
      let clauses = firstClause : restClauses
      pure $ lowerLetClauses clauses body
      where
        parseLetClause startSp = do
          pat <- parsePattern st ex
          next <- peek st
          mTy <- case next of
            Just t | t.cls == TokColon -> do
              _ <- advance st
              ty <- parseType st ex
              pure (Just ty)
            _ -> pure Nothing
          expect TokAssign st ex
          val <- parseExpr (precVal PrecLowest) st ex
          let finalVal = case mTy of
                Just ty -> Ann (mergeSpan (getTypeSpan ty) (getSpan val)) val ty
                Nothing -> val
              clauseSpan = mergeSpan startSp (getSpan finalVal)
          pure (pat, finalVal, clauseSpan)
        
        parseLetClauses acc = do
          mSep <- peek st
          case mSep of
            Just t | t.cls == TokVirtSemi -> do
              _ <- advance st
              clause <- parseLetClause t.span
              parseLetClauses (clause : acc)
            _ -> pure (reverse acc)

        lowerLetClauses clauses body =
          foldr mkLet body clauses

        mkLet (pat, rhs, clauseSpan) acc =
          Let (mergeSpan clauseSpan (getSpan acc)) pat rhs acc
      
    TokCase -> do
      scrutinee <- parseExpr (precVal PrecLowest) st ex
      expect TokOf st ex
      mFirst <- peek st
      case mFirst of
        Just t | t.cls == TokVirtRBrace || t.cls == TokEOF ->
          throw ex $ MkParseError "Case expression must have at least one branch" t.span
        Nothing -> 
          throw ex $ MkParseError "Case expression must have at least one branch" tok.span
        _ -> pure ()
      firstBranch <- parseCaseBranch
      restBranches <- parseCaseBranches []
      mClose <- peek st
      case mClose of
        Just t | t.cls == TokVirtRBrace -> do
          _ <- advance st
          pure ()
        _ -> pure ()
      let branches = firstBranch : restBranches
      pure $ Case (mergeSpan tok.span (getSpan . snd . last $ branches)) scrutinee branches
      where
        parseCaseBranch = do
          pat <- parsePattern st ex
          expect TokFatArrow st ex
          body <-parseExpr (precVal PrecLowest) st ex
          pure (pat,body)

        parseCaseBranches acc = do
          mSep <- peek st
          case mSep of
            Just t | t.cls == TokVirtSemi -> do
              _ <- advance st
              branch <- parseCaseBranch
              parseCaseBranches (branch : acc)
            _ -> pure . reverse $ acc

    TokUIdent x -> do
      -- We parse the payload expression at Application precedence
      payload <- parseExpr (precVal PrecApp) st ex
      pure $ Variant (mergeSpan tok.span (getSpan payload)) x payload

    TokWhere ->
      throw ex (MkParseError "`where` is not valid in expression position" tok.span)

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

-- | Tokens that may begin an expression in Pratt "application" position.
--
-- This set must remain coherent with 'tokenPrecedence' and parseNUD/parseLED
-- behavior so implicit application is recognized consistently.
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

-- | Tokens that may begin a surface pattern.
--
-- Used by equation-clause parsing and other pattern-entry points.
isPatternStarter :: TokenClass -> Bool
isPatternStarter = \case
  TokWildcard -> True
  TokIdent _ -> True
  TokInt _ -> True
  TokFloat _ -> True
  TokString _ -> True
  TokTrue -> True
  TokFalse -> True
  TokUIdent _ -> True
  _ -> False

-- | Consume any number of layout-inserted virtual semicolons.
--
-- Top-level declaration parsing uses this to tolerate line-delimited
-- declaration separators introduced by the layout pass.
consumeVirtualSemis :: forall st es. (st :> es) => State ParserState st -> Eff es ()
consumeVirtualSemis st = do
  mTok <- peek st
  case mTok of
    Just t | t.cls == TokVirtSemi -> do
      _ <- advance st
      consumeVirtualSemis st
    _ -> pure () 

-- | Pure entry point for the Parser.
runParser :: [Token] -> Either ParseError Expr
runParser toks = 
  runPureEff $
    fmap fst $
      runState (MkParserState $ runLayout toks) \st ->
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

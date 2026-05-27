{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE TemplateHaskell #-}
-- | Phase 10 C backend - C2.1 emission.
-- Emits typed C function signatures and actual C expressions for the monomorphic
-- first-pass subset: primitive literals, variables, and let-bindings.
-- Compound forms (application, case, variants, records) still emit compilable
-- placeholder stubs pending C3 data-representation work
module Compiler.CGen
  ( cgenProgram 
  ) where

import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Lazy as TL
import qualified Data.Text.Lazy.Builder as TB
import Data.Char (isAlphaNum)
import Language.Haskell.TH.Syntax (addDependentFile, makeRelativeToProject, runIO)
import Compiler.QQ (c, blk, blks)
import Compiler.AST (Literal(..), Type(..))
import Compiler.AST.Core (ArithOp (..), CoreDecl(..), CoreExpr(..), CorePattern(..))

type Decl = (CoreDecl, Maybe Type)
type Decls = [Decl]

-- | Emit a C translation unit for a list of (declaration, zonked-type) pairs.
-- Pass @Just ty@ when a declaration's zonked type is known.
-- @Nothing@ falls back to @intptr_t@ for all parameters and return types.
-- This fallback path must still emit compilable C, so literal/inline expressions
-- are explicitly coerced to the target emitted C type at use sites.
cgenProgram :: Decls -> Text
cgenProgram pairs = 
  TL.toStrict $
  TB.toLazyText $
  cPreludeChunk
    <> cDeclCountComment pairs
    <> cDeclarationSection pairs

-- | Static C prelude
cPreludeChunk :: TB.Builder
cPreludeChunk = TB.fromText (blks cPreludeText)

-- | Raw prelude text for generated C output.
-- Loaded from a dedicated C template resource at compile time.
cPreludeText :: Text
cPreludeText = $(
  do
    path <- makeRelativeToProject "src/Compiler/CGenPrelude.c"
    addDependentFile path
    src <- runIO (readFile path)
    [| T.pack src |]
  )

-- | Emit a declaration-count comment
cDeclCountComment :: Decls -> TB.Builder
cDeclCountComment pairs =
  let decls = T.pack (show (length pairs)) 
  in TB.fromText $ blks [c| /* declarations: $decls */ |]

-- | Emit all declaration fragments separated by one blank line
cDeclarationSection :: Decls -> TB.Builder
cDeclarationSection pairs =
  intercalateBuilders (TB.fromText "\n") (map cgenDecl pairs)

-- ─── Declaration emission ────────────────────────────────────────────────────

-- | Shape of a top-level Core RHS after peeling off the lambda spine.
data DeclShape
  = DeclFunction [Text] CoreExpr
  -- ^ Parameter names (from @CPVar@; other patterns contribute @"_"@) and terminal body.
  | DeclConstant CoreExpr
  -- ^ Non-lambda RHS treated as a global constant initializer

-- | Classify a top-level RHS by its outer lambda spine.
declShape :: CoreExpr -> DeclShape
declShape expr = case go [] expr of
  ([], body) -> DeclConstant body
  (ps, body) -> DeclFunction ps body
  where 
    go params (CLam _ pat body) = go (params ++ [patName pat]) body
    go params body              = (params, body)
    patName (CPVar _ n)         = n
    patName _                   = "_"

-- | Emit a C fragment for one top-level core declaration.
-- Applies the monomorphism guard before lowering function bodies.
cgenDecl :: Decl -> TB.Builder
cgenDecl (decl, mTy) = case decl of 
  CDeclSig _ name _ -> TB.fromText $ blks [c|/* signature (not yet emitted): $name */ |]
  CDeclDef _ name rhs ->
    -- Monomorphism guard: reject surviving TForall, TMeta, TVar or TSkolem
    case mTy of
      Just ty | not (isMonomorphic ty) ->
        TB.fromText $
        blks [c|
        /* definition: $name */
        /* codegen error: program is not fully monomorphic; instantiate before code generation */ |]
      _ ->
        case declShape rhs of
          DeclFunction params body ->
            let retTy = cgenReturnType mTy
                pTysFull = take (length params) (cgenParamTypes mTy ++ repeat "intptr_t")
                paramList
                  | null params = "void"
                  | otherwise = T.intercalate ", " (zipWith (\t n -> t <> " " <> n) pTysFull params)
            in TB.fromText $
              let fName = cFunctionName name
                  paramUses = cgenMarkParamsUsed params
                  fBody = cgenFunctionBodyScoped params retTy body
              in blks [c|
              /* definition: $name */
              $retTy $fName($paramList) {
                $paramUses$fBody
              } |]
          DeclConstant body ->
            let valTy = maybe "intptr_t" cgenCType mTy
                fName = cFunctionName name
                fBody = cgenExprValueAs valTy body
             in TB.fromText $
              if isStaticCInitializer body
              then blks [c|
              /* definition: $name */
              $valTy $fName = $fBody; |]
              else blks [c|
              /* definition: $name */
              $valTy $fName(void) {
                return $fBody;
              } |]

-- ─── Type mapping ────────────────────────────────────────────────────────────

-- | True only for Core expressions that are safe to emit as file-scope C
-- initializers without introducing helper calls or runtime evaluation.
isStaticCInitializer :: CoreExpr -> Bool
isStaticCInitializer = \case
  CLit{} -> True
  _      -> False

-- | Map a monomorphic Lithic type to its C type string.
-- Compound and unrecognised types fall back to @intptr_t@.
cgenCType :: Type -> Text
cgenCType = \case
  TInt{}    -> "int64_t"
  TFloat{}  -> "double"
  TBool{}   -> "int"
  TString{} -> "const char*"
  _         -> "intptr_t"

-- | Derive the C return type from the rightmost element of an arrow chain.
-- @Nothing@ falls back to @intptr_t@.
cgenReturnType :: Maybe Type -> Text
cgenReturnType Nothing                 = "intptr_t"
cgenReturnType (Just (TArrow _ _ ret)) = cgenReturnType (Just ret)
cgenReturnType (Just t)                = cgenCType t

-- | Extract C parameter types from a left-to-right arrow chain.
-- @Nothing@ returns the empty list; callers pad to required arity with @intptr_t@.
cgenParamTypes :: Maybe Type -> [Text]
cgenParamTypes Nothing                        = []
cgenParamTypes (Just (TArrow _ param rest))   = cgenCType param : cgenParamTypes (Just rest)
cgenParamTypes _                              = []

-- | Return @True@ iff a type contains no @TForall@, @TMeta@, @TVar@, or @TSkolem@
-- nodes — i.e. it is safe to lower to monomorphic C.
isMonomorphic :: Type -> Bool
isMonomorphic = \case
  TForall{}                 -> False
  TMeta{}                   -> False
  TVar{}                    -> False
  TSkolem{}                 -> False
  TArrow _ a b              -> isMonomorphic a && isMonomorphic b
  TRecord _ row             -> isMonomorphic row
  TRowExtend _ _ fldTy rest -> isMonomorphic fldTy && isMonomorphic rest
  TVariant _ inner          -> isMonomorphic inner
  TInt{}                    -> True
  TFloat{}                  -> True
  TBool{}                   -> True
  TString{}                 -> True
  TRowEmpty{}               -> True
  TNominal{}                -> True

-- ─── Statement-level body emission ───────────────────────────────────────────

-- | Emit a C statement sequence while tracking locally bound callable names.
-- Names in @inScope@ are emitted as-is, while non-local call targets are
-- mapped through the top-level C symbol mangling convention.
cgenFunctionBodyScoped :: [Text] -> Text -> CoreExpr -> Text
cgenFunctionBodyScoped inScope retTy = \case
  -- Targets 2 & 3: actual interal and vairable emission.
  CLit _ lit ->
    let r = cgenLiteralValue lit 
    in blk [c| return ($retTy)$r; |]

  CVar _ varName ->
    blk [c| return $varName; |]

  -- Target 4: let-binding to stack-allocated local.
  -- Only CPVar patterns are precisely lowered; other patterns fall through
  -- to a scaffold comment and continue with thge body.
  CLet _ (CPVar _ varName) rhs body ->
    let expr = cgenExprValueAs "intptr_t" rhs
        fBody = cgenFunctionBodyScoped (varName : inScope) retTy body
    in blk [c|
      intptr_t $varName = $expr;
      $fBody |]

  CLet _ pat rhs body ->
    let pTag = cgenPatternTag pat 
        expr = cgenExprTag rhs
        fBody = cgenFunctionBodyScoped inScope retTy body
    in blk [c|
      /* let binding: $pTag */
      /* let rhs: $expr */
      $fBody |]
  
  -- Remaining forms: compilable stubs with typoed placeholder returns.
  CApp _ fn arg ->
    -- C2.2: var-target call lowering.
    -- CVar fn + CVar arg -> direct call return.
    -- Any other call target shape falls back with an explicit diagnostic marker.
    case fn of
      CVar _ fnName ->
        let calleeName = cgenCallName inScope fnName
            argExpr = cgenExprValue arg
        in blk [c| return ($retTy)$calleeName($argExpr); |]
      unsupportedFn ->
        let cFnTag = cgenExprTag unsupportedFn
            cArg   = cgenExprTag arg
        in blk [c|
        /* unsupported-call-target: $cFnTag */
        /* app arg: $cArg */
        return ($retTy)0;   /* placeholder */ |]
  
  CCase _ scrut branches ->
    case () of
      _ | any (isVariantCasePattern . fst) branches ->
        let scrutTmp    = "lithic_case_variant_scrut"
            tagTmp      = "lithic_case_variant_tag"
            scrutExpr   = cgenExprValue scrut
            scrutDecl   = [c|intptr_t $scrutTmp = $scrutExpr; |]
            tagDecl     = [c|intptr_t $tagTmp = lithic_variant_tag($scrutTmp); |]
            branchTexts = 
              T.concat $ zipWith (cgenVariantCaseBranch inScope retTy scrutTmp tagTmp) [0::Int ..] branches
        in blk [c|
        $scrutDecl
        $tagDecl
        $branchTexts
        return ($retTy)0; /* default: no branch matched */ |]
      
      _ | all (isLiteralLikeCasePattern . fst) branches ->
        let scrutTmp    = "lithic_case_scrut"
            scrutTy     = literalCaseScrutType scrut branches
            scrutVal    = cgenExprValueAs scrutTy scrut
            scrutDecl   = [c|$scrutTy $scrutTmp = $scrutVal; |]
            branchTexts =
              T.concat $ zipWith (cgenLiteralCaseBranch inScope retTy scrutTy scrutTmp) [0::Int ..] branches
        in blk [c|
          $scrutDecl
          $branchTexts
          return ($retTy)0; /* default: no branch matched */ |]

      _ ->
        let cScrut = cgenExprTag scrut
            lBranches = tshow (length branches)
        in blk [c|
          /* unsupported-case-scrutinee: $cScrut */
          /* case branches: $lBranches */
          return ($retTy)0; /* placeholder */ |]

  CVariant _ ctor payload ->
    -- C2.2: materialise the payload into an explicit temporary before
    -- handing it to the runtime helper to avoid repeated expression emission.
    let payloadTmp  = "lithic_variant_payload_tmp"
        payloadExpr = cgenExprValue payload
        ctorTag     = cgenVariantTag ctor
    in blk [c|
      intptr_t $payloadTmp = $payloadExpr;
      return ($retTy)lithic_variant_make($ctorTag, $payloadTmp); |]
  
  CRecord _ fields ->
    let lFields = tshow . length $ fields
        recTmp = "lithic_record_tmp"
        mkRecStmt = [c|intptr_t $recTmp = lithic_record_make($lFields); |]
        mkRecGuard = [c|
          if ($recTmp == (intptr_t)0) {
            return ($retTy)0;
          } |]
        initStmts = T.concat $ zipWith (cgenRecordInitStep recTmp retTy) [0 :: Int ..] fields
    in [c|
      /* record field count: $lFields */
      $mkRecStmt
      $mkRecGuard
      $initStmts
      return ($retTy)$recTmp;
    |]
  
  CSelect _ recordExpr fieldName ->
    -- C2.2: materialise both the record expression and the field tag into
    -- explicit temporaries so the helper call is a clean two-arg form.
    let recTmp   = "lithic_select_record_tmp"
        fldTmp   = "lithic_select_field_tmp"
        recExpr  = cgenExprValue recordExpr
        fldExpr  = cgenFieldTag fieldName
    in blk [c|
      intptr_t $recTmp = $recExpr;
      intptr_t $fldTmp = $fldExpr;
      return ($retTy)lithic_record_select($recTmp, $fldTmp); |]

  e@(CBinOp _ _ _ _) ->
    let expr = cgenExprValueAs retTy e
    in blk [c| return $expr; |]

  e@(CNeg _ _) ->
    let expr = cgenExprValueAs retTy e
    in blk [c| return $expr;|]

  other ->
    let cExpr = cgenExprTag other
    in blk [c|
      /* unsupported(phase10-c3): body form $cExpr */
      return ($retTy)0; /* placeholder */
    |]
    
-- ─── Expression-level value emission ─────────────────────────────────────────

-- | Emit a C expression for a simple Core expression that can appear inline
-- (e.g. as the RHS of a @let@ local or a global constant initialiser).
-- Only @CLit@ and @CVar@ are precisely lowered; all other forms emit a typed
-- zero placeholder.
cgenExprValue :: CoreExpr -> Text
cgenExprValue = \case

  CLit _ lit     -> cgenLiteralValue lit

  CVar _ varName -> varName

  appExpr@(CApp _ _ _) ->
    let (callee, args) = collectArgs appExpr
    in case callee of
      CVar _ fnName ->
        let cFnName = cFunctionName fnName
            argVals = T.intercalate ", " (map cgenExprValue args)
        in [c|$cFnName($argVals)|] 
      _ ->
        "/* unsupported-rhs:" <> cgenExprTag appExpr <> " */ (intptr_t)0"

  CSelect _ recordExpr fieldName ->
    let recVal = cgenExprValue recordExpr
        fldTag = cgenFieldTag fieldName
    in [c|lithic_record_select($recVal, $fldTag)|]

  CBinOp _ op lhs rhs ->
    let elhs = cgenExprValue lhs
        opSym = arithOpSym op 
        erhs = cgenExprValue rhs
    in [c|($elhs $opSym $erhs)|]

  CNeg _ op ->
    let eop = cgenExprValue op
    in [c|(-($eop))|]

  other ->
    "/* unsupported-rhs:" <> cgenExprTag other <> " */ (intptr_t)0" 

-- | Map a Core arithmetic operator to its C infix symbol.
arithOpSym :: ArithOp -> Text
arithOpSym = \case
  AAdd -> "+"
  ASub -> "-"
  AMul -> "*"
  ADiv -> "/"

-- | Emit a C expression coerced to a target C type.
-- This is used where fallback typing can otherwise produce invalid C
-- (for example string literals flowing into intptr_t).
cgenExprValueAs :: Text -> CoreExpr -> Text
cgenExprValueAs targetTy expr =
  let raw = cgenExprValue expr
  in [c|($targetTy)$raw|]

-- | Emit a C literal expression for a Lithic literal value.
cgenLiteralValue :: Literal -> Text
cgenLiteralValue = \case
  LInt n      -> "(int64_t)" <> tshow n
  LBool True  -> "1"
  LBool False -> "0"
  LFloat f    -> "(double)" <> T.pack (show f)
  LString s   -> "\"" <> cgenEscapeString s <> "\""

-- | Escape a Lithic string literal for embedding in a C double-quoted string.
cgenEscapeString :: Text -> Text
cgenEscapeString = T.concatMap escapeChar
  where
    escapeChar '"'  = "\\\""
    escapeChar '\\' = "\\\\"
    escapeChar '\n' = "\\n"
    escapeChar '\t' = "\\t"
    escapeChar '\r' = "\\r"
    escapeChar ch    = T.singleton ch

-- ─── Scaffold helpers ─────────────────────────────────────────────────────────

-- | Emit one branch of a literal-scrutinee case chain.
-- Emits @if@ for index 0, @else if@ for subsequent branches, and @else@ for
-- a wildcard / variable catch-all. Each branch carries a source-order comment.
cgenLiteralCaseBranch :: [Text] -> Text -> Text -> Text -> Int -> (CorePattern, CoreExpr) -> Text
cgenLiteralCaseBranch inScope retTy scrutTy scrutTmp ix (pat, body) =
  let bodyText   = cgenFunctionBodyScoped inScope retTy body
      branchTag  = "/* case branch " <> tshow ix <> " */"
      guardKw    = if ix == 0 then "if"     else "else if"
      catchAllKw = if ix == 0 then "if (1)" else "else"
      intCmp n
        | scrutTy == "int64_t" = "(int64_t)" <> tshow n
        | otherwise            = "(intptr_t)(int64_t)" <> tshow n
      zeroCmp
        | scrutTy == "int64_t" = "(int64_t)0"
        | otherwise            = "(intptr_t)0"
      esc s = "\"" <> cgenEscapeString s <> "\""
  in case pat of
    CPLit _ (LInt n) ->
      let cmp = intCmp n
      in [c|
        $branchTag
        $guardKw ($scrutTmp == $cmp) {
          $bodyText
        }
      |]
    
    CPLit _ (LBool True) ->
      [c|
        $branchTag
        $guardKw ($scrutTmp != $zeroCmp) {
          $bodyText
        }
      |]

    CPLit _ (LBool False) ->
      [c|
        $branchTag
        $guardKw ($scrutTmp == $zeroCmp) {
          $bodyText
        }
      |]

    CPLit _ (LString s) ->
      let litStr = esc s
      in [c|
        $branchTag
        $guardKw (($scrutTmp != NULL) && strcmp($scrutTmp, $litStr) == 0) {
          $bodyText
        }
      |]

    CPLit _ unsupportedLit ->
      let litTag = tshow unsupportedLit
      in [c|
        $branchTag
        /* unsupported-case-literal: $litTag */
        return ($retTy)0; /* placeholder */
      |]

    CPVar _ varName ->
      let boundBody = cgenFunctionBodyScoped (varName : inScope) retTy body
      in [c|
        $branchTag
        $catchAllKw {
          intptr_t $varName = (intptr_t)$scrutTmp;
          $boundBody
        }
      |]

    CPWildcard _ ->
      [c|
        $branchTag
        $catchAllKw {
          $bodyText
        }  
      |]

    unsupported ->
      let patTag = cgenPatternTag unsupported
      in [c|
        $branchTag
        /* unsupported-case-pattern: $patTag */
        return ($retTy)0; /* placeholder */
      |]

-- | Emit one branch of a variant-scrutinee case chain.
-- Variant headed branches compare the precomputed variant tag and optionally
-- bind payloads for @CPVar@ payload binders. Wildcard/variable branches lower
-- as catch-all fallbacks preserving source order.
cgenVariantCaseBranch :: [Text] -> Text -> Text -> Text -> Int -> (CorePattern, CoreExpr) -> Text
cgenVariantCaseBranch inScope retTy scrutTmp tagTmp ix (pat, body) =
  let bodyText = cgenFunctionBodyScoped inScope retTy body
      branchTag = "/* case branch " <> tshow ix <> " */"
      guardKw = if ix == 0 then "if" else "else if"
  in case pat of
    CPVariant _ ctor innerPat ->
      let ctorCmp = cgenVariantTag ctor
      in case innerPat of
        CPVar _ payloadName -> 
          let boundBody = cgenFunctionBodyScoped (payloadName : inScope) retTy body
          in blk [c|
          $branchTag
          $guardKw ($tagTmp == $ctorCmp) {
            intptr_t $payloadName = lithic_variant_payload($scrutTmp);
            $boundBody
          } |]
        CPWildcard _ -> blk [c|
          $branchTag
          $guardKw ($tagTmp == $ctorCmp) {
            $bodyText
          } |]
        unsupportedInner ->
          let innerTag = cgenPatternTag unsupportedInner
          in blk [c|
            $branchTag
            $guardKw ($tagTmp == $ctorCmp) {
              /* unsupported-case-pattern-inner: $innerTag */
              return ($retTy)0; /* placeholder */
            }
          |]

    CPWildcard _ ->
      if ix == 0 then 
        blk [c|
          $branchTag
          if (1) { $bodyText } |]
      else
        blk [c|
          $branchTag
          else { $bodyText }|]

    CPVar _ varName ->
      if ix == 0 then
        blk [c|
          $branchTag
          if (1) { 
            intptr_t $varName = $scrutTmp;
            $bodyText 
          } |]
      else 
        blk [c|
          $branchTag
          else {
            intptr_t $varName = $scrutTmp;
            $bodyText } |]

    unsupported ->
      let patTag = cgenPatternTag unsupported
      in blk [c|
        $branchTag
        /* unsupported-case-pattern: $patTag */
        return ($retTy)0; /* placeholder */ |]

-- | Return @True@ when a case branch pattern is variant-headed.
-- Used to select the first-pass variant dispatch lowering path.
isVariantCasePattern :: CorePattern -> Bool
isVariantCasePattern = \case
  CPVariant{} -> True
  _           -> False

-- | Return @True@ when a case pattern can be lowered by the literal-like
-- branch chain path (literals plus fallback binders).
isLiteralLikeCasePattern :: CorePattern -> Bool
isLiteralLikeCasePattern = \case
  CPLit{}      -> True
  CPVar{}      -> True
  CPWildcard{} -> True
  _            -> False

-- | Choose the temporary C type used for non-variant literal-like case
-- lowering. Prefer concrete string/int where we can preserve direct comparisons.
literalCaseScrutType :: CoreExpr -> [(CorePattern, CoreExpr)] -> Text
literalCaseScrutType scrut branches
  | any isStringLitPat pats = "const char*"
  | isIntLiteralScrut scrut && all isIntLikePat pats = "int64_t"
  | otherwise = "intptr_t"
  where
    pats = map fst branches

    isStringLitPat = \case
      CPLit _ (LString _) -> True
      _                   -> False

    isIntLikePat = \case
      CPLit _ (LInt _) -> True
      CPVar{}          -> True
      CPWildcard{}     -> True
      _                -> False

    isIntLiteralScrut = \case
      CLit _ (LInt _) -> True
      _               -> False

-- | Return a compact constructor tag for scaffold diagnostics / comments.
cgenExprTag :: CoreExpr -> Text
cgenExprTag = \case
  CVar{}     -> "CVar"
  CLit{}     -> "CLit"
  CLam{}     -> "CLam"
  CApp{}     -> "CApp"
  CLet{}     -> "CLet"
  CCase{}    -> "CCase"
  CVariant{} -> "CVariant"
  CRecord{}  -> "CRecord"
  CSelect{}  -> "CSelect"
  CBinOp{}   -> "CBinOp"
  CNeg{}     -> "CNeg"

-- | Compact pattern tag for placeholder let-binding comments.
cgenPatternTag :: CorePattern -> Text
cgenPatternTag = \case
  CPVar{}      -> "CPVar"
  CPWildcard{} -> "CPWildcard"
  CPLit{}      -> "CPLit"
  CPVariant{}  -> "CPVariant"
  CPRecord{}   -> "CPRecord"

-- | Compute a deterministic constructor/field hash in unbounded integer space.
-- Keeping this in @Integer@ avoids host-@Int@ overflow during accumulation.
nameToTag :: Text -> Integer
nameToTag = T.foldl' (\acc ch -> acc * 31 + toInteger (fromEnum ch)) 0

-- | Normalize a computed name tag so generated keys never use @0@.
-- The runtime record helper reserves key @0@ as an empty-slot sentinel, so
-- emitted field tags must remain non-zero.
-- The unbounded hash is reduced into @[0 .. maxBound-1]@ and then shifted by
-- @+1@ into @[1 .. maxBound]@ to guarantee positivity at helper boundaries.
-- This bounded normalization can introduce collisions and does not preserve
-- raw-hash distinctness.
nameToTagNonZero :: Text -> Int
nameToTagNonZero name =
  let raw = nameToTag name
      intMax = toInteger (maxBound :: Int)
      bounded = raw `mod` intMax
  in fromInteger (bounded + 1)

-- | Emit a deterministic integer variant-constructor tag.
-- Preserves the ctor name as an inline C comment for readability.
cgenVariantTag :: Text -> Text
cgenVariantTag ctor = 
  let tag = tshow (nameToTagNonZero ctor)
   in [c|/* ctor: $ctor */ (intptr_t) $tag|]

-- | Emit a deterministic integer field tag for record selection.
-- Preserves the field name as an inline C comment for readability.
cgenFieldTag :: Text -> Text
cgenFieldTag fieldName =
  let tag = tshow $ nameToTagNonZero fieldName
   in [c|/* field: $fieldName */ (intptr_t)$tag|]

-- | Emit one record-field initialization step for @CRecord@ lowering.
-- Maps a surface field name to its deterministic integer key, materializes the
-- field expression into a unique temporary, and emits a call to
-- @lithic_record_set@ to populate the runtime record carrier.
-- The @Int@ index is used only to keep generated temporary names stable and
-- collision-free across fields in the same record literal.
cgenRecordInitStep :: Text -> Text -> Int -> (Text, CoreExpr) -> Text
cgenRecordInitStep recTmp retTy ix (fieldName, fieldExpr) =
  let valTmp = "lithic_record_val_tmp_" <> tshow ix
      keyExpr = cgenFieldTag fieldName
      valExpr = cgenExprValue fieldExpr
  in [c|
    intptr_t $valTmp = $valExpr;
    $recTmp = lithic_record_set($recTmp, $keyExpr, $valTmp);
    if ($recTmp == (intptr_t)0) {
      return ($retTy)0;
    }
  |]

-- ─── Utilities ────────────────────────────────────────────────────────────────

-- | Resolve a callable C name from a surface/Core variable name.
-- Names already bound in local scope are emitted unchanged; all other names are
-- treated as top-level declarations and mapped via cFunctionName.
cgenCallName :: [Text] -> Text -> Text
cgenCallName inScope fnName 
  | fnName `elem` inScope = fnName
  | otherwise             = cFunctionName fnName

-- | Convert a Lithic declaration name into a C-safe identifier.
cFunctionName :: Text -> Text
cFunctionName name = "lithic_" <> T.map normalize name
  where
    normalize ch
      | isAlphaNum ch || ch == '_' = ch
      | otherwise                  = '_'

-- | Emit no-op parameter-use statemens so generated code stays warning-free
-- under strict C flags when parameters are not consumed by placeholder bodies.
cgenMarkParamsUsed :: [Text] -> Text
cgenMarkParamsUsed = T.concat . map (\param -> "(void)" <> param <> ";\n")

-- | Flatten a left-associated Core application spine into callee + args.
collectArgs :: CoreExpr -> (CoreExpr, [CoreExpr])
collectArgs = go []
  where
    go acc (CApp _ fn arg) = go (arg : acc) fn
    go acc callee          = (callee, acc)

-- | Compact @show@ helper.
tshow :: forall a. Show a => a -> Text
tshow = T.pack . show

-- | Interleave a separator @Builder@ between a list of @Builder@s.
intercalateBuilders :: TB.Builder -> [TB.Builder] -> TB.Builder
intercalateBuilders _ []       = mempty
intercalateBuilders _ [x]      = x
intercalateBuilders sep (x:xs) = x <> sep <> intercalateBuilders sep xs
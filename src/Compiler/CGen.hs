{-# LANGUAGE QuasiQuotes #-}
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

import Compiler.QQ (c, blk, blks)
import Compiler.AST (Literal(..), Type(..))
import Compiler.AST.Core (CoreDecl(..), CoreExpr(..), CorePattern(..))

-- -- Alias the quasiquoter at the top level to get syntax highlighting of the C blocks
-- c :: QuasiQuoter
-- c = text

type Decl = (CoreDecl, Maybe Type)
type Decls = [Decl]

-- | Emit a C translation unit for a list of (declaration, zonked-type) pairs.
-- Pass @Just ty@ for declarations whose type is known from the typechecker;
-- @Nothing@ falls back to @intptr_t@ for all paramaters and return types.
cgenProgram :: Decls -> Text
cgenProgram pairs = 
  TL.toStrict $
  TB.toLazyText $
  cPreludeChunk
    <> cDeclCountComment pairs
    <> cDeclarationSection pairs

-- | Static C prelude
cPreludeChunk :: TB.Builder
cPreludeChunk = TB.fromText cPreludeText

-- | Raw prelude text for generated C output
cPreludeText :: Text
cPreludeText = blks [c|
    #include <stdint.h>
    #include <stdbool.h>
    #include <stdlib.h>
    #include <stdio.h>
    /* Lithic Phase 10 C backend */
    static inline void lithic_variant_make(intptr_t _tag, intptr_t _payload) { (void)_tag; (void)_payload; }
    static inline void lithic_record_make(intptr_t _field_count) { (void)_field_count; }
    static inline void lithic_record_select(intptr_t _record, intptr_t _field) { (void)_record; (void)_field; }
    static inline void lithic_unsupported_fn(intptr_t _arg) { (void)_arg; } |]

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
  CDeclSig _ name _ -> TB.fromText $ blks [c|/* signature (not yet emitted): $name */" |]
  CDeclDef _ name rhs ->
    -- Monomorphism guard: reject surviving TForall, TMeta, TVar or TSkolem
    case mTy of
      Just ty | not (isMonomorphic ty) ->
        TB.fromText $
        blks [c|
        /* definition: $name */
        /* codegen error: program is not full monomorphic; instantiate before code generation */ |]
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
                  fBody = cgenFunctionBody retTy body
              in blks [c|
              /* definition: $name */
              $retTy $fName($paramList) {
                $fBody
              } |]
          DeclConstant body ->
            let valTy = maybe "intptr_t" cgenCType mTy
                fName = cFunctionName name
                fBody = cgenExprValue body
             in TB.fromText $ blks [c|
             /* definition: $name */
             $valTy $fName = $fBody; |]

-- ─── Type mapping ────────────────────────────────────────────────────────────

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

-- | Emit a C statement sequence for a function body.
-- @retTy@ is the declared return type of the enclosing function and is used to
-- produce valid placeholder @return@ values for forms not yet fully lowered.
cgenFunctionBody :: Text -> CoreExpr -> Text
cgenFunctionBody retTy = \case
  -- Targets 2 & 3: actual interal and vairable emission.
  CLit _ lit ->
    let r = cgenLiteralValue lit 
    in blk [c| return $r; |]
  CVar _ varName ->
    blk [c| return $varName; |]

  -- Target 4: let-binding to stack-allocated local.
  -- Only CPVar patterns are precisely lowered; other patterns fall through
  -- to a scaffold comment and continue with thge body.
  CLet _ (CPVar _ varName) rhs body ->
    let expr = cgenExprValue rhs
        fBody = cgenFunctionBody retTy body
    in blk [c|
      intptr_t $varName = $expr;
      $fBody |]
  CLet _ pat rhs body ->
    let pTag = cgenPatternTag pat 
        expr = cgenExprTag rhs
        fBody = cgenFunctionBody retTy body
    in blk [c|
      /* let binding: $pTag */
      /* let rhs: $expr */
      $fBody |]
  
  -- Remaining forms: compilable stubs with typoed placeholder returns.
  CApp _ fn arg ->
    let cFn = cgenExprTag fn
        cArg = cgenExprTag arg
    in blk [c|
      /* app fn : $cFn */
      /* app arg: $cArg */
      /* TODO(phase10-c2): lower application call */
      lithic_unsupported_fn(0);
      return ($retTy)0;  /* placeholder */ |]
  
  CCase _ scrut branches ->
    let cScrut = cgenExprTag scrut
        lBranches = tshow $ length branches
        cBranches = cgenCaseBranchStubs branches
    in blk [c|
      /* case scrut: $cScrut */
      /* case branches: $lBranches */
      switch (0) {
        $cBranches
        default:
          break;
      }
      return ($retTy)0; /* placeholder */ |]
  
  CVariant _ ctor payload ->
    let cPayload = cgenExprTag payload
        cVariant = cgenVariantTag ctor
        cCallArg = cgenCallArg payload
    in blk [c|
      /* variant ctor: $ctor */
      /* variant payload: $cPayload */
      lithic_variant_make($cVariant, $cCallArg);
      return ($retTy)0; /* placeholder */ |]
  
  CRecord _ fields ->
    let lFields = tshow . length $ fields
    in blk [c|
      /* record field count: $lFields */
      lithic_record_make($lFields);
      return ($retTy)0; /* placeholder */ |]
  
  CSelect _ recordExpr fieldName ->
    let cRec = cgenExprTag recordExpr
        cField = cgenFieldTag fieldName
    in blk [c|
      /* select record: $cRec */
      /* select field: $fieldName */
      lithic_record_select($cRec, $cField);
      return ($retTy)0; /* placeholder */ |]
  other ->
    let cExpr = cgenExprTag other
    in blk [c|
      /* unsupported(phase10-c2): body form $cExpr */
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
  other          -> "/* unsupported-rhs:" <> cgenExprTag other <> " */ (intptr_t)0"

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

-- | Compact pattern tag for placeholder let-binding comments.
cgenPatternTag :: CorePattern -> Text
cgenPatternTag = \case
  CPVar{}      -> "CPVar"
  CPWildcard{} -> "CPWildcard"
  CPLit{}      -> "CPLit"
  CPVariant{}  -> "CPVariant"
  CPRecord{}   -> "CPRecord"

-- | Compact literal kind tag used in call-argument placeholders.
cgenLiteralTag :: Literal -> Text
cgenLiteralTag = \case
  LInt{}    -> "Int"
  LFloat{}  -> "Float"
  LString{} -> "String"
  LBool{}   -> "Bool"

-- | Emit a first-pass call argument placeholder.
cgenCallArg :: CoreExpr -> Text
cgenCallArg = \case
  CVar _ argName -> "/* var:" <> argName <> " */ (intptr_t)0"
  CLit _ lit     -> "/* lit:" <> cgenLiteralTag lit <> " */ (intptr_t)0"
  other          -> "/* unsupported-call-arg:" <> cgenExprTag other <> " */ (intptr_t)0"

-- | Emit a first-pass variant-tag placeholder for a constructor name.
cgenVariantTag :: Text -> Text
cgenVariantTag ctor = "/* ctor:" <> ctor <> " */ (intptr_t)0"

-- | Emit a first-pass field-tag placeholder for record selection.
cgenFieldTag :: Text -> Text
cgenFieldTag fieldName = "/* field:" <> fieldName <> " */ (intptr_t)0"

-- | Emit a @switch@ skeleton for case branches.
-- Branch patterns and bodies are surfaced as comments to keep output compilable.
cgenCaseBranchStubs :: [(CorePattern, CoreExpr)] -> Text
cgenCaseBranchStubs branches =
  T.concat (zipWith emit [0 :: Int ..] branches)
  where
    emit ix (pat, body) =
      "    case " <> tshow ix <> ":\n\
      \      /* pattern: " <> cgenPatternTag pat <> " */\n\
      \      /* body: " <> cgenExprTag body <> " */\n\
      \      break;\n"

-- ─── Utilities ────────────────────────────────────────────────────────────────

-- | Convert a Lithic declaration name into a C-safe identifier.
cFunctionName :: Text -> Text
cFunctionName name = "lithic_" <> T.map normalize name
  where
    normalize ch
      | isAlphaNum ch || ch == '_' = ch
      | otherwise                  = '_'

-- | Compact @show@ helper.
tshow :: forall a. Show a => a -> Text
tshow = T.pack . show

-- | Interleave a separator @Builder@ between a list of @Builder@s.
intercalateBuilders :: TB.Builder -> [TB.Builder] -> TB.Builder
intercalateBuilders _ []       = mempty
intercalateBuilders _ [x]      = x
intercalateBuilders sep (x:xs) = x <> sep <> intercalateBuilders sep xs
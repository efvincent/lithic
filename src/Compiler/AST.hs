module Compiler.AST where
  
import Data.Text (Text)
import GHC.Generics (Generic)

-- | Tracks the location of a node in the source code for localized error reporting
data Span = MkSpan
  { startLine :: !Int
  , startCol  :: !Int
  , endLine   :: !Int
  , endCol    :: !Int
  } deriving (Eq, Generic)

instance Show Span where
  show :: Span -> String
  show ss 
    = "[" <> show ss.startLine 
    <> "," 
    <> show ss.startCol 
    <> "]..[" 
    <> show ss.endLine 
    <> ","
    <> show ss.endCol 
    <> "]"

-- | Top-level declarations (Phase 9 addition)
data Decl
  = DeclDef Span Pattern Expr
  deriving (Show, Eq, Generic)

-- | Top level parse result: either a declaration or an expression.
data TopLevel 
  = TDecl Decl
  | TExpr Expr
  deriving (Show, Eq, Generic)
  
-- | Represents the Kind of a Type (the "type of a Type")
-- Crucial for separating structural rows from nominal structs
data Kind
  = KType             -- ^ Standard concrete types
  | KRow              -- ^ Open or closed structural rows of fields
  | KArrow Kind Kind  -- ^ Higher-kinded types (for later phases)
  deriving (Show, Eq, Generic)

-- | The core type representation for Lithic
data Type
  = TVar Span Text
  | TInt Span
  | TFloat Span
  | TString Span
  | TBool Span
  | TArrow Span Type Type
  | TForall Span [Text] Type        -- ^ Universal quantification: forall a b. a -> b
  | TMeta Span Int                  -- ^ A unification meta-variable
  | TSkolem Span Int Text           -- ^ A rigid skolem constant for Rank-2 typechecking
  | TVariant Span Type
  
  -- Row Polymorphism (Kind:KRow)
  | TRowEmpty Span
  | TRowExtend Span Text Type Type  -- ^ Label, Type of the field, and the rest of the Row

  -- Nominal types (Kind:KType)
  | TNominal Span Text

  -- Bridges KRow to KType. Turns a raw row of fields into an actual usable Record type.
  | TRecord Span Type
  deriving (Show, Eq, Generic)

-- Unary and binary operations
data UnOp  = UMinus deriving (Show, Eq, Generic)
data BinOp = OpSub deriving (Show, Eq, Generic)

-- | Defines the type of lens operation being performed
data UpdateOp
  = OpSet     -- ^ Assignment operator (:=)
  | OpModify  -- ^ Modification operator (%=)
  deriving (Show, Eq, Generic)

-- | Represents a single step in a potentially deep update path
data PathSegment
  = PathField Text    -- ^ Standard record field access: `.field`
  -- Future additions:
  -- | PathIndex Expr -- ^ Array/Map indexing: `[0]`
  -- | PathPrism Text -- ^ Variant projection: `.?Ok`
  deriving (Show, Eq, Generic)

-- | Represents primitive literal values in Lithic
data Literal
  = LInt Int
  | LFloat Double
  | LString Text
  | LBool Bool
  deriving (Show, Eq, Generic)

-- | Represents a pattern in a binder (Lambda, Let, or Case)
data Pattern
  = PVar Span Text
  | PWildcard Span 
  | PLit Span Literal
  | PVariant Span Text Pattern
  | PRecord Span [(Text, Pattern)]
  deriving (Show, Eq, Generic)

-- | Extracts the source span from a Pattern node
getPatternSpan :: Pattern -> Span
getPatternSpan = \case
  PVar sp _       -> sp
  PWildcard sp    -> sp
  PLit sp _       -> sp
  PVariant sp _ _ -> sp
  PRecord sp _    -> sp

-- | The core expression AST for lithic
data Expr
  = Var Span Text                      -- ^ A variable identifier: x
  | Lit Span Literal                   -- ^ A primitive literal
  | Lam Span Pattern (Maybe Type) Expr -- ^ A lambda abstraction, optionally annotated: \x : Int => expr
  | App Span Expr Expr                 -- ^ A function application: f x
  | Let Span Pattern Expr Expr         -- ^ Explicit let-binding for FBIP: let x = expr1 in expr2
  | Ann Span Expr Type                 -- ^ Explicit type annotation: expr : Type
  -- Record additions
  | RecEmpty Span
  | RecExtend Span Text Expr Expr                   -- ^ Label, Field value, Rest of record
  | RecSelect Span Expr Text                        -- ^ Record expression, Label to extract
  | RecUpdate Span Expr [PathSegment] UpdateOp Expr -- ^ Native Lenses
  -- Pattern matching
  | Case Span Expr [(Pattern, Expr)]   -- ^ case expression
  | Variant Span Text Expr             -- ^ Constructing a variant: `Ok 42`
  -- Unary and binary operations
  | Unary Span UnOp Expr
  | Binary Span BinOp Expr Expr
  deriving (Show, Eq, Generic)

-- | Extract the source span from a Type node
getTypeSpan :: Type -> Span
getTypeSpan = \case
  TVar sp _           -> sp
  TInt sp             -> sp
  TFloat sp           -> sp
  TString sp          -> sp
  TBool sp            -> sp
  TArrow sp _ _       -> sp
  TForall sp _ _      -> sp
  TMeta sp _          -> sp
  TSkolem sp _ _      -> sp
  TVariant sp _1      -> sp
  TRowEmpty sp        -> sp
  TRowExtend sp _ _ _ -> sp
  TNominal sp _       -> sp
  TRecord sp _        -> sp

-- | Extracts the source span from any AST node
getSpan :: Expr -> Span
getSpan = \case
  Var sp _             -> sp
  Lit sp _             -> sp
  Lam sp _ _ _         -> sp
  App sp _ _           -> sp
  Let sp _ _ _         -> sp
  Ann sp _ _           -> sp
  RecEmpty sp          -> sp
  RecExtend sp _ _ _   -> sp
  RecSelect sp _ _     -> sp
  RecUpdate sp _ _ _ _ -> sp
  Case sp _ _          -> sp
  Variant sp _ _       -> sp
  Unary sp _ _         -> sp
  Binary sp _ _ _      -> sp
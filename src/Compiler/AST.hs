module Compiler.AST where
  
import Data.Text (Text)
import GHC.Generics (Generic)

-- | Tracks the location of a node in the source code for localized error reporting
data SourceSpan = MkSourceSpan
  { startLine :: !Int
  , startCol  :: !Int
  , endLine   :: !Int
  , endCol    :: !Int
  } deriving (Eq, Generic)

instance Show SourceSpan where
  show :: SourceSpan -> String
  show ss 
    = "[" <> show ss.startLine 
    <> "," 
    <> show ss.startCol 
    <> "]..[" 
    <> show ss.endLine 
    <> ","
    <> show ss.endCol 
    <> "]"

-- | Represents the Kind of a Type (the "type of a Type")
-- Crucial for separating structural rows from nominal structs
data Kind
  = KType             -- ^ Standard concrete types
  | KRow              -- ^ Open or closed structural rows of fields
  | KArrow Kind Kind  -- ^ Higher-kinded types (for later phases)
  deriving (Show, Eq, Generic)

-- | The core type representation for Lithic
data Type
  = TVar SourceSpan Text
  | TInt SourceSpan
  | TArrow SourceSpan Type Type
  | TForall SourceSpan [Text] Type        -- ^ Universal quantification: forall a b. a -> b
  | TMeta SourceSpan Int                  -- ^ A unification meta-variable
  | TSkolem SourceSpan Int Text           -- ^ A rigid skolem constant for Rank-2 typechecking
  
  -- | Row Polymorphism (Kind:KRow)
  | TRowEmpty SourceSpan
  | TRowExtend SourceSpan Text Type Type  -- ^ Label, Type of the field, and the rest of the Row

  -- | Nominal types (Kind:KType)
  | TNominal SourceSpan Text

  -- | Bridges KRow to KType. Turns a raw row of fields into an actual usable Record type.
  | TRecord SourceSpan Type
  deriving (Show, Eq, Generic)

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

-- | The core expression AST for lithic
data Expr
  = Var SourceSpan Text                   -- ^ A variable identifier: x
  | Lit SourceSpan Int                    -- ^ A primitive integer literal
  | Lam SourceSpan Text (Maybe Type) Expr -- ^ A lambda abstraction, optionally annotated: \x : Int -> expr
  | App SourceSpan Expr Expr              -- ^ A function application: f x
  | Let SourceSpan Text Expr Expr         -- ^ Explicit let-binding for FBIP: let x = expr1 in expr2
  | Ann SourceSpan Expr Type              -- ^ Explicit type annotation: expr : Type
  -- | Record additions
  | RecEmpty SourceSpan
  | RecExtend SourceSpan Text Expr Expr   -- ^ Label, Field value, Rest of record
  | RecSelect SourceSpan Expr Text        -- ^ Record expression, Label to extract
  | RecUpdate SourceSpan Expr [PathSegment] UpdateOp Expr -- ^ Native Lenses
  deriving (Show, Eq, Generic)

-- | Extract the source span from a Type node
getTypeSpan :: Type -> SourceSpan
getTypeSpan = \case
  TVar sp _           -> sp
  TInt sp             -> sp
  TArrow sp _ _       -> sp
  TForall sp _ _      -> sp
  TMeta sp _          -> sp
  TSkolem sp _ _      -> sp
  TRowEmpty sp        -> sp
  TRowExtend sp _ _ _ -> sp
  TNominal sp _       -> sp
  TRecord sp _        -> sp

-- | Extracts the source span from any AST node
getSpan :: Expr -> SourceSpan
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
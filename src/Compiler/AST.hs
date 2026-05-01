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

-- | The core type representation for Lithic
data Type
  = TVar SourceSpan Text
  | TInt SourceSpan
  | TArrow SourceSpan Type Type
  | TForall SourceSpan [Text] Type  -- ^ Universal quantification: forall a b. a -> b
  | TMeta SourceSpan Int            -- ^ A unification meta-variable
  deriving (Show, Eq, Generic)

-- | The core expression AST for lithic
data Expr
  = Var SourceSpan Text
  -- ^ A variable identifier: x
  | Lit SourceSpan Int
  -- ^ A primitive integer literal
  | Lam SourceSpan Text (Maybe Type) Expr
  -- ^ A lambda abstraction, optionally annotated: \x : Int -> expr
  | App SourceSpan Expr Expr
  -- ^ A function application: f x
  | Let SourceSpan Text Expr Expr
  -- ^ Explicit let-binding for FBIP: let x = expr1 in expr2
  | Ann SourceSpan Expr Type
  -- ^ Explicit type annotation: expr : Type
  deriving (Show, Eq, Generic)

-- | Extract the source span from a Type node
getTypeSpan :: Type -> SourceSpan
getTypeSpan = \case
  TVar sp _ -> sp
  TInt sp -> sp
  TArrow sp _ _ -> sp
  TForall sp _ _ -> sp
  TMeta sp _ -> sp

-- | Extracts the source span from any AST node
getSpan :: Expr -> SourceSpan
getSpan = \case
  Var sp _     -> sp
  Lit sp _     -> sp
  Lam sp _ _ _ -> sp
  App sp _ _   -> sp
  Let sp _ _ _ -> sp
  Ann sp _ _   -> sp

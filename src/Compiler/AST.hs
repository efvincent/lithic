module Compiler.AST where
  
import Data.Text (Text)
import GHC.Generics (Generic)

-- | Tracks the location of a node in the source code for localized error reporting
data SourceSpan = MkSourceSpan
  { startLine :: !Int
  , startCol  :: !Int
  , endLine   :: !Int
  , endCol    :: !Int
  } deriving (Show, Eq, Generic)

-- | The core type representation for Lithic
data Type
  = TVar SourceSpan Text
  | TInt SourceSpan
  | TArrow SourceSpan Type Type
  | TForall SourceSpan [Text] Type -- ^ Universal quantification: forall a b. a -> b
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


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

-- | The core expression AST for lithic
data Expr
  = Var SourceSpan Text
  -- ^ A variable identifier: x
  | Lam SourceSpan Text Expr
  -- ^ A lambda abstraction: \x -> expr
  | App SourceSpan Expr Expr
  -- ^ A function application: f x
  | Let SourceSpan Text Expr Expr
  -- ^ Explicit let-binding for FBIP: let x = expr1 in expr2
  deriving (Show, Eq, Generic)


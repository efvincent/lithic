module Compiler.QQ (c, blk, blks) where

import Language.Haskell.TH.Quote (QuasiQuoter)
import NeatInterpolation (text)
import Data.Text (Text)

-- Define the alias here, where it isn't being used.
c :: QuasiQuoter
c = text

-- Helper to ensure your generated blocks are always terminated with a newline
blk :: Text -> Text
blk t = t <> "\n"

blks :: Text -> Text
blks t = t <> "\n\n"
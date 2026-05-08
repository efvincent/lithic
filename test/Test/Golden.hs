module Test.Golden
  ( discoverGoldenTests
  ) where

import Test.Tasty (TestTree, testGroup)
import Test.Tasty.Golden (findByExtension, goldenVsString)
import System.FilePath ((</>), takeBaseName)

import qualified Data.ByteString.Lazy.Char8 as BSL
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import qualified Data.IntMap.Strict as IM

import Bluefin.Eff (runPureEff)
import Bluefin.Exception (try)
import Bluefin.Reader (runReader)
import Bluefin.State (evalState)

import Compiler.AST (Expr)
import Compiler.Elaborator (ElabError(..), elabExpr)
import Compiler.Evaluator (EvalError(..), evalCore)
import Compiler.Lexer (LexError(..), runLexer)
import Compiler.Parser (ParseError(..), runParser)
import Compiler.TypeChecker (Env(..), TCState(..), TypeError(..), infer, zonk)

-- | Discover all golden tests under test/fixtures and pair them with the
-- matching snapshots under test/golden.
discoverGoldenTests :: IO TestTree
discoverGoldenTests = do
  lfiles <- findByExtension [".lithic"] "test/fixtures"
  pure $ testGroup "Golden Tests" (map mkGoldenTest lfiles)

mkGoldenTest :: FilePath -> TestTree
mkGoldenTest p =
  let n = takeBaseName p
      goldenPath = "test" </> "golden" </> n <> ".golden"
  in goldenVsString n goldenPath (runCompilerPipeline p)

runCompilerPipeline :: FilePath -> IO BSL.ByteString
runCompilerPipeline path = do
  source <- TIO.readFile path
  let resultText = case runLexer source of
        Left lexErr -> "Lex Error: " <> lexErr.msg
        Right toks -> case runParser toks of
          Left parseErr -> "Parse Error: " <> parseErr.msg
          Right ast -> renderTypedPipeline ast
  pure $ BSL.pack (T.unpack resultText <> "\n")

-- | Render the golden snapshot for a successfully parsed surface term.
-- This preserves the existing AST/type view and appends the current
-- Surface-to-Core elaboration result for Phase 8.
renderTypedPipeline :: Expr -> T.Text
renderTypedPipeline ast =
  case tcResult of
    Left tcErr ->
      "Type Error: " <> tcErr.msg <> " at " <> T.pack (show tcErr.span)
    Right ty ->
      case elabExpr ast of
        Left elabErr ->
          "[AST] " <> T.pack (show ast)
            <> "\n[Type] " <> T.pack (show ty)
            <> "\n[Core Error] " <> elabErr.msg <> " at " <> T.pack (show elabErr.span)
        Right core ->
          let evalLine = case evalCore core of
                Right val -> "\n[Val] " <> T.pack (show val)
                Left err  -> "\n[Eval Error] " <> T.pack (show err)
          in
          "[AST] " <> T.pack (show ast)
            <> "\n[Type] " <> T.pack (show ty)
            <> "\n[Core] " <> T.pack (show core)
            <> evalLine
  where
    tcResult =
      runPureEff $
        evalState (MkTCState 0 IM.empty) \st ->
          try \ex ->
            runReader (MkEnv []) \env -> do
              rawTy <- infer st env ex ast
              zonk st rawTy
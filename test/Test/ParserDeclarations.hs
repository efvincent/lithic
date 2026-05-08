module Test.ParserDeclarations
  ( parserDeclarationsUnitTests
  ) where

import qualified Data.Text as T

import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (Assertion, assertFailure, testCase)

import Compiler.AST (TopLevel(..))
import Compiler.Lexer (runLexer)
import Compiler.Parser (parseTopLevel)

-- | Phase 9 parser baseline for top-level forms.
-- `def` declarations now parse; other declaration syntaxes are still rejected.
parserDeclarationsUnitTests :: TestTree
parserDeclarationsUnitTests =
  testGroup "Phase 9 Parser Declaration Baseline"
    [ testCase "file-scope def parses successfully" $
        expectTopLevelDeclSuccess "def x = 1"

    , testCase "file-scope let without in is currently rejected" $
        expectTopLevelFailure "let x = 1"

    , testCase "equation-style top-level declaration is currently rejected" $
        expectTopLevelFailure "id x = x"

    , testCase "signature without equation is currently rejected" $
        expectTopLevelFailure "id :: Int"

    , testCase "signature-equation pair is currently rejected" $
        expectTopLevelFailure "id :: Int\nid = 1"

    , testCase "guarded declaration is currently rejected" $
        expectTopLevelFailure "isZero n | n == 0 => True"

    , testCase "multiple clauses for same name are currently rejected" $
        expectTopLevelFailure "f 0 = 1\nf 1 = 2"

    , testCase "mutual recursion block is currently rejected" $
        expectTopLevelFailure "f x = g x\ng x = f x"

    , testCase "pattern-headed equation is currently rejected" $
        expectTopLevelFailure "x = 1\ny = 2"

    , testCase "where clause in declaration is currently rejected" $
        expectTopLevelFailure "f x = y where y = 1"

    , testCase "expression-only input still parses as top-level expression" $
        expectTopLevelExprSuccess "let x = 1 in x"
    ]

expectTopLevelFailure :: T.Text -> Assertion
expectTopLevelFailure src =
  case runLexer src of
    Left lexErr ->
      assertFailure
        ("Lexer failed unexpectedly for parser-declaration baseline: " <> show lexErr)
    Right toks ->
      case parseTopLevel toks of
        Left _ -> pure ()
        Right tl ->
          assertFailure
            ("Expected parser to reject declaration form, but got top-level AST: " <> show tl)

expectTopLevelDeclSuccess :: T.Text -> Assertion
expectTopLevelDeclSuccess src =
  case runLexer src of
    Left lexErr ->
      assertFailure
        ("Lexer failed: " <> show lexErr)
    Right toks ->
      case parseTopLevel toks of
        Left parseErr ->
          assertFailure
            ("Expected declaration parse success, but got error: " <> show parseErr)
        Right topLevel ->
          case topLevel of
            TDecl _ -> pure ()
            TExpr expr ->
              assertFailure
                ("Expected top-level declaration, but parsed expression: " <> show expr)

expectTopLevelExprSuccess :: T.Text -> Assertion
expectTopLevelExprSuccess src =
  case runLexer src of
    Left lexErr ->
      assertFailure
        ("Lexer failed: " <> show lexErr)
    Right toks ->
      case parseTopLevel toks of
        Left parseErr ->
          assertFailure
            ("Expected top-level expression parse success, but got error: " <> show parseErr)
        Right topLevel ->
          case topLevel of
            TExpr _ -> pure ()
            TDecl decl ->
              assertFailure
                ("Expected top-level expression, but parsed declaration: " <> show decl)

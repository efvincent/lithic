module Test.ParserDeclarations
  ( parserDeclarationsUnitTests
  ) where

import qualified Data.Text as T

import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (Assertion, assertFailure, testCase)

import Compiler.Lexer (runLexer)
import Compiler.Parser (runParser)

-- | Phase 9 parser baseline: document current rejection of declaration forms.
-- These tests intentionally assert failure; each flips to success as
-- declaration grammar lands in the parser.
parserDeclarationsUnitTests :: TestTree
parserDeclarationsUnitTests =
  testGroup "Phase 9 Parser Declaration Baseline"
    [ testCase "file-scope let without in is currently rejected" $
        expectParseFailure "let x = 1"

    , testCase "equation-style top-level declaration is currently rejected" $
        expectParseFailure "id x = x"

    , testCase "signature without equation is currently rejected" $
        expectParseFailure "id :: Int"

    , testCase "signature-equation pair is currently rejected" $
        expectParseFailure "id :: Int\nid = 1"

    , testCase "guarded declaration is currently rejected" $
        expectParseFailure "isZero n | n == 0 => True"

    , testCase "multiple clauses for same name are currently rejected" $
        expectParseFailure "f 0 = 1\nf 1 = 2"

    , testCase "mutual recursion block is currently rejected" $
        expectParseFailure "f x = g x\ng x = f x"

    , testCase "pattern-headed equation is currently rejected" $
        expectParseFailure "x = 1\ny = 2"

    , testCase "where clause in declaration is currently rejected" $
        expectParseFailure "f x = y where y = 1"

    , testCase "expression-only input still parses successfully" $
        expectParseSuccess "let x = 1 in x"
    ]

-- | Assert that a source snippet is rejected by the current expression-only parser.
expectParseFailure :: T.Text -> Assertion
expectParseFailure src =
  case runLexer src of
    Left lexErr ->
      assertFailure
        ("Lexer failed unexpectedly for parser-declaration baseline: " <> show lexErr)
    Right toks ->
      case runParser toks of
        Left _ -> pure ()
        Right ast ->
          assertFailure
            ("Expected parser to reject declaration form, but got AST: " <> show ast)

-- | Assert that an expression-only input still parses successfully.
expectParseSuccess :: T.Text -> Assertion
expectParseSuccess src =
  case runLexer src of
    Left lexErr ->
      assertFailure
        ("Lexer failed: " <> show lexErr)
    Right toks ->
      case runParser toks of
        Left parseErr ->
          assertFailure
            ("Expected parse success, but got error: " <> show parseErr)
        Right _ast -> pure ()

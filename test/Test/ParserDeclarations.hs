module Test.ParserDeclarations
  ( parserDeclarationsUnitTests
  ) where

import qualified Data.Text as T

import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (Assertion, assertFailure, testCase)

import Compiler.AST (TopLevel(..))
import Compiler.Lexer (Token(..), TokenClass(..), runLexer)
import Compiler.Parser (parseTopLevel)

-- | Phase 9 parser declaration coverage.
-- Includes `def`, signature forms, single-clause equations, and Phase 9F
-- first-slice single-argument multi-clause equations.
parserDeclarationsUnitTests :: TestTree
parserDeclarationsUnitTests =
  testGroup "Phase 9 Parser Declaration Baseline"
    [ testCase "file-scope def parses successfully" $
        expectTopLevelDeclSuccess "def x = 1"

    , testCase "file-scope let without in is currently rejected" $
        expectTopLevelFailure "let x = 1"

    , testCase "equation-style top-level declaration parses successfully (Phase 9D)" $
      expectTopLevelDeclSuccess "id x = x"

    , testCase "signature without equation parses successfully (Phase 9B)" $
      expectTopLevelDeclSuccess "id : Int"

    , testCase "top-level bare ident annotation is parsed as signature declaration" $
      expectTopLevelDeclSuccess "x : Int"

    , testCase "top-level parenthesized annotation is currently rejected" $
      expectTopLevelFailure "(x) : Int"

    , testCase "signature-equation pair parses successfully (Phase 9B.2)" $
      expectTopLevelDeclSuccess "id : Int\nid = 1"

    , testCase "signature-equation pair tolerates blank separator lines" $
      expectTopLevelDeclSuccess "id : Int\n\nid = 1"

    , testCase "signature-equation pair tolerates comment separator lines" $
      expectTopLevelDeclSuccess "id : Int\n-- comment\nid = 1"

    , testCase "guarded declaration is currently rejected" $
        expectTopLevelFailure "isZero n | n == 0 => True"

    , testCase "single-argument multi-clause equations parse successfully (Phase 9F first slice)" $
        expectTopLevelDeclSuccess "f 0 = 1\nf 1 = 2"

    , testCase "single-argument multi-clause equations support constructor-headed patterns" $
      expectTopLevelDeclSuccess "unwrap Ok x = x\nunwrap _ = 0"

    , testCase "single-argument multi-clause equations tolerate trailing spaces" $
      expectTopLevelDeclSuccess "f 0 = 1   \nf 1 = 2   "

    , testCase "multi-argument multi-clause equations are currently rejected" $
      expectTopLevelFailureMessage
        "Multi-argument multi-clause equations are not yet supported"
        "f x y = 1\nf z w = 2"

    , testCase "same-name clauses with inconsistent arity are rejected" $
      expectTopLevelFailureMessage
        "inconsistent arity"
        "f x = 1\nf y z = 2"

    , testCase "inconsistent arity is still detected across blank separator lines" $
      expectTopLevelFailureMessage
        "inconsistent arity"
        "f x = 1\n\nf y z = 2"

    , testCase "mutual recursion block is currently rejected" $
        expectTopLevelFailure "f x = g x\ng x = f x"

    , testCase "pattern-headed equation is currently rejected" $
        expectTopLevelFailure "x = 1\ny = 2"

    , testCase "where clause in declaration is currently rejected" $
        expectTopLevelFailure "f x = y where y = 1"

    , testCase "expression-only input still parses as top-level expression" $
        expectTopLevelExprSuccess "let x = 1 in x"

    , testCase "top-level expression with identifier-led continuation line does not misclassify as clause" $
      expectTopLevelExprSuccess
        "let f = \\x => x in\nf True 1"

    , testCase "grouped local let clauses with one trailing in parse as expression" $
      expectTopLevelExprSuccess "let x = 1\n    y = 2\nin x"

    , testCase "grouped local let allows multiline first-clause rhs" $
      expectTopLevelExprSuccess
        "let x =\n      case True of\n        True => 1\n        False => 0\n    y = 2\nin y"

    , testCase "single-clause let with multiline rhs still parses" $
      expectTopLevelExprSuccess
        "let x =\n  case True of\n    True => 1\n    False => 0\nin x"

    , testCase "grouped local let without trailing in is rejected" $
      expectTopLevelFailure "let x = 1\n    y = 2"

    , testCase "known limitation: single-clause let with multiline record RHS is misclassified as grouped let" $
      expectTopLevelFailure
        "let x =\n    {\n    y = 1,\n    z = 2\n    }\nin x.y"

    , testCase "empty case branch list reports explicit diagnostic" $
      expectTopLevelFailureMessage
        "Case expression must have at least one branch"
        "case x of"

    , testCase "top-level parse rejects token stream missing EOF" $
      expectTopLevelFailureWithoutEOF "let x = 1 in x"
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

expectTopLevelFailureMessage :: T.Text -> T.Text -> Assertion
expectTopLevelFailureMessage expectedMsg src =
  case runLexer src of
    Left lexErr ->
      assertFailure
        ("Lexer failed unexpectedly for parser-declaration baseline: " <> show lexErr)
    Right toks ->
      case parseTopLevel toks of
        Left parseErr ->
          let rendered = T.pack (show parseErr)
          in if expectedMsg `T.isInfixOf` rendered
            then pure ()
            else assertFailure
              ("Expected parser error to contain '"
              <> T.unpack expectedMsg
              <> "', but got: "
              <> show parseErr)
        Right tl ->
          assertFailure
            ("Expected parser failure, but got top-level AST: " <> show tl)

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

expectTopLevelFailureWithoutEOF :: T.Text -> Assertion
expectTopLevelFailureWithoutEOF src =
  case runLexer src of
    Left lexErr ->
      assertFailure
        ("Lexer failed: " <> show lexErr)
    Right toks ->
      let toksNoEOF = filter (\tok -> tok.cls /= TokEOF) toks
      in case parseTopLevel toksNoEOF of
          Left _ -> pure ()
          Right topLevel ->
            assertFailure
              ("Expected parse failure without EOF token, but got: " <> show topLevel)

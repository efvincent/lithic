# Revision history for lithic

## 0.2.0.0 -- 2026-04-30

* Completed type-checker frontend (lexer, parser, AST).
* Implemented Pratt parser with bidirectional expression precedence (application, annotation, lowest).
* Parser supports term-level type annotations: `x : Int`, `\x : T => body`, `let y = e : T in body`.
* Established grammar: `=>` for term-level lambda delimiter, `->` for type-level arrows.
* Uppercase identifiers (`TokUIdent`) recognized in term position for future data constructors.
* Let-binding RHS parses with lowest precedence to enable full expression including annotations.
* Simplified precedence model from 5 levels to 3 (removed unused `PrecBind` and `PrecArrow`).
* REPL now displays `[AST]...` output on successful parse; lexer/parser errors shown inline.
* Thread-safe event loop via `BChan` (REPL → TUI) and `MVar` (TUI → REPL) handoff.
* Pure entry points: `runLexer :: Text -> Either LexError [Token]`, `runParser :: [Token] -> Either ParseError Expr`.

## 0.1.0.0 -- 2026-04-25

* First version. Lexer and basic REPL structure. Released on an unsuspecting world.

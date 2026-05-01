# Revision history for lithic

## 0.4.0.0 -- 2026-05-01

* Added stateful unification infrastructure to the bidirectional typechecker via `TCState`, `TMeta`, `force`, `unify`, and `occurs`.
* Moved ownership of the typechecker substitution state to the executable entrypoint so the REPL runs with a persistent unification handle.
* Corrected deep type finalization so zonked user-facing types return the resolved outer type after forcing substitutions.
* Added `containers` as a package dependency for the `IntMap`-backed substitution store.
* Added `docs/typechecker.md` and synced README, terminal-effect notes, and project instructions to the stateful unification architecture.

## 0.3.0.0 -- 2026-04-30

* Wired bidirectional type inference/checking into the REPL runtime path after parse success.
* REPL now emits `[AST]...` followed by `[Type] ...` for successful input.
* REPL now reports type failures as `Type Error: <msg> at <span>`.
* Parser now accepts uppercase identifiers (`TokUIdent`) as expression NUDs so constructor-like terms parse in expression position.
* Parser implicit application starter set now includes both uppercase identifiers and integer literals.
* Added custom `Show` formatting for `SourceSpan` as `[startLine,startCol]..[endLine,endCol]`.
* Synced documentation (`README.md`, `.github/copilot-instructions.md`, `docs/terminal-effect.md`) to the updated REPL/typechecker behavior.

## 0.2.0.0 -- 2026-04-30

* Completed parser frontend pipeline (lexer, parser, surface AST).
* Implemented Pratt parser with bidirectional expression precedence (application, annotation, lowest).
* Parser supports term-level type annotations: `x : Int`, `\x : T => body`, `let y = e : T in body`.
* Established grammar: `=>` for term-level lambda delimiter, `->` for type-level arrows.
* Uppercase identifiers (`TokUIdent`) recognized in term position for future data constructors.
* Let-binding RHS parses with lowest precedence to enable full expression including annotations.
* Simplified precedence model from 5 levels to 3 (removed unused `PrecBind` and `PrecArrow`).
* Added initial bidirectional typechecker module (not yet wired into the REPL runtime path).
* Improved checking diagnostics for unannotated lambdas in non-function expected contexts.
* REPL now displays `[AST]...` output on successful parse; lexer/parser errors shown inline.
* Thread-safe event loop via `BChan` (REPL → TUI) and `MVar` (TUI → REPL) handoff.
* Pure entry points: `runLexer :: Text -> Either LexError [Token]`, `runParser :: [Token] -> Either ParseError Expr`.

## 0.1.0.0 -- 2026-04-25

* First version. Lexer and basic REPL structure. Released on an unsuspecting world.

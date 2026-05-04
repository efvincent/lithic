# Revision history for lithic

## 0.7.0.0 -- 2026-05-04

* Added initial row-polymorphism surface and type-level machinery:
	* `TRowEmpty` / `TRowExtend` and `TRecord` in the type AST,
	* record expression forms `RecEmpty`, `RecExtend`, and `RecSelect` in the term AST,
	* initial lens-style update node `RecUpdate` with `PathSegment` and `UpdateOp`.
* Extended lexer coverage for record and lens syntax:
	* record tokens (`{`, `}`, `,`, `|`),
	* lens operators (`:=`, `%=`).
* Extended Pratt parsing to support:
	* record literals (`{ x = 1, y = 2 }`),
	* row-tail record forms (`{ x = 1 | rest }`),
	* field selection (`record.field`),
	* native lens updates (`record.{ a.b := v }`, `record.{ a %= f }`).
* Added row-aware unification and path-resolution support in the typechecker:
	* row rewriting/label extraction (`rewriteRow`),
	* open-row meta expansion during field access,
	* record-selection inference,
	* lens update checking for both set (`:=`) and modify (`%=`) operators.
* Added golden coverage for row-polymorphism and lens behavior:
	* positive: `record-basic`, `row-shift`, `lens-set`, `lens-modify`,
	* negative: `fail-missing-field`, `fail-strict-record-mismatch`, `fail-lens-set-type`, `fail-lens-mod-type`.
* Synced documentation (`README.md`, `docs/typechecker.md`, `docs/project-plan.md`, `.github/copilot-instructions.md`) with current parser/typechecker behavior and roadmap state.

## 0.6.0.0 -- 2026-05-03

* Added initial rank-2 subsumption support in the bidirectional checker by expanding `subsumes` with:
	* expected-type skolemization for `forall` types,
	* inferred-type instantiation for polymorphic values,
	* arrow subsumption (domain contravariance and range covariance).
* Added rigid skolem constants (`TSkolem`) in the type AST and unified them only by identity to prevent unsound instantiation.
* Added helper paths for skolem generation and skolemization in the typechecker.
* Added golden coverage for rank-2 success and rigid-skolem rejection paths:
	* `test/golden/rank2-success.lithic` / `.golden`
	* `test/golden/rank2-rigid-fail.lithic` / `.golden`
* Added `docs/higher-rank-types.md` as a focused reference for rank-2 polymorphism, skolemization, `forall`, unification, and occurs-check terminology.
* Added `docs/project-plan.md` as a long-range architecture and roadmap record, and linked it from `README.md`.
* Added a novice-oriented "How To Read The Docs" guide in `README.md` and cross-links from `docs/typechecker.md` and `docs/architecture-vs-type-system.md` to improve concept discoverability.
* Synced documentation (`README.md`, `docs/typechecker.md`, `docs/architecture-vs-type-system.md`) with current rank-2 subsumption behavior.

## 0.5.1.0 -- 2026-05-02

* Added `tasty` and `tasty-golden` test harness to lock in the Hindley-Milner typechecking baseline.
* Added golden test cases for let-polymorphism, the occurs check, and comprehensive AST composition.
* Updated README and `docs/cabal-project.md` with the `cabal test lithic-test` workflow and golden-test layout.

## 0.5.0.0 -- 2026-05-02

* Added HM-style let-polymorphism in the bidirectional checker by generalizing inferred `let`-bound types and instantiating polymorphic bindings on variable lookup.
* Added `instantiate`, `generalize`, `replaceMetas`, `subBound`, `ftvType`, and `ftvEnv` support paths in the typechecker to drive rank-1 polymorphic `let` behavior.
* Updated checker fallback routing to go through the `subsumes` bridge, preserving the future extension point for rank-2 skolemization.
* Extended deep type finalization (`zonk`) to recurse through `TForall` values.
* Removed an unused environment helper from the typechecker.
* Added `docs/optimizations.md` documenting the current let-generalization environment traversal cost and a level-based generalization roadmap.
* Synced `README.md`, `docs/typechecker.md`, and `docs/architecture-vs-type-system.md` with the current implementation status and architecture guidance.

## 0.4.1.0 -- 2026-05-01

* Moved shared source-span helpers (`getSpan`, `getTypeSpan`) into `Compiler.AST` to preserve phase boundaries and remove parser-internal coupling from the typechecker.
* Refined lambda annotation mismatch diagnostics to report the specific annotation span instead of the broader lambda span.
* Added architecture notes in `docs/architecture-vs-type-system.md` and linked them from `README.md`.
* Synced typechecker docs and user-facing examples with the current fresh-meta inference/checking behavior.

## 0.4.0.0 -- 2026-05-01

* Added stateful unification infrastructure to the bidirectional typechecker via `TCState`, `TMeta`, `force`, `unify`, and `occurs`.
* Moved ownership of the typechecker substitution state to the executable entrypoint so the REPL runs with a persistent unification handle.
* Corrected deep type finalization so zonked user-facing types return the resolved outer type after forcing substitutions.
* Added fresh-meta inference/checking paths so unannotated lambdas and unknown function applications can be constrained through unification.
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

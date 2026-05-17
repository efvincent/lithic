# Revision history for lithic

## 0.9.9.0 -- 2026-05-17 (Phase 9H: Core Decl Groups + Persistent REPL Environment)

* H1 — Core/Elaborator declaration-aware boundary:
	* `CoreDecl` and `CoreTopLevel` added to `Compiler.AST.Core`.
	* `elabTopLevel` and `elabDecl` added to `Compiler.Elaborator`.
	* `DeclSig` lowers to `CDeclSig`; `DeclDef` with a named binder lowers to `CDeclDef`.
	* Non-variable top-level binders produce an explicit elaboration diagnostic.
	* `getCoreDeclSpan` accessor added alongside existing `getCoreSpan`/`getCorePatternSpan`.
* H2 — Persistent REPL type environment:
	* REPL now threads a persistent `Env` through the loop via local state (no new effect handle).
	* Input is routed through `parseTopLevel` instead of `runParser`.
	* Named definitions (`f x = body`) accepted, type-inferred, generalized, and persisted in env.
	* Signature-only declarations acknowledged but not yet persisted (deferred to a follow-up slice).
	* Parse/lex/type errors do not corrupt the previously accepted environment.
* Tests:
	* `Test.Phase9HScaffold` filled in with 5 H1 elaboration unit tests covering expression path,
	  signature, named definition, non-variable binder rejection, and lambda body lowering.
* Haddock typos fixed in `Compiler.Elaborator` ("singatures", "requireing").

## 0.9.8.0 -- 2026-05-17 (Phase 9G Where Blocks + Roadmap Restructure)

* Phase 9G: `where` blocks on equation-style top-level declarations.
	* `TokWhere` added to the lexer as a reserved keyword and layout block trigger.
	* `runLayout` opens a column-tracked virtual block after `where` (same mechanism as `of`).
	* `not pending` guard added to the top-level `TokVirtSemi` injection rule to prevent spurious
	  separators before the first token of any newly-opened layout block (latent bug fix).
	* `parseOptionalWhere` / `parseWhereBindings` / `applyWhereToTopLevel` / `wrapBodyWithWhere`
	  added to `Compiler.Parser`.
	* Where bindings are layout-delimited (`TokVirtSemi` separators, `TokVirtRBrace` close).
	* Each binding supports an optional type annotation (`name : Type = expr`).
	* `wrapBodyWithWhere` recursively descends through the `Lam` spine of the equation body
	  and wraps the innermost expression with `foldr Let` over the where-bindings.
	* `TokWhere` in expression position produces an explicit diagnostic in `parseNud`.
	* `def` form does not route through `parseOptionalWhere`; deferred.
* Tests and fixtures:
	* New golden fixture: `where-basic` (single-binding where block).
	* New parser-unit tests: where block inline, with indentation, multiple bindings,
	  on multi-clause equation, def rejection, type-annotated binding, expression-position error.
* Documentation sync:
	* `docs/language-spec.md` v0.5: `where` added to keywords, layout triggers updated,
	  declaration status table updated, scope baseline updated.
	* `README.md`: `where` block example added.
	* `.github/copilot-instructions.md`: Grammar section updated with `where` block form.
	* `docs/project-plan.md` Phase 9G tasks marked complete.
* Code quality:
	* Three comment typos fixed in `Compiler.Parser` (NTO→NOT, nother→Other, innnermost→innermost).
* Roadmap restructure:
	* Phase 9 trimmed to two Phase 10 prerequisites (Core/Elaborator top-level groups; REPL
	  persistent environment). All other Phase 9 deferred syntax tasks explicitly moved to Phase 11.
	* Phase 10 (new): C Code Generation First Pass — monomorphic programs, malloc-and-leak,
	  closures as function-pointer+capture struct, structural records as slow-path heap arrays,
	  variants as tagged C unions, single-file `.c` output.
	* Phase 11 (new): Surface Syntax Completion — absorbs deferred Phase 9 items plus
	  former Phase 9.5 (Lists) and Phase 9.6 (Tuples).
	* Phases 12–17: Module System, Existentials & GADTs, Linear Types + FBIP + C Backend Upgrade,
	  Numeric Capabilities, IO Effect Capability Layer, Tooling Ecosystem.


* Phase 9F first slice: single-argument multi-clause top-level equation grouping.
	* Parser groups repeated same-name arity-1 equation clauses into a single declaration-level lowering.
	* Multi-clause lowering target: `DeclDef name (\\$arg0 => case $arg0 of ...)`.
	* Existing single-clause equation lowering path remains unchanged for snapshot stability.
	* Top-level signature+equation pairing now tolerates layout-inserted virtual semicolon separators between lines.
	* Top-level clause-head detection in the layout pass is tightened to avoid injecting spurious `TokVirtSemi` into ordinary expression inputs.
	* Explicit parser diagnostics are now the contract for unsupported shapes:
		* inconsistent same-name clause arities,
		* multi-argument multi-clause groups (follow-on slice).
* Tests and fixtures:
	* Updated parser declaration unit tests to assert Phase 9F first-slice acceptance.
	* Refreshed multi-clause fixtures/goldens to reflect grouped-lowering behavior and arity diagnostics.
	* Kept explicit failing fixture coverage for non-groupable top-level clause streams.
* Documentation sync:
	* Updated `docs/language-spec.md` declaration status table for multi-clause arity-1 vs arity>1 support.
	* Updated `docs/project-plan.md` roadmap status markers (Phase 9 current, 9F first slice complete).
	* Updated README Phase 9 status note for declaration parsing capabilities.

## 0.9.6.0 -- 2026-05-09 (Phase 9E Layout Complete)

* Phase 9E: bounded layout preprocessing pass.
	* Add `runLayout :: [Token] -> [Token]` pure pass between lexer and parser.
	* Inserts `TokVirtSemi` (clause/statement separator) and `TokVirtRBrace` (block close) virtual tokens.
	* Eliminates the `clauseLayoutCol` field and column-check hack in `peekPrecedence`.
	* Unblocks multi-clause function equations and future `where` blocks.
* Phase 9E (layout-delimited case branches): completed and tested.
	* Case expressions now use `TokVirtSemi`-delimited branches with no `|` prefix.
	* Parser migration from manual `|` consumption to virtual-token-driven branch parsing.
	* All case-related golden fixtures updated and passing.
* Phase 9E (layout-delimited grouped local let): completed and tested.
	* Grouped local `let` clauses with single trailing `in` now supported.
	* Lowered to ordered nested `Let` nodes with span preservation.
	* Sibling-clause detection heuristic gates layout opening to avoid false positives.
	* Comprehensive regression test coverage: basic grouped let, multiline first-clause RHS, multiline second-clause RHS, inner let in RHS, and explicit known-limitation case.
	* Known limitation documented: multiline record-literal fields with `=` at clause-head indentation can be misclassified as sibling clauses; mitigation recommended for declaration-group/where-block work.
* Documentation updates:
	* Updated `docs/language-spec.md` to mark grouped local let as implemented.
	* Added Phase 9E implementation notes in `docs/project-plan.md` covering the grouped-let layout hazard and mitigation strategy.
	* Updated README with grouped local let example.
	* Ensured all Phase 9E task status in roadmap reflects completion.
* Test harness improvements:
	* Added 6 parser-unit regression tests for grouped let behavior, empty-case diagnostic coverage, and the explicit known-limitation case.
	* Added 5 new golden fixtures for grouped-let and known-limitation coverage.

## 0.9.5.0 -- 2026-05-08

* Phase 9D: single-clause equation-style top-level declarations.
	* Parser now accepts `f p1 ... pn = expr` at top level via `parseTopLevel`.
	* Lowered by parser to a `DeclDef` whose RHS is nested lambdas over the equation parameters.
	* `tryParseEquationDecl` helper added; single-clause path tested and goldens in place.
* Phase 9B: signature-only top-level declaration parsing.
	* `parseTopLevel` accepts `ident : Type` as a `DeclSig` declaration.
	* Disambiguation rule: bare `ident : Type` at top level is reserved to signature declarations.
* Phase 9B.2: same-name signature+equation pair parsing.
	* `parseTopLevel` accepts `ident : Type` immediately followed by `ident = expr` (same name) and lowers to a single annotated `DeclDef`.
* Phase 9A: initial top-level declaration infrastructure.
	* Lexer keyword `def` added; `TokDef` routed through Pratt parser.
	* `Decl` and `TopLevel` carrier types added to `Compiler.AST`.
	* `parseTopLevel` entry point introduced alongside expression-oriented `runParser`.
* Golden harness upgraded to use `parseTopLevel` as its pipeline entry point.
	* Declaration fixtures render as `[Decl] <show decl>`; expression fixtures continue through type/core/eval path.
	* Added golden fixtures for: `decl-signature`, `decl-signature-equation`, `decl-equation-single-clause`, `fail-multi-clause-decl`.
* Fixed `mergeSpan` argument order for `Ann` span in signature+equation parser branch (was inverted, producing invalid spans).
* Fixed typo in parse error message: "Expceted EOF after declaration" → "Expected EOF after declaration".
* Removed unused `expectNotImplemented` helper from `test/Test/Evaluator.hs`.

## 0.9.4.0 -- 2026-05-07

* Added a first-class documentation program goal in `docs/project-plan.md` targeting book-scale compiler documentation.
* Added a chapter-oriented documentation track covering parsing, bidirectional typing, coverage analysis, completeness boundaries, Bluefin usage, evaluator semantics, and backend strategy.
* Added documentation quality and cadence policy (Mode 2):
	* per-feature PR documentation deltas,
	* per-phase chapter-level updates,
	* weekly (or every 5-10 PRs) editorial consolidation,
	* release-time chapter progress synchronization.

## 0.9.3.0 -- 2026-05-07

* Completed the post-Phase-7 formalization checkpoint in `docs/language-spec.md`.
* Added explicit implemented-vs-planned semantics split to reduce normative ambiguity.
* Added formalized pattern-coverage/redundancy judgment sketches for specialization, missing-witness generation, and usefulness recursion.
* Added explicit Surface-to-Core boundary and planned elaboration-relation section.
* Marked the formalization checkpoint complete in `docs/project-plan.md`.

## 0.9.2.0 -- 2026-05-07

* Promoted the Phase-7 addendum in `docs/language-spec.md` from provisional draft status to normative status for implemented `case`-branch coverage behavior.
* Reworded stale "planned/interim" sections in the addendum to reflect current implemented semantics for open-universe exhaustiveness and redundancy.
* Clarified current deferred scope boundaries in the language spec (guards, grouped function equations, and binder-pattern coverage outside `case`).
* Marked the final Phase-7 roadmap task complete in `docs/project-plan.md` (addendum promotion to normative).

## 0.9.1.0 -- 2026-05-07

* Completed Phase-7 open-universe usefulness/redundancy enforcement for case branches.
* Extended pattern usefulness/specialization handling so literal-refined branches (for example constructor payload literals) are not misclassified as unreachable.
* Added/updated regression coverage for open-variant redundancy and literal-refinement usefulness behavior.
* Synced `docs/language-spec.md` with implemented semantics:
	* open-universe redundancy now documented as enforced,
	* literal/open-domain policy clarified as exact observed head matching + wildcard/default decomposition,
	* explicit separation maintained between pattern usefulness semantics and future operator capability/type-class resolution.
* Updated `docs/project-plan.md`:
	* marked the open-universe usefulness/redundancy Phase-7 task complete,
	* retained policy notes for infinite/open domains.

## 0.9.0.0 -- 2026-05-06

* Added Phase-7 pattern-coverage scaffolding module Compiler.PatternMatch.
* Added case-branch redundancy checking (unreachable branch errors).
* Added case-branch exhaustiveness checking with witness-based diagnostics.
* Wired coverage checks into case inference path in the bidirectional checker.
* Added HUnit unit tests for bool and closed-variant coverage/redundancy behavior.
* Clarified current Phase-7 interim boundary:
	* Exhaustiveness is enforced for finite and open constructor universes.
	* Unreachable-branch errors are currently enforced for finite universes only.
	* Open-universe redundancy detection is deferred pending fuller usefulness stabilization.
  
## 0.8.1.0 -- 2026-05-06

* Added `docs/language-spec.md` as a normative living core language specification to prevent semantic drift during active phase work.
* Added a concrete Phase-7 addendum template in `docs/language-spec.md` for matrix definitions, exhaustiveness/usefulness judgments, diagnostics contracts, and golden-test obligations.
* Prefilled the Phase-7 addendum with a Maranget-aligned provisional draft covering matrix objects, specialization/default behavior, witness policy, redundancy diagnostics, and integration touch points.
* Defined a formal anti-drift documentation policy requiring spec updates in the same change as parser/typechecker-visible behavior changes.
* Added a lightweight semantic-change PR checklist to `docs/project-plan.md` to enforce spec-sync and golden coverage in review workflow.
* Synced documentation pointers and governance notes across:
	* `README.md` (documentation index and reading order)
	* `docs/project-plan.md` (active anti-drift discipline and post-Phase-7 formalization checkpoint)
	* `.github/copilot-instructions.md` (documentation expectations)

## 0.8.0.0 -- 2026-05-05

* Extended literals across lexer/parser/AST/typechecker:
	* Added literal forms for `Int`, `Float`, `String`, and `Bool`.
	* Added lexer support for quoted string tokens and boolean keywords (`True`, `False`).
* Added arithmetic surface support:
	* Prefix unary minus (`-x`).
	* Infix subtraction (`x - y`) with explicit Pratt precedence.
	* Line comments via `-- ...` in the lexer.
* Added variant and pattern-matching foundations:
	* New AST forms for `Pattern`, `Case`, and `Variant`.
	* Parser support for `case ... of | pat => expr` pipe-style branches and pattern binders in lambda/let sites.
	* Typechecker support for `checkPattern`-driven environment extension and branch checking in `Case`.
* Extended type-level and unification support:
	* Added primitive type nodes `TFloat`, `TString`, and `TBool`.
	* Added `TVariant` and unified variant rows through existing row-polymorphism machinery.
	* Updated `zonk`, `occurs`, `replaceMetas`, `subBound`, and `ftvType` traversal paths to include variants.
* Reorganized golden test inputs:
	* `.lithic` fixtures now live in `test/fixtures/`.
	* Expected snapshots remain in `test/golden/*.golden`.
	* Golden harness now discovers fixtures from `test/fixtures` and maps by basename to `test/golden` outputs.
* Synced documentation and planning docs with current feature state and roadmap phase progression.

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
* Added custom `Show` formatting for `Span` as `[startLine,startCol]..[endLine,endCol]`.
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

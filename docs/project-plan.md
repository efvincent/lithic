# Lithic Project Plan & Architecture Record

## 1. Project Vision
**Lithic** is an experimental, high-performance, purely functional programming language. 
* **Target:** Compiles directly to standard C without a garbage collector or heavy runtime, featuring bidirectional C FFI.
* **Paradigms:** Pure functional, but capable of C-level performance via Functional But In-Place (FBIP) mutations and linear types.
* **Evaluation:** Strict, small-step semantics are the baseline evaluator direction.
* **Type System:** Advanced structural typing featuring Rank-2 Polymorphism, Row Polymorphism, Existential Types, and Bidirectional Typechecking.
* **Developer Experience:** A rich interactive REPL, an integrated LSP server, and native debugging capabilities.

### Documentation Goal (Book-Scale)
Lithic also targets a long-form educational deliverable: documentation approaching book length that teaches what is necessary to understand and build a compiler in this style.

This documentation track is a first-class project goal, not a post-hoc artifact.

Primary instructional pillars include:
1. Parsing architecture and Pratt parsing technique.
2. Bidirectional type checking and unification strategy.
3. Pattern coverage analysis (exhaustiveness and redundancy/usefulness).
4. Completeness boundaries and where formal guarantees do or do not currently hold.
5. Practical effect management in Haskell using Bluefin.
6. Operational semantics choices (small-step vs big-step) and strict evaluator construction.
7. Backend engineering techniques (C code generation and potential LLVM pathways).

## 2. Core Architectural Decisions
These decisions are locked in and should guide all future implementation phases:
* **Compiler Implementation:** Haskell (targeting GHC 9.14.1+ for LTS stability and zero-cost abstraction optimization).
* **Effect Tracking:** The `Bluefin` effect system. We strictly avoid monad transformer stacks (MTL) in favor of explicit, localized effect handles (e.g., `Reader Env`, `State TCState`, `Exception TypeError`). The same Bluefin-style lexical capability model is the basis for Lithic's user-facing effect system: effects in user programs are tracked via row polymorphism (e.g., `{ io } String`) and compiled to C dictionary pointers, not monadic wrappers.
* **Lenses:** `microlens` and `generic-lens` for lightweight, boilerplate-free state updates.
* **Parsing:** A hand-rolled lexer capturing precise `Span` data, feeding into a Pratt Parser (Top-Down Operator Precedence) for elegant, extensible precedence handling.
* **Typechecker Architecture:** A **Bidirectional** engine splitting AST traversal into `check` (top-down expected types) and `infer` (bottom-up type synthesis). 
* **Unification:** Stateful strict unification rather than constraint-graph generation. `TMeta` and `TSkolem` variables are mutated/bound in a fast `Bluefin.State` dictionary.
* **Testing:** Snapshot testing using `tasty` and `tasty-golden` to verify the pure compiler pipeline and localized error messages without brittle unit tests.
* **Native Lenses (FBIP Optimized):** Lithic features a built-in optics surface baked directly into the AST (`RecUpdate Expr [PathSegment] UpdateOp Expr`). 
  * **Unified Path Architecture:** Deep updates support a sequence of `PathSegment`s, seamlessly mixing record fields (`.x`), array/map indices (`[0]`), and eventually Prisms (`.?Ok`) without artificially fracturing the AST.
  * **Ergonomics & Sugar:** The parser supports first-class update operators (`:=` for set, `%=` for modify, and desugared standard operators like `+=` and `-=`).
  * **FBIP Pipeline:** By keeping deep updates as a single AST node, the backend can easily prove unique references (RC=1) and compile them directly into zero-cost, in-place C pointer mutations.
* **The Dual-Mode Record Architecture:** Lithic employs a "Gradual Performance" model for data structures, segregating records at the Kind level while unifying them at the surface syntax level.
  * **Mode A: Structural Rows (`KRow`)**: Created dynamically (e.g., `{ x = 1 }`). These power the flexible, script-like duck-typing of the frontend. In the C-backend, they compile to heap-allocated dictionaries (bypassing strict FBIP).
  * **Mode B: Nominal Records (`KType`)**: Pre-declared structs (e.g., `type Point = { x: Int }`). These compile to static C structs with known byte offsets, enabling true zero-cost, in-place FBIP mutations.
  * **Unified Lenses:** Both modes share the same native lens syntax (`record.{ x := 1 }`) and AST node (`RecUpdate`). The current checker fully supports structural mode and keeps nominal mode as planned follow-up work.
* **Universal Pattern Matching (Destructuring & Exhaustiveness):** Binding sites across the language (`let`, function parameters, `case`) support deep destructuring of Algebraic Data Types, records, and lists. The compiler includes a dedicated Pattern Compilation phase to enforce strict **exhaustiveness and reachability checking**. Unhandled cases (e.g., matching a list of length 3 but omitting the empty or arbitrary-length cases) or unreachable redundant patterns will result in hard compile-time errors, ensuring absolute structural safety before C-generation.
* **Effect System (Lexical Capability Passing):** Lithic avoids the heavy runtime overhead and CPS-transformations of true algebraic continuations. Instead, it utilizes a Bluefin-style capability-passing model. Effects are tracked in the type system via row polymorphism (e.g., `Int -> { io, net } Int`) and compiled to standard C as implicit dictionary pointers. This guarantees native C stack performance and trivial FFI integration while maintaining pure functional control flow.
* **Pattern Guards:** Planned guard handling keeps explicit `|` guard lines (Haskell-style) with ordered fall-through semantics (`| guard => expr`) and lowers through the decision-tree/match compilation pipeline.
* **Function Equations (Planned Surface Form):** Lithic will support grouped multi-clause function equations with optional guards and pattern-headed arguments; elaboration will lower these declarations to a unified lambda-plus-match internal representation.

### Design Decision: Variant Payloads
Variants in Lithic unconditionally require a payload. To represent nullary constructors (e.g., `None`), pass the empty record `{} ` as the payload: `None {}`. The corresponding pattern match is `None {} => ...`.

## 3. Development Methodology
Lithic is developed in isolated **Phases**. A phase represents a single, complete vertical slice of a compiler feature. 
The standard lifecycle of a Phase is:
1.  **Branch:** Create a `feat/` branch.
2.  **Enhance:** Update AST, Parser, Typechecker, or Evaluator.
3.  **Check Correctness:** Write positive and negative `.lithic` golden tests.
4.  **Review & Merge:** Lock in the baseline.

### Anti-Drift Spec Discipline (Active)
To prevent semantic drift during rapid feature work, `docs/language-spec.md` is now the normative living core spec for implemented syntax and static semantics.

Required in any behavior-changing parser/typechecker change:
1. Update `docs/language-spec.md` in the same change.
2. Update `README.md` user-facing examples/contracts if external behavior changed.
3. Update fixtures/golden snapshots if observable output changed.
4. Keep this roadmap aligned when phase scope or semantic commitments shift.

### Documentation Program (Book Track)
Book-track documentation lives alongside implementation and is continuously updated during phase work.

Suggested chapter map (living outline):
1. Compiler architecture and phase boundaries in Lithic.
2. Lexer and Pratt parser internals.
3. Bidirectional typing, subsumption, and unification internals.
4. Row polymorphism, records/variants, and lens update typing.
5. Pattern matrix coverage algorithms (exhaustiveness/redundancy/usefulness).
6. Effectful compiler engineering in Haskell with Bluefin.
7. Evaluator semantics and formal rule design.
8. Backend lowering strategy (C now, LLVM-oriented path later).
9. Tooling and ergonomics (REPL/TUI/LSP-facing diagnostics discipline).

Documentation quality bar:
1. Explain both mechanism (how) and rationale (why).
2. Include concrete implementation references and pseudocode/rule sketches where appropriate.
3. Distinguish normative implemented behavior from planned/future behavior.
4. Keep examples synchronized with current language syntax and diagnostics.

Documentation cadence policy:
1. Per feature PR: include at least one documentation delta in either `docs/language-spec.md` or a chapter-oriented `docs/` companion file when behavior, algorithm contracts, or architecture understanding changes.
2. Per phase milestone: produce or substantially revise one chapter-level document section capturing design trade-offs and implementation details.
3. Weekly (or every 5-10 merged PRs, whichever comes first): run an editorial consolidation pass to merge scattered notes into coherent chapter narrative.
4. Per release tag: ensure chapter index/progress markers are updated and link to newly completed sections.

### PR Checklist (Semantic Changes)
Use this checklist in PR descriptions whenever lexer/parser/typechecker behavior changes.

- [ ] Updated `docs/language-spec.md` in the same change.
- [ ] Updated user-facing behavior notes/examples in `README.md` if externally visible behavior changed.
- [ ] Added or updated `test/fixtures/*.lithic` and `test/golden/*.golden` coverage for the semantic delta.
- [ ] Confirmed diagnostics preserve precise spans for new/changed failure paths.
- [ ] Updated roadmap/docs guidance (`docs/project-plan.md` and/or `.github/copilot-instructions.md`) if phase scope or grammar commitments changed.
- [ ] Added a `CHANGELOG.md` entry summarizing the semantic/documentation delta.

## 4. Phase Tracker & Roadmap

### ✅ Phase 1: The Monomorphic Core
* Scaffolded the project structure, Bluefin effects, hand-rolled lexer, and Pratt parser.
* Implemented `infer` and `check` for simple Lambda Calculus (`TInt`, `TArrow`).

### ✅ Phase 2: Stateful Unification
* Transitioned to stateful typechecking.
* Introduced `TMeta` (meta-variables), shallow `force`, and deep `zonk` resolution.

### ✅ Phase 3: Let-Polymorphism (Hindley-Milner)
* Introduced `TForall` and Let-generalization.
* Implemented `instantiate` (generating fresh metas) and `generalize` (closing over free variables).
* Locked in the testing harness (`tasty-golden`).

### ✅ Phase 4: Rank-2 Skolemization
* Extended bidirectional engine to support functions taking polymorphic arguments.
* Introduced `TSkolem` (rigid constants).
* Upgraded the `subsumes` bridge to implement Skolemization on expected types and Instantiation on inferred types.

### ✅ Phase 5: Row Polymorphism 
* **Objective:** Introduce structural records and native lens operations.
* **Tasks:**
  * [x] Add `TRowEmpty` and `TRowExtend` to AST.
  * [x] Implement row-shifting logic in `unify`.
  * [x] Implement term-level record expressions (`RecEmpty`, `RecExtend`, `RecSelect`).
  * [x] Add `UpdateOp` and `PathSegment` to AST for `RecUpdate`.
  * [x] Add lexer/parser support for core lens operators (`:=`, `%=`) and dotted field paths.
  * [x] Implement structural-record typechecking logic for `RecUpdate`.

### ✅ Phase 6: Variants, Literals & Basic Pattern Matching
* **Objective:** Expand the AST and bidirectional engine to support structural variants, a full primitive suite, and basic pattern destructuring.
* **Tasks:**
  * [x] Implement comprehensive `Literal` suite (Int, Float, String, Bool).
  * [x] Support prefix negation and infix subtraction with proper Pratt precedence.
  * [x] Introduce `Pattern` AST (Wildcard, Var, Literal, Variant, Record).
  * [x] Implement `checkPattern` for bidirectional environment extension.
  * [x] Wire `TVariant` wrapper into the structural row unification engine.

### Numeric Operator Typing Policy (Current + Planned)
* **Current implementation scope (intentional):**
  * Unary minus and subtraction are currently modeled as primitive numeric operators over `Int` and `Float`.
  * Unknown numeric meta-variables are constrained from surrounding concrete numeric operands when possible.
  * Fully unresolved numeric expressions (for example meta/meta arithmetic) produce explicit ambiguity diagnostics rather than silent defaulting.
* **Planned architectural direction (before broad numeric expansion):**
  * Keep the current `Int`/`Float` fast path for early compiler phases.
  * Introduce a constraint-driven numeric capability layer so operator typing is not hard-coded to a fixed primitive set.
  * Route arithmetic through that capability layer so future numeric types are uniformly supported.
  * Keep pattern-coverage semantics independent from operator capability resolution: literal-pattern usefulness uses exact observed head matching plus wildcard/default reasoning, not capability-driven domain enumeration.
  * Defer numeric defaulting policy until the constraint layer exists; avoid ad-hoc implicit widening/defaulting in the checker.
* **Extensibility consequence:**
  * Adding new numeric behavior through libraries alone is not sufficient today; compiler-level operator typing must move to capability constraints to support library-extensible numerics.

### 🚧 Phase 7: Pattern Exhaustiveness & Reachability (CURRENT)
* **Objective:** Implement Luc Maranget's Pattern Matrix decision tree algorithm to make non-exhaustive patterns and unreachable code hard compiler errors.
* **Tasks:**
  * [x] Scaffold `Compiler.PatternMatch` module.
  * [x] Implement Matrix and Occurrence data structures (interim slice).
  * [x] Implement `specialize` and `default` matrix decomposition functions.
  * [x] Wire exhaustiveness checking into the bidirectional `Case` evaluation.
  * [x] Add regression coverage for open-variant row behavior (`open-variant-redundancy`).
  * [x] Upgrade `docs/language-spec.md` with interim pattern-coverage and redundancy boundary notes.
  * [x] Complete open-universe usefulness/redundancy algorithm so unreachable-branch checks are enforced beyond finite constructor universes.
    - Policy detail: for `Int`/`Float`/`String` and open variant rows, rely on exact literal/constructor head usefulness plus default/wildcard decomposition rather than attempting total value-space enumeration.
  * [x] Promote Phase-7 addendum from provisional to fully normative once open-universe redundancy handling stabilizes.

### 📅 Phase 8: Evaluation Semantics (Interpreter)
* **Objective:** Build an internal evaluator to actually execute Lithic code.
* **Decision record (locked):**
  * [x] Baseline evaluation strategy: strict.
  * [x] Baseline formal/operational strategy: small-step.
  * [x] Normative semantics remain small-step regardless of implementation strategy.
  * [x] Preferred implementation model: CEK-style machine when schedule allows.
  * [x] Primary rationale: educational depth and formal rigor over delivery speed.
* **Tasks:**
  * [x] Specify small-step transition judgments for the initial evaluator core.
    - Initial formal artifact: `docs/evaluator-small-step.md`.
  * [x] Specify a minimal Core AST for Phase-8-evaluable terms (documentation first).
    - Scope: literals, lambda/app, let, case, variants, structural records, selection.
    - Excludes: full macro system, declaration groups, and non-essential syntactic sugar.
    - Module boundary decision: keep surface AST in `Compiler.AST`; place Core in `Compiler.AST.Core`.
  * [x] Specify the initial Surface-to-Core desugaring/elaboration boundary.
    - Include ordering constraints for future macro expansion: parse -> expand -> desugar/elaborate -> evaluate.
  * [x] Implement the minimal Core AST in the compiler.
    - Checkpoint A: add `Compiler.AST.Core` module with Phase 8 constructors only.
  * [x] Implement the initial Surface-to-Core desugaring/elaboration pass for the Phase 8 subset.
    - Checkpoint B: add `Compiler.Elaborator` skeleton.
    - Checkpoint C: elaborate var/lit/lam/app/let/case/variant/record/select + annotation erasure.
    - Checkpoint D: keep `RecUpdate` as explicit out-of-scope elaboration error for initial pass.
  * [x] Wire elaboration into the golden test pipeline.
    - Goal: make the snapshot harness exercise Surface -> Core lowering before evaluator work begins.
  * [x] Implement strict evaluator baseline over Core terms.
    - Preferred: CEK-style small-step machine.
    - Interim implementation: big-step closure evaluator over Core (strict), with normative small-step spec retained in docs.
  * [x] Document the value model and reduction contexts used by the evaluator.
    - Captured in `docs/evaluator-small-step.md`.
  * [x] Validate evaluator behavior with focused fixtures/golden outputs.
    - Golden pipeline now renders `[Core]` and `[Val]` outputs, and evaluator unit coverage includes var/lit/lam/app/let/case/variant/record/select behaviors.
    - Golden harness upgraded in Phase 9D to use `parseTopLevel` as its entry point, rendering `[Decl] <show decl>` for top-level declaration inputs alongside the existing expression pipeline outputs.
  * ~~Add a follow-up note on optional future lazy experimentation~~ — **Removed:** Lithic is strictly evaluated; lazy evaluation is not a planned direction.

### Formalization Checkpoint (Post-Phase 7)
After Phase 7 reaches implementation stability, produce a fuller language specification pass that expands beyond the current living core spec:
1. Formal pattern matrix coverage/reachability rules.
2. Surface-to-Core elaboration relation and boundaries.
3. Clear split between normative implemented semantics and planned semantics.

Status: Completed in 0.9.3.0 documentation milestone.

### 📅 Phase 9: Top-Level Bindings & Rich REPL Experience
* **Objective:** Introduce top-level declaration forms, continue improving the interactive environment, and finalize front-end ergonomic parsing features.
* **Top-level binding design notes:**
  * The current surface syntax only supports expressions — all binding is local via `let`. Top-level forms are required before Lithic programs become composable beyond a single expression.
  * Top-level bindings are declaration-level: `def f x = body` or `let f = \x => body` at module scope, distinct from expression-level `let`.
  * REPL and batch compiler should be separate executables. The compiler library must expose a frontend-agnostic API, and compiler modules must not depend on REPL/TUI modules.
  * Elaboration must handle declaration groups: mutually recursive definitions within a group, ordering constraints, and separate Core lowering for declaration forms vs. expression forms.
  * Top-level bindings must thread through the evaluator and REPL: the REPL should accumulate a top-level environment across inputs rather than resetting per expression.
  * Type signatures at declaration scope (e.g., `f : a -> a`) are a parallel addition; initial implementation may defer to inferred types.
  * Layout preprocessing also enables grouped local `let` clauses with a single trailing `in` (for example: `let a = ...; b = ... in body` via virtual separators). This should lower to ordered nested `Let` nodes while preserving source spans.
* **Status (May 2026):**
  * Phase 9A parser foundation is in place: lexer keyword support for `def`, top-level AST carrier types, `parseTopLevel`, and parser declaration baseline tests (including a passing `def x = 1` case).
  * Phase 9B adds signature-only top-level parsing (`name : Type`) in `parseTopLevel` with test coverage.
  * Phase 9B.2 adds same-name signature+equation pairing (`name : Type` followed by `name = expr`) in `parseTopLevel`.
  * Phase 9D adds single-clause equation-style top-level declaration parsing (`f p1 ... pn = expr`) lowered through parser-produced lambdas.
  * Phase 9E (implemented slice): adds a bounded layout preprocessing pass (`runLayout`) between the lexer and the parser. The current implementation powers layout-delimited `case` branches and grouped local `let` clauses, while declaration-group features remain follow-up work.
  * Remaining work after 9E: multi-clause/guard grouping (9E cont.), Core/Elaborator declaration-group plumbing (9F), REPL environment persistence (9G).
* **Tasks:**
  * [ ] Add syntax highlighting, stronger multi-line editing ergonomics, better history/navigation behavior, and tighter evaluator-aware feedback.
  * [x] Add parser support for initial top-level `def` declaration form (`def p = expr`) and top-level parse routing.
  * [x] Extend parser support to minimal top-level binding declarations with optional type signatures (`def`, signature-only, and same-name signature+equation pairing).
  * [ ] Extend parser support to full declaration grouping semantics (`def`/`let` at module scope, multi-clause equations, and grouped signature association).
  * [x] Add parser support for single-clause equation-style declarations (`f p1 ... pn = expr`) lowered to declaration-level lambda form.
  * [x] Decision (Phase 9E): introduce bounded layout-rule preprocessing pass before implementing multi-clause grouping. Rationale: multi-clause parsing requires distinguishing clause heads from Pratt application continuations; a column-check hack inside `peekPrecedence` was evaluated and rejected in favour of a proper `runLayout :: [Token] -> [Token]` pass that inserts virtual `TokVirtSemi` and `TokVirtRBrace` tokens. This keeps the expression parser stateless w.r.t. indentation and unblocks `where` blocks at no additional cost.
  * [x] Decision (Phase 9E): retire `|` as explicit case-branch prefix. Branches will be layout-delimited under `of`; `TokVirtSemi` separates them. `|` is kept reserved to error clearly on old input.
  * [x] Implement `runLayout` preprocessing pass (Phase 9E): insert `TokVirtSemi` / `TokVirtRBrace` virtual tokens; wire between `runLexer` and `parseTopLevel`/`runParser`. Current layout triggers are after `of` and `let`.
  * [x] Update `parseTopLevel` and `parseCase` to use `TokVirtSemi` as separator; remove parser-side branch-column tracking and stop consuming `|` tokens for case branches.
  * [x] Update all golden fixtures and test inputs that use `| pat => expr` syntax.
  * [ ] Add parser support for multi-clause function equations using virtual token separators.
  * [ ] Add parser support for local function-equation syntax with shared-name clauses.
  * [x] Add parser support for grouped local `let` clauses with one trailing `in`, delimited by layout-inserted `TokVirtSemi` separators.
  * [ ] Add parser support for `where` blocks on declarations/equations using layout delimiters (`TokVirtSemi` / `TokVirtRBrace`) and scoped association to the owning declaration group.
  * [ ] Define and implement lowering for declaration/equation `where` blocks to internal local-binding structure with source-span preservation.
  * [ ] Add guard syntax on function equations (Haskell-style guard lists) and lower to decision trees.
  * [ ] Add pattern-headed function equations and desugar to `case` while preserving source spans.
  * [ ] Extend the REPL evaluator loop to maintain a persistent top-level environment across submissions.
  * [ ] Extend Core AST and Elaborator to represent top-level declaration groups.
  * [ ] **Future Lexical/Parsing Enhancements:**
    * [ ] Support floats without an integer part (e.g., `.14159`).
    * [ ] Support scientific notation (e.g., `1e-5`).
    * [ ] Support multi-line strings.
    * [ ] Support Character literals (e.g., `'a'`).

  #### Phase 9E Implementation Note: Grouped Local `let` Layout Pitfalls

  Grouped local `let` support surfaced a subtle layout hazard around same-line clause heads (`let x = ...`). The initial rule opened a let-layout block after every `TokLet`, which over-opened in single-clause forms and caused spurious `TokVirtRBrace` insertions inside multiline RHS expressions.

  Observed failure mode:
  * Inputs such as `let f = \r => ... in ...` or `let x =` followed by multiline RHS were incorrectly interpreted as beginning a grouped-clause block, producing `TokVirtRBrace` where expression tokens were expected.

  Mitigation now implemented:
  * `TokLet` layout opening is gated by sibling-clause detection rather than unconditional opening.
  * The detector requires evidence of a later same-indentation clause head with an assignment, and ignores non-head tokens on continuation lines.
  * Dedicated regression coverage now includes grouped local let, multiline first-clause RHS with a sibling clause, and multiline single-clause let forms.

  Follow-up caution:
  * Reuse the same gating approach when extending layout to declaration groups and `where` blocks to avoid repeating the over-open/early-close token regression.

### 📅 Phase 9.5: List / Sequence Type & `::` Cons Syntax
* **Objective:** Introduce a built-in list/sequence type with `::` as the cons operator at both expression and pattern level.
* **Design notes:**
  * Lithic uses `:` for type annotations (e.g., `expr : Type`), so `:` is not available for cons. `::` is chosen as the surface cons operator, analogous to Haskell's `:`, to avoid ambiguity.
  * `::` is a right-associative infix operator at the expression level: `1 :: 2 :: []`.
  * At the pattern level, `x :: xs` destructs head and tail; `[]` matches the empty list.
  * Exhaustiveness analysis must account for the `::` / `[]` constructor pair as a two-constructor closed universe (no open variant row behavior).
  * The list type may initially be built in as `List a` with special parser support rather than derived from general data declarations.
  * `[a, b, c]` list literal syntax should desugar to `a :: b :: c :: []` during elaboration.
  * Long-term: when a general algebraic data declaration form is available (Phase 10+), the list type can be defined in a standard library file rather than hard-coded in the compiler.
* **Tasks:**
  * [ ] Add `::` as a right-associative infix cons operator in the lexer and parser.
  * [ ] Add `[]` as the empty list literal.
  * [ ] Add `[a, b, c]` list literal sugar and desugar to `::` chains in the elaborator.
  * [ ] Add `List a` type constructor and `TList` AST node (or equivalent row encoding).
  * [ ] Extend `checkPattern` and pattern matrix to handle `::` / `[]` as a closed two-constructor universe.
  * [ ] Extend the evaluator with `VList` or a cons-cell value representation.
  * [ ] Add golden fixtures covering list construction, deconstruction, and exhaustiveness errors.

### 📅 Phase 9.6: Tuples & Tuple Sections
* **Objective:** Introduce tuple syntax as first-class surface sugar over the existing row polymorphism infrastructure, gaining n-ary flat product types without Haskell-style per-arity boilerplate.
* **Design notes:**
  * **Representation:** Tuples are anonymous records with integer positional labels (`0`, `1`, `2`, …). `(Int, String)` is syntactic sugar for `{ 0 : Int, 1 : String }` at the type level, and `(e1, e2)` desugars to `{ 0 = e1, 1 = e2 }` at the term level. The existing row unification engine handles them with zero new machinery.
  * The comma inside `( … )` is a purely structural lexical separator — it has no independent operator meaning and does not conflict with any other use of comma in the grammar.
  * **Unit:** `()` is the zero-tuple, sugar for the empty record `{}`. `TUnit` is an alias for the empty row type. The empty record already exists in the type system; `()` adds only a surface spelling.
  * **Pattern matching:** `(x, y)` in a pattern position desugars to `{ 0 = x, 1 = y }` — handled entirely by the existing record pattern machinery.
  * **Exhaustiveness:** Tuples are single-constructor (they are records); the existing record exhaustiveness path applies unchanged.
  * **Tuple sections:** `(, e)` is sugar for a record extension expression with a hole at position `0`: effectively `\x => { 0 = x, 1 = e }`. Holes are filled left-to-right by freshly introduced lambda parameters. This is record-update/extension sugar, not a separate lambda-introduction rule. Multiple holes introduce one parameter each, still left-to-right.
  * **Performance:** Because tuples lower to row-typed anonymous records, the C backend can lay them out as flat structs by offset rather than heap-allocated dictionaries — identical to the nominal record FBIP path. No per-arity primitive type or hardcoded typeclass instances are required.
  * **No new Core nodes needed:** `CTuple` / `VTuple` are not required. Surface tuple syntax elaborates entirely to existing `CRecord` / `VRecord` with integer keys.
* **Tasks:**
  * [ ] Add `()` / `(e1, e2, …)` expression syntax to the lexer/parser, desugaring to record literals with integer field labels.
  * [ ] Add `(T1, T2, …)` type syntax, desugaring to row types with integer field labels. Add `TUnit` as an alias for the empty row type.
  * [ ] Add `(p1, p2, …)` pattern syntax, desugaring to record patterns with integer field labels.
  * [ ] Add tuple section parsing: holes (`,` without an expression) in a tuple literal introduce lambda parameters. Desugar in the elaborator to record-extension lambdas.
  * [ ] Confirm row unifier and pattern exhaustiveness checker handle integer-labelled rows correctly (no new logic expected, but add regression fixtures).
  * [ ] Add golden fixtures for tuple construction, deconstruction, unit, and tuple sections.

### 📅 Phase 10: Existentials & GADTs
* **Objective:** Introduce Existential quantification (`exists a.`) and Generalized ADT semantics, expanding Lithic into rich data encapsulation.

### 📅 Phase 11: Module System
* **Objective:** Support multi-file projects, imports, exports, and namespace resolution.

### Planned Surface Syntax Addendum: Function Clauses and Guards
The following user-facing forms are target surface syntax for future phases and are roadmap commitments (not implemented in the current parser/runtime):

```haskell
isOdd n
  | n % 2 == 0 => False
  | otherwise => True
```

```haskell
isEmpty :: [a] -> Bool
isEmpty [] = True
isEmpty _ = False
```

Design constraints for implementation:
1. Multi-clause equations for a function name must be grouped and typechecked as one declaration unit.
2. Guarded clauses must preserve ordered fall-through semantics.
3. Pattern-headed equations must lower to a single internal match structure that shares exhaustiveness/redundancy analysis with `case`.
4. Diagnostics must point to clause-local spans (pattern head, guard, or RHS), not only declaration-level spans.

### 📅 Phase 12: Numeric Capabilities & Operator Overloading
* **Objective:** Generalize arithmetic from fixed primitive checks to a constraint-driven numeric capability model.
* **Tasks:**
  * [ ] Introduce capability constraints for arithmetic operators (initially unary minus and subtraction).
  * [ ] Add a trait/class-style predicate model at the type level (for example numeric capability predicates) as first-class constraints in type signatures.
  * [ ] Define evidence passing strategy (dictionary-style elaboration target) so constraints can be resolved statically and lowered cleanly.
  * [ ] Specify coherence rules: overlap policy, orphan policy, and deterministic instance resolution boundaries.
  * [ ] Support a coherent numeric hierarchy beyond `Int` and `Float` (for example fixed-width ints, unsigned ints, and decimal/rational families).
  * [ ] Define and implement explicit ambiguity/defaulting rules for unresolved numeric expressions.
  * [ ] Ensure capability resolution works across module boundaries so library-defined numeric types can participate in arithmetic.

#### Constraint-Layer Rollout Notes
* **Surface syntax:** Continue reserving `=>` for type-level contexts so constrained signatures can be introduced without term-level syntax churn.
* **First target domain:** Numeric operators (`-` unary and binary subtraction), then generalize the same mechanism to other capabilities.
* **Future capability domains:** Equality/ordering, pretty-printing/serialization, collection-like abstractions, and effect capabilities.
* **Design principle:** No implicit magic widening; defaults must be explicit and documented once the constraint solver exists.

### 📅 Phase 13: Linear Types & FBIP
* **Objective:** Upgrade the `Env` Reader to a consumable State/Resource tracker to enforce exact-once usage for deterministic memory management and safe in-place mutation.

### 📅 Phase 14: C Code Generation & FFI
* **Objective:** Lower the fully zonked, typed AST into standard C, proving the zero-runtime concept.
* **Tasks:** Implement a bidirectional Foreign Function Interface (FFI) to call C libraries directly from Lithic.

### 📅 Phase 15: IO Effect Capability Layer
* **Objective:** Surface Lithic's Bluefin-style capability-passing effect model to user programs so effectful IO is expressible without a monadic wrapper.
* **Design notes:**
  * Lithic does not use an `IO` monad. Instead, effects are tracked via row polymorphism in the type system: `read :: { io } String` means `read` requires the `io` capability in scope.
  * Capability handles are passed explicitly at call sites or threaded implicitly through row-polymorphic function signatures; the compiler lowers them to standard C dictionary pointers.
  * The REPL and top-level `main` entry point are implicitly given the full capability set; programmer-defined functions must declare their required capabilities explicitly.
  * Standard capabilities planned for initial slice: `io` (console read/write), `file` (filesystem), `net` (network sockets), `rand` (random number generation).
  * Pure functions (no capability row requirements) compile identically to today's pure Core expressions.
  * This is architecturally compatible with Phase 13 (linear types): a capability handle could carry linearity to prevent aliasing of stateful resources.
* **Tasks:**
  * [ ] Define capability row kind and integrate it with the existing row polymorphism infrastructure.
  * [ ] Add `{ cap1, cap2 } ReturnType` surface syntax for capability-annotated function types.
  * [ ] Implement capability checking in the bidirectional typechecker (capability rows unify like record rows).
  * [ ] Add primitive IO capability operations (`print`, `readLine`, etc.) as built-in declarations with `io` capability requirements.
  * [ ] Thread the REPL's top-level capability environment through the evaluator.
  * [ ] Add golden fixtures for capability-annotated function types and simple IO programs.

### 📅 Phase 16: Tooling Ecosystem (LSP & Debugger)
* **Objective:** Elevate Lithic to a production-ready language with a first-class VSCode developer experience.
* **Incremental Compilation Strategy (LSP-critical):**
  * LSP features require error-tolerant whole-program semantic analysis, not fail-fast compilation.
  * Do not run full backend code generation on each edit; run frontend + semantic phases incrementally and reuse cached artifacts.
  * Preserve partial artifacts under diagnostics so hover/definition/references continue working in unaffected regions.
* **Tasks:**
  * [ ] Build a Language Server Protocol (LSP) server implementation, leveraging the `Span` tracking carried through all compiler phases for precise hover/go-to-definition/diagnostics.
  * [ ] Implement the LSP `textDocument/diagnostic` push model so type errors appear inline in VSCode without requiring a manual build step.
  * [ ] Implement hover (`textDocument/hover`) to surface inferred types and kind information at the cursor position.
  * [ ] Implement go-to-definition and find-references for top-level and local bindings.
  * [ ] Implement semantic syntax highlighting via LSP `textDocument/semanticTokens`.
  * [ ] Introduce diagnostic accumulation sinks in parser/typechecker/elaborator paths so multiple deterministic diagnostics are emitted per edit when practical.
  * [ ] Add parser recovery nodes/spans for malformed regions so analysis can continue beyond local syntax failures.
  * [ ] Add an incremental dependency graph and invalidation strategy (changed module plus transitive dependents only).
  * [ ] Cache per-module frontend/semantic artifacts (tokens/layout, surface AST, typed interface summary, and elaborated/core snapshot where available) keyed by content hash.
  * [ ] Define cache coherence contracts: when signatures/type environments change, invalidate dependent typed artifacts while preserving unaffected modules.
  * [ ] Add LSP-focused performance regression fixtures (cold open, warm edit, cross-file rename, and diagnostic fan-out scenarios).
  * [ ] Introduce debugger adapter protocol (DAP) support to enable VSCode breakpoint, step, and watch variable features:
    * The evaluator must carry a structured execution trace (small-step transition log) that the DAP adapter can expose as step events.
    * Breakpoints map to `Span`-tagged Core nodes; the evaluator checks the active breakpoint set before each reduction step.
    * Watch variables are resolved against the current `Env` (evaluator environment) at each pause point, formatted using the same pretty-printer used by the REPL.
    * Step-in, step-over, and step-out correspond to single-step, skip-subterm, and return-to-parent strategies in the small-step machine.
  * [ ] Ensure the DAP and LSP servers are structurally isolated from compiler stages (no Brick/TUI imports in the server layer).
*(Note for LLM: The workspace is fully loaded upon initialization. Do not ask the user to provide specific files like `AST.hs` or `TypeChecker.hs`, as they are already available in the uploaded context.)*

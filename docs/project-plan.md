# Lithic Project Plan & Architecture Record

## 1. Project Vision
**Lithic** is an experimental, high-performance, purely functional programming language. 
* **Target:** Compiles directly to standard C without a garbage collector or heavy runtime, featuring bidirectional C FFI.
* **Paradigms:** Pure functional, but capable of C-level performance via Functional But In-Place (FBIP) mutations and linear types.
* **Evaluation:** To be determined via experimentation (evaluating strict vs. lazy, and small-step vs. big-step semantics).
* **Type System:** Advanced structural typing featuring Rank-2 Polymorphism, Row Polymorphism, Existential Types, and Bidirectional Typechecking.
* **Developer Experience:** A rich interactive REPL, an integrated LSP server, and native debugging capabilities.

## 2. Core Architectural Decisions
These decisions are locked in and should guide all future implementation phases:
* **Compiler Implementation:** Haskell (targeting GHC 9.14.1+ for LTS stability and zero-cost abstraction optimization).
* **Effect Tracking:** The `Bluefin` effect system. We strictly avoid monad transformer stacks (MTL) in favor of explicit, localized effect handles (e.g., `Reader Env`, `State TCState`, `Exception TypeError`).
* **Lenses:** `microlens` and `generic-lens` for lightweight, boilerplate-free state updates.
* **Parsing:** A hand-rolled lexer capturing precise `SourceSpan` data, feeding into a Pratt Parser (Top-Down Operator Precedence) for elegant, extensible precedence handling.
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
* **Pattern Guards:** Planned guard handling uses ordered guard evaluation with explicit fall-through semantics (`| guard => expr`) and lowers through the decision-tree/match compilation pipeline.
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
  * [ ] Complete open-universe usefulness/redundancy algorithm so unreachable-branch checks are enforced beyond finite constructor universes.
  * [ ] Promote Phase-7 addendum from provisional to fully normative once open-universe redundancy handling stabilizes.

### 📅 Phase 8: Evaluation Semantics (Interpreter)
* **Objective:** Build an internal evaluator to actually execute Lithic code.
* **Tasks:** Experiment with and implement either strict or lazy semantics, evaluating the trade-offs of a small-step vs. big-step evaluator.

### Formalization Checkpoint (Post-Phase 7)
After Phase 7 reaches implementation stability, produce a fuller language specification pass that expands beyond the current living core spec:
1. Formal pattern matrix coverage/reachability rules.
2. Surface-to-Core elaboration relation and boundaries.
3. Clear split between normative implemented semantics and planned semantics.

### 📅 Phase 9: Rich REPL Experience & Lexical Enhancements
* **Objective:** Continue improving the interactive environment and finalize front-end ergonomic parsing features.
* **Tasks:**
  * [ ] Add syntax highlighting, stronger multi-line editing ergonomics, better history/navigation behavior, and tighter evaluator-aware feedback.
  * [ ] Add parser support for top-level and local function-equation syntax with shared-name clauses.
  * [ ] Add guard syntax on function equations (Haskell-style guard lists) and lower to decision trees.
  * [ ] Add pattern-headed function equations and desugar to `case` while preserving source spans.
  * [ ] **Future Lexical/Parsing Enhancements:**
    * [ ] Support floats without an integer part (e.g., `.14159`).
    * [ ] Support scientific notation (e.g., `1e-5`).
    * [ ] Support multi-line strings.
    * [ ] Support Character literals (e.g., `'a'`).

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

### 📅 Phase 15: Tooling Ecosystem (LSP & Debugger)
* **Objective:** Elevate Lithic to a production-ready language.
* **Tasks:** Build a Language Server Protocol (LSP) implementation for VSCode (leveraging our `SourceSpan` tracking) and introduce debugging hooks.
*(Note for LLM: The workspace is fully loaded upon initialization. Do not ask the user to provide specific files like `AST.hs` or `TypeChecker.hs`, as they are already available in the uploaded context.)*

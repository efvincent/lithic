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
* **Pattern Guards:** The pattern matching engine supports guards (`| pattern if cond => expr`), requiring the desugaring phase to support backtracking decision trees to ensure fall-through semantics when guards fail.  

## 3. Development Methodology
Lithic is developed in isolated **Phases**. A phase represents a single, complete vertical slice of a compiler feature. 
The standard lifecycle of a Phase is:
1.  **Branch:** Create a `feat/` branch.
2.  **Enhance:** Update AST, Parser, Typechecker, or Evaluator.
3.  **Check Correctness:** Write positive and negative `.lithic` golden tests.
4.  **Review & Merge:** Lock in the baseline.

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

### 🚧 Phase 5: Row Polymorphism (CURRENT)
* **Objective:** Introduce structural records, variants, and native lens operations.
* **Tasks:** 
  * [x] Add `TRowEmpty` and `TRowExtend` to AST.
  * [x] Implement row-shifting logic in `unify`.
  * [x] Implement term-level record expressions (`RecEmpty`, `RecExtend`, `RecSelect`).
  * [x] Add `UpdateOp` and `PathSegment` to AST for `RecUpdate`.
  * [x] Add lexer/parser support for core lens operators (`:=`, `%=`) and dotted field paths.
  * [x] Implement structural-record typechecking logic for `RecUpdate`.
  * [ ] Extend lens path parsing to index/prism segments.
  * [ ] Implement nominal-record field lookup and update routing.

### 📅 Phase 6: Data Types, Pattern Matching & Existentials
* **Objective:** Introduce ADTs (or GADTs), `case` expressions, and Existential quantification (`exists a.`). This expands Lithic beyond primitives into rich data modeling and encapsulation.

### 📅 Phase 7: Evaluation Semantics (Interpreter)
* **Objective:** Build an internal evaluator to actually execute Lithic code.
* **Tasks:** Experiment with and implement either strict or lazy semantics, evaluating the trade-offs of a small-step vs. big-step evaluator.

### 📅 Phase 8: Rich REPL Experience
* **Objective:** Continue improving the existing Brick-based terminal UI into a richer interactive environment.
* **Tasks:** Add syntax highlighting, stronger multi-line editing ergonomics, better history/navigation behavior, and tighter evaluator-aware feedback.

### 📅 Phase 9: Module System
* **Objective:** Support multi-file projects, imports, exports, and namespace resolution.

### 📅 Phase 10: Linear Types & FBIP
* **Objective:** Upgrade the `Env` Reader to a consumable State/Resource tracker to enforce exact-once usage for deterministic memory management and safe in-place mutation.

### 📅 Phase 11: C Code Generation & FFI
* **Objective:** Lower the fully zonked, typed AST into standard C, proving the zero-runtime concept.
* **Tasks:** Implement a bidirectional Foreign Function Interface (FFI) to call C libraries directly from Lithic.

### 📅 Phase 12: Tooling Ecosystem (LSP & Debugger)
* **Objective:** Elevate Lithic to a production-ready language.
* **Tasks:** Build a Language Server Protocol (LSP) implementation for VSCode (leveraging our `SourceSpan` tracking) and introduce debugging hooks.

## 5. Handover Protocol (New Chat Initialization)
When starting a new LLM session, the user will upload the current state of the entire project repository. The following must be provided in the initial prompt:
1.  A specific declaration of the current Phase and the immediate next step.

*(Note for LLM: The workspace is fully loaded upon initialization. Do not ask the user to provide specific files like `AST.hs` or `TypeChecker.hs`, as they are already available in the uploaded context.)*
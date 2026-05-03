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
* **Objective:** Introduce structural records and variants.
* **Tasks:** Extend AST with `TRowEmpty` and `TRowExtend`. Implement row-shifting logic in the `unify` function to allow order-independent structural matching.

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
When starting a new LLM session, the following must be provided:
1.  This `docs/project-plan.md` file.
2.  The latest `src/Compiler/AST.hs` and `src/Compiler/TypeChecker.hs`.
3.  A specific declaration of the Phase and the immediate next step.
# GitHub Copilot Instructions: Lithic Compiler

## Project Context and Goals

- Lithic is a custom functional programming language compiler and REPL built in Haskell.
- Treat the project as a modular, theoretical testbed for type theory, compiler architecture, and language design.
- Optimize for architectural correctness and long-term extensibility over short-term convenience.
- Main library modules live under `src/Compiler/`.
- Executable entrypoint is `app/Main.hs`.
- Current executable path launches a Brick TUI on the main thread and runs the REPL/compiler loop on a background green thread.

## Core Capabilities and Architecture

Keep phases highly decoupled and preserve clear subsystem boundaries.

1. Lexical Analysis (Lexer):
   - Implement a maximal munch strategy.
   - Track precise source locations with `SourceSpan` on all tokens for diagnostics and future LSP-facing workflows.
   - Keep the lexer pure at the public entry point (`runLexer`).

2. Parsing (Pratt Parser) — **COMPLETED**:
   - Top-down operator precedence (Pratt) with explicit NUD/LED (null/left denotation) structure.
   - Precedence model: `PrecLowest` (0), `PrecAnn` (5), `PrecApp` (30).
   - Juxtaposition is implicit application (e.g., `f x` parses as `App f x`).
   - Let-binding RHS parses with `PrecLowest` to capture full expressions including type annotations.
   - Lambda bodies parse with `PrecLowest` to allow all valid term-level constructs.
   - Type annotations in expression position via `:` operator (e.g., `x : Int`, `\p : a -> b => p`).
   - Application is right-associative at LED; parser uses pushback pattern to avoid left-recursion.
   - Pure entry point: `runParser :: [Token] -> Either ParseError Expr`.
   - Parser is frontend-agnostic; does not perform type checking, elaboration, or evaluation.

3. Type System (Bidirectional Type Checking):
   - Do not default to Hindley-Milner assumptions.
   - Prefer bidirectional typing architecture, with mutually recursive synthesis and checking phases.
   - Design type-level changes so advanced features such as rank-2 types and row polymorphism remain feasible.

4. Terminal UI and REPL:
   - The interactive frontend uses `brick` and `vty`.
   - Preserve separation between frontend-agnostic REPL logic (`Compiler.REPL`) and Brick UI code (`Compiler.TUI`).
   - Keep the `Terminal es` abstraction in place; do not leak Brick-specific behavior into compiler stages.
   - Maintain thread-safe handoff patterns (`BChan` events and non-blocking `MVar` submission patterns) and avoid event-loop blocking.

5. Macro System and Extensible Notation (Future Architecture):
   - The compiler will eventually support hygienic macros and Coq/Lean-style extensible notation.
   - To support this, strictly enforce the separation of Surface Syntax from Core Syntax.
   - The `Expr` AST emitted by the Parser is a `SurfaceExpr`. It remains pure data and must never contain evaluation or type-checking logic.
   - An Elaboration phase (`Compiler.Elaborator`) will eventually sit between parsing and evaluation. It will expand macros, resolve custom notation, and desugar the `SurfaceExpr` into a restricted `CoreExpr` calculus. 
   - Interleave or tightly couple Bidirectional Type Checking with the Elaboration phase, allowing macro expansion to utilize type information.

## Technology Stack and Haskell Conventions

- Effects system:
  - Use Bluefin (`Bluefin.Eff`, `Bluefin.State`, `Bluefin.Exception`).
  - Do not introduce `mtl` style classes (`MonadReader`, `MonadState`, `MonadError`) or alternate effect systems such as `polysemy` or `freer-simple`.
  - Prefer Bluefin handle patterns and lexical effect scoping (`st :> es`).
- Records and updates:
  - Follow existing `OverloadedRecordDot`, `DuplicateRecordFields`, `OverloadedLabels`, `generic-lens`, and `microlens` usage.
  - Prefer `%~` and `.~` for immutable record updates where appropriate.
- Strings:
  - Prefer `Text` for user-facing strings and diagnostics.
- Language level:
  - Assume modern GHC 9.14+ workflows and contemporary language extensions (for example `LambdaCase`, `BlockArguments`, `DataKinds`, `TypeFamilies`) when needed.

## Code Generation and Interaction Guidelines (Critical)

- Keep interaction style technical and objective. Avoid praise or sycophantic language.
- Critically evaluate user suggestions before implementing; do not assume suggestions are correct.
- Weigh long-term architecture impact of changes (for example diagnostics quality, LSP readiness, evaluator evolution, advanced type features).
- Language restrictions for examples:
  - Never emit Python, Java, or TypeScript examples.
  - Use Haskell or Lean 4 for theoretical functional programming concepts.
  - Use Zig or C for imperative compiler-mechanics examples (for example memory layouts or arenas).
- Assume Linux-first environments for operational guidance.
- Prefer dense, rigorous, performance-aware, thread-safe recommendations over beginner-focused explanations.

## Grammar and Syntax Decisions (Strictly Enforced)

### Term-Level Syntax
- **Lambdas:** `\x => body` or `fn x => body` (fat arrow `=>` is the delimiter, never thin arrow `->`)
- **Type-annotated lambdas:** `\x : T => body` (inline annotation without parens, unambiguous)
- **Let-bindings:** `let x = e1 in e2` where e1 may include annotations: `let x = e : T in e2`
- **Implicit application:** Juxtaposition binds tightly (precedence 30): `f x y` parses as `(f x) y`
- **Type annotations:** `expr : Type` (precedence 5, lower than application)
- **Data constructors:** Uppercase identifiers in term position (e.g., `True`, `Just x`, `Left y`) are reserved for future ADT support; currently parse as variables

### Type-Level Syntax
- **Function types:** `a -> b` (thin arrow, right-associative)
- **Universal quantification:** `forall a b. a -> b`
- **Type variables:** Lowercase identifiers (e.g., `a`, `t`)
- **Concrete types:** Uppercase identifiers (e.g., `Int`) or lowercase (e.g., `a` as type variable)

### Constraint and Context Syntax (Reserved for Future)
- **Type class constraints:** Will use `=>` in type signatures (e.g., `Eq a => a -> a`) when typechecker is implemented
- **This is consistent with term-level `=>` because contexts are type-level constructs**

## Error Handling and Diagnostics Strategy

- Compilers should not fail on first error when avoidable.
- Prefer diagnostics accumulation strategies that support tooling resilience (for example stateful error collection) over immediate hard-stop exception flows in parser/typechecker evolution.
- Preserve precise source-location reporting in all diagnostics.

## Current REPL Behavior (As Implemented)

- Prompt for input with `lithic> `.
- Exit on `:quit` or frontend shutdown (Ctrl-C).
- Run lexer, then parser, in sequence.
- Output on success: `[AST]<show ast>` (parsed expression AST).
- Output on lexer failure: `Lex Error: <msg>` (precise source span included in structured error).
- Output on parser failure: `Parse Error: <msg>` (precise source span included in structured error).
- Scrollback viewport shows all historical output and input echoes.
- Input editor is persistent across REPL iterations; cleared on Enter submission.
- When REPL behavior changes, update user-facing docs and README in the same task.

## Build and Validation

- Use `cabal build` as the default validation step after meaningful code changes.
- If behavior changes at runtime, prefer validating with `cabal run lithic-cli` when practical.
- Do not claim tests exist unless they actually exist; this repository currently relies primarily on build validation.

## Documentation Expectations

- Keep `README.md` aligned with actual executable behavior. Include example REPL sessions that reflect current syntax.
- Keep `docs/` content aligned with implementation details when architecture or behavior changes.
- Update docs whenever commands, controls, output formats, or workflow expectations change.
- When preparing a branch for PR: update version number in `lithic.cabal`, add detailed entry to `CHANGELOG.md` with all phase deliverables, and ensure `copilot-instructions.md` reflects current architecture and grammar decisions.

## What to Avoid

- Do not bypass REPL abstractions by embedding Brick-specific logic into compiler stages.
- Do not mix unrelated cleanup into focused changes.
- Do not silently alter parser or lexer semantics without corresponding documentation and validation updates.
- Do not introduce architectural shortcuts that compromise future type-system work, diagnostics accumulation, or LSP-facing integration.
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

2. Parsing (Pratt Parser):
   - Use top-down operator precedence with explicit NUD/LED structure.
   - Treat juxtaposition (for example `f x`) as implicit application.
   - Keep the parser pure at the public entry point (`runParser`).

3. Type System (Bidirectional Type Checking):
   - Do not default to Hindley-Milner assumptions.
   - Prefer bidirectional typing architecture, with mutually recursive synthesis and checking phases.
   - Design type-level changes so advanced features such as rank-2 types and row polymorphism remain feasible.

4. Terminal UI and REPL:
   - The interactive frontend uses `brick` and `vty`.
   - Preserve separation between frontend-agnostic REPL logic (`Compiler.REPL`) and Brick UI code (`Compiler.TUI`).
   - Keep the `Terminal es` abstraction in place; do not leak Brick-specific behavior into compiler stages.
   - Maintain thread-safe handoff patterns (`BChan` events and non-blocking `MVar` submission patterns) and avoid event-loop blocking.

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

## Error Handling and Diagnostics Strategy

- Compilers should not fail on first error when avoidable.
- Prefer diagnostics accumulation strategies that support tooling resilience (for example stateful error collection) over immediate hard-stop exception flows in parser/typechecker evolution.
- Preserve precise source-location reporting in all diagnostics.

## Current REPL Behavior (As Implemented)

- Prompt for input.
- Exit on `:quit` or frontend shutdown.
- Run lexer, then parser.
- Print `Lex Error: ...`, `Parse Error: ...`, or `[AST]...` output.
- When REPL behavior changes, update user-facing docs in the same task.

## Build and Validation

- Use `cabal build` as the default validation step after meaningful code changes.
- If behavior changes at runtime, prefer validating with `cabal run lithic-cli` when practical.
- Do not claim tests exist unless they actually exist; this repository currently relies primarily on build validation.

## Documentation Expectations

- Keep `README.md` aligned with actual executable behavior.
- Keep `docs/` content aligned with implementation details when architecture or behavior changes.
- Update docs whenever commands, controls, output formats, or workflow expectations change.

## What to Avoid

- Do not bypass REPL abstractions by embedding Brick-specific logic into compiler stages.
- Do not mix unrelated cleanup into focused changes.
- Do not silently alter parser or lexer semantics without corresponding documentation and validation updates.
- Do not introduce architectural shortcuts that compromise future type-system work, diagnostics accumulation, or LSP-facing integration.
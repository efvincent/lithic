# lithic

Lithic is a Haskell project for experimenting with a small compiler pipeline and an interactive REPL. The current executable, `lithic-cli`, launches a Brick-based terminal UI that reads expressions, lexes and parses them, and then runs bidirectional type inference/checking backed by a stateful unification engine to print either inferred types or typed diagnostics.

## Quick Start

Use `cabal` from the repository root:

```bash
cabal build
cabal test lithic-test
cabal run lithic-cli
```

Run the golden test suite explicitly:

```bash
cabal test lithic-test
```

Golden cases are discovered from `test/golden/*.lithic` and compared against matching `.golden` files.

In the REPL:

- Enter an expression such as `42`, `\x => x`, `\x : Int => x`, or `let id = \x => x in id 5`.
- Successful input is rendered as two lines: `[AST] <show ast>` followed by `[Type] <show type>`.
- Lexing, parsing, and type errors are shown inline in the same pane.
- Press Enter to submit the current editor contents.
- Enter `:quit` or press Ctrl-C to exit the session.

## Documentation Index

- [Using cabal.project](docs/cabal-project.md)
- [Terminal Custom Effect](docs/terminal-effect.md) explains the REPL abstraction, how `BChan` and `MVar` split cross-thread communication, and why the TUI layer uses `liftIO` with `tryPutMVar`.
- [Bidirectional Typechecking & Unification](docs/typechecker.md) explains the `infer`/`check` architecture, rank-2-aware subsumption (`subsumes`), and how the stateful substitution engine uses `force` and `zonk`.
- [Architecture vs. Type System](docs/architecture-vs-type-system.md) details the difference between Algorithm W and Bidirectional checking, and explains the mechanics of let-generalization.
- [Rank-2 Types and Skolemization](docs/higher-rank-types.md) gives a deeper conceptual treatment of higher-rank polymorphism, why rank-2 requires top-down checking, and how rigid skolems protect soundness.
- [Optimizations and Technical Debt](docs/optimizations.md) describes performance bottlenecks and issues to be addressed in the future.

## How To Read The Docs

If you are new to compilers or type systems, read the docs in this order:

1. Start with [Rank-2 Types and Skolemization](docs/higher-rank-types.md) for core vocabulary (`forall`, unification, occurs check, rigid skolems) and the big-picture intuition.
2. Then read [Architecture vs. Type System](docs/architecture-vs-type-system.md) to understand why Lithic chose a bidirectional design over Algorithm W.
3. Then read [Bidirectional Typechecking & Unification](docs/typechecker.md) for implementation-level details (`infer`, `check`, `subsumes`, `force`, `zonk`).
4. Read [Terminal Custom Effect](docs/terminal-effect.md) when you need to understand REPL/TUI threading and frontend boundaries.
5. Read [Using cabal.project](docs/cabal-project.md) for build/setup behavior and [Optimizations and Technical Debt](docs/optimizations.md) for known performance and roadmap notes.

Use this quick rule when choosing a doc:

- "What does this concept mean?" -> `docs/higher-rank-types.md`
- "Why was this architecture chosen?" -> `docs/architecture-vs-type-system.md`
- "How is it implemented right now?" -> `docs/typechecker.md`
- "How does runtime I/O and UI integration work?" -> `docs/terminal-effect.md`
- "How do I build/test and tune project setup?" -> `docs/cabal-project.md`

## Project Layout (high level)

- `src/Compiler/` contains compiler and REPL modules.
- `app/Main.hs` wires executable startup.
- `test/Main.hs` contains the Tasty golden test harness.
- `test/golden/` contains discovered `.lithic` inputs and expected `.golden` outputs.
- `cabal.project` configures local Cabal project behavior.
- `lithic.cabal` defines package components and dependencies.

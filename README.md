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
- [Bidirectional Typechecking & Unification](docs/typechecker.md) explains the `infer`/`check` architecture, the role of the `subsumes` bridge, and how the stateful substitution engine uses `force` and `zonk`.
- [Architecture vs. Type System](docs/architecture-vs-type-system.md) details the difference between Algorithm W and Bidirectional checking, and explains the mechanics of let-generalization.
- [Optimizations and Technical Debt](docs/optimizations.md) describes performance bottlenecks and issues to be addressed in the future.

## Project Layout (high level)

- `src/Compiler/` contains compiler and REPL modules.
- `app/Main.hs` wires executable startup.
- `test/Main.hs` contains the Tasty golden test harness.
- `test/golden/` contains discovered `.lithic` inputs and expected `.golden` outputs.
- `cabal.project` configures local Cabal project behavior.
- `lithic.cabal` defines package components and dependencies.

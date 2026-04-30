# lithic

Lithic is a Haskell project for experimenting with a small compiler pipeline and an interactive REPL. The current executable, `lithic-cli`, launches a Brick-based terminal UI that reads expressions, lexes and parses them, and prints the resulting AST or an error.

## Quick Start

Use `cabal` from the repository root:

```bash
cabal build
cabal run lithic-cli
```

In the REPL:

- Enter an expression such as `x`, `f x`, `fn x => x`, or `let id = fn x => x in id y`.
- Successful input is rendered as `[AST]...` in the scrollback pane.
- Lexing or parsing failures are shown inline in the same pane.
- Press Enter to submit the current editor contents.
- Enter `:quit` or press Ctrl-C to exit the session.

## Documentation Index

- [Using cabal.project](docs/cabal-project.md)
- [Terminal Custom Effect](docs/terminal-effect.md) explains the REPL abstraction, how `BChan` and `MVar` split cross-thread communication, and why the TUI layer uses `liftIO` with `tryPutMVar`.

## Project Layout (high level)

- `src/Compiler/` contains compiler and REPL modules.
- `app/Main.hs` wires executable startup.
- `cabal.project` configures local Cabal project behavior.
- `lithic.cabal` defines package components and dependencies.

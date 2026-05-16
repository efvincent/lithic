# lithic

Lithic is a Haskell project for experimenting with a small compiler pipeline and an interactive REPL. The current executable, `lithic-cli`, launches a Brick-based terminal UI that reads expressions, lexes and parses them, and then runs bidirectional type inference/checking backed by a stateful unification engine to print either inferred types or typed diagnostics.

This branch also includes initial structural-record row polymorphism and native lens-style record updates.

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

Golden cases are discovered from `test/fixtures/*.lithic` and compared against matching snapshots in `test/golden/*.golden`.

In the REPL:

- Enter an expression such as `42`, `\x => x`, `\x : Int => x`, or `let id = \x => x in id 5`.
- Grouped local `let` clauses are supported with a single trailing `in`, for example:
  ```haskell
  let x = 1
      y = 2
  in x
  ```
- Record expressions and selections are supported, for example `{ x = 1, y = 2 }` and `r.x`.
- Lens-style updates are supported with `:=` (set) and `%=` (modify), for example `state.{ player.hp := 99 }` and `state.{ score %= \s => s }`.
- Case expressions are supported, for example:
  ```haskell
  case v of
    Ok x => x
    Err _ => 0
  ```
- Primitive literals currently include `Int`, `Float`, `String`, and `Bool` (`True`/`False`).
- Prefix unary minus and infix subtraction are supported (`-x`, `x - y`).
- Function-equation syntax with guards and pattern-headed clauses is planned but not yet implemented.
- Top-level declaration parsing (used by the file/golden pipeline) now supports single-argument multi-clause equations in Phase 9F first slice; multi-argument clause groups and guards remain pending.
- Phase-7 behavior: case exhaustiveness and unreachable-branch checks are enforced for both finite constructor universes and the current open-universe cases supported by the pattern analysis.
- Successful input is rendered as two lines: `[AST] <show ast>` followed by `[Type] <show type>`.
- Lexing, parsing, and type errors are shown inline in the same pane.
- Press Enter to submit the current editor contents.
- Enter `:quit` or press Ctrl-C to exit the session.

## Record and Lens Examples

```haskell
let f = \r => r.x in
let r1 = { x = 1, y = 2 } in
let r2 = { y = 99, x = 42 } in
f r2
```

```haskell
let state = { player = { stats = { hp = 100 } } } in
state.{ player.stats.hp := 99 }
```

```haskell
let r = { x = 1 } in
r.{ x %= \v => 99 }
```

## Planned Function-Definition Syntax

The following forms are roadmap targets and are intentionally not accepted by the current parser yet:

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

These forms are planned to land with declaration-group parsing and will elaborate into internal lambda/case structures so existing pattern-coverage machinery can be reused.

## Documentation Index

- [Using cabal.project](docs/cabal-project.md)
- [Language Specification (Living Core Spec)](docs/language-spec.md) is the normative source for current surface syntax, precedence, and static semantics contracts.
- [Terminal Custom Effect](docs/terminal-effect.md) explains the REPL abstraction, how `BChan` and `MVar` split cross-thread communication, and why the TUI layer uses `liftIO` with `tryPutMVar`.
- [Bidirectional Typechecking & Unification](docs/typechecker.md) explains the `infer`/`check` architecture, rank-2-aware subsumption (`subsumes`), and how the stateful substitution engine uses `force` and `zonk`.
- [Architecture vs. Type System](docs/architecture-vs-type-system.md) details the difference between Algorithm W and Bidirectional checking, and explains the mechanics of let-generalization.
- [Rank-2 Types and Skolemization](docs/higher-rank-types.md) gives a deeper conceptual treatment of higher-rank polymorphism, why rank-2 requires top-down checking, and how rigid skolems protect soundness.
- [Project Plan and Architecture Record](docs/project-plan.md) captures the longer-term language vision, locked-in architectural decisions, and the current phase roadmap.
- [Optimizations and Technical Debt](docs/optimizations.md) describes performance bottlenecks and issues to be addressed in the future.

For concrete runnable behavior snapshots, inspect `test/fixtures/` and matching outputs in `test/golden/`, especially `record-basic`, `row-shift`, `lens-set`, `lens-modify`, `variant-basic`, `literals`, `minus-basic`, and `minus-precedence`.

## How To Read The Docs

If you are new to compilers or type systems, read the docs in this order:

1. Start with [Language Specification (Living Core Spec)](docs/language-spec.md) for the normative, anti-drift definition of currently implemented syntax and typing behavior.
2. Then read [Rank-2 Types and Skolemization](docs/higher-rank-types.md) for core vocabulary (`forall`, unification, occurs check, rigid skolems) and the big-picture intuition.
3. Then read [Architecture vs. Type System](docs/architecture-vs-type-system.md) to understand why Lithic chose a bidirectional design over Algorithm W.
4. Then read [Bidirectional Typechecking & Unification](docs/typechecker.md) for implementation-level details (`infer`, `check`, `subsumes`, `force`, `zonk`).
5. Read [Terminal Custom Effect](docs/terminal-effect.md) when you need to understand REPL/TUI threading and frontend boundaries.
6. Read [Project Plan and Architecture Record](docs/project-plan.md) when you want the broader roadmap, phase plan, and long-range language goals.
7. Read [Using cabal.project](docs/cabal-project.md) for build/setup behavior and [Optimizations and Technical Debt](docs/optimizations.md) for known performance and roadmap notes.

Use this quick rule when choosing a doc:

- "What is the exact current language contract?" -> `docs/language-spec.md`
- "What does this concept mean?" -> `docs/higher-rank-types.md`
- "Why was this architecture chosen?" -> `docs/architecture-vs-type-system.md`
- "How is it implemented right now?" -> `docs/typechecker.md`
- "How does runtime I/O and UI integration work?" -> `docs/terminal-effect.md`
- "What is the longer-term roadmap?" -> `docs/project-plan.md`
- "How do I build/test and tune project setup?" -> `docs/cabal-project.md`

## Project Layout (high level)

- `src/Compiler/` contains compiler and REPL modules.
- `app/Main.hs` wires executable startup.
- `test/Main.hs` contains the Tasty golden test harness.
- `test/fixtures/` contains discovered `.lithic` test inputs.
- `test/golden/` contains expected `.golden` outputs.
- `cabal.project` configures local Cabal project behavior.
- `lithic.cabal` defines package components and dependencies.

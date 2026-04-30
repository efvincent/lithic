# Using cabal.project

This project includes a root `cabal.project` file:

```cabal
packages: .

-- Force cabal to ignore the upper bounds on 'config-ini' dependencies
allow-newer: config-ini:containers
           , config-ini:base
           , config-ini:text
```

## What cabal.project does

`cabal.project` controls project-local build behavior for Cabal commands run from this repository. It sits beside `lithic.cabal` and can adjust solver and build settings without changing package metadata.

In this repository, it currently does two key things:

1. `packages: .` tells Cabal to treat the repository root package as part of the local project.
2. `allow-newer` relaxes selected upper-bound checks for `config-ini` against `containers`, `base`, and `text`.

## Why allow-newer is present here

The comment in `cabal.project` states the intention directly: ignore specific upper bounds declared by `config-ini` so dependency solving can proceed with newer versions available in this environment.

This can be useful when:

- Upstream bounds are conservative and known to work in practice.
- You are validating compatibility before upstream metadata is updated.
- You need to keep momentum in local development while waiting on ecosystem updates.

## How this differs from lithic.cabal

- `lithic.cabal` is package metadata and dependency declaration for the project itself.
- `cabal.project` is project-level configuration for how Cabal solves/builds this workspace.

A practical rule:

- Put package requirements and component definitions in `lithic.cabal`.
- Put local project solver overrides and workflow settings in `cabal.project`.

## Common workflows

Build the project:

```bash
cabal build
```

Run the executable:

```bash
cabal run lithic-cli
```

This launches the Brick-based REPL UI on the main thread.

Load in REPL context:

```bash
cabal repl
```

## When to edit cabal.project

Edit `cabal.project` when you need project-local behavior changes such as:

- Solver overrides (`allow-newer`, constraints, source-repository-package entries).
- Multi-package workspace behavior.
- Local build tweaks not meant to be encoded in package metadata.

Prefer not to edit it for API-level dependency intent that belongs in `lithic.cabal`.

## Reproducibility notes

`allow-newer` can reduce strict reproducibility because solver outcomes may vary across toolchain and index states. If reproducibility is critical, pair this with pinned index-state and explicit constraints.

## Troubleshooting

If Cabal fails during dependency solving:

1. Re-run with verbose solver output:

```bash
cabal build -v
```

2. Confirm overrides in `cabal.project` still match the dependency graph.
3. If a newer version is actually incompatible, remove or narrow the relevant `allow-newer` entry and revisit constraints.

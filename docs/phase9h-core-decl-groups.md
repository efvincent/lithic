# Phase 9H Scaffold: Core Decl Groups + Persistent REPL Environment

Status: H1 + H2 first slice implemented (2026-05-17)
Branch: feat/phase9h-core-decl-groups

## Scope

Phase 9H is intentionally limited to the two Phase 10 prerequisites:

1. Core/Elaborator support for top-level declaration groups.
2. REPL runtime support for a persistent top-level environment across submissions.

Non-goals in this phase:

1. Additional surface syntax (guards, multi-arg multi-clause grouping, lists, tuples).
2. C backend work.
3. Macro/notation expansion work.

## Architectural Targets

1. Keep surface parsing concerns in parser modules; do not leak parser-specific choices into Core evaluator internals.
2. Preserve existing separation of frontend-agnostic REPL logic and Brick UI transport.
3. Keep error spans and diagnostics quality unchanged or improved.

## Implementation Checkpoints

## H1: Core Decl Group Surface

Goal: represent top-level declarations in Core-facing data so elaboration/evaluation can consume them.

Candidate touchpoints:

1. src/Compiler/AST/Core.hs
2. src/Compiler/Elaborator.hs
3. src/Compiler/AST.hs (only if bridge types are needed)

Suggested first slice:

1. Add explicit Core declaration carriers (for example, core signature/definition group wrappers).
2. Add elaboration entrypoints for top-level forms (declaration-aware wrapper around current expression elaboration).
3. Keep current expression path stable to avoid test churn during initial scaffold landing.

**Implemented (2026-05-17):** `CDeclDef`, `CDeclSig`, `CoreTopLevel`, `getCoreDeclSpan` added to `AST.Core`. `elabTopLevel` and `elabDecl` added to `Elaborator`.

## H2: Persistent REPL Environment

Goal: submitting one declaration in the REPL should affect subsequent submissions.

Candidate touchpoints:

1. src/Compiler/REPL.hs
2. app/Main.hs
3. src/Compiler/TypeChecker.hs
4. src/Compiler/Evaluator.hs (if value-level persistence is wired in this phase)

Suggested first slice:

1. Route input through top-level parsing path.
2. Distinguish declaration submissions from expression submissions.
3. Thread persistent bindings through loop state without blocking UI event flow.

**Implemented (2026-05-17):** REPL now parses via `parseTopLevel`, threads `Env` as local state through the loop, persists named definitions, and survives error submissions without corrupting existing environment.

## Test Coverage

Unit test home:

1. test/Test/Phase9HScaffold.hs (created in this scaffold commit)

Implemented coverage (2026-05-17):

1. Declaration group elaborates without regressing existing expression elaboration.
2. REPL: declaration in step N is visible in step N+1 expression/type queries.
3. REPL: parser/type errors do not corrupt previously accepted environment.
4. REPL: signature-only declarations are acknowledged but not persisted.

Follow-up candidates:

1. test/fixtures/decl-group-basic.lithic
2. test/fixtures/repl-persist-basic.lithic
3. test/fixtures/repl-persist-error-recovery.lithic

## Exit Criteria

Phase 9H is complete when all of the following hold:

1. Top-level declaration groups are represented in Core/elaboration boundary APIs.
2. REPL state persists accepted top-level bindings across submissions.
3. Existing golden suite remains green.
4. New regression tests exist for declaration-group and persistence behavior.
5. docs/language-spec.md and README.md are updated for externally visible behavior changes.
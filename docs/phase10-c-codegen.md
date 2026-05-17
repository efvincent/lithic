# Phase 10 Scaffold: C Code Generation First Pass

Status: scaffold started (2026-05-17)
Branch: feat/phase10-c-codegen

## Scope

Phase 10 is intentionally limited to a first-pass C backend for already-accepted,
monomorphic Lithic programs.

In scope:

1. Lower Core top-level declarations to a single generated `.c` translation unit.
2. Emit C for the monomorphic subset already covered by the current parser/typechecker/evaluator pipeline.
3. Add a CLI path that writes generated C for valid programs.
4. Validate generated C with `gcc -std=c11` on focused fixtures.

Out of scope:

1. Monomorphization of polymorphic programs.
2. Nominal FBIP layout, ownership tracking, or allocator upgrades.
3. Module-system concerns and multi-file linking.
4. Deferred Phase 11 surface syntax items.

## Architectural Targets

1. Keep code generation downstream of parsing, elaboration, and typechecking; do not couple C emission back into parser or REPL concerns.
2. Preserve the Surface/Core boundary: C generation should consume Core-facing declaration carriers rather than ad hoc surface AST shapes.
3. Keep the first pass explicit about limitations: reject surviving `TForall` or unresolved `TMeta` rather than guessing.
4. Generate simple, inspectable C first; optimization is a follow-up concern.
5. Keep the backend Linux-first and `gcc`-validated.

## Candidate Touchpoints

1. src/Compiler/CGen.hs
2. src/Compiler/AST/Core.hs
3. src/Compiler/Elaborator.hs
4. src/Compiler/TypeChecker.hs
5. app/Main.hs
6. README.md
7. docs/project-plan.md

## Implementation Checkpoints

## C1: Backend Entry and Program Shape

Goal: define a narrow backend API and the minimal declaration/program contract it consumes.

Suggested first slice:

1. Add `Compiler.CGen` with an entry point shaped like `cgenProgram :: [CoreDecl] -> Text`.
2. Define top-level traversal order and generated C file skeleton (`#include`s, helper declarations, `main` strategy if any).
3. Reject non-codegen-ready Core/type states early with explicit diagnostics.

## C2: Core Term Lowering

Goal: emit correct C for the first-pass evaluable subset.

Suggested first slice:

1. Primitive type mapping for `Int`, `Float`, `String`, and `Bool`.
2. Top-level named function emission.
3. `let` lowering to local temporaries.
4. Closure representation for lambdas with captures.
5. `case` lowering to discriminant-based control flow.

## C3: Data Representation

Goal: lower structural data with an intentionally simple first-pass runtime model.

Suggested first slice:

1. Variants as tagged payload carriers.
2. Structural records as heap-allocated field arrays / helper-based lookup.
3. Clear helper-function boundary for allocation, tag dispatch, and field lookup.

## C4: CLI Integration and Validation

Goal: make the backend user-visible and regression-tested.

Suggested first slice:

1. Add a CLI flag such as `--emit-c`.
2. Write generated `.c` output to disk from the existing pipeline.
3. Add fixtures for identity, factorial, record selection, and variant matching.
4. Compile generated output with `gcc -std=c11` in validation scripts/tests.

## Test Plan

Initial validation targets:

1. Codegen rejects polymorphic programs with an explicit backend diagnostic.
2. Monomorphic identity function emits compilable C.
3. Variant match emits correct tag dispatch.
4. Record construction/selection emits compilable C and correct output.
5. Generated C for a small arithmetic/function example compiles and runs.

Follow-up candidates:

1. test/fixtures/codegen-identity.lithic
2. test/fixtures/codegen-factorial.lithic
3. test/fixtures/codegen-record-select.lithic
4. test/fixtures/codegen-variant-match.lithic

## Exit Criteria

Phase 10 is complete when all of the following hold:

1. A backend entry point exists for Core top-level declarations.
2. The supported monomorphic subset emits compilable C.
3. Unsupported polymorphic / unresolved-type programs fail with explicit codegen diagnostics.
4. The CLI can write `.c` output for a valid program.
5. Focused fixtures validate both emitted source shape and `gcc` compilation.
6. README.md and roadmap docs describe the backend workflow accurately.
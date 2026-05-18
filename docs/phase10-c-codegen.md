# Phase 10 Scaffold: C Code Generation First Pass

Status: C2 scaffold complete (2026-05-18) — all Core forms emit compilable placeholder C
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

## Immediate Next Slice (C1.1)

This is the recommended next coding task for the current branch.

Goal: stabilize the backend scaffold output contract before term-lowering work.

Required code changes (src owned by implementation step):

1. Fix C prelude header spellings and keep include order deterministic.
2. Preserve scaffold comments so output remains testable while C2 lowering is incomplete.
3. Keep `cgenProgram` pure and declaration-order preserving.

Prepared tests in this repo now cover:

1. Required prelude headers are present.
2. Declaration-count comment matches list length.
3. Signature/definition placeholder comments are emitted.

Validation command for this slice:

```sh
cabal test lithic-test --test-options='--pattern "CGen Unit Tests"'
```

Definition of done for C1.1:

1. CGen unit tests pass.
2. No behavior regressions in existing golden and unit tests.
3. Docs remain aligned with actual scaffold output.

Status update: complete (header typo fixed; CGen unit tests green).

## Immediate Next Slice (C2.0)

Goal: start declaration-body lowering with a minimal, explicit function skeleton path.

Recommended implementation target (src step):

1. For `CDeclDef name rhs`, emit a C function skeleton for a narrow first shape:
	`rhs` is a lambda-like value that can map to one generated C function.
2. Keep unsupported definition shapes explicit via scaffold comments or diagnostics.
3. Preserve declaration order and current prelude contract.

Current prep tests for this boundary now include:

1. Deterministic declaration ordering.
2. Single blank-line separator between adjacent declarations.

Validation command for prep coverage:

```sh
cabal test lithic-test --test-options='--pattern "CGen Unit Tests"'
```

Definition of done for C2.0 prep handoff:

1. All CGen scaffold unit tests pass.
2. C2 implementation can add focused tests for function skeleton emission without rewriting existing scaffold tests.

## C2 Scaffold Status (Current)

Current `Compiler.CGen` body-level emission coverage (first-pass placeholders):

1. Top-level lambda definitions emit named C function skeletons (`static void lithic_<name>(void)`).
2. Terminal forms emit explicit return-path placeholders:
	- `CLit` emits literal-kind comment + `return;`
	- `CVar` emits variable comment + `return;`
3. Compound forms now emit call/control placeholders instead of generic TODO-only comments:
	- `CApp` currently emits a compile-safe placeholder call (`lithic_unsupported_fn(0)`) plus TODO marker
	- `CCase` emits `switch (0)` skeleton with numbered branch stubs
	- `CVariant` emits `lithic_variant_make(...)`
	- `CRecord` emits `lithic_record_make(...)`
	- `CSelect` emits `lithic_record_select(...)`

Normalization policy now used in this slice:

1. Unsupported body forms route through a single marker: `unsupported(phase10-c2)`.
2. Constructor-specific helper comments remain explicit (`unsupported-call-target`, `unsupported-call-arg`).

Near-term follow-up (post-normalization):

1. Replace `switch (0)` with real discriminant lowering once tag model is finalized.
2. Introduce concrete value temporaries/ABI for call and record helper stubs.
3. Wire runtime helper declarations (`lithic_variant_make`, `lithic_record_make`, `lithic_record_select`) into generated prelude or support runtime.

## Immediate Next Slice (C2.1) — Actual C Emission

Branch: `feat/phase10-c2-emission`

Goal: replace placeholder stubs with actual compilable C for the monomorphic first-pass subset.

### Primitive Type Mapping

| Lithic Type | C Type |
|---|---|
| `Int` | `int64_t` |
| `Float` | `double` |
| `String` | `const char*` |
| `Bool` | `int` (`0`/`1`) |

Types flow into CGen from the typechecker result; a monomorphism guard must reject any surviving `TForall`/`TMeta` at this boundary with an explicit diagnostic.

### C2.1 Coding Targets (in recommended order)

1. **Typed function signatures** — replace `static void lithic_<name>(void)` with a real return type derived from the zonked body type, and generate typed parameters for each lambda argument.
2. **Literal emission** — replace `/* emit literal: Int */\n  return;` with actual C return expressions:
   - `LInt n` → `return (int64_t)<n>;`
   - `LBool True/False` → `return 1;` / `return 0;`
   - `LFloat f` → `return (double)<f>;`
   - `LString s` → `return "<s>";`
3. **Variable terminal** — replace comment-only `CVar` return with `return <varName>;`.
4. **`let` to stack local** — emit `<type> <name> = <rhs_expr>;` and recurse into body instead of a comment-only placeholder.
5. **Monomorphism guard** — add a pre-codegen check that rejects programs with surviving `TForall` or unresolved `TMeta` in any type present at declaration boundaries.

### C2.1 Test Plan

For each item above, add a targeted test to `test/Test/CGen.hs`:

1. `CLit (LInt 42)` body function emits `return (int64_t)42;` and `int64_t` return type.
2. `CLit (LBool True)` body function emits `return 1;` and `int` return type.
3. `CVar "x"` terminal emits `return x;`.
4. `CLet (CPVar "y") (CLit ...) body` emits a local variable declaration before the body.
5. Polymorphic declaration input produces an explicit codegen diagnostic, not silent emission.

### Architecture Notes

- `cgenFunctionBody` currently returns `Text`. To support returning typed C expressions
  (needed for let-RHS), consider promoting it to return a `(CType, Text)` pair or threading
  a type environment. Keep the first slice simple: pass the zonked `Type` alongside `CoreExpr`
  to `cgenDecl` so typed function headers can be emitted without full bidirectional type threading.
- The `collectLamArity` helper already extracts arity from the lambda spine; extend it to
  also collect the list of parameter names so they can be typed in the C signature.
- Keep the `intptr_t` uniform-erasure strategy as a fallback for compound forms until
  C3 data representation is designed; only primitive scalar types need accurate C types in C2.1.
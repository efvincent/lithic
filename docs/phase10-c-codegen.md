# Phase 10 Scaffold: C Code Generation First Pass

Status: C2.2 call/case/variant/select lowering merged on main (PR #28) + C4.3 fixture-level emit/compile integration landed (2026-05-23) + C3.1 compile-time prelude template embedding and C3.2 first-pass prelude safety hardening landed + expanded C4.4 compile/link/run sanity gate (2026-05-24)
Branch: main (post-merge baseline)

## Immediate Next Slice (C3.3/C4.4-expansion)

Goal: deepen runtime representation beyond placeholder helpers while widening runtime execution checks incrementally.

Design decision for this slice:

1. Keep static runtime C blocks in dedicated template resources embedded at compile time; avoid re-introducing large inline literals in Haskell modules.
2. Preserve the current helper ABI shape while incrementally replacing helper internals with explicit first-pass carrier structs.
3. Expand runtime sanity coverage with small harness checks per supported lowering shape, while keeping the suite fast.

Recommended execution order:

1. Runtime helper representation depth (C3.2):
  - Introduce explicit first-pass structs for record and variant carriers used by helper boundaries.
  - Keep helper signatures value-returning (`intptr_t`) at call sites while confining representation details inside helper implementations.
  - Preserve current placeholder fallback markers for unsupported Core forms.
2. Fixture-level emit/compile gate (C4.3):
  - Add focused `test/fixtures` declaration inputs for identity, variant match, and record/select paths.
  - Add test coverage that runs `--emit-c` on fixtures and compiles emitted files with `gcc -std=c11 -Wall -Wextra -Werror -c`.
  - Keep output checks semantic (markers/contracts), not brittle whole-file snapshots.
3. Runtime execution sanity gate (C4.4):
  - For a tiny monomorphic subset, add compile+link+run checks (opt-in or narrowly scoped) to validate observed result shape beyond `-c` object checks.

Current landing status:

1. C4.3 fixture-level emit/compile integration is now landed in `Test.CLIEmitC` with dedicated fixtures for declaration emit paths (`decl-signature-equation`, `emitc-record-select`, `emitc-variant`).
2. `gcc -std=c11 -Wall -Wextra -Werror -c` compile checks run on emitted C at CLI integration level.
3. C3.1 prelude migration is landed: static prelude/helper text is sourced from an embedded template resource rather than a large inline literal in `Compiler.CGen`.
4. C4.4 now includes narrow runtime execution checks in `Test.CGen`: generated monomorphic identity, a non-identity variant-helper path, a record initialization plus selection roundtrip path, a variant-case dispatch path, and an unmatched variant-case fallback path (default return `0`) are compiled, linked with tiny harnesses, and executed under `gcc`.
5. C3.2 first-pass prelude safety hardening is landed in `src/Compiler/CGenPrelude.c`: boxed runtime access helpers now validate handle registration before dereference and fail closed (`0`) for unknown/wrong-kind/null malformed inputs.
6. C4.4 negative runtime-path coverage now includes wrong-kind, null-handle, and malformed non-zero handle variant-case checks in `Test.CGen`.

Definition of done for C3.3/C4.4-expansion:

1. Existing CGen unit tests and CLI `--emit-c` integration tests remain green.
2. New fixture-level emit/compile tests pass under Linux `gcc`.
3. Narrow compile/link/run sanity checks cover at least one non-identity supported lowering path in addition to identity.
4. `README.md` and `docs/project-plan.md` stay aligned with the supported backend surface.

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

## C2.1 Status (Current)

Current `Compiler.CGen` emission coverage:

1. Top-level lambda definitions emit typed C function signatures derived from zonked types when available.
2. Terminal forms now emit actual C returns:
  - `CLit` emits scalar literals (`int64_t`, `double`, string, `0/1` bool)
  - `CVar` emits `return <varName>;`
3. `CLet` with `CPVar` emits a stack local (`intptr_t <name> = <rhs>;`) and continues with lowered body.
4. Compound forms currently remain explicit placeholders:
  - `CApp` emits `lithic_unsupported_fn(0)` plus placeholder return
  - `CCase` emits `switch (0)` skeleton with branch stubs
  - `CVariant` emits `lithic_variant_make(...)`
  - `CRecord` emits `lithic_record_make(...)`
  - `CSelect` emits `lithic_record_select(...)`
5. Non-lambda top-level declarations emit a typed/global constant shape.
6. Monomorphism guard rejects unresolved declaration types and emits:
  - `codegen error: program is not fully monomorphic; instantiate before code generation`

Interpolation policy now used in this slice:

1. `Compiler.QQ` provides `c`, `blk`, and `blks` for C text template assembly.
2. `[c| ... |]` preserves embedded trailing newlines in the quoted block.
3. `blk` appends one trailing newline; `blks` appends two.
4. CGen output tests treat separator boundaries as newline-shape tolerant to avoid brittle assumptions around interpolation formatting.

Style rule for "blocks that need interpolation":

1. Use `[c| ... |]` for multi-line C blocks, brace-delimited statement sections, or templates with multiple interpolated values.
2. Use plain `Text` concatenation for short/simple fragments where interpolation would be noisier than direct concatenation.
3. Do not over-apply interpolation; choose the smallest construct that keeps emitted C shape clear and predictable.

Near-term follow-up (post-normalization):

1. Replace `switch (0)` with real discriminant lowering once tag model is finalized.
2. Introduce concrete value temporaries/ABI for call and record helper stubs.
3. Wire runtime helper declarations (`lithic_variant_make`, `lithic_record_make`, `lithic_record_select`) into generated prelude or support runtime.

## Immediate Next Slice (C2.2) — Call/Case/Variant Lowering Pass

Branch: `feat/phase10-c2-2-callcase-lowering`

Goal: move from typed scalar/literal lowering to first-pass executable control/data lowering while preserving compile-safe output.

### C2.2 Scope

1. Replace `CApp` placeholder return path with first-pass callable emission shape.
2. Replace `CCase` `switch (0)` skeleton with scrutinee-driven control flow for literal/int heads.
3. Tighten `CVariant` and `CSelect` placeholders to use explicit intermediate temporaries and typed coercion boundaries.
4. Keep unsupported forms explicit and compilable with deterministic markers.

### C2.2 Implementation Checklist

1. `CApp`:
  - introduce a minimal call-target/value convention,
  - emit call statements that compile under current placeholder runtime helpers,
  - preserve fallback diagnostics for unsupported call-target shapes.
2. `CCase`:
  - lower literal scrutinee branches to concrete `if`/`else` or `switch` over emitted scrutinee value,
  - preserve branch-order semantics,
  - keep default/unmatched behavior explicit.
3. `CVariant`/`CSelect`:
  - materialize intermediate temporaries to avoid repeated expression emission,
  - keep helper API placeholders stable until C3 runtime layout is finalized.
4. Newline/template policy:
  - continue using `Compiler.QQ` `c`/`blk`/`blks`,
  - preserve separator boundaries required by `Test.CGen`.

### C2.2 Test Additions

Add focused tests in `test/Test/CGen.hs` for:

1. concrete app-lowering shape for supported var-call forms:
  - emitted direct call return marker: `return (intptr_t)f(x);`
  - no retained bare unsupported call marker: `lithic_unsupported_fn(0);`
2. case lowering over literal-int scrutinees:
  - emitted scrutinee temp marker: `int64_t lithic_case_scrut = (int64_t)2;`
  - concrete branch guards:
    - `if (lithic_case_scrut == (int64_t)1)`
    - `else if (lithic_case_scrut == (int64_t)2)`
  - explicit branch-order comments preserved in source order:
    - `/* case branch 0 */`
    - `/* case branch 1 */`
3. variant/select emission with explicit intermediate temporaries:
  - variant payload temp: `intptr_t lithic_variant_payload_tmp = x;`
  - select temps:
    - `intptr_t lithic_select_record_tmp = r;`
    - `intptr_t lithic_select_field_tmp = ...`
4. fallback diagnostics for unsupported call/case forms:
  - unsupported call target marker: `unsupported-call-target: CLit`
  - unsupported case pattern marker: `unsupported-case-pattern: CPVariant`

Validation command:

```sh
cabal test lithic-test --test-options='--pattern "CGen Unit Tests"'
```

Exit criteria for C2.2:

1. Existing CGen unit tests remain green.
2. New C2.2 tests pass and lock emitted call/case skeleton contracts.
3. Full suite remains green (`cabal test lithic-test`).

## Immediate Next Slice (C3.0/C4.2) — Runtime Helper ABI + Compile Validation

Goal: lock a compile-safe runtime helper ABI boundary and require `gcc -c` success for emitted C on representative monomorphic shapes.

Priority order after C2.2:

1. Runtime-helper ABI contract consistency (`lithic_variant_make`, `lithic_record_make`, `lithic_record_select`) for value-context emission.
2. C compile validation in tests for currently supported emitted forms.
3. Runtime representation deepening (closure captures, structural record payload layout, tagged variant payload layout).

### C3.0/C4.2 Checklist

1. Runtime helpers used from `return` expressions must expose value-returning signatures compatible with emitted casts.
2. Add CGen tests that compile generated C via `gcc -std=c11 -Wall -Wextra -Werror -c`.
3. Keep compile checks focused on generated translation-unit validity (object build only, no linking/runtime execution yet).
4. Preserve deterministic output markers expected by existing CGen textual assertions.
5. Add CLI-level integration coverage for `--emit-c` (default output, explicit `-o`, and bare-expression rejection).

### C3.0/C4.2 Test Additions

Add/maintain tests in `test/Test/CGen.hs` for:

1. Monomorphic identity (`Int -> Int`) generated C compiles successfully with `gcc -c`.
2. Variant-helper emission path compiles successfully with `gcc -c`.
3. Prelude helper declarations include value-returning signatures:
  - `static inline intptr_t lithic_variant_make(...)`
  - `static inline intptr_t lithic_record_make(...)`
  - `static inline intptr_t lithic_record_select(...)`

Validation command for this slice:

```sh
cabal test lithic-test --test-options='--pattern "CGen Unit Tests"'
```

## Historical Slice Notes (C2.1) — Actual C Emission

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
# Phase 10 C3.5 Prep Checklist

Status: landed from merged PR #31 baseline follow-up (main, v0.9.17.0)
Branch: feat/phase10-c3-5-case-expr-lowering

## Motivation

The C3.4 slice hardened fail-closed record initialization. The next layer of
correctness work is widening the case-expression lowering and the inline value
expression path so that common programs involving Bool scrutinees, variable-
bound case dispatch, and simple direct calls in expression position actually
lower to correct C rather than falling through to placeholder stubs.

Two concrete gaps block the majority of non-trivial Lithic programs from
producing executable C today:

1. **Variable-scrutinee case** (`CVar _` scrutinee with `CPLit` patterns):
   `case boolVar of True => ...; False => ...` currently hits the
   `unsupportedScrut` fallback and emits a `return 0` stub. This is the most
   common case form in practice.

2. **Direct call in expression value position** (`cgenExprValue` for `CApp`):
   `cgenExprValue` only handles `CLit` and `CVar` precisely. Any `CApp` in
   value position (e.g. the RHS of a `let` local) emits a zero placeholder.
   This blocks things like `let y = f x in ...`.

## Immediate Work Items

### C3.5a — Variable-scrutinee case lowering

Extend `cgenFunctionBody` / `CCase` to handle a `CVar _ varName` (and
downstream `CApp`-based) scrutinee paired with `CPLit` patterns.

Concretely, when the scrutinee is **not** a literal but the branch patterns are
`CPLit`, the existing `cgenLiteralCaseBranch` machinery already handles
`CPLit (LInt n)`, `CPVar`, and `CPWildcard`. The gap is two-fold:

1. The scrutinee dispatch only routes to `cgenLiteralCaseBranch` when
   `scrut` is `CLit _ (LInt _)`. It should also route there when `scrut`
   is a `CVar _ name` (or any general expression), materializing the scrutinee
   into a typed temp first.

2. `cgenLiteralCaseBranch` only lowers `CPLit (LInt n)` precisely; Bool and
   String literal patterns hit the `unsupportedLit` stub. Extend it:
   - `CPLit (LBool True)` → `$prefix ($scrutTmp != 0)`
   - `CPLit (LBool False)` → `$prefix ($scrutTmp == 0)`
   - `CPLit (LString s)` → `$prefix (strcmp($scrutTmp, "$s") == 0)`
     (requires `<string.h>`; already included by prelude via `<stdlib.h>`
     chain — confirm or add explicit include)

The revised dispatch order in `cgenFunctionBody` for `CCase`:

```
1. variant-headed branches (any branch is CPVariant) → existing variant path
2. literal/variable/wildcard-only branches → extend literal-case path to accept
   any scrutinee expression (not just CLit LInt); materialize scrutinee to a
   typed temp before the branch chain
3. fallback → existing unsupportedScrut placeholder
```

### C3.5b — Direct call in expression value position

Extend `cgenExprValue` to handle `CApp (CVar f) arg`:

```
CApp _ (CVar _ fnName) arg -> cFunctionName fnName <> "(" <> cgenExprValue arg <> ")"
```

Multi-argument curried calls `CApp (CApp ...) arg` require flattening the
left-spine into a single call with a collected argument list. Add a helper
`collectArgs :: CoreExpr -> (CoreExpr, [CoreExpr])` that unrolls the left-CApp
spine and returns `(callee, [arg1, arg2, ...])`. Then `cgenExprValue` can emit
`callee(arg1, arg2, ...)` when callee reduces to a `CVar`.

Non-`CVar` callees (lambdas, selects, etc.) remain in the placeholder path for
this slice.

### C3.5c — `CSelect` in expression value position

Extend `cgenExprValue` to handle `CSelect _ recordExpr fieldName`, emitting the
same helper call used in the body path:

```
CSelect _ recExpr fieldName ->
  let recVal  = cgenExprValue recExpr
      fldTag  = cgenFieldTag fieldName
  in "lithic_record_select(" <> recVal <> ", " <> fldTag <> ")"
```

This is needed for patterns like `let y = r.x in ...` to lower correctly.

## Validation Gates

1. Focused CGen suite:
   `cabal test lithic-test --test-options='-p "CGen Unit Tests"'`

2. Focused CLI emit-c integration:
   `cabal test lithic-test --test-options='-p "CLI --emit-c Integration"'`

3. Full test suite:
   `cabal test lithic-test`

## New Test Coverage

For each C3.5 sub-item, add a unit test in `test/Test/CGen.hs`:

- `testCase "Bool scrutinee True branch lowers to inequality check"` — emit
  `case True of True => 1; False => 0`, confirm generated C contains `!= 0`.
- `testCase "Bool scrutinee variable lowers to equality chain"` — `def f b = case b of True => 1; False => 0`, confirm `!= 0` and `== 0` guards emitted.
- `testCase "Bool scrutinee case compiles with gcc -c"` — compile-only gate.
- `testCase "Bool scrutinee case compile-link-run returns expected value"` —
  runtime gate: call with `1` (True), confirm result `1`; call with `0` (False),
  confirm result `0`.
- `testCase "CApp in let-local value position emits direct call"` — `def f x = let y = id x in y` (where `id` is passed in or defined globally), confirm `f(...)` appears in generated C for the RHS.
- `testCase "CSelect in let-local value position emits record_select call"` —
  `def f r = let y = r.x in y`, confirm `lithic_record_select(` appears in let-local.

Add a CLI fixture:
- `test/fixtures/emitc-bool-case.lithic`: `checkBool b = case b of True => 1; False => 0`
- Corresponding `--emit-c` + `gcc -c` integration test in `test/Test/CLIEmitC.hs`.

## Landing Notes (2026-05-26)

C3.5 is now complete.

Resolved follow-up items beyond the original prep checklist:

1. Direct-call value lowering now emits generated C symbol names in inline call
   position.
2. Unsupported-expression fallback text now emits valid C (`(intptr_t)0`).
3. Top-level constant lowering now distinguishes static initializers from
   helper-backed expressions, lowering the latter through zero-argument C
   functions rather than invalid file-scope runtime-call initializers.

Validation results at landing:

1. `cabal test lithic-test --test-options='-p "CGen Unit Tests"'` — 45 passing.
2. `cabal test lithic-test --test-options='-p "CLI --emit-c Integration"'` — 8 passing.
3. `cabal test lithic-test` — 179 passing.

## Exit Criteria

1. `case boolVar of True => ...; False => ...` emits correct, compilable C
   (no `unsupported-case-scrutinee` placeholder for `CVar _ name` + `CPLit LBool` patterns).
2. `CApp (CVar f) arg` in expression value position emits `f(arg)` inline (no
   `unsupported-rhs:CApp` placeholder for direct named calls).
3. `CSelect _ r fld` in expression value position emits
   `lithic_record_select(r, key)` inline.
4. All existing 173 tests remain green.
5. New CGen unit tests and CLI fixture tests added and green.
6. Phase 10 docs/changelog updated in the same change.

## Future Slices (Out of Scope for C3.5)

- **C3.6**: Arithmetic operators in Core and CGen — requires adding `CAdd`,
  `CSub`, `CMul`, `CDiv` to Core AST and Elaborator, then lowering to `+`, `-`,
  `*`, `/` in C.
- **C5.1**: Closure lowering — lambda values as function-pointer + capture
  struct; needed for higher-order functions and partial application at runtime.
- **TUI**: Scrollable REPL viewport — Brick `Viewport` widget so large C output
  (full prelude + declarations) can be reviewed without scrolling off screen.
  Also: `cgenDeclsOnly` variant (without prelude) for REPL output to reduce
  noise further.
- **String case lowering**: `CPLit (LString s)` via `strcmp` — blocked on
  confirming `<string.h>` is available in the prelude.

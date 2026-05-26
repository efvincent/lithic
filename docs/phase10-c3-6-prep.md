# Phase 10 C3.6 Prep Checklist

Status: kickoff prep after C3.5 landing (main, v0.9.17.0)
Branch: feat/phase10-c3-6-arith-lowering (planned)

## Motivation

C3.5 completed case and expression-value lowering depth, but arithmetic is still
outside the current Core/CGen lowering surface. C3.6 introduces first-pass
arithmetic lowering so numeric programs avoid placeholder paths.

## Immediate Work Items

1. Add arithmetic forms to Core (`CAdd`, `CSub`, `CMul`, `CDiv`).
2. Extend elaboration to lower surface arithmetic into the new Core forms.
3. Extend CGen statement-level lowering for arithmetic expressions.
4. Extend CGen expression-value lowering for arithmetic expressions.
5. Add focused CGen and CLI emit-c coverage for arithmetic fixtures.

## Validation Gates

1. `cabal test lithic-test --test-options='-p "CGen Unit Tests"'`
2. `cabal test lithic-test --test-options='-p "CLI --emit-c Integration"'`
3. `cabal test lithic-test`

## Exit Criteria

1. Core carries arithmetic forms end-to-end from elaboration to CGen.
2. Arithmetic expressions lower to compilable C in both function-body and
   expression-value positions.
3. Focused and full suites remain green.
4. Docs/changelog are updated in the same change.

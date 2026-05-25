# Phase 10 C3.4 Prep Checklist

Status: kickoff prep from merged PR #30 baseline (main)
Branch: feat/phase10-c3-4-helper-contracts-next

## Goal
Deepen helper-contract propagation from runtime helper boundaries into generated-record initialization flow while preserving existing helper ABI shape and fail-closed semantics.

## Immediate Work Items

1. C3.4 helper-contract propagation:
- Ensure record construction paths fail closed when helper initialization cannot place/update a field (no silent partial-success return on full-slot insertion failure paths).
- Ensure generated C for record initialization propagates helper failure immediately instead of returning partially initialized handles.
- Keep contract checks and fallback semantics explicit in emitted C markers/comments where practical.

2. C4.5 runtime execution expansion:
- Add one runtime harness path that exercises long-field and multi-step record initialization behavior under the stricter propagation contract.
- Add one negative runtime harness path that locks fail-closed behavior for record-initialization failure propagation.

3. CLI emit-c integration resilience:
- Add fixture-level coverage for long-field record-select emission.
- Keep deterministic executable-path resolution and `gcc -c` fixture compile checks.

## Validation Gates

1. Focused CGen suite:
- cabal test lithic-test --test-options='-p "CGen Unit Tests"'

2. Focused CLI emit-c integration:
- cabal test lithic-test --test-options='-p "CLI --emit-c Integration"'

3. Full test suite:
- cabal test lithic-test

4. Regression expectation:
- Invalid helper-boundary or propagated record-initialization failures return `0` (fail closed), not partially initialized handles.

## Exit Criteria for This Slice

1. Record-initialization failure propagation is explicit and validated in generated C/runtime behavior.
2. New CLI fixture-level long-field emit/compile coverage is green.
3. Existing CGen and CLI integration suites remain green.
4. Phase 10 docs/changelog are updated in the same change if helper/runtime contracts shift.
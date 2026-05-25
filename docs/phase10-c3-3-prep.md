# Phase 10 C3.3 Prep Checklist

Status: kickoff prep from merged PR #29 baseline (main)
Branch: feat/phase10-c3-3-runtime-contracts

## Goal
Harden helper-boundary contracts and extend runtime representation depth while preserving current helper ABI shape and fast validation loops.

## Immediate Work Items

1. C3.3 helper-contract depth:
- Add explicit helper contract checks for invalid/overflow-sensitive record sizes and tag/key path assumptions where applicable.
- Keep handle validation fail-closed behavior (return 0 sentinel) for unknown/wrong-kind/null/malformed handles.
- Keep representation details confined to prelude helper internals.

2. C4.4 runtime execution expansion:
- Add at least one new non-identity compile/link/run harness case that exercises deeper helper internals (not only call-site wiring).
- Add one negative runtime harness case for a malformed path not already covered.

3. CLI emit-c integration resilience:
- Preserve fixture-level emit and gcc -c checks.
- Keep binary-resolution behavior deterministic under clean/rebuilt trees.

## Validation Gates

1. Focused CGen suite:
- cabal test lithic-test --test-options='-p "CGen Unit Tests"'

2. Full test suite:
- cabal test lithic-test

3. Regression expectation:
- No change to current fallback contract: helper-level invalid accesses fail closed to 0.

## Exit Criteria for This Slice

1. New runtime coverage is in place for at least one deeper positive path and one new negative path.
2. Existing CGen and CLI emit-c integration tests remain green.
3. Phase 10 docs and changelog are updated in the same change if runtime/helper contracts shift.

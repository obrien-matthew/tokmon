# Codex credits and menu-bar width

## Phase 1: Model and provider mapping

- [x] Add a credits metric unit and display formatting.
- [x] Decode Codex credit balances from both live and session-fallback payloads.
- [x] Map finite, nonnegative balances to an open-ended `Credits remaining` metric.

## Phase 2: Menu-bar rendering

- [x] Let the percentage text use its intrinsic horizontal width so `100` is not clipped.
- [x] Preserve the current one-row and compact two-row heights.

## Phase 3: Verification and documentation

- [x] Add focused tests for credits decoding/mapping and headline exclusion.
- [x] Update README and the Codex data-source guide.
- [x] Run the test suite and debug/release builds.
- [ ] Move this plan to `docs/plans/completed` when all work is complete.

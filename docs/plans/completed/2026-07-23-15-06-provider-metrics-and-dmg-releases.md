# Provider metrics and DMG releases

## Phase 1: Claude credits and menu-bar metric selection

- [x] Show Claude extra-credit usage and limit, including zero usage with a limit.
- [x] Replace the ineffective provider pin with per-provider metric overrides.
- [x] Apply metric selections immediately while preserving Auto session-first fallback.
- [x] Decode legacy settings safely and ignore the obsolete provider pin.
- [x] Add focused formatting, mapping, selection, and migration tests.

## Phase 2: Remove Anthropic API support

- [x] Remove the Anthropic API provider and registry entry.
- [x] Remove its settings UI, orphaned Keychain write helpers, and action item.
- [x] Remove current README references while preserving historical plans and stored user data.

## Phase 3: Package and release DMGs

- [x] Extract reusable ad-hoc app packaging from the local installer.
- [x] Add deterministic DMG creation with signature and image verification.
- [x] Upload a DMG artifact for every push to `main`.
- [x] Publish that packaged DMG as a GitHub Release only for `v*` tags.
- [x] Document local packaging, artifacts, tags, and the lack of notarization.

## Phase 4: Verification and closure

- [x] Run Swift tests and debug/release builds.
- [x] Run shell syntax, app signature, and DMG verification checks.
- [x] Confirm the worktree contains only intended changes.
- [x] Move this plan to `docs/plans/completed`.

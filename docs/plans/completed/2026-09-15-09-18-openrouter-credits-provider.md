# OpenRouter credits provider

Status: approved 2026-09-15. Scope simplified by the user after review:
the gauge is the key's own spend cap (`limit − limit_remaining`), a real
API-supplied meter, so the configurable maximum and its entire settings
phase are dropped.

## Problem

tokmon covers Claude subscription and Codex. OpenRouter is the third
account the user spends on (omp's estimator and gateway routes run
through it). Its prepaid balance has no denominator — the API reports
lifetime dollars purchased and spent, so `MetricGaugeRow` would render
it as a bare counter (`limit == nil` → no bar).

The original ask was a user-configured maximum to supply that
denominator. Rejected in favour of the simpler, honest alternative: the
`/api/v1/key` endpoint already reports a real enforced meter for keys
that carry a spend cap. That becomes the gauge; the account balance
rides along as an open-ended text row.

## User decisions

1. **Menu bar**: dropdown only. `AppState.menuBarRows` and
   `SettingsView.metricOptions` keep their `kind == .rateLimitWindow`
   filter — no eligibility change, no competition for the two 22pt rows.
2. **Gauge**: the key spend cap, `used = limit − limit_remaining`.
3. **No configurable maximum, no settings at all.** The account balance
   is an open-ended counter, exactly like Codex's credits line.
4. **Low-balance notification**: out of scope.

## Verified API facts (live probe, 2026-09-15, user's omp key)

Key: `sk-or-v1-…`, stored in omp's `agent.db` (`auth_credentials`,
`provider='openrouter'`, `credential_type='api_key'`, `data` =
`{"key":…,"source":…}` — **not** the oauth shape `OmpCredentialStore`
decodes today).

- `GET /api/v1/credits` → `200`
  `{"data":{"total_credits":60,"total_usage":54.561828163}}`
  → balance **$5.44**. Both figures are lifetime cumulative. The docs
  say this route wants a management key; the user's plain inference key
  is accepted today, so a 403 is a soft failure, not an auth error.
- `GET /api/v1/key` → `200` `{"limit":25,"limit_reset":"monthly",
  "limit_remaining":0,"usage":35.010634427,"usage_monthly":25.006061894,
  "is_free_tier":false,"is_management_key":false,"expires_at":null,…}`
  → **the key is currently capped out**: $25/month, nothing remaining.
  Calls through it fail until the cap resets, which is exactly why a
  $5.44 balance alone would be a misleading gauge.

## Design

Two metrics, no configuration:

1. **`key-cap`** — `kind: .spend`, `unit: .usd`,
   `used = min(max(limit − limit_remaining, 0), limit)`, `limit = limit`.
   Emitted only when the key carries a cap (`limit` non-null). Uses the
   API's own arithmetic rather than a `usage_*` field: the two disagree
   by rounding (`usage_monthly` 25.006 against a 25 cap would render the
   self-inconsistent `$25.01 / $25.00`), and only the difference is what
   OpenRouter enforces. Label derives from `limit_reset`:
   `"Key spend (monthly)"`, `"Key spend (lifetime)"` when null,
   `"Key spend (<raw>)"` for anything else. **No `resetsAt`**:
   `limit_reset` names a cadence, not a boundary, and nothing says
   whether it is calendar- or key-anniversary-based, so a countdown
   would be invented.
2. **`credits`** — `kind: .spend`, `unit: .usd`, `used = balance`,
   `limit: nil`, label `"Balance"` → renders `$5.44`, no bar. Same shape
   as `CodexProvider`'s `credits-remaining`. This is what keeps the
   provider useful when the key is uncapped (`limit: null` → no gauge)
   and covers account-wide spend the per-key meter cannot see.

Both endpoints are fetched concurrently and independently: either one
failing degrades to the other rather than blanking the provider.

## Phases

### Phase 1 — Credential source

- [x] `OmpCredentialStore.apiKey(provider:databaseURL:)`: same read-only
  SQLite posture and failure-to-nil discipline, `credential_type =
  'api_key'`, decoding `{"key":…}`. Shares the query with the existing
  oauth reader via a private `rowData` helper; neither reader may return
  the other's rows.
- [x] `OpenRouterProvider` resolves its key: omp store first, then a
  Keychain generic password (`service: "tokmon-openrouter"`) via the
  existing `SecurityCLI.findGenericPassword`, used with `try?` as
  `ClaudeSubscriptionProvider` does. No env-var tier — a
  Finder/launchd-launched GUI app inherits no shell environment, so
  `OPENROUTER_API_KEY` would silently work only under `swift run`.
- [x] Tests, extending `OmpCredentialStoreTests`' real WAL fixture DB
  with a `credentialType` field: valid api_key row, the two readers not
  crossing over, disabled row ignored, malformed/empty payload, missing
  file. Fixture JSON uses ordinary escaped literals — inside a `#"…"#`
  raw string a `\"` is a literal backslash and would produce invalid
  JSON that silently fails to decode.

### Phase 2 — Provider

- [x] `Sources/tokmon/Providers/OpenRouter/OpenRouterProvider.swift`:
  `id = "openrouter"`, glyph `"O"` (unused while dropdown-only, but the
  descriptor requires one), `refreshInterval = 300`,
  `enabledByDefault = false` — it needs a key most users don't have, and
  defaulting it on would show them an auth hint for an account they
  don't own.
- [x] Pure `static func metrics(credits:key:)` over already-decoded
  payloads, so the whole display mapping is testable without network;
  the provider does I/O only.
- [x] Status resolution, decided up front: no key resolved → throw
  `authRequired(hint:)` with **no** network call; both calls fail and
  either returned 401 → `authRequired`; both fail otherwise → rethrow
  the first error (RefreshEngine maps it to `.error` and republishes
  cached metrics); at least one succeeds → `.ok` with what survived.
  Mirrors `CodexProvider.fetchLive`'s `guard !metrics.isEmpty`.
  The per-request `Outcome` type must default its optional fields so
  the partial initializers used on the failure paths compile.
- [x] Register in `ProviderRegistry.allProviders()` after Codex. No
  signature change: with no configurable maximum, nothing needs to be
  injected, so `SettingsView.rows`' parameterless call still works.
- [x] Tests — pure-function cases only, since the suite has no
  `URLProtocol` stub and this plan does not add one: cap arithmetic at
  the probed numbers (25/25, 100%), partially-used cap, uncapped key
  omitted, `limit_reset` null and unknown-string labels, balance as an
  open-ended counter, zero-balance account, overdrawn account, each
  endpoint supplying metrics alone, both absent → empty. Assert
  `MetricGaugeRow.valueText` on the emitted metrics so rendered strings
  are pinned, not just the numbers.

### Phase 3 — Docs and verification

- [x] `MetricKind`: one-line doc comments distinguishing `.spend` from
  `.quota` and noting that only `.rateLimitWindow` reaches the menu bar
  — the distinction is load-bearing (AppState.swift:56) and currently
  undocumented.
- [x] README: provider bullet (both endpoints, credential order, the
  Keychain command for non-omp users, why the gauge is the key cap and
  the balance is text), architecture tree gains the provider directory.
  No glyph-legend change — OpenRouter is dropdown-only. Leave the
  "OpenAI API spend provider" future idea in place; OpenRouter is a
  different vendor and API and does not supersede it.
- [x] `docs/guides/openrouter-data-sources.md`, matching the existing
  `codex-data-sources.md` convention.
- [x] Verify: `swift test`; then build, install, and confirm against the
  live account that the dropdown shows a red 100% `Key spend (monthly)`
  bar and a `Balance $5.44` text row. Screenshot.
- [x] Move plan to `docs/plans/completed/`.

Commit after each phase.

## Risks

- **`/credits` permission drift**: the docs say management key required;
  the user's inference key works today. Mitigated by treating a failure
  there as soft — the gauge survives without the balance row.
- **Uncapped keys show no bar**: if the user raises or removes the $25
  cap, the provider degrades to a single text row. Accepted: that is the
  honest rendering of "no enforced limit exists", and it is why the
  balance row ships alongside.
- **Per-key blind spot**: the cap meter does not see spend through other
  keys on the same account. The balance row covers account-wide truth.

## Non-goals

- No configurable gauge maximum (superseded by the key-cap meter).
- No per-model or per-app OpenRouter cost breakdown.
- No credit top-up, alerting, or low-balance notification.
- No menu-bar title slot for OpenRouter.
- No writing of API keys by tokmon; read-only, like every other
  credential path in the app.

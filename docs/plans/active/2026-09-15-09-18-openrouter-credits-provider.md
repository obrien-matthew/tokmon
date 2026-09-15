# OpenRouter credits provider

Status: awaiting implementation approval (scope settled 2026-09-15;
revised after dual adversarial review — fable-reviewer and
sol-reviewer both rejected the first draft's max design)

## Problem

tokmon covers Claude subscription and Codex. OpenRouter is the third
account the user spends on (omp's estimator and gateway routes run
through it), and its balance is a prepaid pool, not a metered window:
the API reports dollars purchased and dollars spent, with no rate-limit
percentage and no reset time. `MetricGaugeRow` draws a bar only when
`UsageMetric.limit != nil`, so a balance lands in the open-ended
counter path (text, no bar) unless a denominator is supplied.

Hence the ask: an OpenRouter provider **plus** a configurable pool size
so the gauge bar has a denominator.

## User decisions (2026-09-15)

1. **Menu bar**: dropdown only. OpenRouter never occupies a menu-bar
   title slot; `AppState.menuBarRows` and `SettingsView.metricOptions`
   keep their `kind == .rateLimitWindow` filter. Phase 4 of the review
   draft is dropped entirely.
2. **Key spend cap**: ship it as a second metric.
3. **Pool size**: manual — the user tops up a fixed amount, so the bar
   denominator is a number they enter. No lifetime-derived auto mode.
4. **Low-balance notification**: out of scope.

## Verified API facts (live probe, 2026-09-15, user's omp key)

Key: `sk-or-v1-…`, stored in omp's `agent.db` (`auth_credentials`,
`provider='openrouter'`, `credential_type='api_key'`, `data` =
`{"key":…,"source":…}` — **not** the oauth shape `OmpCredentialStore`
decodes today).

- `GET /api/v1/credits` → `200`
  `{"data":{"total_credits":60,"total_usage":54.561828163}}`
  → remaining **$5.44**. Both figures are lifetime, not windowed.
  Docs say a management key is required; the user's plain inference key
  returned 200, so the path works today but may tighten → treat `403`
  as a soft failure, not an auth error.
- `GET /api/v1/key` → `200` `{"limit":25,"limit_reset":"monthly",
  "limit_remaining":0,"usage":35.010634427,"usage_monthly":25.006061894,
  "is_free_tier":false,"is_management_key":false,"expires_at":null,…}`
  → **this key is currently capped out**: a $25/month spend cap with
  `limit_remaining: 0`. Calls through it fail until the cap resets or
  is raised, which also means the $5.44 balance is not spendable
  through this key right now.

## Design decisions

### One credits metric, no fabricated numerator

First draft emitted `used = max − remaining` labelled "Credits
remaining" and promised the text `$5.44 left of $60`. Both reviewers
killed it: `MetricGaugeRow.valueText` renders bounded `.usd` as
`used / limit` (MetricGaugeRow.swift:49-54), so the row would have read
`Credits remaining — $54.56 / $60.00`, and changing that branch would
break Claude's `extra-credits` row.

Revised — `id: "credits"`, `kind: .spend`, `unit: .usd` (`.spend`
matches Claude's dollar-denominated extra-credits precedent):

- **No pool configured (default)**: `used = remaining`, `limit = nil`,
  `label: "Balance"` → renders `$5.44`, no bar. Same shape as Codex's
  existing `credits-remaining`.
- **Pool configured (`$P`)**: `used = min(max(P − remaining, 0), P)`,
  `limit = P`, `label: "Balance ($5.44 left)"` → renders
  `$14.56 / $20.00` with a 72.8% bar. `used` is clamped, not just
  `fraction`, so a top-up above the pool size reads `$0.00 / $20.00`
  (full tank) instead of a negative dollar string. Remaining stays
  visible in the provider-owned label (free text; precedent: Claude's
  model-scoped labels), so the denominator hides nothing.

Fill is depletion-ward in both cases, so the shared orange-70/red-90
escalation means "running low", consistent with every other gauge.

### Why not auto-derive the pool from `total_credits`

Rejected on review: both API figures are lifetime cumulative, so
`1 − remaining / lifetime_purchases` drifts monotonically toward red as
the account ages ($50 left of $100 lifetime = 50%; the same $50 left of
$600 lifetime = 92%). It converges on permanent red and devalues the
escalation colors on the Claude and Codex rows where they are
actionable. The user confirmed a fixed top-up amount, so the pool is
entered once and edited when it changes. `UsageMetric.fraction` already
guards `limit > 0` (Model.swift:41), so an empty field or `0` naturally
means "no bar" — no enum, no third mode, just `Double?`.

### The pool applies immediately, not on relaunch

Providers are constructed once in `TokmonApp.init` (TokmonApp.swift:23-36)
and held as immutable arrays by `AppState` and `RefreshEngine`, so a
value captured at construction would need a relaunch — and after
relaunch `SnapshotCache.load()` republishes metrics with the *old*
denominator baked in, so the user would see the stale bar until the next
poll and conclude the setting is broken.

Instead `OpenRouterProvider` takes `let pool: @Sendable () -> Double?`,
read inside `fetchSnapshot`. `ProviderRegistry.allProviders()` keeps its
parameterless signature (SettingsView.rows calls it,
SettingsView.swift:21-24); the closure is injected in `TokmonApp`,
reading `settingsStore.settings.openRouterCreditPool`. Opening the menu
triggers the existing debounced refresh, so the new bar appears without
relaunch and the Settings caption stays true as written.

## Phases

### Phase 1 — Credential source

- [ ] `OmpCredentialStore.apiKey(provider:databaseURL:)`: same read-only
  SQLite posture and failure-to-nil discipline, `credential_type =
  'api_key'`, decoding `{"key":…}`. Existing oauth `credential(provider:)`
  untouched.
- [ ] `OpenRouterProvider` resolves its key: omp store first, then a
  Keychain generic password (`service: "tokmon-openrouter"`) via the
  existing `SecurityCLI.findGenericPassword`, used with `try?` as
  `ClaudeSubscriptionProvider` does. No env-var tier — a
  Finder/launchd-launched GUI app inherits no shell environment, so it
  would only ever work under `swift run`.
- [ ] Tests, mirroring `OmpCredentialStoreTests`' real WAL fixture DB:
  valid api_key row, oauth row not returned by `apiKey`, api_key row not
  returned by `credential`, malformed JSON, missing file.

### Phase 2 — Provider

- [ ] `Sources/tokmon/Providers/OpenRouter/OpenRouterProvider.swift`:
  `id = "openrouter"`, glyph `"O"`, `refreshInterval = 300`,
  `enabledByDefault = false` (it needs a key; defaulting it on would
  show an auth hint to every other user).
- [ ] Pure `static func metrics(credits:key:pool:)` over already-decoded
  payloads; the provider does I/O only. Both endpoints are fetched
  independently — either failing degrades to the other.
- [ ] Credits metric per the design above.
- [ ] Key-cap metric: `used = max(0, limit − limit_remaining)` (the
  API's own arithmetic; `25 − 0 = 25`, whereas the draft's
  `usage_monthly = 25.006` would render the self-inconsistent
  `$25.01 / $25.00`), `limit = limit`, emitted only when `limit` is
  non-null, label derived from `limit_reset` (`"Key spend (monthly)"`,
  `"Key spend (lifetime)"` when null, `"Key spend (<raw>)"` for an
  unknown value). No `resetsAt`: `limit_reset` does not say whether the
  boundary is calendar or key-anniversary, and inventing a countdown
  would be a lie.
- [ ] Status resolution, decided up front: no key resolved → throw
  `authRequired` with **no** network call; both calls fail and either
  returned 401 → `authRequired`; both fail otherwise → rethrow the
  first error (RefreshEngine maps it to `.error` and republishes cached
  metrics); at least one succeeds → `.ok` with what survived. Mirrors
  `CodexProvider.fetchLive`'s `guard !metrics.isEmpty`.
- [ ] Tests — pure-function cases only, since the suite has no
  `URLProtocol` stub and this plan does not add one: no-pool shape,
  pool fraction (72.8% at the probed numbers), pool clamp when
  `remaining > pool`, overdrawn pool, `total_credits == 0` free-tier
  account, credits payload absent → key metric alone, both absent →
  empty, key `limit == null` → omitted, `limit_reset` null and
  unknown-string labels. Assert `MetricGaugeRow.valueText` on the
  emitted metrics so rendered strings are pinned, not just numbers.
- [ ] Register in `ProviderRegistry.allProviders()` after Codex.

### Phase 3 — Settings

- [ ] `AppSettings`: `var openRouterCreditPool: Double?` via the
  existing `decodeIfPresent` pattern (old settings.json decodes to
  `nil`; no custom enum coding).
- [ ] `SettingsStore.setOpenRouterCreditPool(_:)` — rejects non-finite
  and non-positive values by storing `nil`.
- [ ] `SettingsView`: an "OpenRouter" section with one dollar
  `TextField` bound to local `@State` text, committed on `.onSubmit`
  and focus loss (**not** per keystroke — `SettingsStore.settings` has
  `didSet { save() }`, so a direct binding would rewrite settings.json
  on every character and transiently store `2` while typing `20`).
  Currency-tolerant parsing so `"$20"` works; empty/0/negative/
  unparseable → `nil` → no bar. Section visible only when the provider
  is enabled.
- [ ] Wire the closure in `TokmonApp` where providers are built.
- [ ] Tests: `AppSettings` round-trip with the pool set and unset, and
  decode of a pre-feature settings.json.

### Phase 4 — Docs and verification

- [ ] README: provider bullet (both endpoints, credential order, the
  Keychain command, the pool setting and why it has no auto mode),
  architecture tree gains the provider directory. Leave the "OpenAI API
  spend provider" future idea in place — OpenRouter is a different
  vendor and API, it does not supersede it. No glyph-legend change:
  OpenRouter is dropdown-only by decision 1.
- [ ] `docs/guides/openrouter-data-sources.md`, matching the existing
  `codex-data-sources.md` convention: endpoints, the management-key
  caveat on `/credits`, credential precedence, what each metric means.
- [ ] `MetricKind`: one-line doc comments distinguishing `.spend` from
  `.quota` — the distinction is load-bearing (AppState.swift:56) and
  currently undocumented.
- [ ] Verify: `swift test`; then build + install and confirm against the
  live account — dropdown shows `Balance $5.44` with no bar by default;
  entering a `$20` pool re-renders as `$14.56 / $20.00` at ~73% orange
  **without relaunch**; key cap shows 100% red (currently exhausted).
  Screenshot both states.
- [ ] Move plan to `docs/plans/completed/`.

Commit after each phase.

## Risks

- **`/credits` permission drift**: docs say management key required; the
  user's inference key works today. Mitigated by treating 403 as a soft
  failure — the key-scoped metric survives alone and the gauge degrades
  rather than blanking.
- **Pool staleness**: a hand-entered pool does not follow top-ups, so
  after a larger top-up the bar reads "full tank" until the user edits
  it. Accepted: the alternative (lifetime denominators) is worse, and
  the label always shows the true remaining balance.
- **Two red bars**: with the key cap exhausted, both OpenRouter rows sit
  at/near 100%. That is the account's actual state, not a rendering bug.

## Non-goals

- No per-model or per-app OpenRouter cost breakdown.
- No credit top-up, alerting, or low-balance notification (decision 4).
- No menu-bar title slot for OpenRouter (decision 1).
- No writing of API keys by tokmon; read-only, like every other
  credential path in the app.

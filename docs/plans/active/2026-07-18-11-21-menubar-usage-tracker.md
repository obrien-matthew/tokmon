# tokmon — macOS Menu Bar AI Usage Tracker

**Status:** Approved; Phase 1 complete, Phase 2 next
**Created:** 2026-07-18 11:21

## Goal

A native macOS menu bar app that shows, at a glance, how close the user is to
their AI provider limits: Claude subscription session (5h) and weekly limits,
Anthropic API spend, and Codex/ChatGPT rate limits. The UI is universal — it
renders a normalized metric model — and each provider is a self-contained
module that maps its own data source into that model.

## Decisions (locked with user)

- **Stack:** Native Swift/SwiftUI, `MenuBarExtra`, **macOS 14+** (bumped from
  13 so `SettingsLink` works cleanly from an accessory app).
- **Claude data source:** Claude Code's OAuth credentials (macOS Keychain) +
  the OAuth usage endpoint — authoritative session/weekly percentages.
- **v1 providers:** Claude subscription, Anthropic API spend, Codex/ChatGPT.
- **Distribution:** Personal use only. No signing/notarization/sandbox.

## Decisions (from plan review)

- **Keychain reads shell out to `/usr/bin/security`** rather than linking
  Security.framework. `swift build` produces a new ad-hoc code signature every
  rebuild, so Keychain ACL grants ("Always Allow") never stick for our binary —
  but the Apple-signed `security` CLI is already in the ACL for items it
  created, and Claude Code writes its credentials through it. Both the Claude
  Code item and tokmon's own admin-key item are read/written via
  `security find-generic-password -w` / `add-generic-password`. If this
  accumulates papercuts, fallback is a minimal `.app` wrapper + stable
  self-signed identity (also fixes launch-at-login natively).
- **Launch at login via plain launchd agent plist** in
  `~/Library/LaunchAgents/` — `SMAppService` requires a real app bundle,
  which a bare SwiftPM executable is not.
- **`.menuBarExtraStyle(.window)`** — the default `.menu` style flattens
  content into NSMenu items and can't render custom gauge views; `.window`
  also gives us `onAppear` as the refresh-on-open hook.
- **All persistence is explicit JSON** under
  `~/Library/Application Support/tokmon/` (settings + snapshot cache). No
  UserDefaults — a bundle-ID-less executable gets a fragile prefs domain
  derived from the process name.

## Architecture

### The narrow waist: normalized metric model

Providers vary in *how* they fetch (HTTP polling, Keychain-sourced OAuth,
local files), so all variance lives below a tiny shared contract:

```swift
enum MetricKind: Codable, Sendable { case rateLimitWindow, spend, quota }
enum MetricUnit: Codable, Sendable { case percent, usd, tokens, requests }

struct MetricWindow: Codable, Sendable {
    var duration: TimeInterval?   // e.g. 5h, 7d
    var resetsAt: Date?
}

struct UsageMetric: Codable, Sendable, Identifiable {
    var id: String                // stable within provider, e.g. "session"
    var label: String             // "Session", "Weekly", "Spend (MTD)"
    var kind: MetricKind
    var used: Double
    var limit: Double?            // nil => open-ended counter (e.g. spend)
    var unit: MetricUnit
    var window: MetricWindow?
}

enum ProviderStatus: Codable, Sendable {
    case ok
    case authRequired(hint: String)   // e.g. "Open Claude Code to refresh login"
    case error(message: String)
}

struct ProviderSnapshot: Codable, Sendable {
    var providerID: String
    var fetchedAt: Date
    var status: ProviderStatus
    var metrics: [UsageMetric]
}

protocol UsageProvider: Sendable {
    var id: String { get }
    var descriptor: ProviderDescriptor { get }  // display name, symbol, tint
    var refreshInterval: TimeInterval { get }
    func fetchSnapshot() async throws -> ProviderSnapshot
}
```

Model conventions (all providers and the UI must agree):

- **No provider-specific fields ever enter the shared model.** A provider
  needing richer display emits more metrics, not new fields.
- For `unit == .percent`, `limit` is always `100`.
- `limit == nil` renders as a plain counter row (value + window label): no
  bar, no color escalation, never eligible for the menu bar title.
- `UsageMetric.id` is only provider-unique; cross-provider UI iteration keys
  on `providerID + metric.id`.
- Everything is `Sendable` from day one — these types cross the
  RefreshEngine-actor → MainActor boundary constantly.

### App skeleton

```
tokmon/
├── Package.swift                     # SwiftPM executable target, macOS 14
├── Sources/tokmon/
│   ├── TokmonApp.swift               # @main, MenuBarExtra(.window), .accessory policy
│   ├── Core/
│   │   ├── Model.swift               # metric model above
│   │   ├── ProviderRegistry.swift    # instantiates enabled providers
│   │   ├── RefreshEngine.swift       # actor: loops, backoff, dedup, wake
│   │   ├── SnapshotCache.swift       # last-known-good persisted to disk
│   │   ├── SettingsStore.swift       # explicit JSON, no UserDefaults
│   │   ├── AppState.swift            # @MainActor ObservableObject
│   │   └── SecurityCLI.swift         # keychain via /usr/bin/security
│   ├── UI/
│   │   ├── MenuContentView.swift     # provider sections
│   │   ├── MetricGaugeRow.swift      # THE universal component
│   │   ├── MenuBarLabel.swift        # compact title logic
│   │   └── SettingsView.swift        # enable providers, enter API keys
│   └── Providers/
│       ├── ClaudeSubscription/
│       ├── AnthropicAPI/
│       └── Codex/
└── docs/
```

Key behaviors:

- **RefreshEngine** (actor): one loop per enabled provider at its own cadence;
  exponential backoff on failure (2x up to 30 min); refresh-on-menu-open via
  the window content's `onAppear` (debounced ≥15s). **Per-provider in-flight
  dedup**: concurrent refresh requests coalesce onto the running task, and a
  result older than the last published `fetchedAt` is dropped. Observes
  `NSWorkspace.didWakeNotification` and network-path restoration
  (`NWPathMonitor`) to trigger an immediate refresh-all — sleeping `Task`
  loops don't fire overnight, and the first post-wake fetch usually fails.
- **Countdowns are computed, not fetched**: "resets in 2h 14m" derives from
  `resetsAt` on a UI timer, so it stays correct even when data is stale.
- **SnapshotCache**: on launch and on fetch failure, show last-known-good
  with an "as of 11:04" staleness note — a network blip or auth lapse must
  never blank the widget. `authRequired` shows the hint *alongside* cached
  gauges, not instead of them.
- **Menu bar title**: the most-constrained `rateLimitWindow` metric across
  providers (e.g. `72%`), color-escalated (normal → orange ≥70% → red ≥90%).
  If that metric's provider is in `authRequired`/`error`, show the cached
  value dimmed with a `!` marker rather than dropping it. Configurable later.
- **Secrets**: Claude Code's Keychain item is read-only to us (query by
  service `Claude Code-credentials` only — account is the local username,
  don't hardcode it). tokmon-owned keys live under service `tokmon`. Nothing
  secret in JSON files.
- **Build/run**: pure SwiftPM (`swift run`),
  `NSApp.setActivationPolicy(.accessory)` in code. Settings opens via
  `SettingsLink` + `NSApp.activate(ignoringOtherApps: true)`.

## Phases

### Phase 1 — Core skeleton + universal UI (mock provider)
- [x] `git init`; SwiftPM executable package, macOS 14 minimum.
- [x] Domain model + conventions, `UsageProvider` protocol, `ProviderRegistry`.
- [x] `RefreshEngine` actor: backoff, in-flight dedup, menu-open refresh,
  wake/network-restore refresh.
- [x] `SnapshotCache` + `SettingsStore` (JSON in Application Support).
- [x] `MenuBarExtra(.window)` with `MetricGaugeRow` (gauge, counter, and
  stale/error variants), timer-driven countdowns.
- [x] `MockProvider` emitting all metric kinds/states to exercise the UI.
  (Plus `MockDegradingProvider`: succeeds once then reports authRequired,
  exercising the cached-gauges-with-hint path and degraded headline.)
- [x] README.

**Exit criteria:** menu bar shows mock gauges with live countdowns; mock
error/auth modes show stale-with-timestamp and hint text, never blanks;
title escalates color at thresholds.

### Phase 2 — Claude subscription provider
- [x] Read Claude Code OAuth credentials via `security find-generic-password
  -s "Claude Code-credentials" -w`; parse `claudeAiOauth.accessToken` /
  `expiresAt`. Confirmed: reads work without prompts across rebuilds.
- [x] Endpoint verified empirically (HTTP 200): the response's `limits`
  array is the general source (session / weekly_all / weekly_scoped with
  model display names) and is preferred; `five_hour`/`seven_day` kept as
  fallback. Timestamps have fractional seconds — custom ISO8601 decoding.
  Also present: `spend`/`extra_usage` credits (mapped to an Extra credits
  metric when used > 0).
- [x] Map to metrics: Session, Weekly, Weekly (per-model scoped), Extra
  credits. Unknown limit kinds render with a humanized label, not dropped.
- [x] Expired/absent token → `.authRequired`, cached gauges retained;
  tokens never refreshed/written. Token lifetime observed ~4.7h remaining
  at check — Claude Code keeps it fresh while in use.
- [x] Poll every 5 min.

**Risks:** undocumented endpoint may change shape or gain stricter client
checks; token replay from a non-Claude-Code client is gray-area — mitigated
by low cadence and read-only use. JSONL parsing (ccusage-style) is the noted
fallback, out of scope for v1.

**Exit criteria:** gauges match Claude Code's `/usage` output; deleting the
Keychain item (test copy) yields authRequired with cached gauges intact.

### Phase 3 — Anthropic API spend provider
- [x] Settings field for an Admin API key → stored via `security
  add-generic-password` under service `tokmon`.
- [x] Cost report via Admin API (`/v1/organizations/cost_report`) — contract
  verified against current docs: amounts are decimal strings in cents,
  daily buckets only, has_more/next_page pagination, ~5 min data lag.
  Caveat found: Admin API is unavailable for individual accounts.
- [x] Metrics: USD month-to-date (counter, no limit). Poll every 15 min.
- [x] Action item doc: `docs/action-items/001-create-anthropic-admin-key.md`.

**Exit criteria:** MTD USD matches the console cost page within expected
data lag.

### Phase 4 — Codex/ChatGPT provider (exploratory)
- [x] Investigated: option (b) won — Codex CLI persists `rate_limits`
  (used_percent, window_minutes, resets_at) in token_count events inside
  `~/.codex/sessions/**/rollout-*.jsonl`. No token replay needed. Freshness
  is "as of last Codex turn"; snapshot fetchedAt uses the event timestamp
  so staleness display stays honest.
- [x] Implemented provider mapping primary/secondary windows to metrics
  (300 min → Session, 10080 min → Weekly, generic fallback for others).
- [x] Findings documented in `docs/guides/codex-data-sources.md`.
  Verified live: Weekly 31% matching the newest session file.

**Risks:** highest reverse-engineering uncertainty; explicitly allowed to
land after Phase 5 if blocked.

**Exit criteria:** either working session/weekly gauges cross-checked against
Codex CLI `/status`, or the documented-findings fallback.

### Phase 5 — Polish
- [ ] Settings: enable/disable providers, per-provider config, menu bar
  title metric override.
- [ ] Launch at login: install/remove a launchd agent plist in
  `~/Library/LaunchAgents/com.matthew.tokmon.plist` pointing at the built
  binary (SMAppService needs an app bundle we don't have).
- [ ] Manual refresh button + "last updated" per provider.
- [ ] Final README pass; move this plan to `docs/plans/completed/`.

**Exit criteria:** app relaunches at login and repopulates from cache before
the first fetch completes.

## Out of scope (v1)

- OpenAI API spend provider (protocol makes it easy to add later).
- Notifications/alerts on threshold crossing.
- Historical charts, JSONL-derived per-project cost breakdowns.
- App bundle / signing / notarization / Sparkle / Homebrew (bundle wrapper is
  the named fallback if bundle-less papercuts accumulate).

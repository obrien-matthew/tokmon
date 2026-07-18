# tokmon

A macOS menu bar app that tracks AI provider usage limits at a glance:
Claude subscription session (5h) and weekly limits, Anthropic API spend,
and Codex/ChatGPT rate limits.

The menu bar title shows the single most-constrained rate-limit percentage
across all providers, color-escalated (orange at 70%, red at 90%; note that
macOS may render menu bar labels as monochrome templates — a `!` prefix is
the reliable marker that the shown value is cached from a degraded provider).
Opening the menu shows per-provider gauges with reset countdowns.

## Providers

- **Claude subscription** — session (5h), weekly, and model-scoped weekly
  limits, plus extra-usage credits. Reads Claude Code's OAuth credentials
  from the Keychain (read-only; tokmon never refreshes or writes tokens)
  and polls the same usage endpoint `/usage` reads, every 5 minutes.
- **Codex** — session/weekly rate limits parsed from the rate-limit
  snapshots Codex CLI persists in `~/.codex/sessions` transcripts. Data is
  as fresh as your last Codex turn; the UI shows its actual age. See
  `docs/guides/codex-data-sources.md`.
- **Anthropic API** — month-to-date USD spend via the Admin cost report
  API. Needs an Admin API key (organization accounts only) entered in
  Settings; see `docs/action-items/001-create-anthropic-admin-key.md`.
- **Mocks** — two dev providers (disabled by default, toggleable in
  Settings) exercising every metric kind and the degraded/stale paths.

Settings also cover per-provider enable/disable, a menu bar title override
(pin one provider instead of auto most-constrained), and launch at login
(a launchd agent plist, since a bare SwiftPM executable can't use
SMAppService).

## Build and run

Requires macOS 14+ and a Swift 6 toolchain (Xcode or CLT).

```sh
swift run
```

The app runs as a menu bar accessory (no Dock icon). Quit from the menu.
State lives in `~/Library/Application Support/tokmon/` (snapshot cache and
settings, both plain JSON).

## Architecture

Every provider maps its own data source (HTTP APIs, Keychain-sourced OAuth,
local files) into a small shared metric model, and the UI renders that model
blindly — one gauge component serves all providers, and adding a provider
means writing one fetcher, zero UI.

```
Sources/tokmon/
├── TokmonApp.swift        MenuBarExtra(.window), accessory activation
├── Core/
│   ├── Model.swift        UsageMetric / ProviderSnapshot / UsageProvider
│   ├── RefreshEngine.swift  actor: per-provider polling loops, exponential
│   │                        backoff, in-flight dedup, wake + network-restore
│   │                        refresh, refresh-on-menu-open (debounced)
│   ├── SnapshotCache.swift  last-known-good persisted; failures republish
│   │                        cached metrics under a degraded status so the
│   │                        widget never goes blank
│   ├── SettingsStore.swift  explicit JSON (no UserDefaults — bundle-ID-less)
│   ├── ProviderRegistry.swift
│   └── AppState.swift     MainActor store + menu bar headline selection
├── UI/                    MetricGaugeRow is the single universal component
└── Providers/             one directory per provider
```

Model conventions: `.percent` metrics always have `limit: 100`; `limit: nil`
means an open-ended counter (rendered without a bar, never the headline);
countdowns are computed client-side from `resetsAt` so they stay correct
while data is stale.

## Adding a provider

Write one type conforming to `UsageProvider` (identity, refresh interval,
`fetchSnapshot()` mapping your data source into `UsageMetric`s), add it to
`ProviderRegistry.allProviders()`. The UI, refresh scheduling, caching, and
degraded-state handling come for free. Model conventions to respect: percent
metrics use `limit: 100`; `limit: nil` means an open-ended counter; throw
`ProviderError.authRequired(hint:)` for credential problems so cached gauges
stay visible with a hint.

## Future ideas

- OpenAI API spend provider
- Notifications on threshold crossing
- Historical charts / per-project cost breakdowns (Claude Code JSONL)
- App bundle + signing for distribution

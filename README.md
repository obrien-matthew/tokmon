# tokmon

A macOS menu bar app that tracks AI provider usage limits at a glance:
Claude subscription session (5h) and weekly limits, Anthropic API spend,
and Codex/ChatGPT rate limits.

The menu bar title shows the single most-constrained rate-limit percentage
across all providers, color-escalated (orange at 70%, red at 90%; note that
macOS may render menu bar labels as monochrome templates — a `!` prefix is
the reliable marker that the shown value is cached from a degraded provider).
Opening the menu shows per-provider gauges with reset countdowns.

## Status

Phase 1 complete: core engine, universal UI, mock providers. Real providers
(Claude subscription, Anthropic API spend, Codex) are next — see
`docs/plans/active/`.

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

## Roadmap

- Claude subscription provider (Claude Code OAuth credentials from Keychain,
  read via the `security` CLI; authoritative session/weekly percentages)
- Anthropic API spend provider (Admin API cost report)
- Codex/ChatGPT provider (exploratory)
- Settings polish, launch at login (launchd agent)

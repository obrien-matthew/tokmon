# Codex data sources

Findings from the Phase 4 investigation and the live-endpoint follow-up
(both 2026-07-18), for future maintenance of the Codex provider.

## What tokmon uses first: the live usage endpoint

`GET https://chatgpt.com/backend-api/wham/usage` with headers:

- `Authorization: Bearer <tokens.access_token from ~/.codex/auth.json>`
- `ChatGPT-Account-Id: <tokens.account_id>`
- any User-Agent (verified: a tokmon UA is accepted; no spoofing needed)

Endpoint and headers were confirmed against the open Codex CLI source
(`codex-rs/backend-client/src/client/rate_limit_resets.rs`): path is
`{base}/wham/usage` for chatgpt.com's `/backend-api` base (the
`/api/codex/usage` form is for the other path style). Response carries
`rate_limit.primary_window` / `secondary_window` with `used_percent`,
`limit_window_seconds` (604800 = weekly, 18000 = 5h), `reset_at` (unix
seconds), plus plan/credits fields tokmon ignores.

Token posture matches the Claude provider: read-only use of the CLI's
stored token, never refreshed or written (access tokens observed lasting
several days; Codex CLI refreshes them on use). Any live failure falls
back to session file parsing below.

## Fallback: session file parsing

Codex CLI persists rate-limit snapshots in its session transcripts:

- Location: `~/.codex/sessions/**/rollout-*.jsonl`
- Each turn emits a line with `type: "event_msg"`, `payload.type:
  "token_count"`, whose `payload.rate_limits` contains:
  - `primary` / `secondary`: `{used_percent, window_minutes, resets_at}`
    where `window_minutes` 300 = 5h session, 10080 = weekly, and
    `resets_at` is unix seconds
  - `plan_type` (e.g. "plus"), `credits`, `limit_id`
- tokmon scans the 5 newest files (by mtime) and takes the last matching
  line — the freshest snapshot on disk.

Freshness caveat: this is data *as of the last Codex turn*. The provider
sets the snapshot's `fetchedAt` to the event timestamp so the UI's
staleness label stays truthful.

## History

The v1 provider was file-only (token replay initially rejected as
undocumented-endpoint risk). Went live-first once the endpoint contract
was verified against the Codex source — stale file data understated
nothing but could overstate usage by a full day of decay.

## Fragility notes

- The JSONL schema is Codex-internal and may change between CLI versions;
  the decoder treats every field as optional.
- Older session files may predate rate-limit reporting; the scanner falls
  through up to 5 files before reporting "no data".

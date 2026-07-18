# Codex data sources

Findings from the Phase 4 investigation (2026-07-18), for future maintenance
of the Codex provider.

## What tokmon uses: session file parsing

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

## What was considered and rejected

- **Replaying the ChatGPT OAuth token** from `~/.codex/auth.json`
  (`tokens.access_token`, `auth_mode: "chatgpt"`) against whatever backend
  endpoint Codex's `/status` uses. Rejected for v1: undocumented endpoint,
  token handling risk, and the local files already contain the same
  percentages. Revisit if freshness between Codex sessions matters.

## Fragility notes

- The JSONL schema is Codex-internal and may change between CLI versions;
  the decoder treats every field as optional.
- Older session files may predate rate-limit reporting; the scanner falls
  through up to 5 files before reporting "no data".

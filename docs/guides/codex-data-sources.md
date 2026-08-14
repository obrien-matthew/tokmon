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
seconds), plus plan and credits fields.

The top-level `credits` object supplies `has_credits`, `unlimited`, and a
decimal-string `balance`. Tokmon maps a finite, nonnegative balance to an
open-ended **Credits remaining** metric. A reported zero is shown even when
`has_credits` is false; unlimited balances are omitted because the universal
metric model is numeric. This is a remaining balance, not cumulative spend.

Token posture matches the Claude provider: read-only use of stored
tokens, never refreshed or written. Credentials are tried in order:

1. `~/.codex/auth.json` (`tokens.access_token` + `tokens.account_id`) —
   Codex CLI's copy, refreshed by the CLI on use.
2. oh-my-pi's credential store, `~/.omp/agent/agent.db` (SQLite, WAL),
   table `auth_credentials`, row `provider = 'openai-codex'`,
   `credential_type = 'oauth'`; the JSON `data` column carries `access`,
   `accountId`, and `expires` (epoch ms). Verified live 2026-08-14 that
   the wham/usage endpoint accepts omp-minted tokens (HTTP 200, same
   response shape). Read via `OmpCredentialStore`; expired rows are
   skipped, and any read failure (missing db, busy WAL checkpoint,
   schema drift) just drops the candidate.

Any live failure with every candidate falls back to session file
parsing below.

## Fallback: session file parsing

Codex CLI persists rate-limit snapshots in its session transcripts:

- Location: `~/.codex/sessions/**/rollout-*.jsonl`
- Each turn emits a line with `type: "event_msg"`, `payload.type:
  "token_count"`, whose `payload.rate_limits` contains:
  - `primary` / `secondary`: `{used_percent, window_minutes, resets_at}`
    where `window_minutes` 300 = 5h session, 10080 = weekly, and
    `resets_at` is unix seconds
  - `plan_type` (e.g. "plus"), `credits`, `limit_id`; the same remaining
    credits metric is emitted from this fallback data
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
- The `agent.db` schema is omp-internal and may change between omp
  versions; `OmpCredentialStore` treats every field as optional and any
  failure means "no omp credential", never an error.
- Nothing enforces that omp is signed into the same ChatGPT account as
  Codex CLI; a fallback fetch would report the omp account's usage.

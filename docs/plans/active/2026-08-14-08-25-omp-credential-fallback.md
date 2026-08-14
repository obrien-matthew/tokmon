# oh-my-pi credential fallback for Claude and Codex providers

Status: awaiting approval

## Problem

Both tokmon providers poll account-level usage endpoints, so tokens burned
through any harness (Claude Code, Codex CLI, oh-my-pi) already move the
gauges. But tokmon's only credential sources are Claude Code's Keychain
item and Codex CLI's `~/.codex/auth.json`. A user working mainly in
oh-my-pi (omp) lets those tokens expire unused, and tokmon dims to
authRequired even though omp holds fresh tokens for the same accounts.

omp stores its own OAuth credentials in
`~/.omp/agent/agent.db` (SQLite, WAL mode), table `auth_credentials`:

- `provider` = `anthropic` | `openai-codex`, `credential_type` = `oauth`
- `data` = JSON: `access` (token), `accountId` (36-char UUID, needed for
  the `ChatGPT-Account-Id` header), `expires` (epoch **milliseconds**),
  plus `refresh`/`email`/`orgId` which tokmon must never touch.

Verified on this machine 2026-08-14: both rows present, same account
identity as the CLI credentials, `expires` is an integer in ms.
**Endpoint acceptance verified live 2026-08-14** (review finding): both
`api.anthropic.com/api/oauth/usage` and
`chatgpt.com/backend-api/wham/usage` return HTTP 200 for omp-sourced
tokens, with the same response shapes tokmon already decodes
(`five_hour`/`seven_day`/`limits`/`spend`; `rate_limit.primary_window`/
`secondary_window` + `credits`). No scope/client-provenance rejection.

## Approach

Add a read-only omp credential source and make each provider try an
ordered list of credential candidates instead of a single hardcoded one.
Same posture as existing sources: tokmon never refreshes or writes
tokens, never reads refresh tokens into memory beyond JSON decode.

Ordering: CLI/Keychain credential first (existing behavior preserved),
omp second. Both are expiry-checked up front; an HTTP 401/403 with one
candidate advances to the next instead of failing the fetch.

SQLite access via the system `SQLite3` C module (ships with macOS; no
new SwiftPM dependency). Open with `SQLITE_OPEN_READONLY`. The db is
WAL-mode: even a read-only connection must be able to write the `-shm`
index file, which works here because all three files are user-owned;
if it ever can't, the open fails and we degrade. Statement/connection
cleanup (`sqlite3_finalize`, `sqlite3_close_v2`) on every exit path.
Any open/query failure (missing file, `SQLITE_BUSY` mid-checkpoint,
schema drift) degrades to "no omp credential" — never an error surfaced
to the UI, since omp is an optional source.

## Phases

### Phase 1 — OmpCredentialStore

- [ ] `Sources/tokmon/Core/OmpCredentialStore.swift`:
  - `struct OmpOAuthCredential { let accessToken: String; let accountId: String?; let expiresAt: Date? }`
  - `enum OmpCredentialStore { static func credential(provider: String, databaseURL: URL = default) -> OmpOAuthCredential? }`
  - Query: `SELECT data FROM auth_credentials WHERE provider = ? AND credential_type = 'oauth' AND disabled_cause IS NULL ORDER BY updated_at DESC LIMIT 1` (bound parameter; newest row wins if omp ever holds multiple accounts per provider).
  - JSON decode of the `data` column; `expires` ms → `Date`.
  - All failures return nil.
- [ ] Tests (`OmpCredentialStoreTests`): build a fixture SQLite db in a
  temp directory via the same C API, **in WAL mode** (`PRAGMA
  journal_mode=WAL`) so the test exercises the same journal mode as
  production. Cases: valid row, expired vs unexpired ms timestamp,
  missing row, disabled row, multiple rows (newest `updated_at` wins),
  malformed JSON, missing file.

### Phase 2 — Claude provider fallback

- [ ] Refactor `loadAccessToken()` into a candidate list:
  1. Claude Code Keychain token (existing decode + ms-expiry check),
  2. omp `anthropic` credential (skip if `expiresAt` past).
- [ ] `fetchSnapshot()` iterates candidates; 401/403 advances to the
  next candidate; other HTTP errors still throw immediately. All
  candidates exhausted → `authRequired`.
- [ ] Hint precedence when all candidates fail (review finding): if any
  candidate existed but was expired → "Open Claude Code or omp to
  refresh login"; if none were found at all → "Open Claude Code or omp
  to sign in". Never surface a hint naming only one harness.
- [ ] Extract the expiry-check + candidate-ordering logic into a
  testable pure function; unit-test ordering and expiry skipping.

### Phase 3 — Codex provider fallback

- [ ] Parameterize `fetchLive()` with `(token, accountId)`.
- [ ] Candidates: `~/.codex/auth.json` (existing, no expiry field —
  always a candidate when present), then omp `openai-codex` credential
  (has both `access` and `accountId`; skip if expired).
- [ ] Try live fetch per candidate; any live failure falls through to
  the next, then to the existing session-file fallback, then
  `authRequired` with hint mentioning both harnesses.
- [ ] Unit-test candidate assembly (pure function), not the network.

### Phase 4 — Docs and verification

- [ ] README: Providers section — note the omp fallback credential
  source for both providers; Architecture tree gains
  `OmpCredentialStore.swift`.
- [ ] `docs/guides/codex-data-sources.md`: add omp as a second token
  source.
- [ ] Verify: `swift test`; smoke = build + run installed app, confirm
  both providers fetch OK (candidate 1 path). Endpoint acceptance of
  omp tokens was already proven live during planning (both endpoints
  200, see Approach); repeat via a one-off Swift harness that feeds the
  `OmpCredentialStore`-loaded credential through each provider's
  request path and asserts HTTP 200 (never prints tokens).
- [ ] Move plan to `docs/plans/completed/`.

Commit after each phase.

## Risks

- **agent.db schema is omp-internal** and may change; the store treats
  every field as optional and fails soft (mirrors the codex JSONL
  posture, documented in Fragility notes).
- **WAL read-only open**: if omp is mid-checkpoint, `SQLITE_BUSY` is
  possible; handled as "no credential this poll" — next poll retries.
- **Account mismatch across harnesses**: nothing enforces that omp is
  signed into the same account as Claude Code / Codex CLI. If it isn't,
  a fallback fetch reports the *omp* account's usage under the same
  gauge. Accepted limitation, documented in the provider doc comments;
  detecting it would require comparing identities across stores, which
  is out of scope.
- **Politeness under persistent 401**: an unexpired-but-revoked first
  candidate means two usage requests per 5-minute poll (doomed + omp).
  Bounded at 2 requests, only in the 401 path — acceptable for these
  endpoints' cadence guidance; noted in code comment.
- **Token freshness**: tokmon still never refreshes; if the user stops
  using both harnesses, all candidates expire and the existing
  authRequired/degraded UX applies unchanged.

## Non-goals

- No new line item / provider for omp — usage is account-level and
  already reflected.
- No reading of omp's local usage tables (`usage_history`) — redundant
  local accounting.
- No refresh-token use, ever.

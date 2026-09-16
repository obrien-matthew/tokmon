# OpenRouter data sources

How tokmon's OpenRouter provider gets its numbers, and why the balance
has no bar.

## Endpoints

Both are called concurrently on every poll (5 minutes), with the same
bare API key in an `Authorization: Bearer` header. A successfully decoded
response makes the poll `.ok`, even if that response legitimately emits no
metric; the provider only errors when neither endpoint decodes.

### `GET https://openrouter.ai/api/v1/key` — the gauge

```json
{"data":{"limit":25,"limit_reset":"monthly","limit_remaining":0,
         "usage":35.01,"usage_monthly":25.006,"is_free_tier":false}}
```

The metric is `used = limit − limit_remaining`, `limit = limit`.

- That difference, not any `usage_*` field, is what OpenRouter actually
  enforces. The two disagree by rounding: a `usage_monthly` of 25.006
  against a 25 cap renders the self-inconsistent `$25.01 / $25.00`.
- `limit: null` means the key has no spend cap, so no gauge is emitted.
- A positive finite `limit` without a finite `limit_remaining` is an
  incomplete cap payload, so no gauge is emitted rather than inventing an
  unused or exhausted amount.
- The label comes from `limit_reset`: `Key spend (monthly)`,
  `Key spend (lifetime)` when it is null, `Key spend (<value>)` for
  anything unrecognised.
- **No reset countdown.** `limit_reset` names a cadence, not a boundary,
  and nothing in the payload says whether the month is calendar- or
  key-anniversary-based. Every other tokmon countdown is computed from a
  real `resetsAt`; inventing one here would be a lie.

This meter is per-key. Spend through a different key on the same account
does not move it.

### `GET https://openrouter.ai/api/v1/credits` — the balance

```json
{"data":{"total_credits":60,"total_usage":54.561828163}}
```

The balance is exactly `total_credits − total_usage`, including a negative
overdrawn balance, emitted as an open-ended counter (`limit: nil` → text,
no bar), exactly like Codex's credit line.

Both figures are **lifetime cumulative**, which is why there is no bar:
`1 − balance / total_credits` drifts toward 100% purely as a function of
account age. $50 left of $100 purchased reads 50%; the same $50 left of
$600 purchased reads 92%. A gauge that reddens as you buy more credit
would devalue the escalation colours on every other provider's row, so
the number is shown plainly instead.

The docs describe this route as management-key-only, but ordinary
inference keys are accepted today. A 403 here is a soft failure when the
key endpoint decodes successfully; then its cap gauge stands alone.

## Credentials

Resolved in order, read-only, never written or rotated:

1. **oh-my-pi** — `~/.omp/agent/agent.db`, table `auth_credentials`,
   `provider = 'openrouter'`, `credential_type = 'api_key'`, payload
   `{"key": "sk-or-v1-…"}`. Shares the read-only SQLite path with the
   OAuth credentials the Claude and Codex providers use; the
   `credential_type` filter keeps the two readers apart.
2. **Keychain** — a generic password under service `tokmon-openrouter`,
   read through the `security` CLI (the same signature-stable path the
   Claude provider uses). Create it with:

   ```sh
   security add-generic-password -s tokmon-openrouter -a openrouter -w
   ```

There is deliberately no `OPENROUTER_API_KEY` environment tier: an app
launched from Finder or launchd inherits no shell environment, so it
would appear to work under `swift run` and silently fail once installed.

With no key resolvable, the provider throws `authRequired` before making
any network call, and the menu shows the hint with cached gauges intact.

## Status semantics

| Situation | Result |
| --- | --- |
| No key found anywhere | `authRequired`, no request made |
| At least one endpoint decodes successfully | `.ok` with the metrics its decoded payloads can emit, including none |
| Neither endpoint decodes, either returned 401 | `authRequired` |
| Neither endpoint decodes otherwise | error; `RefreshEngine` republishes cached metrics as degraded |

## Live smoke

`OmpLiveSmokeTests.testOpenRouterEndpointsAcceptOmpAPIKey` exercises the
real key against both endpoints:

```sh
TOKMON_LIVE_SMOKE=1 swift test --filter testOpenRouterEndpointsAcceptOmpAPIKey
```

It skips without `TOKMON_LIVE_SMOKE=1` or an omp key, and independently
asserts HTTP 200 plus the documented `data` envelope for both `/credits`
and `/key`; it does not assert moving amounts or infer endpoint health from
emitted metrics.

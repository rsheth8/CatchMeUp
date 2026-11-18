# CatchMeUp API

The hosted side of "CatchMeUp Cloud": the app signs in with Apple or Google, and
this service runs recap requests on our Anthropic key inside per-user and global
spend limits. It is a Cloudflare Worker with a D1 (SQLite) database. It stores no
transcripts.

Status: **scaffold**. Sign-in, quotas, metering and the recap endpoint are built
and tested. Not built yet: App Store subscription events (the `subscriptions`
table is ready for them), App Attest, and the iOS client. See "What is left".

## Endpoints

| Method and path | Purpose |
|---|---|
| `GET /health` | Liveness, no database. |
| `POST /v1/auth/apple` | `{idToken, nonce}` from Sign in with Apple. Returns `accessToken` (1 hour), `refreshToken` (90 days, sliding), `user`. |
| `POST /v1/auth/google` | Same, for Google. |
| `POST /v1/auth/refresh` | `{refreshToken}` returns a new `accessToken`. |
| `POST /v1/auth/logout` | `{refreshToken}` revokes it. |
| `GET /v1/me` | `{user, quota: {plan, recapsRemaining, resetsAt}}`. |
| `DELETE /v1/me` | Deletes the account (App Store requirement). Reports if a subscription is still running. |
| `POST /v1/recap` | `{task, system, user, maxTokens?}` returns `{text, quota}`. Bearer token required. |

Errors are `{error: {code, message, ...}}`. The ones the app should handle:

| Status and code | Meaning | App should |
|---|---|---|
| 402 `quota_exceeded` | Out of recaps this month (`plan`, `resetsAt` included). | Show the paywall (free) or the reset date (Plus). |
| 429 `rate_limited` / `request_in_flight` | Too fast, or another request is running. | Wait and retry. |
| 503 `service_busy` | The global daily budget is used up. | Offer on-device mode. |
| 503 `model_busy` | The provider is overloaded. | Retry shortly. |
| 413 `input_too_large` | Prompt over `MAX_INPUT_CHARS`. | Split the recording. |
| 422 `refused`, 502 `truncated` / `upstream_error` | The call produced nothing usable. No recap is used up. | Offer retry. |
| 401 `unauthorized` | Token missing, expired or account deleted. | Refresh, then sign in again. |

## How the limits work

Every model call goes through one gate, `reserve()` in `src/ledger.ts`, before the
provider is contacted:

1. The server picks the model, effort and output ceiling. The caller supplies only
   prompt text, and `model` or sampling fields in a request are ignored.
2. A single SQL statement checks all of these and takes a worst-case reservation
   (input estimated at 2.5 characters per token, output at the full `max_tokens`):
   the user's monthly dollar budget, the user's monthly recap count, the global
   daily budget, and a per-minute request rate. Being one statement, two
   simultaneous requests cannot both squeeze under the same limit.
3. After the call, the reservation is replaced with the real cost from the
   provider's usage numbers. A call that fails costs no recap, but any tokens it
   billed (a cut-off reply, a refusal) still count as spend.
4. Usage is always summed from the `ledger` table, never kept in counters, so it
   cannot drift. A reservation from a request that died stops counting after 10
   minutes.

Plans live in `src/plans.ts`:

| | Recaps / month | Budget / month |
|---|---|---|
| free | 3 | $0.40 (safety net) |
| plus | 200 (sanity ceiling) | $3.70 |

Plus is $6.99, about $5.94 after Apple's 15% (Small Business Program, which needs
enrolling in). The default model averaged about $0.037 a recap in `ios/Bench`.

Layers, from the outside in: the Anthropic Console spend limit (the one hard cap
that holds even if this code is wrong), `GLOBAL_DAILY_BUDGET_USD`, the per-user
plan limits, then the per-minute rate. Misconfiguration fails closed: an unpriced
model, a missing key or a non-positive limit returns 500 instead of serving
unmetered.

## Setup

```bash
cd backend
npm install            # Node 20+
npm test               # 74 tests in the real Workers runtime, no network
npm run typecheck
npm run e2e            # local Worker + local database, model stubbed
```

A real call through the local Worker (one recording, about half a cent), with the key
read from the Keychain and never printed:

```bash
ANTHROPIC_API_KEY="$(secret get ANTHROPIC_API_KEY)" npm run e2e -- --live
```

First deploy:

1. `npx wrangler login`, then `npx wrangler d1 create catchmeup` and put the printed id in `wrangler.toml`.
2. `npm run migrate:remote`
3. In the Anthropic Console, create a **separate workspace and key for this service** and set a monthly spend limit on it. Do not reuse the benchmark key.
4. `npx wrangler secret put ANTHROPIC_API_KEY` and `npx wrangler secret put SESSION_SECRET` (use `openssl rand -base64 48`).
5. Set `GOOGLE_AUDIENCE` to the iOS OAuth client id (`GIDClientID` in `ios/CatchMeUp/Info.plist`, currently a placeholder).
6. `npx wrangler deploy`
7. Add a Cloudflare notification for Worker error rate, and watch the `recap_refused` log events with `reason: service_busy`.

## Choosing the model

`RECAP_MODEL` in `wrangler.toml` sets it for everyone. It must have a price in
`src/pricing.ts`; prices are the ones the benchmark used, so check them against
Anthropic's pricing page before launch. Haiku 5.5 is deliberately not in the table
until its price is verified, so selecting it fails closed.

## Decisions to confirm

- **Identity is stored as a hash.** `users.identity_hash` is SHA-256 of
  `provider:subject`; the raw Apple or Google id is never stored. The email is kept
  only while the account exists.
- **Deleting an account keeps a hashed tombstone** (hash, usage ledger, no email) so
  that deleting and signing back in cannot reset the free quota. Signing in again
  reactivates the same account. The privacy policy has to say this.
- **Refresh tokens are not rotated.** Rotation can lock a phone out when a request is
  retried after a dropped connection. The cost is that a stolen refresh token works
  until it expires or the user logs out. App Attest (below) is the planned answer.
- **Apple and Google sign-ins are separate accounts**, so one person can hold two
  free quotas. Acceptable at 3 recaps; revisit if abused.
- **No request bodies are logged.** Logs hold event names, plan, token counts and
  request ids only. A test asserts the key, tokens and transcript text never appear.

## What is left

1. **iOS client** (`HostedRecapEngine`, sign-in token exchange with a nonce, quota UI, paywall, error states). The app currently sends no nonce, and the server requires one.
2. **Subscriptions.** StoreKit 2 products, then App Store Server Notifications V2 into `subscriptions` (JWS signature verification, renewals, refunds, grace periods).
3. **App Attest**, to bind free quota to a genuine install and make farming accounts expensive.
4. **Privacy.** Transcripts now leave the device. The privacy policy, App Privacy answers, `PrivacyInfo.xcprivacy` and in-app wording must change before any public build.
5. **Alerting** on daily spend (Cloudflare notification or a scheduled Worker that emails when spend passes a threshold).

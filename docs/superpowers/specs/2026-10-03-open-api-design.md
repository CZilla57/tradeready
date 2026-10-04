# Read-Only Open API (Roadmap Phase 23) — Design Spec

**Date:** 2026-10-03
**Status:** SCOPED. Builds on `feat/open-api`, stacked on the build-order branches before it (#1–#10, ending with `feat/calendar-sync`). Owner go-ahead 2026-10-03: "continue working until all features on the roadmap are properly completed … implemented in the most beneficial way to the user". Code map verified 2026-10-03 against the `feat/quote-expiration` working tree, where Phase 32 is uncommitted. Nothing built.
**Origin:** `docs/post-launch-feature-roadmap.md` Phase 23, build order #11
**Builds on:** portal completion (`2026-08-07-portal-completion-design.md`: server-owned token table, allowlist assembly, access log), accountant package (`2026-08-07-accountant-package-design.md`: field mappings and the "no secrets, no paths" rule), the `updated_at` server-clock migration, the portal-admin RPC pattern
**Build target:** the Worker, the native SwiftUI app, and one docs page in `CZilla57/tradeready-legal`. **No React Native changes. One migration file, which the owner applies. No deploys.**

## 0. Preconditions verified against the repo

`N/` means `native/TradeReadyNative/`.

**Worker**
- Routing is Hono with no global middleware. Each route owns its CORS, auth and rate limit (`backend-workers/src/index.js:16-18`). Routes use `app.all` with in-handler method checks (`:5-8`, `:61-104`). Anything unmatched is a JSON 404 (`:107`).
- The only owner credential any route accepts is a Supabase session JWT, checked per route against `/auth/v1/user` (`backend-workers/src/routes/estimate/portalManage.js:20-34`, `backend-workers/src/routes/booking/mint.js:24-31`). Nothing accepts a long-lived owner credential, and nothing under `/v1/` exists.
- Rate limiting is an in-memory sliding window per isolate (`backend-workers/lib/guards.js:4-14,19-40`). Durable caps exist only for AI usage and portal requests (`countTodayRequests`, `backend-workers/lib/estimate/portalRequestStore.js:74-85`).
- **IP keying is spoofable.** `clientIp` takes the first `x-forwarded-for` entry before `cf-connecting-ip` (`backend-workers/src/appCors.js:33-37`). Cloudflare appends to an incoming `X-Forwarded-For` rather than replacing it, and `CF-Connecting-IP` is the single edge-observed client address ([Cloudflare HTTP headers](https://developers.cloudflare.com/fundamentals/reference/http-headers/)). A caller can therefore choose the first XFF entry. The API never keys a limit on IP and logs `cf-connecting-ip` only. Fixing the existing routes is out of scope here (§12).
- **Capability-token precedent.** `portal_tokens` stores SHA-256 hashes only, and the raw token appears exactly once (`supabase/migrations/20260807_portal_tokens.sql:1-25`, `backend-workers/lib/estimate/portalTokenStore.js:1-14,26-28`). A known but revoked hash is a hard stop (`portalTokenStore.js:137-146`), and revocation is one-way (`:61-73`). Admin operations are one transactional RPC with an advisory lock and operation replay (`supabase/migrations/20260922_portal_token_admin.sql:9-21,34-56`).
- **Security-log precedent.** `portal_access_log` stores an 8-character token prefix, never a token (`supabase/migrations/20260807_portal_access_log.sql:1-24`), written best-effort (`portalRequestStore.js:62-72`, `backend-workers/src/routes/estimate/portalView.js:72-73`).
- **Allowlist precedent.** The portal builds explicit whitelisted objects, never a cleaned copy (`portalView.js:4-9`). `buildInvoices` (`backend-workers/lib/estimate/portalAssemble.js:144-178`) shows a payment link only when it is current and on an allowlisted host (`:149-160`, `backend-workers/lib/reminderEmail.js:27-37`). `__tests__/portalAssembleWorkers.test.js:86-98` pins exact keys.

**Data**
- Business data is blob rows `{id text primary key, user_id, data jsonb, updated_at, deleted}` (template `supabase/migrations/20260803_local_collections_sync.sql:18-24`). The dashboard-created core tables (jobs, invoices, customers, expenses, settings) are RLS owner-scoped (`supabase/migrations/verify/rls-policies-snapshot-2026-08.txt`). Mileage is the `trips` table (`20260803_local_collections_sync.sql:52-58`).
- `updated_at` is stamped by the database clock on every insert and update of every sync table (`supabase/migrations/20260831_updated_at_server_authority.sql:55-68,85-90`). It is a valid keyset and change watermark.
- Device deletes are soft `deleted = true` updates (`N/NativeSupabasePush.swift:458`), so tombstones exist for consumers.
- Field inventory (`N/Domain/CanonicalModels.swift`): Job `:943-973`, Invoice `:1208-1226`, Payment `:1154-1161`, Customer `:1253-1275`, Expense `:1292-1302`, Trip `:1343-1352`, EstimateApproval `:672-679`, Settings `:1626-1655`. Fields that must never leave:
  - Job: `notes`, `laborRate`, `laborHours`, `laborBreakdown`, `materials`, `materialMarkup`, `jobCosts`, `overhead`, `margin`, `timeSessions`, `photos` (local paths), `quoteOptions` (carries add-on `cost`, `:767`), and `approval.token` / `ip` / `userAgent`.
  - Customer: `notes`, `portal.token`, `importBatchId`.
  - Invoice: `autoEmailRequestedAt`, `importBatchId`, `paymentLinkAmount`.
  - Expense: `notes`, `receiptUri` (a local path).
  - Settings: everything except `businessName`. The blob carries `anthropicKey`, `groqKey`, `providerKey(s)`, `bookingLink.token` and `pushToken` (`:1635-1649`).
- Later phases add more secrets to the same blobs, for example referral codes on the customer (`2026-10-03-referral-program-design.md` §2). Sanitizing a copy would leak each new one until someone remembered to strip it. An allowlist excludes them by default.
- Payment `method` is a free string. RN's union is `stripe|cash|check|card|other` (`types/models.ts:436`). Native writes display strings and `bank_transfer` (`N/Models.swift:249-256`, `N/Domain/FinancialDomain.swift:342-344`). The accountant package derives the source from the id prefix (`N/Domain/NativeAccountingPackage.swift:70-74`).
- PostgREST runs every GET and HEAD in a READ ONLY transaction ([PostgREST transactions](https://docs.postgrest.org/en/stable/references/transactions.html), "Access Mode"). Reads issued as PostgREST GETs cannot write, whatever key they carry.

**Native**
- Settings destinations are an enum plus grouped rows (`N/SettingsView.swift:4-8,43-63`).
- `NativePortalAdministrationService` is the client pattern for a JWT-authed, server-owned capability manager, including operation ids and the refresh retry (`N/NativePortalAdministration.swift:115-186`).

## 1. Recommendation

Build it, as a small and boring v1:

1. **Owner-issued API keys**, hashed at rest, scoped, expirable, and revocable on the next request. This mirrors `portal_tokens`. **No OAuth in v1**: there is no third-party app ecosystem to delegate to yet, and OAuth needs a consent screen, client registration and refresh tokens for no present user.
2. **Seven read resources** (customers, jobs, estimates, invoices, payments, expenses, mileage) plus `/v1/account`. Each is an explicit allowlist built by one pure mapper per resource. The mappers are shared with Phase 17 if it is ever revived.
3. **Incremental sync is the main use case.** Every list is keyset-paginated on the DB-clock `updated_at`, accepts `updated_since`, and returns tombstones for deleted records. That is exactly what Zapier-style polling and an accountant's sync job need.
4. **Freshness honesty.** Every response carries `dataAsOf`, the newest server `updated_at` the owner has. The docs say plainly that the API shows the cloud copy as of the owning device's last sync.
5. **Read-only as an invariant, enforced three ways:** GET-only routes, a data module that can only issue PostgREST GETs (READ ONLY transactions), and a test that fails on any non-GET to a business table.

Key management lives in the app (Settings → API access). Documentation is a static page plus an OpenAPI document generated from the same field lists the mappers use.

## 2. Auth and key lifecycle

**Key format:** `trk_` + 43 characters of base64url over 32 random bytes from the Worker's CSPRNG (256 bits). The fixed prefix makes keys recognizable in logs and secret scanners. Display form is the first 12 characters, for example `trk_Ab3dE9fQ…`.

**At rest:** `key_hash = sha256(raw key)` hex, the `portal_tokens` choice. A 256-bit random key cannot be brute-forced from its hash, so a slow KDF adds cost and no safety. The raw key exists once, in the create or rotate response. It is **never** stored server-side (no replay table holds it, unlike `portal_operations`) and never stored on the device.

**Presentation:** `Authorization: Bearer trk_…` only. Query-string keys are refused (`400 key_in_query`), because URLs land in logs and browser history.

**Scopes:** `customers:read`, `jobs:read` (jobs and estimates), `invoices:read` (invoices and payments), `expenses:read`, `mileage:read`. `/v1/account` needs any scope. The UI offers presets: **Everything** (all five) and **Bookkeeping** (invoices, expenses, mileage, customers), plus custom toggles.

**Lifecycle**
| Action | Effect |
|---|---|
| Create | Name (≤ 40 characters), scopes, expiry (none / 90 days / 1 year; default 1 year). At most **5 live keys** per owner |
| Rotate | One transaction: mint a replacement with the same name and scopes, and set the old key's `expires_at` to now + 24 hours (or now, if the owner picks "immediately"). The UI shows the grace window |
| Revoke | Sets `revoked_at` (one-way, never cleared). Effective on the next request |
| Expiry | Checked on every request. An expired key is a hard 401 |
| Account deletion | `on delete cascade` from `auth.users`, so every key and log row goes with the account |

**Resolution** (one round trip, §4 RPC): hash the presented key, then look it up.
- Unknown hash → 401 `invalid_key`. Nothing is logged against an owner, because there is none.
- Known but revoked or expired → 401 `key_revoked` / `key_expired`, logged as `denied` against that key. The owner can then see that something is still calling with an old key.
- Live → owner id, key id and scopes, with the rate-limit counters incremented in the same transaction.

**Management endpoint:** `POST /api/api-keys/manage` with actions `list | create | rotate | revoke | activity`. It is JWT-authed with `appCors`, copying `portalManage.js`, and the per-user in-memory limit is 10/min. `create` and `rotate` take an `operationId` (UUID). A retried id returns the key's id and prefix with `409 already_completed` and **no** raw key, and the app tells the owner to revoke and recreate. That is the price of never storing the raw key, and it should be rare.

**Threat model**
| Threat | Control |
|---|---|
| Key leaked from a third-party tool | Scopes, expiry, instant revoke, "last used" and activity in-app, read-only blast radius |
| Database dump | Hashes only. 256-bit keys are not reversible |
| Key in a browser page | No CORS headers on `/v1/*`, so browsers cannot read responses cross-origin. The docs say keys are server-to-server only |
| Cross-tenant read | Every query goes through one builder that always adds `user_id=eq.<resolved owner>`. Route tests assert it on every fetch URL. Service-role reads are the same trust model the portal already uses |
| Secret field exposure | Allowlist mappers with exact-key tests. New blob fields are invisible until added deliberately |
| Writes through the API | GET-only router, GET-only data module (READ ONLY transactions), a test against non-GET business fetches, no write path in the code |
| Credential stuffing | 256-bit keys, plus a per-isolate limit of 20 failed attempts per minute per `cf-connecting-ip` to shed junk load. This is a load guard, not a security boundary |
| Log leakage | Logs store the key id, never the key. Route templates are logged, never query values |

## 3. Resources and public schemas

Common rules:
- Money is a JSON number rounded to cents, matching the portal (`portalAssemble.js:161-168`). The currency is always `"USD"` on `/v1/account`.
- Business dates are the stored local `YYYY-MM-DD` strings, never shifted.
- Server timestamps (`updatedAt`) are ISO-8601 UTC.
- Ids are the stored text ids.
- Absent optional values are `null`, never omitted, so every object has a fixed key set.
- Archived records are included with `archivedAt` set. Deleted records appear only as tombstones (§5).

| Resource | Source | Public fields (exact) |
|---|---|---|
| `GET /v1/account` | `settings.data.businessName` | `businessName, currency, dataAsOf, apiVersion, key: {id, name, prefix, scopes, expiresAt}` |
| `customers` | `customers` | `id, name, email, phone, address, leadSource, createdAt, archivedAt, updatedAt` |
| `jobs` | `jobs` | `id, customerId, customerName, title, description, status, scheduledDate, scheduledStartTime, scheduledEndTime, address, price, invoiceId, recurringJobId, estimateSentAt, createdAt, archivedAt, updatedAt` |
| `estimates` | `jobs` with `approval` or `estimateSentAt` | `id` (the job id), `jobId, customerId, customerName, title, status, sentAt, validUntil, total, lineItems[{label, amount}], options: {tiers[{id, name, total}], addOns[{id, label, amount}], recommendedTierId} \| null, decision, decidedAt, signerName, selection: {tierId, tierName, addOnIds, total} \| null, updatedAt` |
| `invoices` | `invoices` | `id, number, customerId, customerName, jobId, recurringInvoiceId, description, amount, amountPaid, balanceDue, status, issueDate, due, paid, paidAt, depositRequest: {amount, percent, requestedAt} \| null, lineItems[{description, category, amount}], payments[…payment fields…], paymentLinkUrl, updatedAt` |
| `payments` | flattened from `invoices.data.payments` | `id, invoiceId, invoiceNumber, customerId, amount, date, method, source, voided, voidedAt, processorReference, updatedAt` |
| `expenses` | `expenses` | `id, date, description, amount, category, categoryLabel, jobId, hasReceipt, createdAt, updatedAt` |
| `mileage` | `trips` | `id, date, miles, odometerStart, odometerEnd, fromLabel, toLabel, fromJobId, toJobId, purpose, createdAt, updatedAt` |

Derivations, all reusing existing math rather than re-deriving it:
- **jobs.`price`** is `estimateTotal`, the customer-facing price. Labor, materials, markup, overhead and margin are never exposed.
- **estimates** read only the frozen, customer-facing `approval.snapshot` and `approval.selection`, never `quoteOptions`, which carries internal costs.
  - `status` is `draft | sent | approved | declined | expired`, using `NativeQuoteExpiry` semantics ported from the Worker's `snapshotExpiry` (`backend-workers/lib/estimate/estimateExpiry.js`).
  - `decidedAt` is `approval.consentAt`. A manual owner decision has no `decidedAt`.
  - `ip`, `userAgent`, `declineReason` and `token` are excluded. The decline reason is the customer's free text to the owner, so it stays out by default (§13 D7).
- **invoices**
  - `amountPaid`, `balanceDue` and `status` (`paid | partly_paid | unpaid`) come from `backend-workers/lib/paymentMath.js`, the byte-twin of the device ledger math, including the legacy fallback.
  - `issueDate` uses the accountant package's id-timestamp rule, else `null`.
  - `customerName` is `data.customer`.
  - `email` and `phone` are **not** repeated on invoices. They live on `customers` under its own scope.
  - `paymentLinkUrl` is shown only under the portal's current-balance and allowed-host gate (`portalAssemble.js:149-160`), else `null`.
- **payments.`method`** is normalized to `stripe | cash | check | card | bank_transfer | other`, using the native display-string map. `source` is `device | stripe | legacy` (accountant-package rule). `processorReference` is `stripeSessionId` (or the Phase 18 payment intent id), else `null`. The payment `note` is excluded as an internal note (§13 D7).
- **expenses.`categoryLabel`** comes from the shared category table, with an unknown id shown as "Other". `hasReceipt` means `receiptUri` is present; the path itself is never returned.

The mapper lives in `backend-workers/lib/api/resources.js`. It exports `FIELDS[resource]` (ordered key lists) and `toPublic[resource](row)`. Tests assert `Object.keys(toPublic.x(row))` deep-equals `FIELDS.x` for fixture rows that carry **every** known blob field plus unknown junk.

## 4. Storage (migration file `supabase/migrations/20261003_api_keys.sql`; the owner applies it)

```sql
create table public.api_keys (
  id           uuid primary key default gen_random_uuid(),
  user_id      uuid not null references auth.users(id) on delete cascade,
  key_hash     text not null unique,          -- sha256 hex of the raw key
  key_prefix   text not null,                 -- first 12 chars, display only
  name         text not null check (char_length(name) between 1 and 40),
  scopes       text[] not null,               -- subset of the five scopes
  created_at   timestamptz not null default now(),
  expires_at   timestamptz,
  revoked_at   timestamptz,                   -- one-way
  last_used_at timestamptz,
  replaced_by  uuid references public.api_keys(id)
);
create index api_keys_owner_live on public.api_keys (user_id) where revoked_at is null;

create table public.api_access_log (
  id         bigint generated always as identity primary key,
  user_id    uuid not null references auth.users(id) on delete cascade,
  key_id     uuid not null references public.api_keys(id) on delete cascade,
  event      text not null,     -- 'ok' | 'denied' | 'rate_limited' | 'error'
  route      text not null,     -- template, e.g. '/v1/invoices/:id' — never query values
  status     int  not null,
  ip         text,              -- cf-connecting-ip only
  created_at timestamptz not null default now()
);
create index api_access_log_owner_time on public.api_access_log (user_id, created_at desc);

create table public.api_usage_counters (   -- durable per-key windows
  key_id       uuid not null references public.api_keys(id) on delete cascade,
  window_kind  text not null,              -- 'minute' | 'day'
  window_start timestamptz not null,
  hits         int not null default 0,
  primary key (key_id, window_kind, window_start)
);
```

- **RLS:**
  - `api_keys`: an owner-read policy, which lets a future client read metadata. `key_hash` is a column-level `revoke` from `authenticated`.
  - `api_access_log`: owner read.
  - `api_usage_counters`: no client policy (deny-all, the `ai_usage_log` precedent).
  - All writes are service-role only.
- **RPC `api_key_authorize(p_key_hash, p_route, p_ip)`**, `security definer`, executable by `service_role` only. It does the following in one transaction:
  - Look the key up.
  - Refuse a revoked or expired key, logging `denied`.
  - Upsert-increment the minute and day counters and refuse over-limit requests (`rate_limited`, with the reset time).
  - Bump `last_used_at` at most once a minute.
  - Return `{ok, userId, keyId, scopes, name, prefix, expiresAt}` or `{ok:false, error, retryAfter}`.
  - Like the portal RPCs, a transport 404 means "not deployed", and the routes answer `503 unavailable` (fail closed).
- **RPC `api_key_admin(p_user, p_action, …)`** does create, rotate and revoke under a per-owner advisory lock, enforcing the 5-live-key cap and the rotate-and-expire pairing. Row ownership is checked inside the function.
- **Retention:** the existing daily cron gains a delete of `api_access_log` rows older than 90 days and counter rows older than 2 days.
- A verify script `supabase/migrations/verify/20261003_api_keys_verify.sql` follows the 2026-08 RLS snapshot pattern.

## 5. Request contract

- **Base:** `https://tradeready-backend.tradeready.workers.dev/v1/…` on the existing Worker, under a new `/v1/*` route group in `backend-workers/src/index.js`. A branded host such as `api.gettradereadyapp.com` is a later DNS change (§13 Q4). The docs name one base URL constant so a move is a docs edit.
- **Methods:** `GET` only. Any other method returns `405 method_not_allowed` with `Allow: GET`. No `OPTIONS` and no CORS headers.
- **Lists:** `GET /v1/{resource}?limit=&cursor=&updated_since=`.
  - `limit` is 1–100 (default 50).
  - Order is `(updated_at, id)` ascending, so the order is stable and append-friendly.
  - `cursor` is an opaque base64url of `{u: updated_at, i: id, r: resource}`, HMAC-tagged with `API_CURSOR_SECRET`. A tampered or cross-resource cursor gets `400 invalid_cursor`.
  - The PostgREST query is `or=(updated_at.gt.U,and(updated_at.eq.U,id.gt.I))&order=updated_at.asc,id.asc&limit=limit+1`.
- **Response:** `{ data: [...], nextCursor: string|null, dataAsOf: string|null, nextUpdatedSince: string|null }`.
  - `dataAsOf` is the newest `updated_at` across the owner's rows in that table, from one indexed `order=updated_at.desc&limit=1` read.
  - `nextUpdatedSince` is the last row's `updated_at` minus 5 seconds. It is a safety overlap for transactions that commit out of clock order. Consumers upsert by `id`, so overlap duplicates are harmless, and the docs say so.
- **Tombstones:** without `updated_since`, deleted rows are excluded. With it, rows deleted since then appear as `{id, deleted: true, updatedAt}`, so a syncing consumer learns about deletions.
- **Single record:** `GET /v1/{resource}/{id}` returns `{data: {...}, dataAsOf}`. A deleted, missing or other-owner id is `404 not_found`, and the three are indistinguishable.
- **Payments list:** pagination walks invoices by `(updated_at, id)`. One page holds the payments of up to `limit` invoices (so 0..n payments), and `nextCursor` continues. `updatedAt` on a payment is its invoice's. This is documented rather than hidden. `/v1/invoices` also embeds `payments`.
- **Estimates list:** walks jobs with the PostgREST filter `or=(data->approval.not.is.null,data->>estimateSentAt.not.is.null)`. Same keyset.
- **Unknown query parameters** get `400 invalid_parameter` naming the parameter, so a typo never silently returns everything.
- **Errors** are `{ error: { code, message } }` with stable codes: `invalid_key`, `key_revoked`, `key_expired`, `key_in_query`, `insufficient_scope` (403), `not_found`, `invalid_parameter`, `invalid_cursor`, `method_not_allowed`, `rate_limited` (429 with `Retry-After`), `unavailable` (503), `server_error` (500, no internals).
- **Headers on every response:** `TradeReady-Api-Version: 2026-10-03`, `X-RateLimit-Limit`, `X-RateLimit-Remaining`, `X-RateLimit-Reset`, `Cache-Control: no-store`.

## 6. Rate limits and cost

| Layer | Limit | Mechanism |
|---|---|---|
| Per key, burst | 60 requests per minute | `api_key_authorize` minute counter (durable). A Cloudflare `[[ratelimits]]` binding (`period = 60`) can be added in front as a cheap first layer. It is per-location and eventually consistent by design ([Workers rate limiting](https://developers.cloudflare.com/workers/runtime-apis/bindings/rate-limit/)), so it is never the only layer |
| Per key, daily | 5,000 requests per day (UTC) | Day counter in the same RPC |
| Per owner, daily | 10,000 across all keys | The RPC sums the owner's day counters |
| Failed auth per IP | 20 per minute per isolate | `createRateLimiter` keyed on `cf-connecting-ip` |

Each request costs one RPC plus one or two PostgREST GETs. A key polling every 15 minutes across seven resources is under 700 requests a day. List responses select only `id,updated_at,deleted,data` and are capped at 100 rows.

## 7. Versioning

- **The path is the major version.** Within `/v1`, changes are additive only: new resources, new fields and new enum values. Docs warn consumers to tolerate unknown enum values.
- **Breaking changes** ship as `/v2` with at least 6 months of overlap. `/v1` responses then carry `Deprecation` and `Sunset` headers.
- **The `TradeReady-Api-Version` header** carries the date of the last additive change, for consumers who log it.
- **Field lists are frozen by tests.** Adding a field means editing `FIELDS`, the OpenAPI document and the docs changelog in the same change.
- **Planned additive follow-ups** (not v1): Phase 28 `tipAmount` on payments, Phase 21 `properties` and equipment as their own resource, Phase 20 forms. Each needs its own allowlist entry. None leaks before then.

## 8. Docs

- `tradeready-legal/developers.html` covers getting a key (Settings → API access), auth, scopes, the base URL, pagination and incremental sync (with a worked `updated_since` loop), tombstones, freshness (`dataAsOf`, last-sync caveat), rate limits, errors, versioning, a per-resource field table, curl examples and a changelog. Keys are server-to-server only, and every example uses a placeholder key.
- `GET /v1/openapi.json` (no auth, cacheable) is an OpenAPI 3.1 document built at module load from `FIELDS` and the route table, so it cannot drift from the mappers. A test asserts every route and every field is documented.
- Zapier: the docs show the generic "API request" or webhooks-style polling setup. A listed Zapier app is a partner registration, out of scope (§12).

## 9. Native (Settings → API access)

- New `SettingsDestination.apiAccess` and a row in the "APP" group ("API access", "Connect other tools to read your data").
- `N/NativeAPIKeyAdministration.swift` copies the `NativePortalAdministrationService` shape: endpoint allowlist, JWT bearer, refresh-and-retry once, operation ids, and typed errors. It holds no state; the server is the authority.
- **`NativeAPIAccessView`**
  - Lists keys: name, prefix, scopes, created date, "Last used …" (or "Never"), and expiry or "Revoked".
  - "Create key" sheet: name, preset or custom scopes, expiry.
  - Show-once sheet: the key in monospace, a Copy button that writes to `UIPasteboard` with `localOnly` and a 2-minute expiration, "I've saved it", and the line "TradeReady can't show this key again."
  - Rotate (with grace choice) and Revoke (destructive confirmation). Recent activity shows the last 50 log rows (time, route, status).
  - The freshness note reads: "Other tools see your data as of your phone's last sync."
  - A link opens `developers.html`.
- Offline or signed-out: the page shows the cloud-required empty state used by booking settings. Nothing is cached or synced, and the settings blob gains no field.
- Analytics: `api_key_created` and `api_key_revoked` with scope count only. This needs the catalog entry, mirroring `NativeAnalyticsEvents`.

## 10. Testing

- **Worker unit tests** (`node --test`, new `backend-workers/tests/apiResources.test.cjs` and `apiAuth.test.cjs`):
  - Mapper exact keys for every resource, using fixtures that carry every canonical field plus `referralCode`, `anthropicKey`, `portal`, `approval.token`, `ip`, `userAgent` and junk keys. None of these appear in output.
  - Money rounding, ledger math parity with `paymentMath.js` (legacy fallback, voids, overpaid), the payment-link gate, method normalization, the estimate status table including expiry in the owner's zone, and tombstone shape.
  - Cursor round-trip, tamper rejection, cross-resource rejection, `limit + 1` page detection, and the `nextUpdatedSince` overlap.
  - Key parsing: prefix, length, query-string refusal.
- **Route tests** (root Jest under `TZ=America/Phoenix`, `__tests__/openApiWorkers.test.js`, stubbed fetch):
  - Every Supabase URL carries `user_id=eq.<owner>`.
  - **No non-GET reaches `jobs|invoices|customers|expenses|trips|settings`**. The only POSTs allowed are the authorize RPC and the log insert.
  - `405` for POST, PUT, PATCH and DELETE on every `/v1` path.
  - Scope 403s. Revoked and expired keys give 401 and a `denied` log. 429 with headers. RPC 404 gives 503 (fail closed).
  - Unknown parameters give 400. Responses carry no CORS headers.
  - A key never appears in any `console.*` call or log body (spy assertion).
- **Manage route:** create, rotate, revoke and list, the 5-key cap, operation replay with no raw key, JWT failure, and a rotate that expires the old key after the grace window.
- **SQL verify script:** RLS on all three tables, no client policy on counters, function `EXECUTE` revoked from `anon` and `authenticated`, and counter increments under concurrent calls (deferred to a staging database like the portal-admin proof).
- **Native** (`run-api-access-tests.sh`, registered in `run-all-domain-tests.sh`): service request shaping, endpoint allowlist, error mapping, operation-id reuse on retry, and the show-once view model clearing the key on dismiss.
- **OpenAPI:** every route and field is present, and the document parses.
- **Gates:** `sh native/run-all-domain-tests.sh`, the Release compile, `cd backend-workers && npm test`, the targeted root Jest files under `TZ=America/Phoenix`, and `sh native/run-doc-reference-check.sh`.

## 11. Rollout order and stages

| Stage | Contents | Gate |
|---|---|---|
| A — buildable now | Mappers, cursor, route group, auth module (against the RPC contract, fake in tests), manage route, all tests | Green gates. Nothing deployed |
| B — migration | `20261003_api_keys.sql` plus its verify script, written in the repo | **Owner applies** it (staging first if one exists) |
| C — native | Settings → API access, behind `apiAccessEnabled`, which defaults to off until the Worker is deployed | Green gates, simulator smoke against staging |
| D — docs | `developers.html` and the privacy and terms wording (§13 Q2, Q3), on a `tradeready-legal` branch | **Owner approves** the wording before publishing |
| E — ship | Owner deploys the Worker, publishes the page, ships the native build | Device smoke: create, call, rotate, revoke |

Rollback: unroute `/v1/*`, or revoke every key with one `update`. The tables can stay.

## 12. Accepted residuals

- The API is only as fresh as the owner's last device sync. Mitigated by `dataAsOf` and the docs, not solved.
- Service-role reads put tenant isolation in Worker code (one query builder plus tests), the same model as the portal. A defense-in-depth option is to run reads as the owner through RLS with a minted short-lived JWT. That needs the Supabase JWT signing secret as a new Worker secret, so it is deferred.
- `nextUpdatedSince` uses a 5-second overlap. A transaction open longer than that between its `now()` and its commit could still be missed by a watermark consumer. That is very unlikely for sync upserts, and it is documented.
- The existing `clientIp` XFF-first spoofability affects every IP-keyed limit and the estimate consent record (see the Phase 19 spec §0). It is flagged here and not fixed. Phase 19 fixes the consent path.
- No write API, webhooks or listed Zapier app.
- There is no sub-account or "accountant" identity. Whoever holds a key reads with that key's scopes.

## 13. Decisions

**Decided (recommendations; owner may override)**
| # | Decision | Choice |
|---|---|---|
| D1 | Auth | Owner API keys (`trk_`, 256-bit), SHA-256 at rest, shown once. No OAuth in v1 |
| D2 | Scopes | Five read scopes plus Everything and Bookkeeping presets |
| D3 | Key limits | 5 live keys per owner. Expiry none, 90 days or 1 year (default 1 year). Rotate keeps a 24-hour grace by default |
| D4 | Lost create response | No raw-key replay. Revoke and recreate |
| D5 | Read-only enforcement | GET-only routes, a GET-only data module (PostgREST READ ONLY), and a non-GET test |
| D6 | Pagination | Keyset on DB-clock `updated_at, id`; `updated_since`; tombstones; HMAC-tagged cursor |
| D7 | Excluded by default | All internal notes (job, customer, expense, payment `note`), decline reasons, consent IP and user agent, every cost or margin input, local paths, tokens and codes |
| D8 | Money format | JSON numbers rounded to cents (portal parity) |
| D9 | Browser use | No CORS. Server-to-server only |
| D10 | Rate limits | 60/min and 5,000/day per key, 10,000/day per owner, durable via RPC |
| D11 | Audit log | `api_access_log` (key id, route template, status, `cf-connecting-ip`), owner-readable in the app, 90-day retention |
| D12 | Versioning | `/v1` additive-only, `/v2` with at least 6 months of overlap, a version-date header |
| D13 | Docs | `developers.html` plus a generated `/v1/openapi.json` |
| D14 | Settings blob | Unchanged. Keys are server-authority only |

**NEEDS OWNER APPROVAL**
| # | Item | Question | Recommendation |
|---|---|---|---|
| Q1 | Migration `20261003_api_keys.sql` | May we write this migration (three tables and two `security definer` RPCs) for you to apply before the Worker deploy? | **Yes.** It is additive only, with no change to existing tables, and the routes fail closed (503) until it is applied |
| Q2 | Privacy policy | Add to `privacy.html` §1/§5: "If you create an API key, services you give it to can read the data types you chose. We log each API request (time, key, endpoint, IP address) for 90 days for security." Approve this wording? | **Yes**, before the docs page is published |
| Q3 | Terms | Add a short "API access" section to `terms.html`: read-only, the owner is responsible for where keys go, limits may change, access may be suspended for abuse, no uptime warranty. Approve this wording? | **Yes**, a short paragraph next to §7 "Your Data" |
| Q4 | Base URL | Ship v1 on the existing `*.workers.dev` host, or add a Cloudflare custom domain `api.gettradereadyapp.com` first (a DNS change)? | **workers.dev for v1.** Add the branded host later as an alias; the docs use one base-URL constant |
| Q5 | Privacy label | Confirm no App Store privacy-label change. The app collects no new data types; API access logs are server-side security logs of owner-initiated third-party requests | **No label change.** Re-check if the log ever feeds analytics |
| Q6 | Subscription gating | Should keys stop working when the subscription lapses? Server-side entitlement enforcement is a deferred decision today (`backend-workers/lib/guards.js:12-14`) | **Not in v1.** Revisit with the general entitlement-enforcement decision |
| Q7 | Optional Cloudflare `[[ratelimits]]` binding | Add it to `wrangler.toml` as a first-layer burst limiter (config only, no new service)? | **Optional.** The durable RPC counters are sufficient alone. Add it only if request volume ever makes the RPC the bottleneck |

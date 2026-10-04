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
| Rotate | One transaction: mint a replacement with the same name and scopes, and set the old key's `expires_at` to now + 24 hours (or now, if the owner picks "immediately"). The UI shows the grace window. A grace key behind the rotated key ends immediately, and at most 5 grace keys work at once (so at most 10 working keys in all) |
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
| Failed auth per IP | 20 per minute per isolate | In-memory counter keyed on `cf-connecting-ip`. Blocks only requests without a well-formed key; valid keys are never rejected by it (§14.4 #10) |
| Unknown / over-limit key hash, and unknown hashes from a blocked IP | 5 unknown answers per minute per hash; over-limit until reset; 5 RPCs per minute per blocked IP for hashes outside the positive cache | In-memory, keyed on sha256 of the presented key, so a well-formed key cannot hammer the database (§14.4 #10) |

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

## 14. Build record (2026-10-03)

### Worker and pages

#### 14.1 App-facing contract (settled; the native Settings → API access screen builds against this)

`POST /api/api-keys/manage` on the existing Worker (`BuildEnvironment.endpoint("api/api-keys/manage", sendsUserData: true)`).

- Headers: `Authorization: Bearer <Supabase access token>`, `Content-Type: application/json`. CORS is `appCors` (`POST, OPTIONS`); `OPTIONS` answers 200 with an empty body.
- Every error body is `{"error": "<code>"}`, sometimes with extra keys listed below. Codes are stable.

| Status | `error` | When |
|---|---|---|
| 405 | `method_not_allowed` | Any method other than POST/OPTIONS |
| 401 | `unauthorized` | Missing bearer, or `/auth/v1/user` rejects it. Refresh the session once and retry (portal-admin convention) |
| 429 | `rate_limited` | More than 10 calls per minute for this user (per isolate) |
| 400 | `invalid_request` | Unknown action, malformed field, bad UUID, bad name/scopes/expiry/grace |
| 404 | `not_found` | `keyId` unknown, another owner's, or (rotate only) revoked, expired or already rotated |
| 409 | `key_limit` | `create` when 5 live keys exist. Extra: `"maxLiveKeys": 5` |
| 409 | `already_completed` | `create`/`rotate` replayed with an `operationId` that already committed. Extra: `"key": {"id": "<uuid>", "prefix": "trk_XXXXXXXX"}`. **No secret.** The app tells the owner to revoke that key and create a new one |
| 409 | `operation_conflict` | Same `operationId` sent with a different request |
| 503 | `unavailable` | The migration is not applied yet (RPC transport 404). Fail closed |
| 500 | `server_error` | Anything else. No internals in the body |

`KeySummary` (every action that returns a key uses this exact object; all keys always present):

```json
{
  "id": "6f1c…uuid",
  "name": "QuickBooks sync",
  "prefix": "trk_Ab3dE9fQ",
  "scopes": ["customers:read", "invoices:read"],
  "createdAt": "2026-10-03T17:00:00.000Z",
  "expiresAt": "2027-10-03T17:00:00.000Z",
  "revokedAt": null,
  "lastUsedAt": null,
  "replacedBy": null,
  "status": "active"
}
```

- Timestamps are ISO-8601 UTC strings or `null`. `expiresAt: null` means "never expires".
- `status` is computed by the server at response time: `revoked` (revokedAt set) → `expired` (expiresAt ≤ now) → `expiring` (replacedBy set: the old key in a rotation grace window, still working until `expiresAt`) → `active`.
- `scopes` are always in canonical order: `customers:read`, `jobs:read`, `invoices:read`, `expenses:read`, `mileage:read`. Presets: **Everything** = all five; **Bookkeeping** = `customers:read`, `invoices:read`, `expenses:read`, `mileage:read`.

Actions (request → 200 response):

| Action | Request body | 200 body |
|---|---|---|
| `list` | `{"action":"list"}` | `{"ok":true,"keys":[KeySummary…],"liveCount":2,"maxLiveKeys":5}`. Newest first: every non-revoked unexpired key plus the 50 most recent keys overall. `liveCount` counts `active` keys (the cap; `expiring` keys don't count) |
| `create` | `{"action":"create","operationId":"<UUID v4>","name":"QuickBooks sync","scopes":["invoices:read"],"expiry":"1y"}` | `{"ok":true,"key":KeySummary,"secret":"trk_<43 chars>"}` |
| `rotate` | `{"action":"rotate","operationId":"<UUID v4>","keyId":"<uuid>","grace":"24h"}` | `{"ok":true,"key":KeySummary,"secret":"trk_<43 chars>","previous":KeySummary}` |
| `revoke` | `{"action":"revoke","keyId":"<uuid>"}` | `{"ok":true,"key":KeySummary}`. Idempotent: revoking a revoked key returns it unchanged |
| `activity` | `{"action":"activity"}` or `{"action":"activity","keyId":"<uuid>"}` | `{"ok":true,"events":[{"at":"…Z","keyId":"<uuid>","event":"ok","route":"/v1/invoices","status":200,"ip":"203.0.113.9"}]}`. Newest first, at most 50. `event` is `ok`, `denied`, `rate_limited` or `error`; `route` is a template such as `/v1/invoices/:id`, never query values |

Field rules:
- `operationId`: required for `create` and `rotate`, a UUID v4 (any case). Reuse the same id when retrying the same request after a lost response.
- `name`: string, trimmed by the server, 1–40 characters, no control characters.
- `scopes`: non-empty array of the five scope strings. Duplicates are collapsed.
- `expiry`: `"1y"` (default when absent), `"90d"` or `"none"`. The server computes `expiresAt` from its own clock.
- `grace`: `"24h"` (default when absent) or `"immediate"`. The new key gets the old key's name and scopes and a fresh expiry from the old key's expiry choice (none stays none; otherwise the old key's original lifetime, 90 days or 1 year, from now). The old key's `expiresAt` becomes now + 24 h (or now) and its `replacedBy` is the new key's id.
- `secret` appears only in a `create` or `rotate` 200 body, exactly once. It is never stored server-side and the app must never persist it.
- Live-key cap: 5 keys with status `active`. `expiring` keys (rotation grace) don't count, so a rotate never fails on the cap.

The public `/v1` contract is §5 as built, plus the decisions in 14.4. The app never calls `/v1`.

#### 14.2 What was built, by file

Worker (`backend-workers/`):
- `lib/api/keys.js`: key format (`trk_` + 43 base64url chars over 32 CSPRNG bytes), sha256 hashing, 12-character display prefix, Bearer parsing, key-in-query detection, the five scopes and two presets, resource→scope map, name/scope normalization, limits (5 live keys, expiry `1y`/`90d`/`none`, grace `24h`/`immediate`).
- `lib/api/resources.js`: `SCHEMA` (OpenAPI 3.1 JSON Schema per resource), `FIELDS` (derived from `SCHEMA`), and one allowlist mapper per resource built key by key (`toPublic.*`), the estimate status table, ledger math via `lib/paymentMath.js`, the portal's payment-link gate and estimate total (both parity-tested against `lib/estimate/portalAssemble.js`), method/source normalization, the accountant issue-date rule, expense category labels, tombstones and the resource registry.
- `lib/api/cursor.js`: HMAC-SHA256-tagged keyset cursor `{u, i, r}` with tamper and cross-resource rejection.
- `lib/api/store.js`: the GET-only data module. One builder (`ownerQuery`) always adds `user_id=eq.<owner>` and refuses a non-UUID owner; one `fetch` call hard-wired to `GET`.
- `lib/api/auth.js`: `authorizeKey` (the `api_key_authorize` RPC; 404 → unavailable), `logApiRequest` (best-effort `api_access_log` insert), the failed-auth load guard on `createRateLimiter`.
- `lib/api/v1.js`: `handleV1`, the whole request contract (routing, GET-only, key-in-query, auth, scopes, parameters, keyset pages, tombstones, `dataAsOf`, `nextUpdatedSince`, headers, error vocabulary) and the route table.
- `lib/api/openapi.js`: the OpenAPI 3.1 document, built once from `SCHEMA`/`FIELDS`/`ROUTES`; `API_BASE_URL` is the single base-URL constant.
- `lib/api/keyAdmin.js`: `apiKeysManageCore` for list/create/rotate/revoke/activity against the `api_key_admin` RPC and owner-scoped REST reads.
- `lib/api/retention.js`: `pruneApiLogs` (log rows > 90 days, counter rows > 2 days).
- `src/routes/api/v1.js`: Hono shell for `/v1` and `/v1/*` (no CORS; caller IP from `cf-connecting-ip` only).
- `src/routes/api/keysManage.js`: Hono shell for `POST /api/api-keys/manage` (appCors, Supabase JWT, 10/min per user, CSPRNG bytes).
- `src/index.js`: routes `/v1`, `/v1/*` and `/api/api-keys/manage`; the daily 15:00 UTC cron branch also runs `pruneApiLogs`.
- `wrangler.toml` (comment only) and `.dev.vars.example`: the new `API_CURSOR_SECRET`.

Database (written, not applied):
- `supabase/migrations/20261003_api_keys.sql`: `api_keys`, `api_access_log`, `api_usage_counters`, RLS and grants, `api_key_authorize`, `api_key_admin`, and the `api_key_public` projection.
- `supabase/migrations/verify/20261003_api_keys_verify.sql`: read-only, self-checking hosted-project verification (RLS-snapshot pattern).
- `supabase/verify/local/api_keys.sh`: throwaway-local-PostgreSQL proof (same harness as `supabase/verify/local/run.sh`), including the concurrent counter check.

Tests: `backend-workers/tests/apiResources.test.cjs`, `backend-workers/tests/apiAuth.test.cjs`, `backend-workers/tests/apiKeysManage.test.cjs`, `__tests__/openApiWorkers.test.js`; `docs/native-fixture-manifest.json` regenerated for the new oracle.

No `backend/` (Vercel) twin: the open API is Workers-only, like the portal's Phase 12 additions. No `native/` or React Native changes.

#### 14.3 Preconditions re-checked against the tree (2026-10-03)

- §0 said `clientIp` prefers `x-forwarded-for`. It no longer does: commit `dd4c9b7` made `backend-workers/src/appCors.js` prefer `cf-connecting-ip`. The API still never calls `clientIp`: it reads `cf-connecting-ip` directly and never falls back to `x-forwarded-for`, so the §12 residual no longer applies to this phase.
- Phase 32 is committed on this base (`aa1bbbf`); `estimateExpiry.js` and `quoteOptions.js` are reused unchanged.
- This branch does not contain Phases 20, 21, 24, 26, 28, 33 or 34. Their future blob fields (for example referral codes, tips) are excluded by the allowlist without any code here; the fixtures carry `referralCode`, vendor keys, `portal` and junk keys to prove it. Adding `tipAmount` (Phase 28) and the Phase 21/20 resources later is an additive `SCHEMA` edit (§7).
- Everything else in §0 holds as written.

#### 14.4 Decisions where the spec was silent

Storage and RPCs:
1. `api_keys` gains three columns beyond §4: `expiry_days` (90 | 365 | null, so rotate keeps the owner's lifetime choice), `operation_id` (unique when set) and `request_hash` (replay detection without storing the raw key). Plus check constraints on hash shape, prefix length, scopes and log `event`, and `replaced_by … on delete set null`.
2. "Live" means not revoked, not expired and not replaced. The 5-key cap counts live keys, so rotate (which swaps one live key for another) never fails on it. Keys in a rotation grace window are bounded separately (corrected 2026-10-04, see the fix note at the end of this section): rotating a key ends its own grace predecessor now, and after every rotate at most 5 grace keys keep working, so an owner never holds more than 5 live + 5 grace = 10 working keys. (Originally grace keys were uncounted and repeated rotation could leave an unbounded number of working keys.)
3. Rotate inherits name, scopes and lifetime. The old key's `expires_at` becomes the earlier of its current expiry and now + grace. Only a live, not-yet-rotated key rotates; anything else is `not_found`.
4. Revoke is idempotent: a second revoke answers 200 with the key unchanged (`revoked_at` never moves).
5. Rate limits are check-then-increment under a per-owner advisory lock, so concurrent requests never over-admit and **refused requests consume no quota**. The `X-RateLimit-*` headers describe the per-key minute window. Daily windows are UTC.
6. `denied` and `rate_limited` rows are written by the RPC at most once per key per minute, so a client hammering with a dead or limited key cannot grow the log without bound. Unknown hashes are never logged (there is no owner).
7. Both RPCs refuse a client JWT that reaches them anyway (the `booking_is_client_caller` logic, inlined to avoid a dependency on the booking migrations).

Request contract:
8. Check order: GET-only → key in query → route → Bearer parse (a missing or malformed key meets the failed-auth block; a well-formed key skips it, §14.4 #10) → per-hash memory guards → RPC → scope → parameters → reads. `HEAD` and `OPTIONS` are 405 like every non-GET.
9. Key-in-query means a credential-like parameter name (`api_key`, `apikey`, `key`, `access_token`, `token`, `authorization`, `bearer`) or any value starting with `trk_`. It is refused before routing and counts as an auth failure for the IP guard.
10. Failed-auth guard: the 20th failure per minute from one `cf-connecting-ip` blocks that address for a minute, answered `429 rate_limited` before any RPC call. It applies only to requests with no well-formed key (missing or malformed `Authorization`); a request carrying a well-formed `trk_` key is never rejected by it and goes to the authorize RPC (corrected 2026-10-04: it originally rejected every request from the address, valid keys included). Well-formed keys are shed per key hash instead: 5 "unknown key" answers for the same hash in a minute make that hash a `401 invalid_key` from memory until the minute ends, and a `rate_limited` answer makes that hash a `429` from memory (same `Retry-After` and `X-RateLimit-*`) until the reset. Per isolate, capped at 2,000 entries per map (expired swept, then oldest evicted), keyed by sha256 only.
11. Worker-written log rows (requests that resolved a key): 2xx → `ok`, 403 → `denied`, 429 → `rate_limited`, anything else (400, 404, 500, 503) → `error`. Requests that never resolved an owner (405, malformed bearer, key in query, unknown path) are not logged.
12. Headers: `TradeReady-Api-Version` and `Cache-Control: no-store` on every `/v1` response; `X-RateLimit-Limit/Remaining/Reset` (Reset in Unix seconds) on every response that resolved a key, including 429. Pre-auth responses have no key to describe, so they omit the rate headers. `/v1/openapi.json` is `Cache-Control: public, max-age=3600`. 401s carry `WWW-Authenticate: Bearer realm="TradeReady API"`.
13. Failure mapping: authorize RPC not deployed, undecodable or erroring → `503 unavailable` (fail closed); a data read failing after auth → `500 server_error`; `API_CURSOR_SECRET` unset → list endpoints `503 unavailable` (single records and `/v1/account` still work; cursors are never minted unsigned).
14. `updated_since` must carry a time zone (`Z` or `±hh:mm`) and is applied as `updated_at >= value`. `nextCursor` and `nextUpdatedSince` follow the last raw row scanned (a payments page can hold zero payments; an estimates page skips non-estimate jobs). `nextUpdatedSince` is `null` when the page is empty.
15. `GET /v1/account` returns `{data: {...}}` with `dataAsOf` inside the account object (it is in the §3 field list). Its `dataAsOf` is the newest change across the tables the key can read. `businessName` is read with `select=businessName:data->>businessName`, so the settings blob (vendor keys, tokens) never reaches the Worker.
16. Paths: one trailing slash is tolerated; ids longer than 200 characters or with broken percent-encoding are 404; `/v1` itself is 404.

Resources:
17. Estimate status table: (1) a decision on the approval link wins; (2) otherwise a job status the owner moved by hand: `declined`, or any of `approved/scheduled/in_progress/complete/invoiced/paid` → `approved` (with `decidedAt`, `signerName` and `selection` null); (3) otherwise no link and job status `lead` → `draft`; (4) otherwise `sent`, or `expired` after `validUntil` in the snapshot's zone (`snapshotExpiry`). An estimate sent without a link (only `estimateSentAt`) uses `estimateValidUntil` with anywhere-on-Earth, `total` = `estimateTotal`, `lineItems` `[]`, `options` null.
18. Estimate `total` is the portal's: the accepted selection total, else the lowest option for an undecided options estimate, else the snapshot total.
19. Payments: the legacy synthesized `legacy_<invoiceId>` entry is included (so a key's payments always sum to `amountPaid`) and is reachable at `/v1/payments/legacy_<invoiceId>`. `processorReference` is `stripeSessionId`, else the id after `stripe_` (covers Phase 18's `stripe_<payment_intent_id>` without reading a new field). The method map adds `stripe`. A single payment is found with `data->payments=cs.[{"id":…}]`.
20. Invoice `paid` is the stored flag; `status` is derived from the ledger. Money is rounded half away from zero to cents after `toPrecision(15)` (so 12.345 → 12.35).
21. Manage `activity` returns `ip` too: it is the owner's own security log, and the privacy wording (Q2) discloses it.

#### 14.4a Security-review fixes (2026-10-04, branch `fix/open-api-guard`)

Four review findings, fixed and tested:

1. **Failed-auth IP guard no longer blocks valid keys, and distinct random keys stay bounded** (`lib/api/v1.js`, `lib/api/auth.js`). The Bearer is parsed first; a request with no well-formed key meets the IP block (429 while blocked). A well-formed key is never flatly rejected by it, so a shared egress address cannot lock out valid keys and `?token=x` junk cannot hold a block against other owners. Every unknown, revoked or expired key counts as a failure against the caller's IP (the 20th per minute blocks the address for a minute; a failure inside a block does not extend it). While an address is blocked, a key hash outside the **positive cache** may reach the authorize RPC only 5 times per minute per IP, then 429 from memory (`Retry-After` = rest of the block). So 500 distinct random well-formed keys from one IP cost at most 20 + 5 = 25 RPCs per window, which the route test pins exactly. The positive cache holds sha256 hashes that authorized (or were rate limited, which only a live key can be) in the last 5 minutes (cap 500). It exempts a hash from the IP budget but never skips the RPC: revocation and expiry are checked on every request, and a denial removes the hash. Accepted trade-off: a valid key this isolate has not seen in the last 5 minutes, arriving from an address that is over the threshold, shares that address's 5-call budget. A per-hash negative cache answers 401 `invalid_key` from memory after 5 unknown results for the same hash in a minute. Corrects #10.
2. **Rate-limited keys are shed before the database** (same files). A `rate_limited` RPC answer makes that hash a 429 from memory until the reported reset (`retryAfter`, 60 s if none), with the same `Retry-After` and `X-RateLimit-*` headers. Every guard map is separate, per isolate and capped (2,000 entries; 500 for the positive cache), keyed by hash only; past a cap, expired entries are swept and the oldest in that map are evicted, so an attacker's churn in one map cannot evict known-good or active rate-limit entries in another.
3. **Show-once key can no longer be copied around the clipboard policy** (`NativeAPIAccessView.swift`). `.textSelection(.enabled)` is removed from the secret, so the Copy button (local-only, 2-minute expiry, §9) is the only copy path. `native/APIAccessTests/main.swift` now fails if the view source contains `textSelection`.
4. **Working keys are bounded including grace keys** (`20261003_api_keys.sql`, edited in place; still unapplied). Rotation ends the rotated key's own grace predecessor immediately, and after each rotate only the 5 latest-expiring grace keys keep working (the rest end now). This holds even when a replacement is revoked (which leaves its predecessor in grace with no live successor). With the live cap of 5 this gives at most 10 working keys, and rotate still never fails on the cap. Corrects #2. The verify SQL pins the grace cap in the RPC source, and `supabase/verify/local/api_keys.sh` covers lineage rotation, create/rotate/revoke churn and rotate at the live cap.

#### 14.5 Uncommitted `tradeready-legal` edit

- New file `tradeready-legal/developers.html` (the only file touched in that repo; `book.html`, `estimate.html`, `portal.html` keep their other-phase edits untouched). Static, no script, CSP-compatible with the existing `_headers`. Covers getting a key, auth, scopes and presets, the workers.dev base URL (Q4), pagination, incremental sync with a worked Node.js loop, tombstones, freshness, rate limits, errors, versioning, per-resource field tables, Zapier, security and privacy, and a changelog. Q6 (subscription gating) and Q7 (Cloudflare binding) are not mentioned.
- The field tables are generated from the Worker's `SCHEMA`/`FIELDS` (scratch generator), and a jsdom check pins them to `FIELDS` exactly.
- Not done (owner's call when publishing): adding the page to `sitemap.xml` and linking it from `support.html`.

#### 14.6 Legal and privacy wording to apply (approved recommendations Q2, Q3; not applied here)

- **`privacy.html` §1/§5 (Q2):** "If you create an API key, services you give it to can read the data types you chose. We log each API request (time, key, endpoint, IP address) for 90 days for security."
- **`terms.html`, new "API access" section next to §7 "Your Data" (Q3):** "API access. TradeReady offers a read-only API for connecting other tools to your data. If you create an API key, you are responsible for where you use it and who you give it to: anyone who has the key can read the kinds of data you chose for it until it expires or you revoke it. Keep keys secret and revoke any key you think has been exposed. We may change API rate limits, and we may suspend or revoke keys used in a way that harms the service or other users. The API is provided as is, without any commitment to uptime or availability."
- **Q5:** no App Store privacy-label change (re-check if the access log ever feeds analytics).

#### 14.7 Test results

| Command | Result |
|---|---|
| `cd backend-workers && npm test` | 238 pass, 0 fail (38 suites; 160 before this phase + 78 new: apiResources 39, apiAuth 23, apiKeysManage 16) |
| `TZ=America/Phoenix npm test -- --runInBand --runTestsByPath __tests__/openApiWorkers.test.js` | 38 pass |
| Every root suite that references `backend-workers` (29 files, including the portal, booking and phase 8 suites) under `TZ=America/Phoenix` | 29 suites, 459 tests pass |
| `sh supabase/verify/local/api_keys.sh` (throwaway local PostgreSQL) | 52 pass, 0 fail: applies twice, hosted verify SQL passes and flags a leaked `key_hash` grant and a client EXECUTE grant, client roles refused, cap/rotate/revoke/replay, denied-log throttle, 70 concurrent callers → exactly 60 admitted, owner daily cap, RLS and column privileges, cascade delete |
| Mutation check (scratch): 10 deliberate security breaks, each run against the suite meant to catch it (owner filter dropped, invoice email added, job notes added, non-GET allowed, raw key sent to the RPC, `x-forwarded-for` used as the IP, scope check skipped, unsigned cursor accepted, full settings blob selected, key written to the console) | all 12 runs failed, as they should; files restored byte for byte |
| `developers.html` jsdom check (scratch) | 61 pass; fails with the page absent (pre-edit state) and catches 10/10 broken variants |
| esbuild bundle of `src/index.js` (local, nothing deployed) | builds; the bundle serves `/v1/openapi.json` 200 and `DELETE /v1/customers` 405 |
| `node scripts/parity-manifest.mjs --write` then `--check` | current (adds the `openApiWorkers` oracle) |
| `sh native/run-doc-reference-check.sh` | 0 missing. Run on this spec: 1 missing, `N/NativeAPIKeyAdministration.swift` in §9, which the native slice creates |

#### 14.8 Owner ship steps (in order)

1. Apply `supabase/migrations/20261003_api_keys.sql` in the Supabase SQL editor (staging first if one exists). Then run `supabase/migrations/verify/20261003_api_keys_verify.sql`; expect "ALL API KEY CHECKS PASSED" (psql) or every `ok` true (editor grid).
2. Set the cursor secret: `wrangler secret put API_CURSOR_SECRET` with a long random value (for example the output of `openssl rand -base64 48`). Same for staging when it exists.
3. Deploy the Worker.
4. Smoke from a terminal with a key created in the app: `curl …/v1/account -H "Authorization: Bearer $KEY"`, one list with `limit=1` and its `nextCursor`, then rotate and revoke in the app and confirm the old key gets 401.
5. Turn on the native `apiAccessEnabled` flag (native slice) once the Worker is live.
6. Review and publish `tradeready-legal/developers.html` together with the 14.6 privacy and terms wording; optionally add it to `sitemap.xml` and link it from `support.html`.
7. Optional, after step 1: add `api_keys` and `api_access_log` to the expected list in `supabase/verify/account_deletion_cascade.sql` (left unchanged so that gate stays green before the migration is applied; both tables already cascade).

#### 14.9 Not done / residuals

- Native Settings → API access (§9) belongs to the native slice.
- Hosted-project verification and a staging concurrency run wait for the owner's migration apply; the local proof covers the SQL behavior.
- `Deprecation`/`Sunset` headers have nothing to announce until a `/v2` exists.
- The failed-auth guard and the 10/min manage limit are in-memory per isolate, as §6 accepts; the durable limits are the RPC counters.

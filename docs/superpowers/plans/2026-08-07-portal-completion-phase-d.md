# Portal Completion Phase D (server-owned tokens) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Portal capability tokens become server-authoritative (D1-A): a `portal_tokens` table stores sha256 hashes, mint/enable/rotate are owner-JWT endpoints, disable and rotate take effect instantly (no sync round-trip), and the unindexed JSON-path scan disappears from the hot path. Plus the read-event logging (`view`/`ics`/`photo`) deferred from Phase C.

**Architecture:** New `portalTokenStore.js` owns the table and the composed resolver `resolvePortalCustomer(env, token)`; the READ-ONLY `portalStore.js` contract is untouched (its blob lookup becomes the resolver's legacy fallback). One JWT-authed action `portal-manage` (mint / set_enabled / rotate) beside the portal family. The device keeps a **display copy** in `Customer.portal` (URL row + share sheet work offline), but the server row is the auth authority.

## The token resolution contract (load-bearing)

`resolvePortalCustomer(env, token)`:

1. `hash = sha256hex(token)` → look up `portal_tokens` by primary key, NO filters.
   - Row found, `enabled && !revoked_at` → fetch the customer record by `(user_id, customer_id, deleted=false)` → authenticated.
   - Row found but revoked or disabled → **null (oracle-free 404). Never fall through** — this is what makes rotate/disable instant and is the fix for the v1 "revocation waits for sync" residual. A rotated link's old token is in the table as revoked, so it can never sneak back in via the blob.
2. Hash unknown → legacy fallback: the existing blob JSON-path lookup (pre-Phase-D tokens). On a hit, **lazily backfill** a `portal_tokens` row for that hash (best-effort, never throws, never blocks the response) so the customer's next request takes the indexed path and future rotation kills this link properly.
3. Both miss → null.

Accepted residual (documented): an OTA-old client that mints via the old stateless path writes a blob-only token the fallback honors and backfills — a customer can briefly hold two live links until the next server-side rotate revokes all rows. Solo-operator blast radius, converges on any rotate.

## Global Constraints

- Phases A–C constraints carry over. Baseline 2622 tests / 194 suites. Branch `feat/portal-completion` (== master `1e1960e`).
- Raw tokens are NEVER stored server-side — hashes only; mint/rotate return the raw token exactly once.
- One ACTIVE row per customer: `mint` refuses (409 `already_exists`) when an active row exists — protects a link already in a customer's inbox from a stale-paint create on a second device; `rotate` is the explicit destructive path (revokes ALL rows for the customer, then inserts the new one).
- `revoked_at` is one-way; `enabled` is the reversible switch. Legacy blob tokens get a table row via lazy backfill (resolver) or manage-time backfill (any portal-manage action on a blob-only customer) — after which the table governs.
- Read-event logging reuses Phase C's `logPortalEvent` (best-effort, token_prefix only): `view` on portal-view success, `ics` on portal-ics success, `photo` on photos-public success with the literal prefix `signedurl` (that route authenticates by HMAC, not token).
- Client manage calls require the deployed Worker — backend deploys before the OTA (standard ordering); old clients keep working via the fallback.

---

### Task 1: `portal_tokens` migration + token store

**Files:** Create `supabase/migrations/20260807_portal_tokens.sql`, `backend-workers/lib/estimate/portalTokenStore.js`; test `__tests__/portalTokensWorkers.test.js` (store half).

```sql
-- Phase 12D (2026-08-07 portal-completion spec §3a, decision D1-A): portal
-- capability tokens move to a server-owned table. Stores sha256 HASHES only —
-- the raw token appears exactly once in the mint/rotate response. The device
-- keeps a display copy in Customer.portal; THIS table is the auth authority:
-- disable and rotate take effect on the next request, no sync round-trip.
-- Applied out-of-band via the Supabase SQL editor. Service-role writes; the
-- device never reads it (owner-read policy = the multi-tenant floor rule).
create table if not exists public.portal_tokens (
  token_hash  text primary key,
  user_id     uuid not null references auth.users(id) on delete cascade,
  customer_id text not null,
  enabled     boolean not null default true,
  created_at  timestamptz not null default now(),
  revoked_at  timestamptz  -- one-way: rotate stamps it; nothing clears it
);

create index if not exists portal_tokens_customer_idx
  on public.portal_tokens (user_id, customer_id);

alter table public.portal_tokens enable row level security;

create policy "read own portal tokens"
  on public.portal_tokens for select
  using (auth.uid() = user_id);
```

`portalTokenStore.js` (service-role; sibling of portalRequestStore):
- `sha256Hex(value)` — `node:crypto` createHash.
- `fetchTokenRow(env, tokenHash)` — PK lookup, no state filters (the resolver decides).
- `insertTokenRow(env, { tokenHash, userId, customerId })` — `Prefer: resolution=ignore-duplicates` (lazy backfill may race itself across isolates; first write wins, retry is a no-op).
- `revokeCustomerTokens(env, userId, customerId)` — PATCH all non-revoked rows for the customer: `{ enabled: false, revoked_at: now }`.
- `setCustomerTokenEnabled(env, userId, customerId, enabled)` — PATCH active (non-revoked) rows' `enabled`.
- `fetchCustomerById(env, userId, customerId)` — customers row by id, both-key scoped, `deleted=eq.false`, `select=user_id,id,data` (the resolver + manage ownership check).
- `resolvePortalCustomer(env, token)` — the contract above; composes `fetchTokenRow` + `fetchCustomerById` + portalStore's `lookupCustomerByPortalToken` (legacy) + best-effort backfill.

Tests: URL/method/Prefer pinning for each; resolver matrix — active hit (returns `{user_id,id,data}` without touching the blob path), revoked → null (blob NOT consulted — pinned by asserting no customers JSON-path query fired), disabled → null, unknown hash + blob hit → row returned AND a backfill insert fired with the right hash, unknown + blob miss → null, backfill failure still returns the customer (never throws).

Commit: `feat(portal): portal_tokens table + server-side token resolver with legacy fallback`

### Task 2: routes adopt the resolver + read-event logging

**Files:** Modify `backend-workers/src/routes/estimate/portalView.js`, `backend-workers/lib/estimate/portalIcs.js`, `backend-workers/lib/estimate/portalRequest.js`, `backend-workers/src/routes/photosPublic.js`; extend `__tests__/portalIcsWorkers.test.js`, `__tests__/portalRequestWorkers.test.js`, `__tests__/photoSignWorkers.test.js` (route-visible behavior only where cheap), new assertions in `__tests__/portalTokensWorkers.test.js` for the view path.

- Swap `lookupCustomerByPortalToken` → `resolvePortalCustomer` at all three call sites (portal-view route, portalIcs core, portalRequest core). Error semantics unchanged (same oracle-free 404s).
- Logging (all best-effort via `logPortalEvent`): portal-view logs `view` after a successful assemble; portal-ics logs `ics` on success; photos-public logs `photo` with `tokenPrefix: 'signedurl'` and the signed `userId` on success. Phase C's `request`/`denied` unchanged.
- Existing suites keep passing because the resolver's legacy fallback reproduces the old blob behavior for fetch-mocked tests; add one assertion per path that the log write fired.

Commit: `feat(portal): token-table resolution + read-event security logging across the portal family`

### Task 3: `portal-manage` endpoint (mint / set_enabled / rotate)

**Files:** Create `backend-workers/lib/estimate/portalManage.js`, `backend-workers/src/routes/estimate/portalManage.js`; modify `backend-workers/src/index.js`; test = second half of `__tests__/portalTokensWorkers.test.js`.

Core `portalManageCore(env, { userId, body, randHex })` → `{ status, json }`:

1. `action` ∈ mint | set_enabled | rotate; `customerId` non-empty string → else 400.
2. Ownership: `fetchCustomerById(env, userId, customerId)` → miss = 404 `{ error: 'Not found' }` (booking-respond convention — no oracle about other tenants' customers).
3. **Manage-time legacy backfill**: if the customer blob carries `portal.token` and the table has no rows for this customer, insert the blob token's hash first (`enabled` mirroring the blob flag) — after this, every action below operates purely on the table.
4. `mint`: active row exists → 409 `{ error: 'already_exists' }`. Else insert `{ hash(newToken), enabled: true }` → 200 `{ ok: true, token: newToken }`. Token = `randHex` (48 hex chars, injected by the route from `randomBytes(24)` — injected-inputs testing discipline, booking-reserve precedent).
5. `set_enabled` (`enabled` must be boolean): no rows at all → 404; else PATCH active rows → 200 `{ ok: true, enabled }`.
6. `rotate`: `revokeCustomerTokens` then insert fresh → 200 `{ ok: true, token: newToken }`. (Works from zero rows too — rotate-as-create is fine; the destructive confirm lives client-side.)

Route: JWT auth via the local `authUserId` pattern (photos.js precedent — POST bearer to `/auth/v1/user` with the anon key), per-user rate limit 10/min (mint convention), `appCors` (app-facing endpoint, needs the `Authorization` header — NOT the estimate/browser CORS), POST/OPTIONS only, 401/405/429/500 shells. Register before the `:action` catch-all.

Tests: 400 matrix; foreign/unknown customer 404; mint happy (returns 48-hex raw token; insert carries its sha256, never the raw value — pinned); mint-when-active 409; set_enabled flips and 404s on token-less customer; rotate revokes-then-inserts (call order pinned) and returns a fresh token; legacy blob customer: set_enabled backfills the blob token's hash then applies; no raw token in any Supabase write body.

Commit: `feat(portal): JWT-authed portal-manage endpoint (mint, enable, rotate)`

### Task 4: client — manage wrapper + CustomerDetail rework

**Files:** Modify `utils/portalLink.ts`, `screens/CustomerDetailScreen.tsx`; update `__tests__/portalLink.test.ts`, `__tests__/portalLinkCustomerDetail.test.tsx`.

- `portalLink.ts` gains `managePortal(action, customerId, enabled?)` → POST `${BACKEND_URL}/api/estimate/portal-manage` with the Supabase bearer, discriminated result `{ ok: true, token?, enabled? } | { ok: false, reason: 'already-exists' | 'signed-out' | 'no-backend' | 'server' | 'network' }` (bookingLink/estimateApprovalLink result-union convention, no Alerts in the util). `mintPortalToken` (stateless) export stays for now — dead code the moment CustomerDetail flips, removed in the Phase E sweep so an interleaved OTA can't strand a caller.
- CustomerDetail flows (server is authority; blob copy written only after the server confirms):
  - Create: existing record guard + stale-paint adopt guard unchanged → `managePortal('mint', id)` → ok: write `{ token, enabled: true }` via the normal customer save; `already-exists`: Alert "This customer already has a portal link (created on another device). It will appear here after sync." — NO blob write, NO rotate.
  - Toggle: optimistic UI OFF — call `managePortal('set_enabled', id, next)` first; on ok write the blob copy; on failure Alert and leave the switch as it was (instant server-side revocation is the feature; a lying switch defeats it).
  - Rotate: destructive confirm (unchanged copy) → `managePortal('rotate', id)` → ok: write new token to blob.
- Test updates: mock `managePortal` in the CustomerDetail suite; pin create-writes-only-after-ok, 409 path shows the Alert without minting, toggle failure leaves the switch, rotate passes through. `portalLink.test.ts`: wrapper URL/auth-header/result-union cases.

Commit: `feat(portal): CustomerDetail portal controls go server-authoritative`

## Self-review notes

- Spec §3a D1-A fully covered; §8 read-events close the Phase C deferral. The resolver's revoked-hash hard-stop is the piece that actually delivers "revocable" — called out as load-bearing.
- portalStore.js remains read-only; all new writes live in portalTokenStore/portalRequestStore.
- Low-entropy fixture rule (fresh gitleaks lesson): every test token/hash fixture uses repeat-char or patterned-low-entropy forms.
- Deploy ordering for the report: apply `portal_tokens` migration → `wrangler deploy` → client rides next OTA. Old clients degrade gracefully via the fallback.

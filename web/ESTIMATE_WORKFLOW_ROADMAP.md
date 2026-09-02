# Web portal: estimate & change-order workflow

Status: **scoped, not started** (companion to `web/EDITING_ROADMAP.md`).

This document scopes the remaining "Estimate and invoice workflow" items from
`web/EDITING_ROADMAP.md` — the ones that were deferred as "Cloudflare
Worker-backed." Read `web/EDITING_ROADMAP.md` first for the write-boundary rules
and the definition of done every new mutation must meet; this doc adds only what
is specific to the estimate/consent flow.

## The key finding

Most of this is more reachable from the browser than "Worker-backed" implies.
The estimate endpoints are plain **JWT-authed HTTP**: the mobile app calls
`POST /api/estimate/create-link` with a native `fetch` and the user's Supabase
access token, and the portal already holds that same token. The Worker mints the
approval token and writes it into the job blob with the service role; the caller
just supplies `{ jobId, snapshot }` (plus `changeOrderId` for a change order) and
receives a customer-facing URL.

Two things make the port cheap:

- The snapshot builders (`buildEstimateSnapshot`, `buildChangeOrderSnapshot` in
  `utils/`) are pure and depend only on `computeEstimateBreakdown` and
  `directCostLabel` — both already ported browser-safe into
  `web/src/ui/billableMath.ts` for the invoice-from-job work.
- The consent/change-order helpers (`applyEstimateDecision`,
  `applyManualDecision`, `validateChangeOrderInput`, `canAddChangeOrder`,
  `newChangeOrderId`, `cancelChangeOrder`) are pure. Recording a change order is
  a normal owner-scoped blob write — no Worker involved at all.

The **only** true backend change is CORS (below). Everything else is a browser
port plus new typed write operations and JobDetail UI.

## Decisions taken

- **CORS scope**: update the Worker's `create-link` endpoint to accept the
  portal origins — `https://app.gettradereadyapp.com` (production, per
  `web/README.md`) and `http://localhost:5173` (local dev) — so link-sending
  works from the portal and can be exercised locally against the live Worker.
- **Status reconciliation**: **derive for display, write on action.** The portal
  computes the reconciled status (a customer's `approval.decision` advancing an
  `estimate_sent` job to `approved`/`declined`) at read time so it never shows a
  stale status, but only writes the advanced status back to Supabase when the
  owner takes an explicit action. No mutation-on-load.

## The one backend change: CORS on `create-link`

`backend-workers/src/routes/estimate/createLink.js` hardcodes
`Access-Control-Allow-Origin: https://gettradereadyapp.com` with a comment that
"CORS never applies to this endpoint (the app calls it with a native fetch)."
A browser POST from the portal is blocked by preflight until that endpoint
echoes the portal origin instead.

Scope of the change (createLink only — the shared `lib/estimate/cors.js`
allowlist is for the *customer approval page* origins, a different concern):

- Echo the caller's `Origin` when it is one of the portal origins above, else
  keep today's static fallback; add `Vary: Origin`.
- The endpoint already returns 200 for `OPTIONS` and already allows the
  `Authorization` and `Content-Type` request headers, so no other preflight work
  is needed.
- There is a parallel Vercel copy at `backend/lib/estimate/createLink.js`. The
  mobile app's `backendUrl` points at the Workers host
  (`https://tradeready-backend.tradeready.workers.dev`), so the portal targets
  the Workers copy; keep the two in parity if the Vercel one is still live.

This ships as its own small backend PR, ahead of the portal link-sending work.

## Web config prerequisite

The web bundle currently hardcodes only the Supabase URL/key (`web/src/lib/
supabase.ts`); there is no backend base URL. Add the Workers base URL the same
way (a hardcoded public constant — it is not a secret), consumed by a new
`web/src/lib/estimateApi.ts` that owns the authed `fetch` to `create-link`.

The `estimateApi.ts` call is a mutation *by proxy* but not a
`supabase.from(...).insert|update|upsert|delete`, so it does not trip the
read-only architecture guard (`readOnly.arch.test.ts`). Keep the actual token
write where it belongs — the Worker — and treat the portal's post-mint local
reconciliation (status stamp) as a normal `writeRepository` operation.

## Workstreams

### 1. Consent-coupled status reconciliation (foundation)

**Browser-only.** Port `applyEstimateDecision` (and the change-order
`changeOrderStatus`/`manualDecision` reading already in
`web/src/ui/changeOrderMath.ts`) so the portal can derive the true status from a
frozen decision. Surface it in `web/src/ui/status.ts` for display, and add a
`writeRepository` op that advances the stored status only when the owner acts.

Why first: it is pure, independently valuable, and fixes a latent bug — today a
job a customer already approved keeps showing "Estimate Sent" in the portal
until the mobile app next syncs and advances it. Every other item below is
incomplete until the portal can reflect the customer's answer.

### 2. Record a change order (+ manual decision)

**Browser-only.** A change order is an object appended to `job.changeOrders`;
recording one is an owner-scoped blob write, exactly like the invoice-from-job
op. Needs:

- Port `newChangeOrderId`, `validateChangeOrderInput`, `canAddChangeOrder`,
  `applyManualDecision`, `cancelChangeOrder` into `changeOrderMath.ts` (all
  pure).
- New `writeRepository` ops: `addChangeOrder` (guarded by `canAddChangeOrder`
  and the approval-lock semantics, fresh-row-merged so it preserves
  server-owned `approval`/history), `recordChangeOrderDecision` (manual on-site
  approve/decline), `cancelChangeOrder`.
- JobDetail UI to add, list (with derived status), decide, and cancel change
  orders.

This also delivers the "revise pricing after an approved decision" item: once a
customer has signed, re-pricing legitimately goes *through* a change order, not
by editing the locked estimate.

### 3. Send an estimate + create its approval link

**Needs the CORS change.** Port `buildEstimateSnapshot` (deps already in
`billableMath.ts`). Flow: build snapshot → `estimateApi` POST to `create-link`
with the session token → the Worker writes `approval` and returns the URL → a
`writeRepository` op stamps `estimate_sent` on the fresh row (preserving the
`approval` the Worker just wrote) → refetch (`retry(['jobs'])`) → surface the URL
for the owner to copy/share. MVP is mint-and-copy; actually emailing the
customer is a separate action (mobile mints and emails independently).

Order matters: mint first (Worker writes `approval`), then stamp status locally,
so the local write builds on the row that already carries the token.

### 4. Send a change-order approval link

**Needs the CORS change.** Same shape as (3) with `buildChangeOrderSnapshot` and
`changeOrderId` in the body; the Worker writes the token into that CO's
`approval`. Builds directly on (2).

### 5. Declined "revise & re-send"

**Browser-only + reuses (3).** A `writeRepository` op resets a declined estimate's
frozen `approval` so the pricing editor unlocks (`canAuthorEstimate` in
`status.ts` gates on `approval.decision`), then the owner re-prices with the
existing editor and re-sends via (3). Care point: this deliberately clears a
frozen consent artifact, so it is an explicit, confirmed owner action.

## Recommended sequencing

1. **Foundation** — workstream 1 (pure, safe, fixes the stale-status bug).
2. **Change orders** — workstream 2 (fully browser-side, no CORS dependency;
   also delivers "revise after approval").
3. **Link-sending** — the CORS backend PR, then workstreams 3, 4, and 5.

Effort: (1) small; (2) medium, comparable to invoice-from-job; the CORS PR
small; (3)/(4)/(5) medium together and gated on the CORS change.

## Cross-cutting concerns

- **Preserve server-owned `approval`.** The Worker writes `approval` via the
  service role. Portal writes must never clobber it — the existing fresh-row
  merges (`updateJobDetails`, `updateJobPricing`) already spread the server row
  and overwrite only their own fields, so `approval`/`changeOrders` survive; new
  ops must keep that discipline.
- **Definition of done.** Every new mutation meets the nine-point contract in
  `web/EDITING_ROADMAP.md` (typed op, boundary validation, fresh-row load,
  owned-field assignment, derived-value reconciliation, tombstone/owner scoping,
  disabled repeat submit, post-write refresh, repository + screen tests).
- **Concurrency.** The mint + status-stamp is two writes; a mint that succeeds
  but a stamp that fails leaves a job with a token but no `estimate_sent` — the
  next send is idempotent (`planApprovalWrite` returns the existing link), so the
  failure is recoverable, matching mobile.

## Non-goals

- The customer-facing approval pages (`estimate.html` / `change.html` on the
  Pages host) and the `respond` / `change-respond` endpoints are the customer's
  side — the portal only reflects their outcome, never reimplements them.
- Emailing the customer directly from the portal. MVP produces the link; the
  owner sends it. Portal-driven email can follow if wanted.

## Files that constrain this work

| File | Contract |
| --- | --- |
| `backend-workers/src/routes/estimate/createLink.js` | Token mint + `approval` write; the CORS change lives here |
| `backend-workers/lib/estimateStore.js` | `planApprovalWrite` freeze/idempotency semantics |
| `utils/estimateSnapshot.ts` | `buildEstimateSnapshot` — port target |
| `utils/changeOrders.ts` | Change-order helpers + `buildChangeOrderSnapshot` — port targets (skip the `escapeHtml`-bound message builders) |
| `utils/jobStatus.ts` | `applyEstimateDecision` and the consent-coupled transition rules |
| `utils/storage/estimateApprovals.ts` | How the device reconciles status from a server-written decision |
| `web/src/ui/billableMath.ts` | Already-ported `computeEstimateBreakdown` / `directCostLabel` the snapshots need |
| `web/src/ui/changeOrderMath.ts` | Existing browser-safe CO status/rollups to extend |
| `web/src/ui/status.ts` | `canAuthorEstimate` approval gate + pipeline the reconciliation feeds |
| `web/src/lib/writeRepository.ts` | Home of every new typed mutation |
| `web/README.md` | Portal production origin (`app.gettradereadyapp.com`) for the CORS allowlist |

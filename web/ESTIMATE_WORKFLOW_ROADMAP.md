# Web portal: estimate and change-order workflow

Status: **revised scope, not started** (companion to
`web/EDITING_ROADMAP.md`).

This document scopes the remaining estimate-consent and change-order work in
the web portal. Read `web/EDITING_ROADMAP.md` first for the existing write
boundary and its nine-point definition of done. This document adds the
workflow-specific data-integrity, delivery, refresh, and rollout requirements.

The target outcome is not merely feature parity with mobile. The portal must
preserve the exact estimate or change the customer reviewed, retain prior
decisions, and avoid losing a customer response when the portal, mobile app,
and Cloudflare Worker touch the same Job blob concurrently.

## Current implementation boundary

The browser can call `POST /api/estimate/create-link` with the user's Supabase
access token. The Worker verifies that session, mints the capability token, and
writes the approval object into the owner-scoped job. The existing customer
pages and `respond` / `change-respond` endpoints remain the customer side of
the flow.

Much of the domain logic is already reusable:

- `buildEstimateSnapshot` and `buildChangeOrderSnapshot` are pure. Their
  pricing dependencies already have browser-safe equivalents in
  `web/src/ui/billableMath.ts`.
- `applyEstimateDecision`, `validateChangeOrderInput`, `canAddChangeOrder`,
  `applyManualDecision`, `cancelChangeOrder`, and the change-order rollups are
  pure and can be ported without React Native dependencies.
- The portal already has a typed write boundary, fresh-row reads,
  field-scoped conflict handling, post-write refresh, and screen/repository
  tests to extend.

Two existing properties are not sufficient for this workflow:

1. A fresh-row spread preserves unrelated top-level fields, but it does not
   merge two concurrent edits to `job.changeOrders`. The Worker and clients
   currently replace the complete JSON blob after a read.
2. A status derived from `approval.decision` is correct only after the portal
   has fetched that Worker-written decision. The current focus refresh and
   same-origin `BroadcastChannel` do not make a focused tab aware of a
   customer's response immediately.

Therefore CORS is required, but it is not the only backend work. A
concurrency-safe conditional-write contract is a prerequisite for expanding
the number of Job-blob writers.

## Product and architecture decisions

### Consent and revision history

- An approved base estimate is immutable. Post-approval scope or price changes
  are new change orders; they do not rewrite the estimate the customer signed.
- A declined estimate may be revised, but its approval record is first appended
  unchanged to `job.approvalHistory`. The active `job.approval` is then cleared
  atomically so its old token stops resolving and a later send mints a new
  token and snapshot.
- `approvalHistory?: EstimateApproval[]` is additive on the Job blob. It is
  append-only, is never exposed to the customer approval endpoint, and must be
  preserved by every client and Worker write.
- Any active approval artifact locks snapshot-affecting estimate fields, even
  before a decision. An owner who needs to change an open estimate must use an
  explicit **Withdraw link and revise** action. That action stamps
  `withdrawnAt`, archives the attempt, clears the active approval, and
  invalidates its token before the editor unlocks.
- The portal labels this action **Revise declined estimate**. It never offers
  the action for an approved estimate.

### Link creation is not delivery

- Minting an estimate link creates a frozen review artifact; it does not prove
  the owner delivered it. A successful mint leaves the stored job status
  unchanged and presents the URL as **Link ready**.
- The owner explicitly confirms **Mark estimate as sent** after sharing it.
  That action stamps `approval.sharedAt`, `status: estimate_sent`, and
  `estimateSentAt` on the authoritative job. Automated follow-up timing starts
  from that confirmation, not token creation.
- A change-order link follows the same distinction. Add optional server-stamped
  `sharedAt?: DateString` and `withdrawnAt?: DateString` fields to the reusable
  `EstimateApproval` artifact. The portal owns only the request to stamp these
  fields; the conditional server mutation owns their clock values. Its derived
  states are `pending`, `ready`,
  `awaiting`, `approved`, `declined`, and `cancelled`: an approval token without
  `approval.sharedAt` is `ready`; `approval.sharedAt` without a decision is
  `awaiting`.
- Copying a link is not itself proof of delivery. The UI keeps **Copy link** and
  **Mark sent** as separate actions and explains that distinction.

### Status reconciliation and freshness

- Add one browser-safe `effectiveJobStatus(job)` helper that applies a frozen
  estimate decision without mutating the record or regressing
  `scheduled` through `paid`.
- All web badges, estimate filters, pipeline rendering, and action eligibility
  use the effective status. Raw `job.status` remains the stored synchronization
  field.
- While a visible Job or Estimate detail screen has an awaiting decision, poll
  the `jobs` collection at a modest interval (start with 15 seconds), stop when
  the tab is hidden or the decision lands, and provide an explicit Refresh
  action. Do not claim live freshness outside those conditions.
- Every owner mutation reloads the authoritative job, derives its effective
  status, applies the requested action against that state, and persists any
  necessary status reconciliation in the same conditional write. Do not issue
  a preliminary “reconcile status” write followed by a second business write.

### Backend and configuration

- Cloudflare Workers is the canonical production backend for this workflow.
  **Resolved (2026-09-02):** the Vercel copy (`backend/`) is dormant and
  unrouted — every client points at `tradeready-backend.tradeready.workers.dev`
  (`app.json`, `jest.setup.js`; the web portal calls no estimate mutation yet),
  and the docs record it as a rollback target held since the 2026-08-06 cutover.
  Therefore all Phase 0 conditional-write and CORS work targets
  `backend-workers/` only; there is no dual-backend test matrix. `backend/` stays
  frozen as-is. Remaining action: confirm the Vercel project's reminder cron is
  disabled (or the project paused) so it cannot double-send, then formally mark
  `backend/` decommissioned.
- The web client reads `VITE_BACKEND_URL`, with the Workers production URL as a
  documented production default. Production builds reject non-HTTPS values;
  local development may use `http://localhost`.
- `web/src/lib/estimateApi.ts` is the only web module allowed to call
  business-mutation HTTP endpoints. Extend the architecture test so moving
  such calls into an arbitrary screen fails the repository gate.

## Prerequisite: concurrency-safe Job writes

The existing Worker sequence is fetch Job -> modify nested approval data ->
replace the Job blob. The portal's planned change-order writes would add more
read-modify-write races. Before adding those operations, introduce a shared
conditional-write contract based on the authoritative database `updated_at`.

Required behavior:

1. Job reads used for a mutation return `data` and `updated_at`.
2. The write supplies the exact version it read and updates only when that
   version is still current.
3. A zero-row update is a conflict, never a success.
4. On conflict, refetch and perform a bounded retry only when the requested
   operation can be safely reapplied by stable change-order ID.
5. If the same approval, decision, cancellation, revision, or editable field
   changed, stop and return a typed conflict for owner review.
6. The database trigger remains the sole authority for the new `updated_at`.
   Worker writes must stop supplying their own timestamp.

The same contract applies to portal writes and these Worker actions:

- mint an estimate link;
- mint a change-order link;
- record an estimate decision;
- record a change-order decision.

The merge rules are operation-specific:

| Operation | Safe retry after unrelated conflict | Same-target conflict |
| --- | --- | --- |
| Add change order | Reappend if its stable ID is absent | Duplicate ID is an error |
| Edit pending change order | Reapply when target is still pending and unchanged from baseline | Show conflict |
| Delete pending change order | Reapply when target is still pending and unchanged | Show conflict |
| Cancel change order | Reapply when still undecided | Existing decision wins |
| Manual decision | Reapply when no link decision/manual decision/cancellation landed | Existing outcome wins |
| Mint approval link | Rebuild from fresh data; retry only while target remains eligible | Decision/cancellation wins |
| Customer decision | Retry only while token still matches and no terminal outcome landed | Existing terminal outcome wins |
| Withdraw undecided estimate link | Archive once when the token still matches | Decision wins |
| Archive declined estimate approval | Append the exact active approval once | Changed active approval is a conflict |

Tests must interleave every portal operation with a Worker decision and prove
that neither side is silently lost.

## Backend work

### Conditional persistence

Extend `backend-workers/lib/estimateStore.js` with versioned fetch and
conditional update helpers, and use them from `createLink`, `respond`, and
`changeRespond`. Do not keep an unconditional upsert for approval mutations.

Return `409 Conflict` when a bounded retry cannot safely resolve a race. Error
responses must not reveal whether a different user's job exists.

### CORS on `create-link`

`backend-workers/src/routes/estimate/createLink.js` currently emits a static
`Access-Control-Allow-Origin`. For browser calls:

- Echo `Origin` only when it is in the explicit allowlist:
  `https://app.gettradereadyapp.com` and `http://localhost:5173`, plus any
  separately documented staging origin.
- Keep the current marketing-site origin only if a real caller still needs it.
- Add `Vary: Origin` to preflight and POST responses.
- Keep `POST, OPTIONS` and the `Authorization, Content-Type` request headers.
- Do not use `*` and do not add credentialed-cookie CORS; authorization remains
  the bearer token.
- Test allowed, disallowed, absent, production, local, and staging origins on
  success and error responses.

### Approval request contract

`POST /api/estimate/create-link` gains `expectedUpdatedAt`. The caller must
have freshly loaded the target version. The Worker verifies ownership and
eligibility, then conditionally writes the approval artifact.

For an estimate, the Worker rejects minting when:

- the job is deleted or not owned by the authenticated user;
- the estimate total is not positive;
- a terminal approved decision exists;
- the expected version is stale.

If an identical undecided active artifact already exists, the endpoint returns
its existing link idempotently. If an active artifact exists but its snapshot
does not match the requested fresh snapshot, it returns `409`; the owner must
withdraw that artifact before revising. The pricing editor is unavailable
while any active approval artifact exists.

For a change order, it additionally verifies that the stable ID exists, the
order is neither decided nor cancelled, and its title/amount still match the
submitted frozen snapshot.

The response remains `{ url, token, sentAt }`. It never returns another user's
data or logs the bearer token, capability token, or complete approval URL.

## Web workstreams

### 1. Effective status and approval refresh

Port `applyEstimateDecision` and add `effectiveJobStatus(job)`. Update all job
and estimate badges, filters, timelines, and action gates to use it. Add the
visible-awaiting polling and explicit Refresh behavior described above.

Add a typed conditional Job mutation helper inside `writeRepository.ts` so
each later operation can act on effective status and persist reconciliation in
one write.

### 2. Complete change-order authoring

Port the browser-safe helpers into `changeOrderMath.ts`, including the new
`ready` state. Add typed operations:

- `addChangeOrder`;
- `updatePendingChangeOrder`;
- `deletePendingChangeOrder`;
- `recordChangeOrderDecision`;
- `cancelChangeOrder`;
- `markChangeOrderSent`.

The create/edit form includes title, optional description, and signed amount.
Negative credits are allowed only when the authoritative billable total cannot
fall below zero. Use a collision-resistant ID suitable across tabs and devices
(`crypto.randomUUID()` with a supported fallback), not a process-local counter.

The UI action matrix is:

| Derived state | Allowed actions |
| --- | --- |
| Pending | Edit, delete, create link, manually approve/decline, cancel |
| Ready | Copy link, mark sent, manually approve/decline, cancel |
| Awaiting | Copy/re-send link, manually approve/decline, cancel, refresh |
| Approved | View immutable consent details |
| Declined | View immutable decision details |
| Cancelled | View immutable cancellation details |

Every destructive or consent-bearing action requires clear confirmation,
disables repeat submission, preserves the form on failure, and is keyboard and
screen-reader accessible.

### 3. Authoritative estimate-link creation

Add `estimateApi.ts` with session acquisition immediately before each request,
runtime response validation, an abort/timeout path, and typed handling for
`401`, `409`, `422`, `429`, malformed JSON, and network failures.

The screen passes its rendered baseline to the operation. At action time:

1. Reload the authoritative job, customer, and settings.
2. Compare all snapshot-affecting job fields with the displayed baseline.
3. If they differ, refresh the review and require the owner to confirm again.
4. Build the snapshot from the fresh values.
5. Call `create-link` with `expectedUpdatedAt`.
6. Refetch the job and display **Link ready** with Copy and Mark sent actions.

The Worker-written `approval` is never mirrored from the HTTP response into a
stale browser Job object. Refetching the authoritative row is the only local
reconciliation after minting.

### 4. Change-order approval links

Reuse the API contract and freshness checks for one stable change-order ID.
Before building the snapshot, verify that the fresh entry matches the displayed
title and amount and is still pending or ready. A changed, decided, deleted, or
cancelled entry requires a refresh rather than a send.

Minting creates the ready state. `markChangeOrderSent` stamps the matching
`approval.sharedAt` through the conditional Job mutation boundary and advances
the derived state to awaiting.

### 5. Revision-preserving declined estimate flow

Add `beginDeclinedEstimateRevision`, restricted to an effective declined state.
In one conditional write it:

- appends the exact active approval to `approvalHistory` if not already there;
- clears the active `approval` so the old capability token becomes invalid;
- returns the job to `lead` and clears the current `estimateSentAt`;
- leaves the archived approval snapshot and consent metadata unchanged.

The owner then edits pricing with the existing editor and creates a completely
new link through workstream 3. Repeated clicks are idempotent and cannot append
the same approval twice.

Add the sibling `withdrawOpenEstimateForRevision`, restricted to an active
undecided approval. It stamps `withdrawnAt` with server time, appends that exact
artifact to `approvalHistory`, clears the active approval, and invalidates the
old link in one conditional write. If a customer decision lands first, the
withdrawal fails with a conflict and the decision remains authoritative.

## Architecture guard and API safety

The current source scan catches direct Supabase mutations outside
`writeRepository.ts`, but it cannot recognize a mutating HTTP fetch. Extend it
so:

- `estimateApi.ts` is the only source file allowed to call the configured
  backend's business-mutation routes;
- screens cannot call `/api/estimate/create-link` directly;
- the allowlist test fails if the designated API module disappears or no longer
  contains a mutation call;
- no service-role credential or provider secret can enter `web/src`.

Unit tests for `estimateApi.ts` cover session expiry, token refresh, timeouts,
non-JSON error bodies, every documented HTTP status, and response shape
validation.

## Recommended sequencing and gates

### Phase 0 — decisions and backend authority

1. Confirm Workers as canonical and resolve the Vercel copy. **Done
   (2026-09-02):** Workers is canonical; the Vercel `backend/` is dormant and
   unrouted, so tasks 3–4 target `backend-workers/` only. Follow-up before
   decommission: verify the dormant Vercel reminder cron cannot double-send. See
   the Backend and configuration decision above.
2. Add `approvalHistory` plus approval `sharedAt` / `withdrawnAt` to the shared
   model and parity tests.
3. Implement versioned reads and conditional Job writes in the Worker. **Done
   (2026-09-02):** `backend-workers/lib/estimateStore.js` gains
   `fetchJobVersioned` / `fetchJobForUserVersioned` (behavior #1),
   `conditionalUpdateJob` (an `updated_at=eq` guarded PATCH that treats a
   zero-row write as a conflict and sends no client timestamp — behaviors #2,
   #3, #6), and `updateJobConditionally`, a bounded retry loop that delegates the
   operation-specific safe-reapply decision to a caller `plan` (behaviors #4,
   #5). The DB-trigger prerequisite (`set_updated_at_trg`, migration 20260831)
   is already in place. Covered by `__tests__/estimateStoreConditional.test.js`.
4. Convert create/respond/change-respond to the conditional contract. **Done
   (2026-09-02):** all three Workers routes now write through
   `updateJobConditionally` with an operation-specific `plan` — customer
   estimate/change decisions re-check the token on the freshest version and hold
   the terminal lock; link minting reuses one token across retries and freezes
   an already-approved snapshot. Status codes and response shapes are unchanged;
   the now-unused unconditional `upsertJob` was removed. Covered by
   `__tests__/estimateRouteConditionalWorkers.test.js`, whose concurrency cases
   prove an owner edit + customer decision both survive, a racing manual decision
   beats a stale customer link (loser gets 409), and a customer approval landing
   before a re-send wins (no second token, snapshot not regressed).

**Gate:** all Worker tests pass, including the complete concurrency matrix. Do
not begin portal mutations until customer decisions are proven lossless.

### Phase 1 — read-side truth

Implement effective status, ready/awaiting change-order states, polling,
explicit refresh, and read-only UI updates.

**Gate:** a customer response made in another browser appears without a tab
focus cycle; no read path mutates Supabase; later pipeline statuses never
regress.

### Phase 2 — change-order authoring and manual outcomes

Implement the full pending lifecycle and conditional manual/cancel/send
operations.

**Gate:** repository and screen race tests pass; the first conditional terminal
outcome wins and a racing manual decision, customer decision, or cancellation
receives a conflict instead of overwriting it; pending edit/delete rules and
negative-credit validation are covered.

### Phase 3 — link APIs and CORS

Ship configuration, the guarded HTTP API module, CORS, authoritative snapshot
review, estimate links, and change-order links.

**Gate:** lint, typecheck, unit tests, production build, Worker tests, and a
browser-to-live-Worker smoke test all pass. Verify production and localhost
preflight behavior before exposing the UI.

### Phase 4 — declined revisions

Implement immutable approval history and revise/re-send.

**Gate:** the old link is invalid, the old snapshot and decision remain visible
to the owner, the new link has a new token and snapshot, and repeated revision
actions do not duplicate history. The same assertions cover withdrawing an
undecided link, including a customer-decision race.

### Phase 5 — cross-client release verification

Run these end-to-end scenarios with a test account:

1. Web creates link -> owner marks sent -> customer approves -> focused web
   screen refreshes -> owner schedules the job.
2. Web creates change -> customer approves while another web tab edits an
   unrelated job field -> both changes survive.
3. Web starts a manual decision while customer decides -> exactly one terminal
   outcome survives and the loser receives a conflict.
4. Customer declines -> owner archives and revises -> old link fails -> new
   snapshot can be approved.
5. Mobile syncs after each web path and preserves approval history,
   approval delivery/withdrawal stamps, status, and change orders.

Record telemetry for link minted, link copied, owner-confirmed sent, approved,
declined, conflict, and failure. Do not record capability URLs or tokens.

**Gate:** update `web/README.md`, `web/EDITING_ROADMAP.md`, architecture notes,
and shipped-feature claims only after the live Worker/customer-page/mobile-sync
smoke tests pass.

## Non-goals

- Reimplementing the public estimate or change-order customer pages in React.
- Sending email or SMS directly from the portal in this release. The portal
  creates and copies links and records an explicit owner delivery confirmation.
- Editing an approved estimate. All post-approval scope changes are separate
  change orders.
- An offline web mutation queue. Failed browser writes remain visible and
  retryable, but require a connection.
- A generic Job writer or generic conflict merger. Every mutation keeps a typed
  domain contract and operation-specific conflict rules.

## Definition of done

In addition to the nine-point mutation contract in `EDITING_ROADMAP.md`, this
project is complete only when:

1. No portal or Worker action can silently overwrite a concurrent approval,
   manual decision, cancellation, revision, or separate change order.
2. Every approval snapshot is built from an authoritative version reviewed by
   the owner and conditionally frozen against that same version.
3. Link creation and owner-confirmed delivery are distinct in data, UI, and
   telemetry.
4. An active approval artifact locks snapshot-affecting estimate fields;
   declined and withdrawn revisions preserve immutable prior snapshots and
   metadata and invalidate old links.
5. Focused awaiting screens refresh customer outcomes without a focus cycle and
   expose a manual refresh fallback.
6. Pending change orders support title, description, signed amount, edit, and
   delete; all later states are immutable except the specifically allowed
   manual/cancel/send actions above.
7. CORS and API error behavior are tested for all configured environments.
8. Repository, screen, architecture, Worker, cross-tab, and cross-client tests
   pass, followed by lint, typecheck, and the production web build.
9. Documentation describes only behavior that passed the live release smoke
   test.

## Files that constrain this work

| File | Contract |
| --- | --- |
| `backend-workers/src/routes/estimate/createLink.js` | Authenticated token minting, eligibility, conditional write, and portal CORS |
| `backend-workers/src/routes/estimate/respond.js` | Estimate decision freeze and conditional persistence |
| `backend-workers/src/routes/estimate/changeRespond.js` | Per-change decision freeze and race handling |
| `backend-workers/lib/estimateStore.js` | Versioned reads and conditional Job persistence |
| `utils/estimateSnapshot.ts` | Canonical estimate snapshot shape |
| `utils/changeOrders.ts` | Change-order validation, status, decisions, cancellation, and snapshot rules |
| `utils/jobStatus.ts` | Consent-coupled transition and no-regression rules |
| `utils/storage/estimateApprovals.ts` | Current mobile reconciliation behavior to keep compatible |
| `types/models.ts` | Additive approval-history and approval delivery/withdrawal fields |
| `web/src/ui/billableMath.ts` | Browser-safe estimate breakdown dependencies |
| `web/src/ui/changeOrderMath.ts` | Browser-safe status and rollups to extend |
| `web/src/ui/status.ts` | Effective status, action gates, badges, and pipeline |
| `web/src/lib/writeRepository.ts` | Typed conditional owner mutations |
| `web/src/lib/estimateApi.ts` | Sole browser HTTP mutation client |
| `web/src/lib/readOnly.arch.test.ts` | Direct-Supabase and backend-mutation source guard |
| `web/src/lib/DataContext.tsx` | Scoped refresh and awaiting-decision polling |
| `web/README.md` | Environment, deployment, and shipped-product documentation |

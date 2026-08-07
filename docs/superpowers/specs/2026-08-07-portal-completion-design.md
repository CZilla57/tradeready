# Customer Portal Completion (Phase 12) — Design Spec

**Date:** 2026-08-07
**Status:** DESIGN — stopped for owner approval per the kickoff prompt ("Stop for approval" before any schema or backend change)
**Origin:** Roadmap Phase 12 kickoff (owner-curated 2026-08-06, `docs/post-launch-feature-roadmap.md:260-310`)
**Builds on:** v1 portal spec `2026-08-04-customer-portal-design.md` (live since 2026-08-05, master `4339848`); Phase 11 booking/manage (`2026-08-07-calendar-availability-booking-design.md`); job-photos R2 (2026-08-06)

## 0. Precondition corrections (verified against the repo today)

- The roadmap note "portal branch unmerged" is STALE: `4339848` is in master
  history, backend deployed on both twins, portal.html live, device-smoked
  2026-08-05.
- The capability-6 blocker (job-photos R2) cleared 2026-08-06: `jobPhotos`
  synced collection + `/api/photos/:photoId` (Workers, JWT-authed) exist.
- portal.html calls the **Workers** backend only (`portal.html:39`). The
  Vercel `portal-view` twin still exists but receives no page traffic.

## 1. Scope — the 8 capabilities, mapped to build vs reuse

| # | Capability | Verdict |
|---|---|---|
| 1 | Upcoming appointment details | **Additive read.** Schedule fields already live on the jobs `portal-view` fetches (`Job.scheduledDate/StartTime/EndTime`); today they're filtered out by the whitelist. Add an `appointments[]` section. |
| 2 | Add-to-calendar | **Reuse + small new read.** `buildIcs` exists (`backend-workers/lib/booking/ics.js`) but is keyed to booking manageTokens. Add a portal-token-authenticated ICS endpoint for job appointments. |
| 3 | Estimate status + approval | **Shipped in v1.** No change. |
| 4 | Change-order viewing + approval | **Additive read.** change.html + `change-view`/`change-respond` are live; the portal just doesn't list COs. Add `changeOrders[]` linking to the shipped pages. Declined-is-FINAL 409 untouched. |
| 5 | Invoice total / paid-to-date / balance / pay | **Mostly shipped.** `amount`, `balanceDue`, gated `paymentLinkUrl` already returned. Add explicit `amountPaid` (ledger math — `paymentMath.amountPaid` exists in both twins) instead of page-side subtraction. Pay-link amount gate (PAID_EPSILON + host allowlist + `!paid`) is load-bearing and unchanged. |
| 6 | Customer-visible documents/photos | **New build.** Needs: per-photo visibility flag (none exists), an anonymous-reader delivery path (none exists — photos GET is owner-JWT-only), short-lived signed URLs (no signing mechanism exists anywhere in either backend). Photos only in this phase; see §11 for why "documents" defers. |
| 7 | Request follow-up work | **New build — the portal's first write path.** Reuse the `bookingRequests` machinery end-to-end (insert + owner push + device lead conversion). |
| 8 | Request reschedule / cancellation | **Split.** Appointments that originated as bookings: link to the shipped `booking.html?m=<manageToken>` page — zero new writes, full Phase-D state machine + audit history. Owner-scheduled jobs (no booking behind them): covered by the same request write as #7 with a `reschedule`/`cancel` kind. |

## 2. Response schema — current vs proposed

### Current (`portal-view`, both twins, whitelist-tested)

```jsonc
{
  "businessName": "…",              // ≤120
  "customerName": "…",              // ≤120
  "estimates": [ { "title", "total", "decision", "approvalUrl" } ],
  "invoices":  [ { "number", "amount", "balanceDue", "due", "paid", "paidAt", "paymentLinkUrl" } ]
}
```

### Proposed (additive — old portal.html keeps working against the new response)

```jsonc
{
  "businessName": "…",
  "customerName": "…",

  "appointments": [ {              // NEW — this customer's scheduled jobs
    "title": "…",                  // job title, ≤200
    "date": "YYYY-MM-DD",          // owner-naive, rendered via UTC getters (booking.html precedent)
    "start": "HH:MM" | null,
    "end":   "HH:MM" | null,
    "icsUrl": "…/api/estimate/portal-ics?p=<token>&j=<jobId>",   // NEW endpoint, §4
    "manageUrl": "…/booking.html?m=<manageToken>" | null,
    //   present only when the job originated from a booking (matched via
    //   bookingRequests.convertedJobId) — reuses shipped Phase-D confirm/
    //   reschedule/cancel + audit history
    "jobRef": "<jobId>"            // needed by the request write (§5); jobIds
    //   already cross the wire today inside approvalUrl — not a new exposure
  } ],

  "estimates": [ /* unchanged */ ],

  "changeOrders": [ {              // NEW — only link-carrying COs (mirrors the
    "jobTitle": "…",               //   estimates rule: no approval.token → invisible)
    "title": "…",                  // CO title, ≤200
    "amount": 123.45,              // may be negative (descope credit)
    "status": "awaiting" | "approved" | "declined" | "cancelled",  // derived
    //   via the same precedence as changeOrderStatus (manualDecision counts)
    "changeUrl": "…/change.html?j=<jobId>&co=<coId>&t=<approval.token>"
  } ],

  "invoices": [ {
    /* the 7 existing fields unchanged, plus: */
    "amountPaid": 100.00           // NEW — ledger-derived paid-to-date
  } ],

  "photos": [ {                    // NEW — ONLY photos with customerVisible === true
    "jobTitle": "…",               // caption; grouped client-side
    "url": "…"                     // short-lived signed URL (§6); NEVER persisted
  } ]
}
```

**Whitelist discipline unchanged:** every new section is constructed
key-by-key (no spreads), extended exact-keys leak test on both twins.
Appointment selection rule: jobs with a `scheduledDate`, not archived, status
not terminal/declined, date within `[today−1, +60d]` (string-compared,
owner-naive, FA-039-safe). Exact bounds finalized at plan phase.

**What still never crosses the wire:** internal notes, costs/labor rates/
margins, AI content, local file paths, other customers, contact info,
non-visible photos, raw R2 keys, Supabase ids other than job/CO ids already
exposed by the shipped link URLs.

## 3. Authorization design

### 3a. Token model — the "server-owned table" kickoff item (Decision D1)

Today: `Customer.portal = {token, enabled}` is device-written, synced in the
customer blob; the backend resolves it via an **unindexed JSON-path scan**
(`customers?data->portal->>token=eq.…`). Known residuals: LWW clobber
(re-mint heals), revocation is eventually-consistent behind device sync.

The kickoff asks: "Move portal capability tokens into a server-owned table
if not already completed." It is not completed. Two options:

**Option A — server-owned `portal_tokens` table (recommended; matches the
kickoff):**

```sql
create table portal_tokens (
  token_hash text primary key,      -- sha256(token); raw token never stored
  user_id uuid not null references auth.users(id) on delete cascade,
  customer_id text not null,
  enabled boolean not null default true,
  created_at timestamptz default now(),
  revoked_at timestamptz            -- one-way stamp
);
-- owner-scoped RLS per the multi-tenant floor (booking_reservations precedent);
-- device never reads it; service-role writes only via the mint/manage endpoints.
```

- Mint becomes stateful: `/api/booking/mint` stays untouched (booking links
  still use it); the portal gets a small JWT-authed `portal-mint` action that
  mints AND inserts the row, returning the raw token once. Enable/disable/
  rotate become JWT-authed server calls; rotate stamps `revoked_at` on the
  old row. Lookup becomes an indexed primary-key hit on `token_hash` —
  also fixing the scan.
- The device keeps a **display copy** in `Customer.portal` (so the URL row
  and share sheet still work offline) but the server column is authoritative
  for auth; the LWW clobber class stops mattering for security.
- Migration/back-compat: portal-view looks up `portal_tokens` first, falls
  back to the blob path for pre-existing tokens; CustomerDetail backfills a
  row on the first portal action per customer. Fallback removed at a later
  cleanup phase.
- Cost: one migration, mint divergence from the booking convention (booking
  stays stateless — deliberate, documented asymmetry), ~4 small endpoints/
  actions instead of 0.

**Option B — keep device-owned, decline this kickoff item** (status quo +
document why). Zero migration, keeps mint symmetry with booking. Residuals
stay. Only pick if the owner overrides the kickoff.

### 3b. Per-surface authorization table (proposed end state)

| Surface | Auth | Writes |
|---|---|---|
| `portal-view`, `portal-ics` | portal token (server table w/ blob fallback) | none |
| photo bytes | short-lived HMAC-signed URL (§6) | none |
| estimate approve/decline | per-job `approval.token`, constant-time (shipped) | jobs blob (shipped) |
| CO approve/decline | per-CO `approval.token` (shipped, declined-FINAL 409) | jobs blob (shipped) |
| booking manage (confirm/reschedule/cancel + ICS) | per-booking `manageToken` (shipped) | bookingRequests + reservation (shipped) |
| `portal-request` (NEW, §5) | portal token | bookingRequests insert only |
| portal mint/enable/rotate (NEW if D1=A) | owner Supabase JWT | portal_tokens |

Tenant isolation invariant unchanged: every jobs/invoices/photos query is
filtered by BOTH `user_id` and `customerId`; R2 keys are prefix-derived from
the record's `user_id`, never from caller input.

## 4. Add-to-calendar (`portal-ics`)

`GET /api/estimate/portal-ics?p=<token>&j=<jobId>` → resolves the portal
token, verifies the job belongs to that user AND that customer, then emits
one VEVENT via the existing `buildIcs` escaping/formatting.

Timezone decision: booking slots carry stored UTC instants; owner-scheduled
jobs are **naive** local strings with no zone. Proposal: emit **floating
local time** (RFC 5545 DTSTART with no `Z`/TZID) for job appointments —
correct for the trades case (customer and business in the same locale), zero
new timezone machinery, no DST edge cases. When the appointment originated
from a booking, portal.html prefers the booking manage ICS link (real UTC).
Alternative (rejected for now): convert via `Settings.timeZone` — only
stamped when bookable slots were ever enabled, so it would be absent for
many users; floating time degrades more gracefully.

## 5. The write path: `portal-request` (capabilities 7 + 8)

One new action, `POST /api/estimate/portal-request`, body
`{p, kind: "followup" | "reschedule" | "cancel", note, jobRef?, requestKey}`.

- **Reuses the bookingRequests machinery** — `insertBookingRequest` +
  `notifyOwner` from `lib/booking/` (imported, not duplicated). The
  READ-ONLY contract on `portalStore.js` stays intact: the write lives in a
  separate `portalRequest` module; portalStore is untouched.
- `kind: "followup"` → row `status: "new"`, name/contact copied server-side
  from the resolved customer record, plus `source: "portal"` and
  `sourceCustomerId` so the device conversion links the EXISTING customer
  (id-keyed, not name-matched) and creates the lead job. Existing push +
  Today pipeline fire unchanged.
- `kind: "reschedule" | "cancel"` (owner-scheduled appointments only — booked
  ones use the manage page) → row `status: "new"` with `jobRef` echoed and a
  templated note ("Reschedule requested for <date> — <note>"). It surfaces
  through the existing new-request push/Today path; it does NOT touch the
  jobs blob and does NOT auto-convert to a lead (conversion skips rows
  carrying `kind: "portal_appointment_request"` — exact skip mechanism
  finalized at plan phase). No new BookingRequest status values needed.
- **Idempotent:** the page mints a random `requestKey` per form render;
  the server derives the row id deterministically from
  `sha256(token + requestKey)` and inserts with
  `Prefer: resolution=ignore-duplicates` — a network retry lands on the same
  row, no double lead, no double push.
- **Server-timestamped:** `createdAt`/history stamped server-side
  (`new Date().toISOString()`), never trusted from the page.
- **Stale-device-safe:** pure INSERT of a new row — never read-modify-write
  of an existing blob, so the estimate/CO stale-write exposure class does not
  apply to this path.
- Abuse posture: honeypot field (booking-submit precedent), note capped 300
  (manage precedent), rate limit 10/min/IP + per-token 5/day durable cap via
  the log table (§8) — the in-memory limiter alone is per-isolate and
  insufficient for a write path.

New optional `BookingRequest` fields (`source?`, `sourceCustomerId?`,
`jobRef?`, request-kind marker) = **persisted-shape change → needs owner
approval** (Decision D3).

## 6. Photos: visibility flag + signed URLs (capability 6)

- **`JobPhoto.customerVisible?: boolean`** — additive optional, ABSENT MEANS
  HIDDEN (fail closed). Owner toggles per photo in JobDetail's photo viewer
  ("Visible to customer"). Persisted-shape change → **owner approval
  (Decision D2)**.
- **Delivery — short-lived HMAC-signed URLs** (kickoff requirement):
  `GET /api/photos-public/<photoId>?u=<userId>&e=<expiryEpoch>&s=<hmac>`
  where `s = HMAC-SHA256(PORTAL_URL_SIGNING_SECRET, userId|photoId|e)`.
  - Signed at `portal-view` response time for each visible photo; TTL ~15
    minutes (a portal page session), so a photo untoggled by the owner
    disappears within the TTL without a per-fetch DB read.
  - Verified with `constantTimeEqual`; expired/invalid → 404, oracle-free.
  - Streams from R2 with `Cache-Control: private, max-age=300`.
  - **Never persisted** — signatures are computed per response (kickoff:
    "Do not persist signed URLs in database records"). Nothing new is
    written anywhere.
  - New Workers secret `PORTAL_URL_SIGNING_SECRET` (wrangler secret; missing
    secret → photos section omitted, portal otherwise works — fail-soft).
  - The existing owner-JWT `/api/photos/:photoId` route is untouched.
- Only photos with `uploadedAt` set are offered (bytes known to be in R2).
- Portal shows photos grouped by job title; no filenames, ids only inside
  the signed URL.

## 7. Threat model (delta over v1)

**Assets:** customer PII (names, appointment times), financial data (invoice
amounts, balances), job photos (potentially interiors of homes), the owner's
lead pipeline integrity.

| Threat | Mitigation |
|---|---|
| Token guessing | 192-bit CSPRNG tokens (unchanged); indexed hash lookup (D1-A) removes the timing surface of the JSON scan; constant-time compares on all per-object tokens. |
| Link leakage / forwarding | Accepted-by-design for capability links (documented on the page footer). New: photos add sensitivity — visibility is opt-in per photo, and signed URLs expire ~15 min, so a forwarded portal URL exposes photos only while the recipient holds the live portal link (same trust level as the rest of the portal). |
| Cross-tenant read | Unchanged invariant: user_id + customerId on every query; R2 keys prefix-derived server-side. Signed URL binds userId+photoId; tampering breaks the HMAC. |
| Overcharge via stale pay link | Shipped PAID_EPSILON gate unchanged; `amountPaid` is display-only. |
| Phishing via response URLs | All URLs constructed server-side from constants (`estimate.html`/`change.html`/`booking.html` bases, allowlisted payment hosts); page `esc()`s everything. |
| Write abuse (spam leads) | Honeypot + IP limit + durable per-token daily cap + note length cap; inserts only (no blob RMW); idempotency key kills retry dupes. Owner push makes floods visible immediately; disable/rotate kills the token. |
| Stale-device overwrite | New write path is insert-only; existing estimate/CO RMW exposure is unchanged (documented residual, out of scope here). |
| Token in logs | Standing rule kept: no token values in any log line; the new security log stores a token **prefix** (8 chars) only (§8). |
| Revocation lag | D1-A makes disable/rotate server-authoritative and instant (no sync round-trip). Archive behavior stays "archiving does NOT disable the portal" — deliberate, re-documented (kickoff asks for this to be explicit). |

## 8. Rate limiting + security logging

- Reads keep the in-memory limiter (30/min/IP) — cost ceiling, fine for
  GETs.
- **New durable log table `portal_access_log`** (service-role writes,
  owner-RLS like the sibling log tables): `{user_id, token_prefix (8 chars),
  event: view|ics|photo|request|denied, ip, created_at}`. Written
  best-effort (never throws, `markLog` convention). Serves three purposes:
  the kickoff's "security logging without logging raw portal tokens", the
  durable per-token write cap (§5), and future "portal was viewed" surfacing
  (not built this phase). Retention/pruning decided at plan phase.
  This is a migration → listed under Decision D4.

## 9. Customer flow (portal.html)

Single page, sections in order: header (business + customer name) →
**Upcoming appointments** (date/time card, "Add to calendar", "Manage" when
booked-originated, "Request a change" otherwise) → **Estimates** (unchanged)
→ **Changes** (CO cards: title, ±amount, status chip, "Review & approve"
when awaiting) → **Invoices** (adds "Paid so far" line via `amountPaid`) →
**Photos** (visible photos, grouped by job, tap to open full size) →
**Need something else?** (follow-up request form: note + send; confirmation
banner on success, idempotent on retry). Same conventions as today: `esc()`
everything, quote-style money for estimates/`invoiceMoney` for invoices,
banner states, no framework, Workers API base.

## 10. Deployment plan

**Workers-only** (Phase 11 precedent D4: Vercel is frozen for new surface;
portal.html already calls Workers exclusively). The Vercel `portal-view`
keeps serving the v1 shape untouched — nothing consumes it from the page.

Order (each step gate-green, phase-gated per change control):

1. **Migrations** (if approved): `portal_tokens` + `portal_access_log` —
   applied out-of-band via Supabase SQL editor, idempotent, owner-RLS
   (booking_reservations template).
2. **Backend (Workers)**: read additions first (`appointments`/
   `changeOrders`/`amountPaid`/`photos` + `portal-ics` + signed-URL route),
   then the write path (`portal-request`), then token-table adoption with
   blob fallback. Deploy after each sub-phase; kickoff's "read-only before
   write paths" honored.
   Secrets: `PORTAL_URL_SIGNING_SECRET` (new).
3. **portal.html** (tradeready-legal): additive render sections — ships
   AFTER the backend deploy (deploy-before-publish, v1 precedent). Old page
   against new backend is fine (extra JSON keys ignored); new page against
   old backend shows empty new sections (fail-soft).
4. **Client (app)**: JobDetail visibility toggle, CustomerDetail portal
   changes for D1-A (mint/toggle/rotate via server), models.ts additions.
   Rides the next OTA train (standing owner call on OTA timing).
5. **Device smoke** (owner): appointment card + ICS import, CO approve from
   portal, photo visible/hidden round-trip + URL expiry, follow-up request
   → push → lead conversion, reschedule request on an owner-scheduled job,
   rotate kills old link instantly (D1-A).
6. Marketing claims updated only after smoke (claims discipline).

**Testing:** every new backend module gets Workers-side unit tests (booking
test convention) — this also closes the standing gap that the Workers
portal handler has ZERO direct coverage today (all v1 portal tests pin the
Vercel twin). Extended exact-keys whitelist test, signed-URL vectors
(tamper/expiry/wrong-user), idempotent-insert test, ICS snapshot, RNTL for
the two new app UI surfaces. Full gate green per commit (baseline 2552/188).

## 11. Out of scope (this phase)

- Invoice-PDF/document serving — the PDF bucket is a transient email
  handoff (objects deleted after send); a durable document store is its own
  design. "Documents" in the kickoff = photos for now.
- Portal-initiated free-text messaging/chat (kickoff: "without building a
  full messaging platform").
- Server-side ledger/blob merge trigger (pre-existing residual).
- Payment-link minting from the portal (v1 limitation stands).
- "Portal was viewed" owner notification (log table enables it later).
- Vercel twin parity for new capabilities (frozen backend).

## 12. Decisions required from the owner

| # | Decision | Recommendation |
|---|---|---|
| D1 | Portal tokens → server-owned `portal_tokens` table (Option A) vs stay device-owned (B) | **A** — it's the kickoff's own ask; fixes revocation lag + unindexed scan; blob fallback keeps existing links alive |
| D2 | `JobPhoto.customerVisible?: boolean` additive field (persisted shape) | Approve — absent-means-hidden, fail closed |
| D3 | `BookingRequest` additive fields (`source`, `sourceCustomerId`, `jobRef`, kind marker) (persisted shape) | Approve — insert-only rows, additive optional |
| D4 | Two migrations (`portal_tokens` if D1-A, `portal_access_log`) + new Workers secret `PORTAL_URL_SIGNING_SECRET` | Approve |
| D5 | Photos-only for capability 6 (documents deferred) | Approve |
| D6 | Floating-local-time ICS for owner-scheduled jobs (§4) | Approve |
| D7 | Capability order/scope trims, if any — e.g. ship reads (1–6) and hold writes (7–8) for a later sub-phase | Full list as specced; sub-phased delivery order already honors read-before-write |

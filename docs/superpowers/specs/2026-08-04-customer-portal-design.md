# Customer Portal — Design Spec

**Date:** 2026-08-04
**Status:** Architecture approved at memo level (owner, 2026-08-04: estimates + invoices scope); spec pending owner review
**Origin:** ChatGPT recs review 2026-08-03 — "extend the estimate-approval page"; sequenced after the booking link (merged `cec034f`)

## 1. Goal

Give each customer a persistent capability link — their own page showing every
estimate (with approve/decline) and invoice (with Pay when a link exists) from
this business. Extends the shipped estimate-approval infrastructure; shared
from CustomerDetail.

**Owner scope decision (2026-08-04):** estimates + invoices. No appointments
in v1.

## 2. The key property: a read-only feature

The portal adds **zero new server write paths**:

- Approve/decline: the portal links each pending estimate to its existing
  `estimate.html?j=<jobId>&t=<approvalToken>` page — the shipped, e-signed,
  server-authoritative flow, untouched.
- Pay: the portal shows a Pay button only when the invoice carries a cached
  `paymentLinkUrl` (minted by the owner's send flow). No link → no button
  (v1 limitation: the portal cannot mint links; minting requires owner auth).
- The one new backend action, `portal-view`, is a sanitized token-gated READ.

No Supabase migration. No new tables. No alerts. The Vercel function count
stays **11 of 12** — `portal-view` joins the existing estimate dispatcher.

## 3. Data model

One additive optional field on `Customer` (types/models.ts — persisted-shape
change, part of what this spec asks the owner to approve):

```ts
/**
 * Customer-portal capability link. OPTIONAL and additive. Device-written
 * ONLY (CustomerDetail); the backend resolves token → customer by READING
 * the customers table. Public-by-design token (it's in the shared URL).
 */
portal?: { token: string; enabled: boolean };
```

Same conventions as `Settings.bookingLink`: 48-hex server-minted token,
device-written through the normal customer save path (load → map → save on
the existing record; creation stays `getOrCreateCustomer`-only), synced as
part of the customer blob, absent-means-no-portal. Same accepted LWW
residual class (cross-device clobber; re-mint heals) — documented in README.

Token minting reuses the **existing stateless `/api/booking/mint`** endpoint
(JWT-authed, purpose-agnostic secure RNG; the device has no secure RNG). No
new mint endpoint, no duplicated mint handler.

## 4. Backend: one dispatcher action

`api/estimate/[action].js` ROUTES gains `'portal-view'` →
`lib/estimate/portalView.js` (the estimate dispatcher is the right home: same
customer-facing domain, same CORS allowlist, and it keeps the function count
at 11). The booking dispatcher is untouched.

`GET /api/estimate/portal-view?p=<token>`:

1. `applyCors` (shared allowlist), OPTIONS 200, non-GET 405, IP rate limit
   (`createRateLimiter({ limit: 30 })`), missing `p` → 400
   `{ error: 'Missing link parameters.' }` (the owner-ratified estimate-page
   precedent), unknown/disabled → 404 `{ error: 'This link is invalid.' }`
   (oracle-free).
2. Resolve customer: `customers?data->portal->>token=eq.<p>&data->portal->>enabled=eq.true&deleted=eq.false&select=user_id,id,data`
   (service role; `lib/estimate/portalStore.js`, mirroring `lib/booking/store.js`).
3. Fetch that user's settings row (businessName only) and the customer's jobs
   + invoices: `jobs?user_id=eq.<u>&data->>customerId=eq.<c>&deleted=eq.false`
   and the same for invoices — service-role reads, filtered by BOTH user_id
   and customerId so a token can never cross tenants.
4. Return the sanitized bundle — a whitelist, tested key-by-key like
   booking's config test:

```
{
  businessName,                       // capped 120
  customerName,                       // the customer's own name
  estimates: [{                       // jobs where approval?.token exists
    title, total,                     // approval.snapshot total (the frozen quote)
    decision,                         // null | "approved" | "declined"
    approvalUrl                       // gettradereadyapp.com/estimate.html?j=<id>&t=<token>
  }],
  invoices: [{                        // this customer's invoices
    number, amount, balanceDue,       // balanceDue via lib/paymentMath.js (existing)
    due, paid, paidAt,                // paid boolean + ISO date when present
    paymentLinkUrl                    // only when cached AND https + allowlisted host
  }]
}
```

Nothing else crosses the wire: no ids beyond what approvalUrl needs, no
contact info, no notes, no pricing internals (labor rates etc.), no other
customers, no settings fields. `paymentLinkUrl` is filtered through the same
allowed-hosts check the dunning email uses (`isAllowedPaymentLink` in
`lib/reminderEmail.js` — exported for reuse, not duplicated) so a legacy or
tampered link can never turn the portal into a phishing surface.

Estimates listed = jobs with an approval link (that's what a customer can see
and act on — the frozen snapshot + the shipped approval page). Jobs without
approval links are internal and stay invisible.

## 5. portal.html (tradeready-legal repo)

Static page beside `estimate.html`/`book.html`, same conventions (`esc()`
everything, banner states, no framework). Sections: header
"<businessName> — <customerName>" → **Estimates** (each: title, total,
status chip, "Review & approve" link to its approval page when undecided) →
**Invoices** (each: number, amount — balance shown when partly paid — due
date, PAID chip or Pay button). Empty states for each section. Invalid-link
and network-error banners. URL: `gettradereadyapp.com/portal.html?p=<token>`.
Committed on tradeready-legal `main`, **held unpushed** until the backend
deploy (same launch ordering as book.html — both publish together).

## 6. App UI (CustomerDetail)

A "Customer portal" row group on CustomerDetail, mirroring the Settings
booking section's shape and its clobber-safe lesson: create ("Create portal
link" → mint → write `portal` onto the customer record via the normal
customer save), share (share sheet with the URL), toggle ("Portal enabled"),
rotate ("Get a new link" with the destructive Alert). Local component state +
immediate saves; CustomerDetail has no draft/dirty machinery to conflict
with (verified in the plan phase — if it does, the booking clobber fix
pattern applies).

`utils/portalLink.ts` mirrors `utils/bookingLink.ts`: `PORTAL_PUBLIC_BASE`,
`buildPortalUrl(token)`, and it reuses `mintBookingToken()` (renamed
consideration deferred — it is a generic mint; the plan phase re-exports it
as `mintPortalToken` alias rather than duplicating the fetch wrapper).

## 7. Error handling & abuse posture

Same posture as booking config: capability URL, IP rate limit, oracle-free
404, length-capped businessName, response whitelist test, CORS allowlist,
deploy-before-publish. A disabled portal 404s on next fetch; rotation kills
the old token instantly. Documented residuals: invoices predating
`customerId` stamping don't appear until `migrateCustomerIdentity` heals
them (runs every owner sign-in, so transient); portal token LWW class as §3.

## 8. Testing

- `portalStore` lookup (token+enabled filter, tenant scoping in the jobs/
  invoices queries) — fetch-mocked, mirroring bookingStore tests.
- `portalView`: whitelist leak test (exact keys, recursively — the response
  is the security boundary), estimates filtered to approval-carrying jobs,
  decision passthrough, balanceDue math via real paymentMath, payment-link
  host filtering (allowlisted kept, squareup.com/http dropped), 404/400/405/
  OPTIONS/429 matrix, dispatcher routing.
- Client: portalLink URL builder; CustomerDetail portal section (RNTL —
  create/share/toggle/rotate + the clobber-regression pattern if the screen
  has any save-all path).
- Full gate green per commit (baseline 2067 / 135).

## 9. Out of scope (v1)

Appointments · payment-link minting from the portal · portal-initiated
messages · notification to owner on portal visits · listing claims ("client
portal" may NOT be claimed until device-smoked).

## 10. Launch chain (owner-gated)

1. Backend deploy (no env changes, no migration).
2. Push tradeready-legal `main` — publishes portal.html AND the held
   book.html together (booking's chain steps 3–4 merge with this one).
3. Device smoke: create portal link from a customer with an estimate + an
   invoice → open in browser → approve flow round-trips → Pay opens link.
4. OTA rides the normal train (JS-only).

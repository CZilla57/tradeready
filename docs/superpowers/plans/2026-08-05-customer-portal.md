# Customer Portal Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A per-customer capability link (`gettradereadyapp.com/portal.html?p=<token>`) showing that customer's estimates (approve/decline via the shipped flow) and invoices (Pay via cached links), shared from CustomerDetail.

**Architecture:** Read-only extension of the estimate-approval infrastructure per `docs/superpowers/specs/2026-08-04-customer-portal-design.md` (owner-approved 2026-08-05). One new sanitized `portal-view` action on the existing estimate dispatcher (function count stays 11 of 12); token lives on the customer record (`Customer.portal`), device-written, minted via the existing stateless booking mint. **Zero new server write paths, no Supabase migration.**

**Tech Stack:** Same as booking: strict-TS Expo app · CommonJS Vercel backend · Jest (jest-expo) · static page in tradeready-legal.

## Global Constraints

- **No new dependencies. No app.json changes.** Gate before EVERY commit from `tradeready/`: `npm run typecheck` (0) → `npm test` (all pass; baseline **2070 tests / 136 suites**) → `npm run lint` (0 warnings).
- **Branch:** all tradeready commits on `feat/customer-portal` (from master `2d5c374`). The tradeready-legal commit (Task 5) lands on that repo's `main` but is **NEVER pushed** (publishing is launch-chain, owner-gated).
- **The server writes NOTHING in this feature.** `portal-view` and `portalStore` are read-only; any INSERT/UPDATE/upsert in them is a defect. Every jobs/invoices query MUST filter by BOTH `user_id` and `customerId` (tenant scoping).
- **`api/estimate/[action].js` gains exactly ONE route (`portal-view`) and nothing else changes in it.** (The booking-era "estimate dispatcher untouched" rule was branch-scoped; the owner-approved portal spec explicitly amends it. `api/booking/` is untouched this time.) Function count stays exactly 11 — no new file under `backend/api/`.
- Exact strings: missing `p` → 400 `{ error: 'Missing link parameters.' }` (owner-ratified precedent); unknown/disabled token → 404 `{ error: 'This link is invalid.' }` (oracle-free). Portal URL base `https://gettradereadyapp.com/portal.html`; approval links built on `https://gettradereadyapp.com/estimate.html`.
- Response bodies are **whitelists** — tests assert exact key sets. `paymentLinkUrl` passes through `isAllowedPaymentLink` (already exported from `backend/lib/reminderEmail.js:110`) and is `null` on paid invoices.
- Backend CommonJS `.js`; app strict TS; house comment style (constraints, not narration).

---

### Task 1: Backend portal store (read-only Supabase access)

**Files:**
- Create: `backend/lib/estimate/portalStore.js`
- Test: `__tests__/portalStore.test.js`

**Interfaces:**
- Consumes: env `SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY` (deployed; no new env vars).
- Produces: `lookupCustomerByPortalToken(token) → Promise<{ user_id, id, data } | null>`; `fetchBusinessName(userId) → Promise<string>`; `fetchCustomerJobs(userId, customerId) → Promise<Array<{id, data}>>`; `fetchCustomerInvoices(userId, customerId) → Promise<Array<{id, data}>>`.

- [ ] **Step 1: Write the failing test.** Create `__tests__/portalStore.test.js`:

```js
// __tests__/portalStore.test.js
// Portal backend store is READ-ONLY (spec §2) and tenant-scoped: every
// jobs/invoices query carries BOTH user_id and customerId — the assertion
// that a portal token can never read across tenants lives here.

process.env.SUPABASE_URL = 'https://unit.test';
process.env.SUPABASE_SERVICE_ROLE_KEY = 'service-role-test';

const {
  lookupCustomerByPortalToken,
  fetchBusinessName,
  fetchCustomerJobs,
  fetchCustomerInvoices,
} = require('../backend/lib/estimate/portalStore');

afterEach(() => { delete global.fetch; });

function okFetch(rows) {
  global.fetch = jest.fn().mockResolvedValue({ ok: true, json: async () => rows });
}

describe('lookupCustomerByPortalToken', () => {
  it('filters by JSON-path token + enabled + not deleted and selects user_id,id,data', async () => {
    okFetch([{ user_id: 'u1', id: 'c1', data: { name: 'Dana' } }]);
    const row = await lookupCustomerByPortalToken('tok123');
    expect(row.id).toBe('c1');
    const url = global.fetch.mock.calls[0][0];
    expect(url).toContain('/rest/v1/customers');
    expect(url).toContain('data->portal->>token=eq.tok123');
    expect(url).toContain('data->portal->>enabled=eq.true');
    expect(url).toContain('deleted=eq.false');
    expect(url).toContain('select=user_id,id,data');
  });

  it('returns null when no row matches (unknown and disabled are indistinguishable)', async () => {
    okFetch([]);
    expect(await lookupCustomerByPortalToken('nope')).toBeNull();
  });

  it('throws on a non-ok response', async () => {
    global.fetch = jest.fn().mockResolvedValue({ ok: false, status: 500, text: async () => 'boom' });
    await expect(lookupCustomerByPortalToken('x')).rejects.toThrow('Supabase');
  });
});

describe('fetchBusinessName', () => {
  it('reads the settings row and returns businessName, empty-string fallback', async () => {
    okFetch([{ data: { businessName: 'Rivera Plumbing' } }]);
    expect(await fetchBusinessName('u1')).toBe('Rivera Plumbing');
    expect(global.fetch.mock.calls[0][0]).toContain('settings?user_id=eq.u1');
    okFetch([]);
    expect(await fetchBusinessName('u1')).toBe('');
  });
});

describe.each([
  ['fetchCustomerJobs', fetchCustomerJobs, 'jobs'],
  ['fetchCustomerInvoices', fetchCustomerInvoices, 'invoices'],
])('%s', (_name, fn, table) => {
  it('scopes by BOTH user_id and customerId, excludes deleted', async () => {
    okFetch([{ id: 'r1', data: {} }]);
    const rows = await fn('u1', 'c1');
    expect(rows).toHaveLength(1);
    const url = global.fetch.mock.calls[0][0];
    expect(url).toContain(`/rest/v1/${table}`);
    expect(url).toContain('user_id=eq.u1');
    expect(url).toContain('data->>customerId=eq.c1');
    expect(url).toContain('deleted=eq.false');
    expect(url).toContain('select=id,data');
  });
});
```

- [ ] **Step 2: Run it to verify it fails.** Run: `npx jest __tests__/portalStore.test.js`
Expected: FAIL — module not found.

- [ ] **Step 3: Implement.** Create `backend/lib/estimate/portalStore.js`:

```js
// Supabase access for the customer-portal read (2026-08-04 portal spec §4).
// Service role, READ-ONLY by contract — the portal adds zero server write
// paths; an insert/update here is a defect. Every jobs/invoices query is
// scoped by BOTH user_id and customerId so a portal token can never read
// across tenants. NOT routed by Vercel (lives under lib/).

const SUPABASE_URL = process.env.SUPABASE_URL;
const SUPABASE_SERVICE_ROLE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY;

function headers() {
  return {
    Authorization: `Bearer ${SUPABASE_SERVICE_ROLE_KEY}`,
    apikey: SUPABASE_SERVICE_ROLE_KEY,
  };
}

async function get(pathAndQuery) {
  const res = await fetch(`${SUPABASE_URL}/rest/v1/${pathAndQuery}`, { headers: headers() });
  if (!res.ok) throw new Error(`Supabase fetch ${res.status}: ${await res.text()}`);
  return res.json();
}

// { user_id, id, data } for an ENABLED portal link, else null. Disabled and
// unknown tokens are indistinguishable to callers on purpose (no oracle).
async function lookupCustomerByPortalToken(token) {
  const rows = await get(
    `customers?data->portal->>token=eq.${encodeURIComponent(token)}&data->portal->>enabled=eq.true&deleted=eq.false&select=user_id,id,data`
  );
  return rows.length ? rows[0] : null;
}

async function fetchBusinessName(userId) {
  const rows = await get(`settings?user_id=eq.${encodeURIComponent(userId)}&select=data`);
  return rows.length ? String(rows[0].data?.businessName || '') : '';
}

async function fetchCustomerJobs(userId, customerId) {
  return get(
    `jobs?user_id=eq.${encodeURIComponent(userId)}&data->>customerId=eq.${encodeURIComponent(customerId)}&deleted=eq.false&select=id,data`
  );
}

async function fetchCustomerInvoices(userId, customerId) {
  return get(
    `invoices?user_id=eq.${encodeURIComponent(userId)}&data->>customerId=eq.${encodeURIComponent(customerId)}&deleted=eq.false&select=id,data`
  );
}

module.exports = { lookupCustomerByPortalToken, fetchBusinessName, fetchCustomerJobs, fetchCustomerInvoices };
```

- [ ] **Step 4: Run the test to verify it passes.** Run: `npx jest __tests__/portalStore.test.js`
Expected: PASS (6 tests).

- [ ] **Step 5: Full gate, then commit.**

```bash
npm run typecheck && npm test && npm run lint
git add backend/lib/estimate/portalStore.js __tests__/portalStore.test.js
git commit -m "feat: portal backend store — read-only, tenant-scoped customer lookup"
```

---

### Task 2: portal-view handler + dispatcher route

**Files:**
- Create: `backend/lib/estimate/portalView.js`
- Modify: `backend/api/estimate/[action].js` (ONE new ROUTES entry)
- Test: `__tests__/portalView.test.js`, `__tests__/estimateDispatcherPortal.test.js`

**Interfaces:**
- Consumes: Task 1's four store functions; `applyCors` (`./cors`); `createRateLimiter` (`../guards`); `balanceDue` (`../paymentMath`, REAL — not mocked in tests); `isAllowedPaymentLink` (`../reminderEmail`, real).
- Produces: `GET /api/estimate/portal-view?p=` → the spec §4 whitelist bundle.

- [ ] **Step 1: Write the failing handler test.** Create `__tests__/portalView.test.js`:

```js
// __tests__/portalView.test.js
// The portal read is the feature's security boundary: the response is a
// WHITELIST (exact-keys assertions), estimates are only approval-carrying
// jobs, and payment links pass the same host allowlist as dunning email.
// balanceDue/isAllowedPaymentLink are REAL — behavior, not mocks.

jest.mock('../backend/lib/estimate/portalStore', () => ({
  lookupCustomerByPortalToken: jest.fn(),
  fetchBusinessName: jest.fn(),
  fetchCustomerJobs: jest.fn(),
  fetchCustomerInvoices: jest.fn(),
}));

const store = require('../backend/lib/estimate/portalStore');
const portalView = require('../backend/lib/estimate/portalView');

function mockRes() {
  const res = { headers: {}, statusCode: 0, body: null };
  res.setHeader = (k, v) => { res.headers[k] = v; };
  res.status = (c) => { res.statusCode = c; return res; };
  res.json = (b) => { res.body = b; return res; };
  res.end = () => res;
  return res;
}

function req(query, extra = {}) {
  return { method: 'GET', headers: { origin: 'https://gettradereadyapp.com' }, query, ...extra };
}

beforeEach(() => {
  jest.clearAllMocks();
  store.lookupCustomerByPortalToken.mockResolvedValue({
    user_id: 'u1', id: 'c1',
    data: { name: 'Dana Rivers', email: 'private@example.com', portal: { token: 'T', enabled: true } },
  });
  store.fetchBusinessName.mockResolvedValue('Rivera Plumbing');
  store.fetchCustomerJobs.mockResolvedValue([
    { id: 'j1', data: { title: 'Internal job', status: 'scheduled' } }, // no approval — invisible
    { id: 'j2', data: { title: 'Water heater', status: 'estimate_sent',
      approval: { token: 'apptok', snapshot: { jobTitle: 'Water heater replacement', total: 1200 } } } },
    { id: 'j3', data: { title: 'Fence', status: 'declined',
      approval: { token: 'apptok3', decision: 'declined', snapshot: { jobTitle: 'Fence repair', total: 800 } } } },
  ]);
  store.fetchCustomerInvoices.mockResolvedValue([
    { id: 'i1', data: { number: 'INV-0001', amount: 500, due: '2026-08-20', paid: false,
      paymentLinkUrl: 'https://buy.stripe.com/pay123' } },
    { id: 'i2', data: { number: 'INV-0002', amount: 300, due: '2026-07-01', paid: true, paidAt: '2026-07-03',
      paymentLinkUrl: 'https://buy.stripe.com/old' } },
    { id: 'i3', data: { number: 'INV-0003', amount: 250, due: '2026-08-25', paid: false,
      paymentLinkUrl: 'https://squareup.com/pay/SECRET-TOKEN' } }, // disallowed host
  ]);
});

describe('portal-view', () => {
  it('returns the exact whitelist shape — nothing else leaks', async () => {
    const res = mockRes();
    await portalView(req({ p: 'T' }), res);
    expect(res.statusCode).toBe(200);
    expect(Object.keys(res.body).sort()).toEqual(['businessName', 'customerName', 'estimates', 'invoices']);
    expect(res.body.businessName).toBe('Rivera Plumbing');
    expect(res.body.customerName).toBe('Dana Rivers');
    for (const e of res.body.estimates) {
      expect(Object.keys(e).sort()).toEqual(['approvalUrl', 'decision', 'title', 'total']);
    }
    for (const i of res.body.invoices) {
      expect(Object.keys(i).sort()).toEqual(['amount', 'balanceDue', 'due', 'number', 'paid', 'paidAt', 'paymentLinkUrl']);
    }
    expect(JSON.stringify(res.body)).not.toContain('private@example.com');
  });

  it('lists only approval-carrying jobs as estimates, with decision + approval URL', async () => {
    const res = mockRes();
    await portalView(req({ p: 'T' }), res);
    expect(res.body.estimates).toHaveLength(2);
    const [pending, declined] = res.body.estimates;
    expect(pending.title).toBe('Water heater replacement');
    expect(pending.total).toBe(1200);
    expect(pending.decision).toBeNull();
    expect(pending.approvalUrl).toBe('https://gettradereadyapp.com/estimate.html?j=j2&t=apptok');
    expect(declined.decision).toBe('declined');
  });

  it('computes balanceDue with the real payment math and filters payment links', async () => {
    const res = mockRes();
    await portalView(req({ p: 'T' }), res);
    const [open, paid, badHost] = res.body.invoices;
    expect(open.balanceDue).toBe(500);            // no ledger → full amount
    expect(open.paymentLinkUrl).toBe('https://buy.stripe.com/pay123');
    expect(paid.paid).toBe(true);
    expect(paid.paymentLinkUrl).toBeNull();       // paid → never a link
    expect(badHost.paymentLinkUrl).toBeNull();    // squareup.com is not allowlisted
    expect(JSON.stringify(res.body)).not.toContain('SECRET-TOKEN');
  });

  it('404s unknown/disabled tokens oracle-free and 400s a missing token', async () => {
    store.lookupCustomerByPortalToken.mockResolvedValue(null);
    const res = mockRes();
    await portalView(req({ p: 'nope' }), res);
    expect(res.statusCode).toBe(404);
    expect(res.body).toEqual({ error: 'This link is invalid.' });
    const missing = mockRes();
    await portalView(req({}), missing);
    expect(missing.statusCode).toBe(400);
    expect(missing.body).toEqual({ error: 'Missing link parameters.' });
  });

  it('handles OPTIONS/405/CORS and 500s on store failure', async () => {
    const pre = mockRes();
    await portalView({ method: 'OPTIONS', headers: {}, query: {} }, pre);
    expect(pre.statusCode).toBe(200);
    const post = mockRes();
    await portalView({ method: 'POST', headers: {}, query: {} }, post);
    expect(post.statusCode).toBe(405);
    const res = mockRes();
    await portalView(req({ p: 'T' }), res);
    expect(res.headers['Access-Control-Allow-Origin']).toBe('https://gettradereadyapp.com');
    store.fetchCustomerJobs.mockRejectedValue(new Error('db down'));
    const err = mockRes();
    await portalView(req({ p: 'T' }), err);
    expect(err.statusCode).toBe(500);
  });
});
```

- [ ] **Step 2: Run it to verify it fails.** Run: `npx jest __tests__/portalView.test.js`
Expected: FAIL — module not found.

- [ ] **Step 3: Implement.** Create `backend/lib/estimate/portalView.js`:

```js
// GET /api/estimate/portal-view?p=<token>
// The customer-portal read (2026-08-04 portal spec §4). READ-ONLY — the
// portal's approve/decline and Pay actions reuse the shipped estimate page
// and cached payment links; this handler only assembles a WHITELISTED view.
// The whitelist is the security boundary: the rows it reads also carry
// contact info, rates, notes and other customers' data — none of which may
// cross the wire to an anonymous caller.

const { applyCors } = require('./cors');
const { createRateLimiter } = require('../guards');
const {
  lookupCustomerByPortalToken,
  fetchBusinessName,
  fetchCustomerJobs,
  fetchCustomerInvoices,
} = require('./portalStore');
const { balanceDue } = require('../paymentMath');
const { isAllowedPaymentLink } = require('../reminderEmail');

const ESTIMATE_PAGE = 'https://gettradereadyapp.com/estimate.html';
const allow = createRateLimiter({ limit: 30 });

module.exports = async function portalView(req, res) {
  applyCors(req, res, 'GET, OPTIONS');
  if (req.method === 'OPTIONS') return res.status(200).end();
  if (req.method !== 'GET') return res.status(405).json({ error: 'Method not allowed' });

  const ip = (req.headers['x-forwarded-for'] || req.socket?.remoteAddress || 'unknown').split(',')[0].trim();
  if (!allow(ip)) return res.status(429).json({ error: 'Too many requests.' });

  const token = req.query.p;
  if (!token) return res.status(400).json({ error: 'Missing link parameters.' });

  let row;
  try {
    row = await lookupCustomerByPortalToken(String(token));
  } catch (err) {
    console.error('[estimate/portal-view] lookup failed:', err.message);
    return res.status(500).json({ error: 'Database error' });
  }
  if (!row) return res.status(404).json({ error: 'This link is invalid.' });

  let businessName, jobRows, invoiceRows;
  try {
    [businessName, jobRows, invoiceRows] = await Promise.all([
      fetchBusinessName(row.user_id),
      fetchCustomerJobs(row.user_id, row.id),
      fetchCustomerInvoices(row.user_id, row.id),
    ]);
  } catch (err) {
    console.error('[estimate/portal-view] fetch failed:', err.message);
    return res.status(500).json({ error: 'Database error' });
  }

  // Only jobs with an approval link are customer-visible estimates — the
  // frozen snapshot plus the shipped approval page. Internal jobs stay
  // invisible.
  const estimates = jobRows
    .filter((r) => r.data && r.data.approval && r.data.approval.token)
    .map((r) => ({
      title: String(r.data.approval.snapshot?.jobTitle || r.data.title || '').slice(0, 200),
      total: Number(r.data.approval.snapshot?.total || 0),
      decision: r.data.approval.decision || null,
      approvalUrl: `${ESTIMATE_PAGE}?j=${encodeURIComponent(r.id)}&t=${encodeURIComponent(r.data.approval.token)}`,
    }));

  const invoices = invoiceRows.map((r) => {
    const inv = r.data || {};
    const link = inv.paymentLinkUrl;
    return {
      number: String(inv.number || ''),
      amount: Number(inv.amount || 0),
      balanceDue: balanceDue(inv),
      due: inv.due || null,
      paid: !!inv.paid,
      paidAt: inv.paidAt || null,
      // Same host allowlist as the dunning email — a tampered or legacy link
      // can never turn the portal into a phishing surface. Paid invoices get
      // no link at all.
      paymentLinkUrl: !inv.paid && isAllowedPaymentLink(link) ? link : null,
    };
  });

  return res.status(200).json({
    businessName: String(businessName || '').slice(0, 120),
    customerName: String(row.data?.name || '').slice(0, 120),
    estimates,
    invoices,
  });
};
```

- [ ] **Step 4: Run the handler test to verify it passes.** Run: `npx jest __tests__/portalView.test.js`
Expected: PASS (5 tests). If `balanceDue` behaves differently than the fixture assumes (no-ledger invoice → full amount), READ `backend/lib/paymentMath.js` and fix the FIXTURE, not the math.

- [ ] **Step 5: Write the failing dispatcher test.** Create `__tests__/estimateDispatcherPortal.test.js`:

```js
// __tests__/estimateDispatcherPortal.test.js
// portal-view joins the estimate dispatcher (2026-08-05 portal spec — the
// owner-approved amendment to the dispatcher's route set). The three
// original routes must keep routing untouched.

jest.mock('../backend/lib/estimate/createLink', () => jest.fn((q, r) => r.status(200).json({ route: 'create-link' })));
jest.mock('../backend/lib/estimate/respond', () => jest.fn((q, r) => r.status(200).json({ route: 'respond' })));
jest.mock('../backend/lib/estimate/view', () => jest.fn((q, r) => r.status(200).json({ route: 'view' })));
jest.mock('../backend/lib/estimate/portalView', () => jest.fn((q, r) => r.status(200).json({ route: 'portal-view' })));

const handler = require('../backend/api/estimate/[action]');

function mockRes() {
  const res = { statusCode: 0, body: null };
  res.status = (c) => { res.statusCode = c; return res; };
  res.json = (b) => { res.body = b; return res; };
  return res;
}

describe('estimate dispatcher with portal-view', () => {
  it.each(['create-link', 'respond', 'view', 'portal-view'])('routes %s', async (action) => {
    const res = mockRes();
    await handler({ query: { action } }, res);
    expect(res.body).toEqual({ route: action });
  });

  it('404s unknown and prototype-inherited actions', async () => {
    for (const action of ['nope', 'constructor']) {
      const res = mockRes();
      await handler({ query: { action } }, res);
      expect(res.statusCode).toBe(404);
    }
  });
});
```

- [ ] **Step 6: Run it to verify it fails.** Run: `npx jest __tests__/estimateDispatcherPortal.test.js`
Expected: FAIL — `portal-view` routes to 404.

- [ ] **Step 7: Add the route.** In `backend/api/estimate/[action].js`: add `const portalView = require('../../lib/estimate/portalView');` beside the other requires, add `'portal-view': portalView,` to `ROUTES`, and extend the header comment's route list with `/api/estimate/portal-view` (customer-portal read, 2026-08-05). Change nothing else.

- [ ] **Step 8: Run the test to verify it passes.** Run: `npx jest __tests__/estimateDispatcherPortal.test.js`
Expected: PASS (5 tests). Also: `find backend/api -name "*.js" | wc -l` → still `11`.

- [ ] **Step 9: Full gate, then commit.**

```bash
npm run typecheck && npm test && npm run lint
git add backend/lib/estimate/portalView.js "backend/api/estimate/[action].js" __tests__/portalView.test.js __tests__/estimateDispatcherPortal.test.js
git commit -m "feat: portal-view — whitelisted customer-portal read on the estimate dispatcher"
```

---

### Task 3: Client — Customer.portal type + utils/portalLink.ts

**Files:**
- Modify: `types/models.ts` (Customer gains `portal?`)
- Create: `utils/portalLink.ts`
- Test: `__tests__/portalLink.test.ts`

**Interfaces:**
- Consumes: `mintBookingToken` + `MintResult` type from `utils/bookingLink.ts` (both exported).
- Produces: `PORTAL_PUBLIC_BASE`; `buildPortalUrl(token): string`; `mintPortalToken(): Promise<MintResult>`; `Customer.portal?: { token: string; enabled: boolean }`. Task 4 consumes exactly these.

- [ ] **Step 1: Write the failing test.** Create `__tests__/portalLink.test.ts`:

```ts
// __tests__/portalLink.test.ts
// The portal mint IS the booking mint (spec §3: the endpoint is a
// purpose-agnostic stateless RNG) — the identity assertion pins that reuse
// so nobody later forks a duplicate fetch wrapper.

import { buildPortalUrl, mintPortalToken, PORTAL_PUBLIC_BASE } from '../utils/portalLink';
import { mintBookingToken } from '../utils/bookingLink';

describe('portalLink', () => {
  it('builds the portal URL with an encoded token', () => {
    expect(PORTAL_PUBLIC_BASE).toBe('https://gettradereadyapp.com/portal.html');
    expect(buildPortalUrl('abc123')).toBe('https://gettradereadyapp.com/portal.html?p=abc123');
    expect(buildPortalUrl('a&b')).toBe('https://gettradereadyapp.com/portal.html?p=a%26b');
  });

  it('mintPortalToken IS mintBookingToken (single mint wrapper, no fork)', () => {
    expect(mintPortalToken).toBe(mintBookingToken);
  });
});
```

- [ ] **Step 2: Run it to verify it fails.** Run: `npx jest __tests__/portalLink.test.ts`
Expected: FAIL — module not found.

- [ ] **Step 3: Implement.** In `types/models.ts`, inside the `Customer` interface after the `createdAt?` member (types/models.ts:353), add:

```ts
  /**
   * Customer-portal capability link (2026-08-04 portal spec). OPTIONAL and
   * additive. Device-written ONLY (CustomerDetail); the backend resolves
   * token → customer by READING the customers table, never writing it.
   * Public-by-design token (it's in the shared URL) — not secret data.
   */
  portal?: { token: string; enabled: boolean };
```

Create `utils/portalLink.ts`:

```ts
// utils/portalLink.ts
// App-side plumbing for the per-customer portal link (2026-08-04 portal
// spec §3, §6). The token is minted server-side by the SAME stateless
// endpoint the booking link uses — it is a purpose-agnostic secure RNG, so
// this module re-exports the existing wrapper under a portal name instead
// of forking a second fetch wrapper. The caller writes the token onto the
// customer record; normal sync publishes it.

import { mintBookingToken } from "./bookingLink";
import type { MintResult } from "./bookingLink";

export const PORTAL_PUBLIC_BASE = "https://gettradereadyapp.com/portal.html";

export function buildPortalUrl(token: string): string {
  return `${PORTAL_PUBLIC_BASE}?p=${encodeURIComponent(token)}`;
}

export const mintPortalToken: () => Promise<MintResult> = mintBookingToken;
export type { MintResult };
```

- [ ] **Step 4: Run the test to verify it passes.** Run: `npx jest __tests__/portalLink.test.ts`
Expected: PASS (2 tests).

- [ ] **Step 5: Full gate, then commit.**

```bash
npm run typecheck && npm test && npm run lint
git add types/models.ts utils/portalLink.ts __tests__/portalLink.test.ts
git commit -m "feat: Customer.portal field + portal link client plumbing"
```

---

### Task 4: CustomerDetail — Customer portal section

**Files:**
- Modify: `screens/CustomerDetailScreen.tsx`
- Test: `__tests__/portalLinkCustomerDetail.test.tsx`

**Interfaces:**
- Consumes: `mintPortalToken`, `buildPortalUrl`, `MintResult` (Task 3); `loadCustomers`/`saveCustomers` (already imported by the screen); RN `Share`, `Alert`; `reportError` from `../utils/analytics`.
- Produces: the owner-facing create/share/toggle/rotate controls on CustomerDetail.

- [ ] **Step 1 (mandatory recon):** Read `screens/CustomerDetailScreen.tsx` fully. Establish: (a) how sections are composed/themed (`createStyles(colors, shadow)` factory); (b) where the portal section fits (after the notes section, before merge/delete actions); (c) `displayCustomer` state (line ~164) is the record the section reads; (d) **the clobber check**: read `updateCustomerNotes` in `utils/storage/customers.ts` and confirm it loads customers fresh and maps ONLY the notes field onto the matched record — i.e. a notes save cannot overwrite `portal`. If it instead writes a stale whole record, STOP and report BLOCKED with the evidence (that would need the booking-clobber treatment first).

- [ ] **Step 2: Write the failing test.** Create `__tests__/portalLinkCustomerDetail.test.tsx`, harness modeled on `__tests__/bookingLinkSettings.test.tsx` (storage-barrel mock + `await render`) and `__tests__/TodayScreenSettingsGear.test.tsx` (the `useFocusEffect` mount-effect mock — CustomerDetail uses navigation hooks; adapt to what recon found). Mock `../utils/portalLink` with `...jest.requireActual`, faking only `mintPortalToken`. Route param: `{ customer: cust }` shaped as recon found. Five cases:

```tsx
// 1. absent portal → renders "Create portal link"
// 2. tapping it (mintPortalToken → {ok:true, token:'e'.repeat(48)}) calls
//    saveCustomers with THIS customer carrying portal {token, enabled:true}
//    and every other customer in the list untouched (assert on the full
//    array passed to saveCustomers — the map-by-id is the point)
// 3. with portal present → renders the buildPortalUrl(token) text and the
//    "Portal enabled" toggle ON
// 4. flipping the toggle → saveCustomers with the same token, enabled:false
// 5. mint failure {ok:false, reason:'network', message} → Alert.alert
//    called, saveCustomers NOT called
```

Write them as real RNTL tests. `loadCustomers` resolves `[cust, otherCust]` so case 2's untouched-neighbor assertion is meaningful.

- [ ] **Step 3: Run it to verify it fails.** Run: `npx jest __tests__/portalLinkCustomerDetail.test.tsx`
Expected: FAIL — section doesn't exist.

- [ ] **Step 4: Implement the section.** Handlers (adapt names/state to the screen's conventions; keep ALL of the booking fix-wave's lessons — try/catch with `reportError` on every handler including share, and update `displayCustomer` after a successful save):

```tsx
const handleCreatePortalLink = async () => {
  const out = await mintPortalToken();
  if (!out.ok) { Alert.alert("Couldn't create portal link", out.message); return; }
  try {
    const next = { token: out.token, enabled: true };
    const custs = await loadCustomers();
    await saveCustomers(custs.map((c) => (c.id === displayCustomer.id ? { ...c, portal: next } : c)));
    setDisplayCustomer((prev: Customer) => ({ ...prev, portal: next }));
  } catch (err) {
    reportError(err, { context: "portalLinkCreate" });
    Alert.alert("Couldn't save the portal link", "Please try again.");
  }
};

const handleTogglePortal = async (enabled: boolean) => {
  try {
    const custs = await loadCustomers();
    const current = custs.find((c) => c.id === displayCustomer.id)?.portal;
    if (!current) return;
    const next = { ...current, enabled };
    await saveCustomers(custs.map((c) => (c.id === displayCustomer.id ? { ...c, portal: next } : c)));
    setDisplayCustomer((prev: Customer) => ({ ...prev, portal: next }));
  } catch (err) {
    reportError(err, { context: "portalLinkToggle" });
    Alert.alert("Couldn't update the portal", "Please try again.");
  }
};

const handleSharePortalLink = async (token: string) => {
  try {
    await Share.share({ message: buildPortalUrl(token) });
  } catch (err) {
    reportError(err, { context: "portalLinkShare" });
  }
};

const handleNewPortalLink = () => {
  Alert.alert(
    "Get a new link?",
    "This customer's current portal link will stop working immediately.",
    [
      { text: "Cancel", style: "cancel" },
      { text: "Get new link", style: "destructive", onPress: () => { void handleCreatePortalLink(); } },
    ]
  );
};
```

Section UI mirrors the Settings booking section's composition in this screen's idiom: header "Customer portal"; absent state → one-line explainer ("Their own page for estimates and invoices.") + "Create portal link" button; present state → selectable URL text, "Share link", "Portal enabled" switch, "Get a new link" row.

- [ ] **Step 5: Run the test to verify it passes.** Run: `npx jest __tests__/portalLinkCustomerDetail.test.tsx`
Expected: PASS (5 tests).

- [ ] **Step 6: Full gate, then commit.**

```bash
npm run typecheck && npm test && npm run lint
git add screens/CustomerDetailScreen.tsx __tests__/portalLinkCustomerDetail.test.tsx
git commit -m "feat: CustomerDetail portal section — create, share, toggle, rotate"
```

---

### Task 5: portal.html (tradeready-legal repo — commit, HOLD push)

**Files:**
- Create: `C:\Users\Chadr\OneDrive\Documents\TraderPro App\tradeready-legal\portal.html`

**Interfaces:**
- Consumes: `GET https://backend-tradeready1.vercel.app/api/estimate/portal-view?p=` (Task 2's response shape).
- Produces: the public portal page. **Committed on tradeready-legal `main`, NEVER pushed** (launch chain).

- [ ] **Step 1: Create the page.** Full content — conventions from `estimate.html`/`book.html` (same styles, `esc()`, `banner()`, `money()`):

```html
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>Your account — TradeReady</title>
  <style>
    *, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }
    body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
           font-size: 16px; line-height: 1.6; color: #1a1a1a; background: #f9f9f9; padding: 2rem 1rem; }
    .page { max-width: 560px; margin: 0 auto; background: #fff; border-radius: 12px;
            padding: 2rem; box-shadow: 0 1px 4px rgba(0,0,0,.08); }
    .brand { font-size: 1.4rem; font-weight: 800; color: #2563eb; margin-bottom: 1rem; }
    h1 { font-size: 1.25rem; margin-bottom: .25rem; }
    h2 { font-size: 1.05rem; margin: 1.5rem 0 .5rem; }
    .muted { color: #6b7280; font-size: .9rem; }
    .card { border: 1px solid #e5e7eb; border-radius: 8px; padding: .85rem; margin-bottom: .6rem; }
    .row { display: flex; justify-content: space-between; align-items: center; gap: .5rem; }
    .chip { font-size: .8rem; font-weight: 700; padding: .15rem .55rem; border-radius: 999px; white-space: nowrap; }
    .chip-ok { background: #ecfdf5; color: #065f46; }
    .chip-info { background: #eff6ff; color: #1e40af; }
    .chip-warn { background: #fffbeb; color: #92400e; }
    .chip-err { background: #fef2f2; color: #991b1b; }
    a.button { display: inline-block; padding: .5rem .9rem; border-radius: 8px; font-weight: 600;
               text-decoration: none; background: #2563eb; color: #fff; font-size: .9rem; }
    .banner { padding: 1rem; border-radius: 8px; text-align: center; font-weight: 600; }
    .err { background: #fef2f2; color: #991b1b; }
    .footer { margin-top: 2rem; padding-top: 1rem; border-top: 1px solid #e5e7eb; font-size: .8rem; color: #9ca3af; }
  </style>
</head>
<body>
<div class="page">
  <div class="brand">TradeReady</div>
  <div id="content"><p class="muted">Loading your account…</p></div>
  <div class="footer">This private page was shared with you by the business. Anyone with the link can view it.</div>
</div>

<script>
  var API = 'https://backend-tradeready1.vercel.app/api/estimate';
  var params = new URLSearchParams(location.search);
  var token = params.get('p');
  var content = document.getElementById('content');

  function esc(s) { var d = document.createElement('div'); d.textContent = s == null ? '' : String(s); return d.innerHTML; }
  function money(n) { return '$' + Number(n || 0).toLocaleString(undefined, { minimumFractionDigits: 0, maximumFractionDigits: 2 }); }
  function banner(cls, msg) { content.innerHTML = '<div class="banner ' + cls + '">' + esc(msg) + '</div>'; }

  if (!token) { banner('err', 'This link is missing information. Please ask for a new link.'); }
  else { load(); }

  async function load() {
    try {
      var res = await fetch(API + '/portal-view?p=' + encodeURIComponent(token));
      if (!res.ok) { banner('err', 'This link is invalid.'); return; }
      render(await res.json());
    } catch (e) { banner('err', 'Could not load this page. Please check your connection.'); }
  }

  function estimateCard(e) {
    var status, action = '';
    if (e.decision === 'approved') status = '<span class="chip chip-ok">Approved</span>';
    else if (e.decision === 'declined') status = '<span class="chip chip-err">Declined</span>';
    else {
      status = '<span class="chip chip-info">Awaiting your approval</span>';
      action = '<div style="margin-top:.5rem"><a class="button" href="' + esc(e.approvalUrl) + '">Review &amp; approve</a></div>';
    }
    return '<div class="card"><div class="row"><strong>' + esc(e.title) + '</strong>' + status + '</div>' +
           '<div class="muted">' + money(e.total) + '</div>' + action + '</div>';
  }

  function invoiceCard(i) {
    var right, amount;
    if (i.paid) {
      right = '<span class="chip chip-ok">Paid</span>';
      amount = money(i.amount);
    } else {
      right = i.paymentLinkUrl
        ? '<a class="button" href="' + esc(i.paymentLinkUrl) + '">Pay</a>'
        : '<span class="chip chip-warn">Due</span>';
      amount = i.balanceDue < i.amount
        ? money(i.balanceDue) + ' of ' + money(i.amount) + ' outstanding'
        : money(i.amount);
    }
    return '<div class="card"><div class="row"><strong>' + esc(i.number) + '</strong>' + right + '</div>' +
           '<div class="muted">' + amount + (i.due && !i.paid ? ' · due ' + esc(i.due) : '') + '</div></div>';
  }

  function render(data) {
    var estimates = (data.estimates || []).map(estimateCard).join('') || '<p class="muted">No estimates yet.</p>';
    var invoices = (data.invoices || []).map(invoiceCard).join('') || '<p class="muted">No invoices yet.</p>';
    content.innerHTML =
      '<h1>' + esc(data.businessName || 'Your account') + '</h1>' +
      '<p class="muted">' + esc(data.customerName || '') + '</p>' +
      '<h2>Estimates</h2>' + estimates +
      '<h2>Invoices</h2>' + invoices;
  }
</script>
</body>
</html>
```

- [ ] **Step 2: Offline sanity check.** Open the file with no params (`file://`): must render "This link is missing information." — proving the script runs. (Full flow is launch-chain, after this feature's backend deploy.)

- [ ] **Step 3: Commit on tradeready-legal main — DO NOT PUSH.**

```bash
cd "C:/Users/Chadr/OneDrive/Documents/TraderPro App/tradeready-legal" && git status --short
git add portal.html
git commit -m "Add customer portal page (estimates + invoices)"
```

Confirm afterward the commit is local-only (`git log origin/main..main --oneline` lists it). Pushing publishes — launch chain, owner-gated.

---

### Task 6: Docs + final gate

**Files:**
- Modify: `README.md`, `ARCHITECTURE.md`

**Interfaces:** consumes everything above; produces docs matching reality **including the file map** (the booking final review made the map a merge gate — do not repeat that gap).

- [ ] **Step 1: README.** (a) Features: a "Customer portal" bullet — per-customer link showing estimates (approve/decline via the estimate page) and invoices (Pay via cached links); read-only backend. (b) **File map**: add `utils/portalLink.ts`, `backend/lib/estimate/portalView.js`, `portalStore.js` entries in the map's voice. (c) Known Limitations: portal token rides the customer record (same cross-device LWW class; re-mint heals); invoices predating `customerId` stamping stay invisible on the portal until `migrateCustomerIdentity` heals them at the owner's next sign-in (transient).
- [ ] **Step 2: ARCHITECTURE.md.** Add `portal-view` to the estimate dispatcher's route list (still one function, 11 of 12) and `Customer.portal` to the data-model notes with one line on the read-only design.
- [ ] **Step 3: Full gate.** `npm run typecheck && npm test && npm run lint` — expect 0 / baseline+~23 new tests all passing / 0.
- [ ] **Step 4: Commit.**

```bash
git add README.md ARCHITECTURE.md
git commit -m "docs: customer portal in README (features, file map, limitations) and ARCHITECTURE"
```

- [ ] **Step 5: Report, don't merge.** Merge + launch chain (backend deploy, then the legal push publishing portal.html — book.html is already live from the booking launch — then device smoke) are owner-gated.

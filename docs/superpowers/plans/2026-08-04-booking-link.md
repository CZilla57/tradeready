# Booking / Request-a-Quote Link Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A public request-a-quote link (`gettradereadyapp.com/book.html?b=<token>`) whose submissions land in the tradesperson's Jobs list as lead jobs with real Customer records, plus an email alert and the first use of a new push-notification pipeline.

**Architecture:** Server inserts sanitized submissions into a new synced `bookingRequests` collection (service role); the device converts them to Customer + lead Job through the sanctioned client paths (`upsertCustomerInList`), mirroring `applyEstimateDecisions`. One new Vercel dispatcher (`api/booking/[action].js`: `mint`/`config`/`submit`) takes the deployment 10 → 11 of 12 functions. Spec: `docs/superpowers/specs/2026-08-04-booking-link-design.md`.

**Tech Stack:** Expo 54 / RN 0.81 / strict TS (app) · CommonJS Node on Vercel (backend) · Supabase REST + service role · Resend · Expo Push API · Jest (jest-expo).

## Global Constraints

- **No new dependencies. No app.json changes. No Expo SDK change** (change-control Rule 3).
- **Gate before EVERY commit**, run from `C:\Users\Chadr\OneDrive\Documents\TraderPro App\tradeready\`: `npm run typecheck` (0 errors) → `npm test` (all pass; baseline 2000 tests / 123 suites) → `npm run lint` (0 warnings). Never commit red (Rule 2).
- **Branch:** all tradeready commits on `feat/booking-link` (created at execution start). The tradeready-legal commit (Task 11) is made on that repo's `main` but **NEVER pushed** — publishing is an owner-gated launch-chain step.
- **Never touch** `initialSync`, the `__dataOwner` guard, or the estimate dispatcher `api/estimate/[action].js`.
- Exact strings: table/key/collection name `bookingRequests` (camelCase, quoted in SQL); booking token = 48 hex chars (24 random bytes); request id `bk<epoch-ms>_<6 hex>`; converted lead job id `jbk_<requestId>`; public 404 body for bad/disabled links is exactly `{ error: 'This link is invalid.' }` (no oracle between unknown and disabled).
- Backend files are CommonJS `.js` with the repo's comment style (explain constraints, not narration). App files are strict TS with the same house style.
- Field caps (server-authoritative, from spec §6): name 100, phone 50, email 200, address 300, details 2000, preferredTiming 200. Required: name, details, and at least one of phone/email.

---

### Task 1: BookingRequest model, synced collection, and Supabase migration

**Files:**
- Modify: `types/models.ts` (add `BookingRequest`; add two optional `Settings` fields)
- Modify: `utils/storage/keys.ts` (add `bookingRequests` key)
- Create: `utils/storage/bookingRequests.ts`
- Modify: `utils/sync.ts` (add `'bookingRequests'` to `COLLECTION_TABLES`, line ~16)
- Modify: `utils/storage/index.ts` (barrel export)
- Create: `supabase/migrations/20260804_booking_requests.sql`
- Test: `__tests__/bookingRequestsStorage.test.ts`

**Interfaces:**
- Consumes: `enqueueCollectionChanges(table, old, next)` and `trySync()` from `utils/sync.ts`; `KEYS` from `utils/storage/keys.ts`.
- Produces: `BookingRequest` type (types/models.ts); `loadBookingRequests(): Promise<BookingRequest[]>` and `saveBookingRequests(requests: BookingRequest[]): Promise<void>` exported from `utils/storage`; `Settings.bookingLink?: { token: string; enabled: boolean }`; `Settings.pushToken?: { token: string; platform: "ios" | "android"; updatedAt: string }`.

- [ ] **Step 1: Add the types.** In `types/models.ts`, directly after the `Trip` interface, add:

```ts
/**
 * A public request-a-quote submission (booking link, 2026-08-04 spec).
 * Rows are INSERTED server-side only (backend/lib/booking/); the device's
 * applyBookingRequests converts status "new" → Customer + lead Job and flips
 * status to "converted". Synced like any collection.
 */
export interface BookingRequest {
  id: string;            // server-minted: bk<epoch-ms>_<6 hex>
  status: "new" | "converted";
  name: string;
  phone: string;
  email: string;
  address: string;
  details: string;
  preferredTiming: string;
  createdAt: string;     // ISO timestamp, server clock
  convertedJobId?: string;
  convertedCustomerId?: string;
}
```

In the `Settings` interface (types/models.ts:467), after `vehicleDeductionMethod?`, add:

```ts
  /**
   * Public booking link (request-a-quote). OPTIONAL and additive — absent
   * means no link minted. Device-written ONLY (Settings screen); the backend
   * resolves token → user by READING the settings blob, never writing it.
   * Public-by-design (the token is in the shared URL) — not a SECURE_FIELD.
   */
  bookingLink?: { token: string; enabled: boolean };
  /**
   * Expo push token for owner alerts. OPTIONAL and additive. Device-written
   * by utils/pushToken.ts (only-on-change); read server-side to send booking
   * alerts. Not a secret credential — not a SECURE_FIELD.
   */
  pushToken?: { token: string; platform: "ios" | "android"; updatedAt: string };
```

- [ ] **Step 2: Write the failing storage test.** Create `__tests__/bookingRequestsStorage.test.ts` — mirror of `__tests__/recurringInvoicesStorage.test.ts`:

```ts
// __tests__/bookingRequestsStorage.test.ts
// The bookingRequests collection: AsyncStorage under KEYS.bookingRequests,
// synced from birth (2026-08-04 booking-link spec) — every save diffs into
// the sync queue like the other collections.

import AsyncStorage from '@react-native-async-storage/async-storage';
import { enqueueCollectionChanges, trySync } from '../utils/sync';
import { loadBookingRequests, saveBookingRequests } from '../utils/storage';
import type { BookingRequest } from '../types/models';

jest.mock('../utils/sync', () => ({
  enqueue: jest.fn(),
  enqueueCollectionChanges: jest.fn(),
  trySync: jest.fn(),
  pruneQueueRecords: jest.fn(),
}));
jest.mock('../utils/notifications', () => ({ syncNotifications: jest.fn() }));

const request: BookingRequest = {
  id: 'bk1700000000000_a1b2c3',
  status: 'new',
  name: 'Dana Rivers',
  phone: '555-0142',
  email: 'dana@example.com',
  address: '12 Elm St',
  details: 'Water heater is leaking',
  preferredTiming: 'Weekday mornings',
  createdAt: '2026-08-04T15:00:00.000Z',
};

beforeEach(() => {
  jest.clearAllMocks();
  (AsyncStorage.getItem as jest.Mock).mockResolvedValue(null);
  (AsyncStorage.setItem as jest.Mock).mockResolvedValue(undefined);
});

describe('bookingRequests storage', () => {
  test('loadBookingRequests returns [] when nothing is stored', async () => {
    expect(await loadBookingRequests()).toEqual([]);
  });

  test('saveBookingRequests writes JSON under the bookingRequests key', async () => {
    await saveBookingRequests([request]);
    expect(AsyncStorage.setItem).toHaveBeenCalledWith(
      'bookingRequests',
      JSON.stringify([request])
    );
  });

  test('saveBookingRequests diffs into the sync queue and kicks a background sync', async () => {
    await saveBookingRequests([request]);
    expect(enqueueCollectionChanges).toHaveBeenCalledWith('bookingRequests', [], [request]);
    expect(trySync).toHaveBeenCalled();
  });

  test('loadBookingRequests round-trips a saved request', async () => {
    (AsyncStorage.getItem as jest.Mock).mockResolvedValue(JSON.stringify([request]));
    expect(await loadBookingRequests()).toEqual([request]);
  });

  test('corrupt JSON degrades to [] instead of throwing', async () => {
    (AsyncStorage.getItem as jest.Mock).mockResolvedValue('{not json');
    expect(await loadBookingRequests()).toEqual([]);
  });
});
```

- [ ] **Step 3: Run it to verify it fails.** Run: `npx jest __tests__/bookingRequestsStorage.test.ts`
Expected: FAIL — `loadBookingRequests` is not exported.

- [ ] **Step 4: Implement.**

`utils/storage/keys.ts` — add to the `KEYS` map after `pricebook`:

```ts
  bookingRequests: "bookingRequests",
```

Create `utils/storage/bookingRequests.ts` (mirror of `utils/storage/trips.ts`):

```ts
import AsyncStorage from "@react-native-async-storage/async-storage";
import { enqueueCollectionChanges, trySync } from "../sync";
import { KEYS } from "./keys";
import type { BookingRequest } from "../../types/models";

export async function loadBookingRequests(): Promise<BookingRequest[]> {
  try {
    const raw = await AsyncStorage.getItem(KEYS.bookingRequests);
    return raw ? JSON.parse(raw) : [];
  } catch {
    return [];
  }
}

export async function saveBookingRequests(requests: BookingRequest[]): Promise<void> {
  const oldRaw = await AsyncStorage.getItem(KEYS.bookingRequests);
  const old: BookingRequest[] = oldRaw ? JSON.parse(oldRaw) : [];
  await AsyncStorage.setItem(KEYS.bookingRequests, JSON.stringify(requests));
  await enqueueCollectionChanges("bookingRequests", old, requests);
  trySync();
}
```

`utils/sync.ts` line ~16 — append to `COLLECTION_TABLES`:

```ts
const COLLECTION_TABLES = ['jobs', 'invoices', 'customers', 'expenses', 'pricebook', 'recurringJobs', 'recurringInvoices', 'trips', 'bookingRequests'] as const;
```

**Verify while editing** (do not change anything else in sync.ts): the backfill constant a few lines below (`backfillLocalOnlyCollections` / the 2026-08-03 late-added-tables list) must NOT gain `bookingRequests` — this collection is brand new, no device holds pre-sync local rows to backfill. The cross-user wipe list and `pushAllLocalToCloud` pick the new table up automatically from `COLLECTION_TABLES`.

`utils/storage/index.ts` — after the `loadTrips` line, add:

```ts
export { loadBookingRequests, saveBookingRequests } from "./bookingRequests";
```

Create `supabase/migrations/20260804_booking_requests.sql` (template: `20260803_local_collections_sync.sql`):

```sql
-- Cloud table for public booking-link submissions (2026-08-04 spec).
-- Name matches the client's COLLECTION_TABLES entry EXACTLY — camelCase is a
-- quoted identifier on purpose; supabase-js .from('bookingRequests') resolves
-- case-sensitively. Same blob shape + owner-scoped RLS as the other data
-- tables. Rows are INSERTED by the backend with the service role (which
-- bypasses RLS); the policy below is what lets the owner's device pull and
-- update its own rows.
--
-- RELEASE GATE: run this in the Supabase SQL editor BEFORE shipping the OTA
-- that adds bookingRequests to COLLECTION_TABLES — a missing cloud table
-- wedges every push into retained-retry (2026-07-14 pricebook incident).
-- Applied out-of-band via the Supabase SQL editor. Safe to re-run (idempotent).

create table if not exists public."bookingRequests" (
  id text primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  data jsonb not null,
  updated_at timestamptz not null default now(),
  deleted boolean not null default false
);

alter table public."bookingRequests" enable row level security;

drop policy if exists "users manage own bookingRequests" on public."bookingRequests";
create policy "users manage own bookingRequests"
  on public."bookingRequests"
  for all
  using (auth.uid() = user_id)
  with check (auth.uid() = user_id);
```

- [ ] **Step 5: Run the test to verify it passes.** Run: `npx jest __tests__/bookingRequestsStorage.test.ts`
Expected: PASS (5 tests).

- [ ] **Step 6: Full gate, then commit.**

```bash
npm run typecheck && npm test && npm run lint
git add types/models.ts utils/storage/keys.ts utils/storage/bookingRequests.ts utils/sync.ts utils/storage/index.ts supabase/migrations/20260804_booking_requests.sql __tests__/bookingRequestsStorage.test.ts
git commit -m "feat: add bookingRequests synced collection + settings fields for booking link"
```

---

### Task 2: Device converter — bookingRequests → Customer + lead Job

**Files:**
- Create: `utils/storage/bookingConversion.ts`
- Modify: `utils/storage/index.ts` (export `applyBookingRequests`)
- Modify: `App.tsx` (~line 384: extend the sign-in migration chain)
- Test: `__tests__/bookingConversion.test.ts`

**Interfaces:**
- Consumes: `loadBookingRequests`/`saveBookingRequests` (Task 1); `loadJobs`/`saveJobs`, `loadCustomers`/`saveCustomers` from `./collections`; `loadSettings` from `./settings`; `upsertCustomerInList(customers, { name, email, phone, address })` from `./customers` (returns `{ customer, customers, changed }`).
- Produces: pure `convertBookingRequests(requests, jobs, customers, settings)` returning `{ requests, jobs, customers, changed }`; async `applyBookingRequests(): Promise<void>` exported from `utils/storage`.

- [ ] **Step 1: Write the failing test.** Create `__tests__/bookingConversion.test.ts`:

```ts
// __tests__/bookingConversion.test.ts
// Pure conversion core for booking requests (2026-08-04 spec §3.3): every
// "new" request becomes a Customer (real contact fields) + a lead Job with a
// DETERMINISTIC id (jbk_<requestId>) so a crash between saves can never
// duplicate a lead. Idempotent and flag-free, like applyDecisionsToJobs.

import { convertBookingRequests } from '../utils/storage/bookingConversion';
import { defaultSettings } from '../utils/storage';
import type { BookingRequest, Customer } from '../types/models';

jest.mock('../utils/sync', () => ({
  enqueue: jest.fn(),
  enqueueCollectionChanges: jest.fn(),
  trySync: jest.fn(),
  pruneQueueRecords: jest.fn(),
}));
jest.mock('../utils/notifications', () => ({ syncNotifications: jest.fn() }));

const settings = { ...defaultSettings(), laborRate: 95, materialMarkup: 25, overheadPercent: 10, marginPercent: 30 };

const request: BookingRequest = {
  id: 'bk1700000000000_a1b2c3',
  status: 'new',
  name: 'Dana Rivers',
  phone: '555-0142',
  email: 'dana@example.com',
  address: '12 Elm St',
  details: 'Water heater is leaking',
  preferredTiming: 'Weekday mornings',
  createdAt: '2026-08-04T15:00:00.000Z',
};

describe('convertBookingRequests', () => {
  test('converts a new request into a customer with full contact info + a lead job', () => {
    const out = convertBookingRequests([request], [], [], settings);
    expect(out.changed).toBe(true);

    expect(out.customers).toHaveLength(1);
    const c = out.customers[0];
    expect(c.name).toBe('Dana Rivers');
    expect(c.email).toBe('dana@example.com');
    expect(c.phone).toBe('555-0142');
    expect(c.address).toBe('12 Elm St');

    expect(out.jobs).toHaveLength(1);
    const j = out.jobs[0];
    expect(j.id).toBe('jbk_bk1700000000000_a1b2c3');
    expect(j.status).toBe('lead');
    expect(j.customerId).toBe(c.id);
    expect(j.customerName).toBe('Dana Rivers');
    expect(j.title).toBe('Quote request');
    expect(j.description).toBe('Water heater is leaking');
    expect(j.address).toBe('12 Elm St');
    expect(j.notes).toBe('Preferred timing: Weekday mornings\nCame in via booking link 2026-08-04');
    expect(j.scheduledDate).toBeNull();
    expect(j.invoiceId).toBeNull();
    expect(j.createdAt).toBe('2026-08-04');
    // AddJob new-job pricing parity (AddJobScreen.tsx ~337): settings values
    // with the same fallbacks.
    expect(j.estimateTotal).toBe(0);
    expect(j.laborHours).toBe(0);
    expect(j.materials).toEqual([]);
    expect(j.laborRate).toBe(95);
    expect(j.materialMarkup).toBe(25);
    expect(j.overhead).toBe(10);
    expect(j.margin).toBe(30);

    const r = out.requests[0];
    expect(r.status).toBe('converted');
    expect(r.convertedJobId).toBe(j.id);
    expect(r.convertedCustomerId).toBe(c.id);
  });

  test('omits the timing line when preferredTiming is empty', () => {
    const out = convertBookingRequests([{ ...request, preferredTiming: '' }], [], [], settings);
    expect(out.jobs[0].notes).toBe('Came in via booking link 2026-08-04');
  });

  test('joins an existing customer by normalized name and backfills blank contact fields', () => {
    const existing: Customer = { id: 'c1', name: 'dana rivers', email: '', phone: '', address: '', notes: '', createdAt: '2026-01-01' };
    const out = convertBookingRequests([request], [], [existing], settings);
    expect(out.customers).toHaveLength(1);
    expect(out.jobs[0].customerId).toBe('c1');
    expect(out.customers[0].email).toBe('dana@example.com'); // backfilled, not clobbered
  });

  test('is idempotent — a second run over its own output changes nothing', () => {
    const first = convertBookingRequests([request], [], [], settings);
    const second = convertBookingRequests(first.requests, first.jobs, first.customers, settings);
    expect(second.changed).toBe(false);
    expect(second.jobs).toBe(first.jobs);
    expect(second.customers).toBe(first.customers);
    expect(second.requests).toBe(first.requests);
  });

  test('crash recovery: job already exists but request still "new" — no duplicate job, request gets marked', () => {
    const first = convertBookingRequests([request], [], [], settings);
    const rerun = convertBookingRequests([request], first.jobs, first.customers, settings);
    expect(rerun.jobs).toHaveLength(1);
    expect(rerun.changed).toBe(true); // the request row still needed marking
    expect(rerun.requests[0].status).toBe('converted');
  });

  test('ignores converted requests entirely', () => {
    const done: BookingRequest = { ...request, status: 'converted', convertedJobId: 'jX', convertedCustomerId: 'cX' };
    const out = convertBookingRequests([done], [], [], settings);
    expect(out.changed).toBe(false);
  });
});
```

- [ ] **Step 2: Run it to verify it fails.** Run: `npx jest __tests__/bookingConversion.test.ts`
Expected: FAIL — module `../utils/storage/bookingConversion` not found.

- [ ] **Step 3: Implement.** Create `utils/storage/bookingConversion.ts`:

```ts
// Converts server-inserted booking requests into the local data model.
// Idempotent and flag-free (modeled on applyEstimateDecisions /
// migrateCustomerIdentity): safe on every sign-in and foreground. The server
// only ever INSERTS request rows with status "new"; the device owns Customer
// and Job creation via the sanctioned paths, then marks the request
// "converted" so the state syncs back and other devices converge.
//
// The lead job id is DETERMINISTIC (jbk_<requestId>): if a run crashes after
// saveJobs but before the request is marked, the rerun regenerates the same
// id and merge-by-id absorbs it — no duplicate leads, same philosophy as the
// recurring engines' ruleId+occurrenceNumber dedupe guard.

import { loadJobs, saveJobs, loadCustomers, saveCustomers } from "./collections";
import { loadSettings } from "./settings";
import { loadBookingRequests, saveBookingRequests } from "./bookingRequests";
import { upsertCustomerInList } from "./customers";
import type { BookingRequest, Customer, Job, Settings } from "../../types/models";

export function convertBookingRequests(
  requests: BookingRequest[],
  jobs: Job[],
  customers: Customer[],
  settings: Settings,
): { requests: BookingRequest[]; jobs: Job[]; customers: Customer[]; changed: boolean } {
  let nextCustomers = customers;
  let nextJobs = jobs;
  let customersChanged = false;
  let jobsChanged = false;
  let requestsChanged = false;

  const nextRequests = requests.map((r) => {
    if (r.status !== "new") return r;

    const { customer, customers: c2, changed } = upsertCustomerInList(nextCustomers, {
      name: r.name,
      email: r.email,
      phone: r.phone,
      address: r.address,
    });
    if (changed) { nextCustomers = c2; customersChanged = true; }
    if (!customer) return r; // unusable name — leave the request for inspection

    const jobId = `jbk_${r.id}`;
    if (!nextJobs.some((j) => j.id === jobId)) {
      // The server's UTC day is fine here — the date is informational, and
      // deriving it from the request keeps conversion fully deterministic.
      const requestDate = r.createdAt.slice(0, 10);
      const timingLine = r.preferredTiming.trim() ? `Preferred timing: ${r.preferredTiming.trim()}\n` : "";
      const lead: Job = {
        id: jobId,
        customerId: customer.id,
        customerName: customer.name,
        title: "Quote request",
        description: r.details,
        status: "lead",
        scheduledDate: null,
        scheduledStartTime: null,
        scheduledEndTime: null,
        address: r.address,
        // AddJob new-job pricing parity (AddJobScreen.tsx ~337), fallbacks included.
        estimateTotal: 0,
        laborHours: 0,
        laborRate: settings.laborRate ?? 85,
        materials: [],
        materialMarkup: settings.materialMarkup ?? 20,
        overhead: settings.overheadPercent ?? 15,
        margin: settings.marginPercent ?? 20,
        notes: `${timingLine}Came in via booking link ${requestDate}`,
        invoiceId: null,
        createdAt: requestDate,
      };
      nextJobs = [...nextJobs, lead];
      jobsChanged = true;
    }

    requestsChanged = true;
    return { ...r, status: "converted" as const, convertedJobId: jobId, convertedCustomerId: customer.id };
  });

  return {
    requests: requestsChanged ? nextRequests : requests,
    jobs: jobsChanged ? nextJobs : jobs,
    customers: customersChanged ? nextCustomers : customers,
    changed: requestsChanged || jobsChanged || customersChanged,
  };
}

// Save-only-what-changed: a save re-enqueues the whole collection, so a no-op
// run must not write (same rule as migrateCustomerIdentity).
export async function applyBookingRequests(): Promise<void> {
  const [requests, jobs, customers, settings] = await Promise.all([
    loadBookingRequests(),
    loadJobs(),
    loadCustomers(),
    loadSettings(),
  ]);
  if (!requests.some((r) => r.status === "new")) return;
  const out = convertBookingRequests(requests, jobs, customers, settings);
  if (out.customers !== customers) await saveCustomers(out.customers);
  if (out.jobs !== jobs) await saveJobs(out.jobs);
  if (out.requests !== requests) await saveBookingRequests(out.requests);
}
```

Add to `utils/storage/index.ts` after the `applyEstimateDecisions` line:

```ts
export { applyBookingRequests } from "./bookingConversion";
```

- [ ] **Step 4: Run the test to verify it passes.** Run: `npx jest __tests__/bookingConversion.test.ts`
Expected: PASS (6 tests).

- [ ] **Step 5: Wire into App.tsx.** In the sign-in effect chain (App.tsx ~line 378–385), extend the promise chain — `applyBookingRequests` runs after `applyEstimateDecisions` (both are cheap no-ops when nothing is pending). Update the import on line 74 to include it:

```ts
import { loadSettings, loadInvoices, migrateCustomerIdentity, migrateSampleDataIds, applyEstimateDecisions, applyBookingRequests, scrubLegacySquareToken } from "./utils/storage";
```

and in the chain:

```ts
      .then(() => applyEstimateDecisions())
      .catch(() => {})
      .then(() => applyBookingRequests())
      .catch(() => {})
      .then(() => scrubLegacySquareToken())
      .catch(() => {});
```

**Also** find where `applyEstimateDecisions` runs on app foreground (`context/AuthContext.tsx`, after `syncIfOnline`) and add `applyBookingRequests()` immediately after it with identical error-swallowing style, so requests convert on foreground pulls too — read the surrounding code first and match it exactly.

- [ ] **Step 6: Full gate, then commit.**

```bash
npm run typecheck && npm test && npm run lint
git add utils/storage/bookingConversion.ts utils/storage/index.ts App.tsx context/AuthContext.tsx __tests__/bookingConversion.test.ts
git commit -m "feat: convert booking requests into customers + lead jobs on device"
```

---

### Task 3: Backend store — token lookup and request insert

**Files:**
- Create: `backend/lib/booking/store.js`
- Test: `__tests__/bookingStore.test.js`

**Interfaces:**
- Consumes: env `SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY` (already deployed; no new env vars).
- Produces: `lookupUserByBookingToken(token) → Promise<{ user_id, data } | null>`; `insertBookingRequest(userId, request) → Promise<void>`; `newRequestId(now, randHex) → string` (pure).

- [ ] **Step 1: Write the failing test.** Create `__tests__/bookingStore.test.js`:

```js
// __tests__/bookingStore.test.js
// Booking backend store: token → user resolution reads the settings blob
// (the device WRITES the token via normal settings sync; the server only
// reads), and submissions INSERT rows shaped exactly like the sync engine's
// own pushes so pullRemote absorbs them unchanged.

process.env.SUPABASE_URL = 'https://unit.test';
process.env.SUPABASE_SERVICE_ROLE_KEY = 'service-role-test';

const { lookupUserByBookingToken, insertBookingRequest, newRequestId } = require('../backend/lib/booking/store');

describe('newRequestId', () => {
  it('builds bk<epoch>_<hex> from its inputs (pure, injectable)', () => {
    expect(newRequestId(1700000000000, 'a1b2c3')).toBe('bk1700000000000_a1b2c3');
  });
});

describe('lookupUserByBookingToken', () => {
  afterEach(() => { delete global.fetch; });

  it('queries settings by JSON-path token + enabled and returns the row', async () => {
    global.fetch = jest.fn().mockResolvedValue({
      ok: true,
      json: async () => [{ user_id: 'u1', data: { businessName: 'Rivera Plumbing' } }],
    });
    const row = await lookupUserByBookingToken('abc123');
    expect(row.user_id).toBe('u1');
    const url = global.fetch.mock.calls[0][0];
    expect(url).toContain('/rest/v1/settings');
    expect(url).toContain('data->bookingLink->>token=eq.abc123');
    expect(url).toContain('data->bookingLink->>enabled=eq.true');
    expect(url).toContain('select=user_id,data');
  });

  it('returns null when no row matches', async () => {
    global.fetch = jest.fn().mockResolvedValue({ ok: true, json: async () => [] });
    expect(await lookupUserByBookingToken('nope')).toBeNull();
  });

  it('throws on a non-ok response (caller maps to 500)', async () => {
    global.fetch = jest.fn().mockResolvedValue({ ok: false, status: 500, text: async () => 'boom' });
    await expect(lookupUserByBookingToken('abc')).rejects.toThrow('Supabase');
  });
});

describe('insertBookingRequest', () => {
  afterEach(() => { delete global.fetch; });

  it('POSTs the standard blob row shape to bookingRequests', async () => {
    global.fetch = jest.fn().mockResolvedValue({ ok: true });
    const request = { id: 'bk1_x', status: 'new', name: 'Dana' };
    await insertBookingRequest('u1', request);
    const [url, opts] = global.fetch.mock.calls[0];
    expect(url).toBe('https://unit.test/rest/v1/bookingRequests');
    const body = JSON.parse(opts.body);
    expect(body.id).toBe('bk1_x');
    expect(body.user_id).toBe('u1');
    expect(body.data).toEqual(request);
    expect(body.deleted).toBe(false);
    expect(typeof body.updated_at).toBe('string');
    expect(opts.headers.Authorization).toBe('Bearer service-role-test');
  });

  it('throws on a non-ok response', async () => {
    global.fetch = jest.fn().mockResolvedValue({ ok: false, status: 401, text: async () => 'denied' });
    await expect(insertBookingRequest('u1', { id: 'x' })).rejects.toThrow('Supabase');
  });
});
```

- [ ] **Step 2: Run it to verify it fails.** Run: `npx jest __tests__/bookingStore.test.js`
Expected: FAIL — module not found.

- [ ] **Step 3: Implement.** Create `backend/lib/booking/store.js`:

```js
// Supabase access for the booking endpoints. Service role (bypasses RLS),
// exactly like ../estimateStore.js. NOT routed by Vercel (lives under lib/).
//
// The booking token lives INSIDE the owner's settings blob and is written
// only by the device (normal settings sync). The server resolves it with a
// PostgREST JSON-path filter and never writes settings — that one-way flow is
// what makes token rotation race-free (spec §4).

const SUPABASE_URL = process.env.SUPABASE_URL;
const SUPABASE_SERVICE_ROLE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY;

function headers() {
  return {
    Authorization: `Bearer ${SUPABASE_SERVICE_ROLE_KEY}`,
    apikey: SUPABASE_SERVICE_ROLE_KEY,
  };
}

// bk<epoch-ms>_<6 hex>. Inputs injected so it stays pure/deterministic;
// callers pass Date.now() and crypto.randomBytes(3).toString('hex').
function newRequestId(nowMs, randHex) {
  return `bk${nowMs}_${randHex}`;
}

// Returns { user_id, data } for an ENABLED booking link, else null. Disabled
// and unknown tokens are indistinguishable to callers on purpose (no oracle).
async function lookupUserByBookingToken(token) {
  const res = await fetch(
    `${SUPABASE_URL}/rest/v1/settings?data->bookingLink->>token=eq.${encodeURIComponent(token)}&data->bookingLink->>enabled=eq.true&select=user_id,data`,
    { headers: headers() }
  );
  if (!res.ok) throw new Error(`Supabase fetch ${res.status}: ${await res.text()}`);
  const rows = await res.json();
  return rows.length ? rows[0] : null;
}

// Row shape matches what the sync engine itself pushes, so the device's
// pullRemote absorbs these rows with zero special-casing.
async function insertBookingRequest(userId, request) {
  const res = await fetch(`${SUPABASE_URL}/rest/v1/bookingRequests`, {
    method: 'POST',
    headers: { ...headers(), 'Content-Type': 'application/json', Prefer: 'resolution=merge-duplicates' },
    body: JSON.stringify({
      id: request.id,
      user_id: userId,
      data: request,
      updated_at: new Date().toISOString(),
      deleted: false,
    }),
  });
  if (!res.ok) throw new Error(`Supabase insert ${res.status}: ${await res.text()}`);
}

module.exports = { lookupUserByBookingToken, insertBookingRequest, newRequestId };
```

- [ ] **Step 4: Run the test to verify it passes.** Run: `npx jest __tests__/bookingStore.test.js`
Expected: PASS (6 tests).

- [ ] **Step 5: Full gate, then commit.**

```bash
npm run typecheck && npm test && npm run lint
git add backend/lib/booking/store.js __tests__/bookingStore.test.js
git commit -m "feat: booking backend store — settings-blob token lookup + request insert"
```

---

### Task 4: Owner alerts — email via Resend + Expo push send

**Files:**
- Create: `backend/lib/booking/notifyOwner.js`
- Test: `__tests__/bookingNotify.test.js`

**Interfaces:**
- Consumes: env `SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY`, `RESEND_API_KEY` (all already deployed — no new env vars).
- Produces: `buildBookingEmail({ to, request }) → { from, to, subject, text }` (pure); `notifyOwner({ userId, settingsData, request }) → Promise<void>` — never throws.

- [ ] **Step 1: Write the failing test.** Create `__tests__/bookingNotify.test.js`:

```js
// __tests__/bookingNotify.test.js
// Booking alerts are fire-and-forget: an alert failure must never fail the
// submission (spec §5). Subject header is attacker-influenceable submission
// data — CR/LF stripped, length capped.

process.env.SUPABASE_URL = 'https://unit.test';
process.env.SUPABASE_SERVICE_ROLE_KEY = 'service-role-test';
process.env.RESEND_API_KEY = 'resend-test';

const { buildBookingEmail, notifyOwner } = require('../backend/lib/booking/notifyOwner');

const request = {
  id: 'bk1_x', status: 'new', name: 'Dana Rivers', phone: '555-0142',
  email: 'dana@example.com', address: '12 Elm St',
  details: 'Water heater is leaking', preferredTiming: 'Mornings',
  createdAt: '2026-08-04T15:00:00.000Z',
};

describe('buildBookingEmail', () => {
  it('builds a complete plain-text email from the verified domain', () => {
    const email = buildBookingEmail({ to: 'owner@example.com', request });
    expect(email.from).toBe('TradeReady <leads@gettradereadyapp.com>');
    expect(email.to).toBe('owner@example.com');
    expect(email.subject).toBe('New quote request from Dana Rivers');
    expect(email.text).toContain('Water heater is leaking');
    expect(email.text).toContain('555-0142');
    expect(email.text).toContain('dana@example.com');
    expect(email.text).toContain('12 Elm St');
    expect(email.text).toContain('Mornings');
    expect(email.text).toContain('Open TradeReady');
  });

  it('strips header-smuggling characters from the subject and caps length', () => {
    const evil = { ...request, name: 'A\r\nBcc: spam@x.com' + 'x'.repeat(200) };
    const email = buildBookingEmail({ to: 'o@x.com', request: evil });
    expect(email.subject).not.toMatch(/[\r\n]/);
    expect(email.subject.length).toBeLessThanOrEqual(120);
  });
});

describe('notifyOwner', () => {
  afterEach(() => { delete global.fetch; });

  it('sends email (admin lookup + Resend) and push when a pushToken exists', async () => {
    global.fetch = jest.fn()
      .mockResolvedValueOnce({ ok: true, json: async () => ({ email: 'owner@example.com' }) }) // admin user lookup
      .mockResolvedValueOnce({ ok: true, text: async () => '' })                                // resend
      .mockResolvedValueOnce({ ok: true, text: async () => '' });                               // expo push
    await notifyOwner({
      userId: 'u1',
      settingsData: { pushToken: { token: 'ExponentPushToken[abc]' } },
      request,
    });
    const urls = global.fetch.mock.calls.map((c) => c[0]);
    expect(urls[0]).toBe('https://unit.test/auth/v1/admin/users/u1');
    expect(urls[1]).toBe('https://api.resend.com/emails');
    expect(urls[2]).toBe('https://exp.host/--/api/v2/push/send');
    const push = JSON.parse(global.fetch.mock.calls[2][1].body);
    expect(push.to).toBe('ExponentPushToken[abc]');
    expect(push.title).toBe('New quote request');
    expect(push.data).toEqual({ type: 'booking_request' });
  });

  it('skips push when settings has no pushToken', async () => {
    global.fetch = jest.fn()
      .mockResolvedValueOnce({ ok: true, json: async () => ({ email: 'owner@example.com' }) })
      .mockResolvedValueOnce({ ok: true, text: async () => '' });
    await notifyOwner({ userId: 'u1', settingsData: {}, request });
    expect(global.fetch).toHaveBeenCalledTimes(2);
  });

  it('never throws — even when every call fails', async () => {
    global.fetch = jest.fn().mockRejectedValue(new Error('network down'));
    await expect(
      notifyOwner({ userId: 'u1', settingsData: { pushToken: { token: 'T' } }, request })
    ).resolves.toBeUndefined();
  });
});
```

- [ ] **Step 2: Run it to verify it fails.** Run: `npx jest __tests__/bookingNotify.test.js`
Expected: FAIL — module not found.

- [ ] **Step 3: Implement.** Create `backend/lib/booking/notifyOwner.js`:

```js
// Owner alerts for a new booking request: email always (Resend, same
// transport as api/cron/send-reminders.js), push when the settings blob
// carries an Expo push token (registered by utils/pushToken.ts; absent until
// the binary has the push entitlement — spec §7). Fire-and-forget by
// contract: every failure is logged and swallowed; a lost alert must never
// fail the customer's submission.

const SUPABASE_URL = process.env.SUPABASE_URL;
const SUPABASE_SERVICE_ROLE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY;
const RESEND_API_KEY = process.env.RESEND_API_KEY;

const SENDER = 'TradeReady <leads@gettradereadyapp.com>';

// Subject is attacker-influenceable submission data landing in a mail header:
// strip CR/LF (header smuggling), collapse whitespace, cap length. Same
// threat model as sanitizeFromPhrase in ../reminderEmail.js, scoped to a
// subject line.
function sanitizeSubjectPart(name) {
  return String(name || '').replace(/[\r\n]/g, ' ').replace(/\s+/g, ' ').trim().slice(0, 80);
}

function buildBookingEmail({ to, request }) {
  const lines = [
    `New quote request via your booking link:`,
    ``,
    `Name: ${request.name}`,
    `Phone: ${request.phone || '-'}`,
    `Email: ${request.email || '-'}`,
    `Address: ${request.address || '-'}`,
    `Preferred timing: ${request.preferredTiming || '-'}`,
    ``,
    `What they need:`,
    request.details,
    ``,
    `Open TradeReady to see the new lead in Jobs.`,
  ];
  return {
    from: SENDER,
    to,
    subject: `New quote request from ${sanitizeSubjectPart(request.name)}`.slice(0, 120),
    text: lines.join('\n'),
  };
}

async function fetchOwnerEmail(userId) {
  const res = await fetch(`${SUPABASE_URL}/auth/v1/admin/users/${encodeURIComponent(userId)}`, {
    headers: { Authorization: `Bearer ${SUPABASE_SERVICE_ROLE_KEY}`, apikey: SUPABASE_SERVICE_ROLE_KEY },
  });
  if (!res.ok) throw new Error(`Admin user lookup ${res.status}`);
  const user = await res.json();
  return user && user.email ? user.email : null;
}

async function notifyOwner({ userId, settingsData, request }) {
  try {
    const to = await fetchOwnerEmail(userId);
    if (to && RESEND_API_KEY) {
      const r = await fetch('https://api.resend.com/emails', {
        method: 'POST',
        headers: { Authorization: `Bearer ${RESEND_API_KEY}`, 'Content-Type': 'application/json' },
        body: JSON.stringify(buildBookingEmail({ to, request })),
      });
      if (!r.ok) throw new Error(`Resend ${r.status}: ${await r.text()}`);
    }
  } catch (err) {
    console.error('[booking/notify] email failed:', err.message);
  }

  try {
    const token = settingsData && settingsData.pushToken && settingsData.pushToken.token;
    if (token) {
      const r = await fetch('https://exp.host/--/api/v2/push/send', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          to: token,
          title: 'New quote request',
          body: `${request.name} — ${String(request.details || '').slice(0, 120)}`,
          data: { type: 'booking_request' },
        }),
      });
      if (!r.ok) throw new Error(`Expo push ${r.status}: ${await r.text()}`);
    }
  } catch (err) {
    console.error('[booking/notify] push failed:', err.message);
  }
}

module.exports = { buildBookingEmail, notifyOwner };
```

- [ ] **Step 4: Run the test to verify it passes.** Run: `npx jest __tests__/bookingNotify.test.js`
Expected: PASS (5 tests).

- [ ] **Step 5: Full gate, then commit.**

```bash
npm run typecheck && npm test && npm run lint
git add backend/lib/booking/notifyOwner.js __tests__/bookingNotify.test.js
git commit -m "feat: booking owner alerts — Resend email + Expo push, fire-and-forget"
```

---

### Task 5: Validation + public submit handler

**Files:**
- Create: `backend/lib/booking/validate.js`
- Create: `backend/lib/booking/submit.js`
- Test: `__tests__/bookingValidate.test.js`, `__tests__/bookingSubmit.test.js`

**Interfaces:**
- Consumes: `lookupUserByBookingToken`, `insertBookingRequest`, `newRequestId` (Task 3); `notifyOwner` (Task 4); `applyCors` from `backend/lib/estimate/cors.js`; `createRateLimiter` from `backend/lib/guards.js`.
- Produces: `validateBookingPayload(body) → { ok: true, value } | { ok: false, error }` (pure); `submit(req, res)` handler consumed by the Task 7 dispatcher.

- [ ] **Step 1: Write the failing validation test.** Create `__tests__/bookingValidate.test.js`:

```js
// __tests__/bookingValidate.test.js
// Server-authoritative field rules from spec §6. The page validates too, but
// only this layer is trusted.

const { validateBookingPayload } = require('../backend/lib/booking/validate');

const good = {
  name: '  Dana Rivers ', phone: '555-0142', email: 'dana@example.com',
  address: '12 Elm St', details: 'Water heater is leaking', preferredTiming: 'Mornings',
};

describe('validateBookingPayload', () => {
  it('accepts a full payload and returns trimmed values', () => {
    const out = validateBookingPayload(good);
    expect(out.ok).toBe(true);
    expect(out.value.name).toBe('Dana Rivers');
    expect(out.value.preferredTiming).toBe('Mornings');
  });

  it('accepts phone-only and email-only contact', () => {
    expect(validateBookingPayload({ ...good, email: '' }).ok).toBe(true);
    expect(validateBookingPayload({ ...good, phone: '' }).ok).toBe(true);
  });

  it('rejects when name or details is missing', () => {
    expect(validateBookingPayload({ ...good, name: '  ' }).ok).toBe(false);
    expect(validateBookingPayload({ ...good, details: '' }).ok).toBe(false);
  });

  it('rejects when BOTH phone and email are empty', () => {
    const out = validateBookingPayload({ ...good, phone: ' ', email: '' });
    expect(out.ok).toBe(false);
    expect(out.error).toMatch(/phone or email/i);
  });

  it('rejects a malformed email but allows empty when phone exists', () => {
    expect(validateBookingPayload({ ...good, email: 'not-an-email' }).ok).toBe(false);
  });

  it('enforces length caps (name 100, phone 50, email 200, address 300, details 2000, timing 200)', () => {
    expect(validateBookingPayload({ ...good, name: 'x'.repeat(101) }).ok).toBe(false);
    expect(validateBookingPayload({ ...good, phone: 'x'.repeat(51) }).ok).toBe(false);
    expect(validateBookingPayload({ ...good, email: 'a@' + 'x'.repeat(199) }).ok).toBe(false);
    expect(validateBookingPayload({ ...good, address: 'x'.repeat(301) }).ok).toBe(false);
    expect(validateBookingPayload({ ...good, details: 'x'.repeat(2001) }).ok).toBe(false);
    expect(validateBookingPayload({ ...good, preferredTiming: 'x'.repeat(201) }).ok).toBe(false);
  });

  it('rejects non-string fields instead of coercing', () => {
    expect(validateBookingPayload({ ...good, details: { $gt: '' } }).ok).toBe(false);
  });
});
```

- [ ] **Step 2: Run it to verify it fails.** Run: `npx jest __tests__/bookingValidate.test.js`
Expected: FAIL — module not found.

- [ ] **Step 3: Implement validation.** Create `backend/lib/booking/validate.js`:

```js
// Field rules for public booking submissions (spec §6). Pure — no I/O.
// Returns { ok: true, value } with trimmed strings, or { ok: false, error }
// with a client-safe message the page shows inline.

const CAPS = { name: 100, phone: 50, email: 200, address: 300, details: 2000, preferredTiming: 200 };
const EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

function validateBookingPayload(body) {
  const src = body || {};
  const value = {};
  for (const [field, cap] of Object.entries(CAPS)) {
    const raw = src[field];
    if (raw != null && typeof raw !== 'string') return { ok: false, error: `${field} must be text.` };
    const trimmed = (raw || '').trim();
    if (trimmed.length > cap) return { ok: false, error: `${field} is too long (max ${cap} characters).` };
    value[field] = trimmed;
  }
  if (!value.name) return { ok: false, error: 'Please tell us your name.' };
  if (!value.details) return { ok: false, error: 'Please describe what you need done.' };
  if (!value.phone && !value.email) return { ok: false, error: 'Please give a phone or email so we can reach you.' };
  if (value.email && !EMAIL_RE.test(value.email)) return { ok: false, error: 'That email address doesn\'t look right.' };
  return { ok: true, value };
}

module.exports = { validateBookingPayload };
```

- [ ] **Step 4: Run the validation test to verify it passes.** Run: `npx jest __tests__/bookingValidate.test.js`
Expected: PASS (7 tests).

- [ ] **Step 5: Write the failing submit-handler test.** Create `__tests__/bookingSubmit.test.js`:

```js
// __tests__/bookingSubmit.test.js
// The public submit handler: honeypot drops silently (don't teach the bot),
// alerts are fire-and-forget, and the inserted row carries a server-minted
// id + status "new" + server-clock createdAt.

jest.mock('../backend/lib/booking/store', () => ({
  lookupUserByBookingToken: jest.fn(),
  insertBookingRequest: jest.fn(),
  newRequestId: jest.fn(() => 'bk1700000000000_a1b2c3'),
}));
jest.mock('../backend/lib/booking/notifyOwner', () => ({ notifyOwner: jest.fn().mockResolvedValue(undefined) }));

const store = require('../backend/lib/booking/store');
const { notifyOwner } = require('../backend/lib/booking/notifyOwner');
const submit = require('../backend/lib/booking/submit');

function mockRes() {
  const res = { headers: {}, statusCode: 0, body: null };
  res.setHeader = (k, v) => { res.headers[k] = v; };
  res.status = (c) => { res.statusCode = c; return res; };
  res.json = (b) => { res.body = b; return res; };
  res.end = () => res;
  return res;
}

function makeReq(body, ip = '1.2.3.4') {
  return { method: 'POST', headers: { 'x-forwarded-for': ip, origin: 'https://gettradereadyapp.com' }, body };
}

const payload = {
  b: 'tok123', name: 'Dana Rivers', phone: '555-0142', email: 'dana@example.com',
  address: '12 Elm St', details: 'Water heater is leaking', preferredTiming: 'Mornings', website: '',
};

beforeEach(() => {
  jest.clearAllMocks();
  store.lookupUserByBookingToken.mockResolvedValue({ user_id: 'u1', data: { businessName: 'Rivera Plumbing' } });
  store.insertBookingRequest.mockResolvedValue(undefined);
});

describe('booking submit', () => {
  it('inserts a "new" request and fires alerts on the happy path', async () => {
    const res = mockRes();
    await submit(makeReq(payload), res);
    expect(res.statusCode).toBe(200);
    expect(res.body).toEqual({ ok: true });
    const [userId, request] = store.insertBookingRequest.mock.calls[0];
    expect(userId).toBe('u1');
    expect(request.id).toBe('bk1700000000000_a1b2c3');
    expect(request.status).toBe('new');
    expect(request.name).toBe('Dana Rivers');
    expect(typeof request.createdAt).toBe('string');
    expect(notifyOwner).toHaveBeenCalledWith(expect.objectContaining({ userId: 'u1', request: expect.any(Object) }));
  });

  it('honeypot: non-empty website returns ok WITHOUT inserting or alerting', async () => {
    const res = mockRes();
    await submit(makeReq({ ...payload, website: 'http://spam' }), res);
    expect(res.statusCode).toBe(200);
    expect(res.body).toEqual({ ok: true });
    expect(store.insertBookingRequest).not.toHaveBeenCalled();
    expect(notifyOwner).not.toHaveBeenCalled();
  });

  it('404s an unknown/disabled token with the oracle-free message', async () => {
    store.lookupUserByBookingToken.mockResolvedValue(null);
    const res = mockRes();
    await submit(makeReq(payload), res);
    expect(res.statusCode).toBe(404);
    expect(res.body).toEqual({ error: 'This link is invalid.' });
    expect(store.insertBookingRequest).not.toHaveBeenCalled();
  });

  it('400s validation failures with the field message and does not insert', async () => {
    const res = mockRes();
    await submit(makeReq({ ...payload, details: '' }), res);
    expect(res.statusCode).toBe(400);
    expect(res.body.error).toMatch(/describe what you need/);
    expect(store.insertBookingRequest).not.toHaveBeenCalled();
  });

  it('500s when the insert fails (nothing partial persists)', async () => {
    store.insertBookingRequest.mockRejectedValue(new Error('db down'));
    const res = mockRes();
    await submit(makeReq(payload), res);
    expect(res.statusCode).toBe(500);
    expect(notifyOwner).not.toHaveBeenCalled();
  });

  it('still returns 200 when alerts fail after a successful insert', async () => {
    notifyOwner.mockRejectedValue(new Error('mail down'));
    const res = mockRes();
    await submit(makeReq(payload), res);
    expect(res.statusCode).toBe(200);
    expect(res.body).toEqual({ ok: true });
  });

  it('405s non-POST and handles OPTIONS preflight', async () => {
    const res = mockRes();
    await submit({ method: 'GET', headers: {} }, res);
    expect(res.statusCode).toBe(405);
    const pre = mockRes();
    await submit({ method: 'OPTIONS', headers: {} }, pre);
    expect(pre.statusCode).toBe(200);
  });

  it('rate limits by IP with 429', async () => {
    for (let i = 0; i < 10; i++) await submit(makeReq(payload, '9.9.9.9'), mockRes());
    const res = mockRes();
    await submit(makeReq(payload, '9.9.9.9'), res);
    expect(res.statusCode).toBe(429);
  });
});
```

- [ ] **Step 6: Run it to verify it fails.** Run: `npx jest __tests__/bookingSubmit.test.js`
Expected: FAIL — module not found.

- [ ] **Step 7: Implement submit.** Create `backend/lib/booking/submit.js`:

```js
// POST /api/booking/submit  { b, name, phone, email, address, details,
// preferredTiming, website }
// Public, token-gated write path for the booking link. Inserts ONE row into
// bookingRequests (service role); the DEVICE converts it to Customer + lead
// Job (utils/storage/bookingConversion.ts). Alerts are fire-and-forget —
// their failure never fails the submission. `website` is the honeypot: bots
// fill it, humans never see it; a hit gets a fake success so the bot learns
// nothing.

const crypto = require('crypto');
const { lookupUserByBookingToken, insertBookingRequest, newRequestId } = require('./store');
const { validateBookingPayload } = require('./validate');
const { notifyOwner } = require('./notifyOwner');
const { applyCors } = require('../estimate/cors');
const { createRateLimiter } = require('../guards');

const allow = createRateLimiter({ limit: 10 });

module.exports = async function submit(req, res) {
  applyCors(req, res, 'POST, OPTIONS');
  if (req.method === 'OPTIONS') return res.status(200).end();
  if (req.method !== 'POST') return res.status(405).json({ error: 'Method not allowed' });

  const ip = (req.headers['x-forwarded-for'] || req.socket?.remoteAddress || 'unknown').split(',')[0].trim();
  if (!allow(ip)) return res.status(429).json({ error: 'Too many requests. Please wait a moment.' });

  const body = req.body || {};
  if (typeof body.website === 'string' && body.website.trim() !== '') {
    return res.status(200).json({ ok: true }); // honeypot — silent drop
  }

  const token = body.b;
  if (!token || typeof token !== 'string') return res.status(400).json({ error: 'Missing link parameters.' });

  const checked = validateBookingPayload(body);
  if (!checked.ok) return res.status(400).json({ error: checked.error });

  let row;
  try {
    row = await lookupUserByBookingToken(token);
  } catch (err) {
    console.error('[booking/submit] lookup failed:', err.message);
    return res.status(500).json({ error: 'Database error' });
  }
  if (!row) return res.status(404).json({ error: 'This link is invalid.' });

  const request = {
    id: newRequestId(Date.now(), crypto.randomBytes(3).toString('hex')),
    status: 'new',
    ...checked.value,
    createdAt: new Date().toISOString(),
  };

  try {
    await insertBookingRequest(row.user_id, request);
  } catch (err) {
    console.error('[booking/submit] insert failed:', err.message);
    return res.status(500).json({ error: 'Database error' });
  }

  try {
    await notifyOwner({ userId: row.user_id, settingsData: row.data, request });
  } catch (err) {
    console.error('[booking/submit] notify failed:', err.message);
  }

  return res.status(200).json({ ok: true });
};
```

- [ ] **Step 8: Run the test to verify it passes.** Run: `npx jest __tests__/bookingSubmit.test.js`
Expected: PASS (8 tests).

- [ ] **Step 9: Full gate, then commit.**

```bash
npm run typecheck && npm test && npm run lint
git add backend/lib/booking/validate.js backend/lib/booking/submit.js __tests__/bookingValidate.test.js __tests__/bookingSubmit.test.js
git commit -m "feat: public booking submit endpoint — validation, honeypot, token-gated insert"
```

---

### Task 6: Public config handler (form bootstrap)

**Files:**
- Create: `backend/lib/booking/config.js`
- Test: `__tests__/bookingConfig.test.js`

**Interfaces:**
- Consumes: `lookupUserByBookingToken` (Task 3); `applyCors`; `createRateLimiter`.
- Produces: `config(req, res)` handler for the Task 7 dispatcher. Response body is EXACTLY `{ businessName }`.

- [ ] **Step 1: Write the failing test.** Create `__tests__/bookingConfig.test.js`:

```js
// __tests__/bookingConfig.test.js
// The form-bootstrap read leaks NOTHING but the business display name —
// the response-keys assertion is the point of this suite.

jest.mock('../backend/lib/booking/store', () => ({
  lookupUserByBookingToken: jest.fn(),
}));

const store = require('../backend/lib/booking/store');
const config = require('../backend/lib/booking/config');

function mockRes() {
  const res = { headers: {}, statusCode: 0, body: null };
  res.setHeader = (k, v) => { res.headers[k] = v; };
  res.status = (c) => { res.statusCode = c; return res; };
  res.json = (b) => { res.body = b; return res; };
  res.end = () => res;
  return res;
}

beforeEach(() => {
  jest.clearAllMocks();
  store.lookupUserByBookingToken.mockResolvedValue({
    user_id: 'u1',
    data: { businessName: 'Rivera Plumbing', email: 'private@example.com', laborRate: 95, pushToken: { token: 'SECRETISH' } },
  });
});

describe('booking config', () => {
  it('returns ONLY businessName — no other settings fields leak', async () => {
    const res = mockRes();
    await config({ method: 'GET', headers: {}, query: { b: 'tok123' } }, res);
    expect(res.statusCode).toBe(200);
    expect(res.body).toEqual({ businessName: 'Rivera Plumbing' });
    expect(Object.keys(res.body)).toEqual(['businessName']);
  });

  it('404s unknown/disabled tokens with the oracle-free message', async () => {
    store.lookupUserByBookingToken.mockResolvedValue(null);
    const res = mockRes();
    await config({ method: 'GET', headers: {}, query: { b: 'nope' } }, res);
    expect(res.statusCode).toBe(404);
    expect(res.body).toEqual({ error: 'This link is invalid.' });
  });

  it('400s a missing token, 405s non-GET, 200s OPTIONS', async () => {
    const res = mockRes();
    await config({ method: 'GET', headers: {}, query: {} }, res);
    expect(res.statusCode).toBe(400);
    const post = mockRes();
    await config({ method: 'POST', headers: {}, query: {} }, post);
    expect(post.statusCode).toBe(405);
    const pre = mockRes();
    await config({ method: 'OPTIONS', headers: {}, query: {} }, pre);
    expect(pre.statusCode).toBe(200);
  });

  it('applies the CORS allowlist headers', async () => {
    const res = mockRes();
    await config({ method: 'GET', headers: { origin: 'https://gettradereadyapp.com' }, query: { b: 'tok123' } }, res);
    expect(res.headers['Access-Control-Allow-Origin']).toBe('https://gettradereadyapp.com');
    expect(res.headers['Vary']).toBe('Origin');
  });
});
```

- [ ] **Step 2: Run it to verify it fails.** Run: `npx jest __tests__/bookingConfig.test.js`
Expected: FAIL — module not found.

- [ ] **Step 3: Implement.** Create `backend/lib/booking/config.js`:

```js
// GET /api/booking/config?b=<token>
// Form bootstrap for book.html. Returns ONLY the business display name —
// the settings blob it reads also holds contact info, rates and the push
// token, none of which may leak to an anonymous caller.

const { lookupUserByBookingToken } = require('./store');
const { applyCors } = require('../estimate/cors');
const { createRateLimiter } = require('../guards');

const allow = createRateLimiter({ limit: 30 });

module.exports = async function config(req, res) {
  applyCors(req, res, 'GET, OPTIONS');
  if (req.method === 'OPTIONS') return res.status(200).end();
  if (req.method !== 'GET') return res.status(405).json({ error: 'Method not allowed' });

  const ip = (req.headers['x-forwarded-for'] || req.socket?.remoteAddress || 'unknown').split(',')[0].trim();
  if (!allow(ip)) return res.status(429).json({ error: 'Too many requests.' });

  const token = req.query.b;
  if (!token) return res.status(400).json({ error: 'Missing link parameters.' });

  let row;
  try {
    row = await lookupUserByBookingToken(String(token));
  } catch (err) {
    console.error('[booking/config] lookup failed:', err.message);
    return res.status(500).json({ error: 'Database error' });
  }
  if (!row) return res.status(404).json({ error: 'This link is invalid.' });

  return res.status(200).json({ businessName: String(row.data?.businessName || '').slice(0, 120) });
};
```

- [ ] **Step 4: Run the test to verify it passes.** Run: `npx jest __tests__/bookingConfig.test.js`
Expected: PASS (4 tests).

- [ ] **Step 5: Full gate, then commit.**

```bash
npm run typecheck && npm test && npm run lint
git add backend/lib/booking/config.js __tests__/bookingConfig.test.js
git commit -m "feat: booking config endpoint — business-name-only form bootstrap"
```

---

### Task 7: Mint handler + booking dispatcher (the one new Vercel function)

**Files:**
- Create: `backend/lib/booking/mint.js`
- Create: `backend/api/booking/[action].js`
- Test: `__tests__/bookingMint.test.js`, `__tests__/bookingDispatcher.test.js`

**Interfaces:**
- Consumes: handlers from Tasks 5–6; env `SUPABASE_URL`, `SUPABASE_ANON_KEY`.
- Produces: `POST /api/booking/mint` (JWT) → `{ token }`; the deployed routes `/api/booking/config`, `/api/booking/submit`, `/api/booking/mint`. **This file takes the function count 10 → 11 of 12.**

- [ ] **Step 1: Write the failing mint test.** Create `__tests__/bookingMint.test.js`:

```js
// __tests__/bookingMint.test.js
// Mint is JWT-authed and STATELESS — it returns a secure token and writes
// nothing; the device saves it into settings and normal sync publishes it.
// (The device has no secure RNG — the create-link precedent.)

process.env.SUPABASE_URL = 'https://unit.test';
process.env.SUPABASE_ANON_KEY = 'anon-test';

const mint = require('../backend/lib/booking/mint');

function mockRes() {
  const res = { headers: {}, statusCode: 0, body: null };
  res.setHeader = (k, v) => { res.headers[k] = v; };
  res.status = (c) => { res.statusCode = c; return res; };
  res.json = (b) => { res.body = b; return res; };
  res.end = () => res;
  return res;
}

afterEach(() => { delete global.fetch; });

describe('booking mint', () => {
  it('401s without a bearer token', async () => {
    const res = mockRes();
    await mint({ method: 'POST', headers: {} }, res);
    expect(res.statusCode).toBe(401);
  });

  it('401s an invalid session', async () => {
    global.fetch = jest.fn().mockResolvedValue({ ok: false });
    const res = mockRes();
    await mint({ method: 'POST', headers: { authorization: 'Bearer bad' } }, res);
    expect(res.statusCode).toBe(401);
  });

  it('returns a fresh 48-hex token for a valid session and performs no writes', async () => {
    global.fetch = jest.fn().mockResolvedValue({ ok: true, json: async () => ({ id: 'u1' }) });
    const res = mockRes();
    await mint({ method: 'POST', headers: { authorization: 'Bearer good' } }, res);
    expect(res.statusCode).toBe(200);
    expect(res.body.token).toMatch(/^[0-9a-f]{48}$/);
    // Only the auth verification call — stateless by contract.
    expect(global.fetch).toHaveBeenCalledTimes(1);
    expect(global.fetch.mock.calls[0][0]).toBe('https://unit.test/auth/v1/user');
  });

  it('405s non-POST', async () => {
    const res = mockRes();
    await mint({ method: 'GET', headers: {} }, res);
    expect(res.statusCode).toBe(405);
  });
});
```

- [ ] **Step 2: Run it to verify it fails.** Run: `npx jest __tests__/bookingMint.test.js`
Expected: FAIL — module not found.

- [ ] **Step 3: Implement mint.** Create `backend/lib/booking/mint.js`:

```js
// POST /api/booking/mint
// Server-side RNG for the booking token (the device has no secure RNG — the
// create-link precedent). STATELESS on purpose: the device writes the token
// into its settings blob and normal sync publishes it, so the server never
// races a device settings save (spec §4). JWT-authed + per-user rate limit.

const crypto = require('crypto');
const { createRateLimiter } = require('../guards');

const allow = createRateLimiter({ limit: 10 });

module.exports = async function mint(req, res) {
  // Native fetch from the app — CORS is inert here; static real host, like
  // create-link.
  res.setHeader('Access-Control-Allow-Origin', 'https://gettradereadyapp.com');
  res.setHeader('Access-Control-Allow-Methods', 'POST, OPTIONS');
  res.setHeader('Access-Control-Allow-Headers', 'Content-Type, Authorization');
  if (req.method === 'OPTIONS') return res.status(200).end();
  if (req.method !== 'POST') return res.status(405).json({ error: 'Method not allowed' });

  const SUPABASE_URL = process.env.SUPABASE_URL;
  const SUPABASE_ANON_KEY = process.env.SUPABASE_ANON_KEY;
  if (!SUPABASE_URL || !SUPABASE_ANON_KEY) return res.status(500).json({ error: 'Server misconfiguration.' });

  const auth = req.headers['authorization'];
  if (!auth || !auth.startsWith('Bearer ')) return res.status(401).json({ error: 'Unauthorized' });
  const userRes = await fetch(`${SUPABASE_URL}/auth/v1/user`, {
    headers: { Authorization: auth, apikey: SUPABASE_ANON_KEY },
  });
  if (!userRes.ok) return res.status(401).json({ error: 'Invalid or expired session.' });
  const userId = (await userRes.json())?.id;
  if (!userId) return res.status(401).json({ error: 'Unauthorized' });

  if (!allow(userId)) return res.status(429).json({ error: 'Too many requests. Please wait a moment.' });

  return res.status(200).json({ token: crypto.randomBytes(24).toString('hex') });
};
```

- [ ] **Step 4: Run the mint test to verify it passes.** Run: `npx jest __tests__/bookingMint.test.js`
Expected: PASS (4 tests).

- [ ] **Step 5: Write the failing dispatcher test.** Create `__tests__/bookingDispatcher.test.js`:

```js
// __tests__/bookingDispatcher.test.js
// One serverless function for all booking routes (12-function-cap
// discipline). hasOwnProperty guard pins against prototype-name actions —
// the same hardening as api/estimate/[action].js.

jest.mock('../backend/lib/booking/mint', () => jest.fn((req, res) => res.status(200).json({ route: 'mint' })));
jest.mock('../backend/lib/booking/config', () => jest.fn((req, res) => res.status(200).json({ route: 'config' })));
jest.mock('../backend/lib/booking/submit', () => jest.fn((req, res) => res.status(200).json({ route: 'submit' })));

const handler = require('../backend/api/booking/[action]');

function mockRes() {
  const res = { statusCode: 0, body: null };
  res.status = (c) => { res.statusCode = c; return res; };
  res.json = (b) => { res.body = b; return res; };
  return res;
}

describe('booking dispatcher', () => {
  it.each(['mint', 'config', 'submit'])('routes %s to its handler', async (action) => {
    const res = mockRes();
    await handler({ query: { action } }, res);
    expect(res.body).toEqual({ route: action });
  });

  it('404s unknown actions', async () => {
    const res = mockRes();
    await handler({ query: { action: 'nope' } }, res);
    expect(res.statusCode).toBe(404);
  });

  it('404s prototype-inherited action names', async () => {
    const res = mockRes();
    await handler({ query: { action: 'constructor' } }, res);
    expect(res.statusCode).toBe(404);
  });
});
```

- [ ] **Step 6: Run it to verify it fails.** Run: `npx jest "__tests__/bookingDispatcher.test.js"`
Expected: FAIL — module not found.

- [ ] **Step 7: Implement the dispatcher.** Create `backend/api/booking/[action].js`:

```js
/**
 * One serverless function serving all booking-link routes — the 11th of the
 * Hobby plan's 12 (see api/estimate/[action].js for the cap story; count
 * before adding any api/ file). Handlers live in lib/booking/ and each owns
 * its CORS, method check, auth and rate limiting.
 *
 * Routes: /api/booking/mint (JWT), /api/booking/config (public, token-gated),
 * /api/booking/submit (public, token-gated).
 */
const mint = require('../../lib/booking/mint');
const config = require('../../lib/booking/config');
const submit = require('../../lib/booking/submit');

const ROUTES = {
  'mint': mint,
  'config': config,
  'submit': submit,
};

module.exports = async function handler(req, res) {
  const action = req.query.action;
  // Own keys only — inherited names like ?action=constructor would otherwise
  // resolve via Object.prototype and slip past the not-found check.
  const route = Object.prototype.hasOwnProperty.call(ROUTES, action) ? ROUTES[action] : null;
  if (!route) return res.status(404).json({ error: 'Not found' });
  return route(req, res);
};
```

- [ ] **Step 8: Run the test to verify it passes.** Run: `npx jest "__tests__/bookingDispatcher.test.js"`
Expected: PASS (5 tests). Also verify the function count is 11: `find backend/api -name "*.js" | wc -l` → `11`.

- [ ] **Step 9: Full gate, then commit.**

```bash
npm run typecheck && npm test && npm run lint
git add backend/lib/booking/mint.js "backend/api/booking/[action].js" __tests__/bookingMint.test.js __tests__/bookingDispatcher.test.js
git commit -m "feat: booking dispatcher + stateless JWT mint (Vercel function 11 of 12)"
```

---

### Task 8: Client mint helper — utils/bookingLink.ts

**Files:**
- Create: `utils/bookingLink.ts`
- Test: `__tests__/bookingLink.test.ts`

**Interfaces:**
- Consumes: `supabase.auth.getSession()` from `utils/supabase`; `Constants.expoConfig.extra.backendUrl` (same access pattern as `utils/estimateApprovalLink.ts:22`).
- Produces: `BOOKING_PUBLIC_BASE` (`'https://gettradereadyapp.com/book.html'`); `buildBookingUrl(token): string`; `mintBookingToken(): Promise<MintResult>` where `MintResult = { ok: true; token: string } | { ok: false; reason: "no-backend" | "signed-out" | "server" | "network"; message: string }`. The Settings UI (Task 10) consumes exactly these.

- [ ] **Step 1: Write the failing test.** Create `__tests__/bookingLink.test.ts`:

```ts
// __tests__/bookingLink.test.ts
// The app-side mint wrapper mirrors createApprovalLink's discriminated-result
// shape so the Settings screen decides how to surface each failure.

import { buildBookingUrl, mintBookingToken } from '../utils/bookingLink';
import { supabase } from '../utils/supabase';

jest.mock('../utils/supabase', () => ({
  supabase: { auth: { getSession: jest.fn() } },
}));
jest.mock('expo-constants', () => ({
  expoConfig: { extra: { backendUrl: 'https://backend.unit.test', eas: { projectId: 'proj' } } },
}));

const getSession = supabase.auth.getSession as jest.Mock;

afterEach(() => {
  jest.clearAllMocks();
  (global as { fetch?: unknown }).fetch = undefined;
});

describe('buildBookingUrl', () => {
  it('appends the token as ?b=', () => {
    expect(buildBookingUrl('abc123')).toBe('https://gettradereadyapp.com/book.html?b=abc123');
  });
});

describe('mintBookingToken', () => {
  it('returns signed-out without a session', async () => {
    getSession.mockResolvedValue({ data: { session: null } });
    const out = await mintBookingToken();
    expect(out).toMatchObject({ ok: false, reason: 'signed-out' });
  });

  it('POSTs to /api/booking/mint with the JWT and returns the token', async () => {
    getSession.mockResolvedValue({ data: { session: { access_token: 'jwt1', user: { id: 'u1' } } } });
    global.fetch = jest.fn().mockResolvedValue({ ok: true, json: async () => ({ token: 'a'.repeat(48) }) }) as never;
    const out = await mintBookingToken();
    expect(out).toEqual({ ok: true, token: 'a'.repeat(48) });
    const [url, opts] = (global.fetch as jest.Mock).mock.calls[0];
    expect(url).toBe('https://backend.unit.test/api/booking/mint');
    expect((opts.headers as Record<string, string>).Authorization).toBe('Bearer jwt1');
  });

  it('maps a server error body to reason "server"', async () => {
    getSession.mockResolvedValue({ data: { session: { access_token: 'jwt1', user: { id: 'u1' } } } });
    global.fetch = jest.fn().mockResolvedValue({ ok: false, json: async () => ({ error: 'nope' }) }) as never;
    const out = await mintBookingToken();
    expect(out).toMatchObject({ ok: false, reason: 'server', message: 'nope' });
  });

  it('maps a thrown fetch to reason "network"', async () => {
    getSession.mockResolvedValue({ data: { session: { access_token: 'jwt1', user: { id: 'u1' } } } });
    global.fetch = jest.fn().mockRejectedValue(new Error('offline')) as never;
    const out = await mintBookingToken();
    expect(out).toMatchObject({ ok: false, reason: 'network' });
  });
});
```

- [ ] **Step 2: Run it to verify it fails.** Run: `npx jest __tests__/bookingLink.test.ts`
Expected: FAIL — module not found.

- [ ] **Step 3: Implement.** Create `utils/bookingLink.ts`:

```ts
// utils/bookingLink.ts
// App-side plumbing for the public booking link (2026-08-04 spec §4, §8).
// The token itself is minted SERVER-side (the device has no secure RNG) and
// stored in the settings blob by the caller; this module only talks to the
// mint endpoint and builds the shareable URL. Discriminated result instead of
// Alerts, mirroring utils/estimateApprovalLink.ts, so the Settings screen
// owns presentation.

import Constants from "expo-constants";
import { supabase } from "./supabase";

const BACKEND_URL = (Constants.expoConfig?.extra as { backendUrl?: string } | undefined)?.backendUrl;

export const BOOKING_PUBLIC_BASE = "https://gettradereadyapp.com/book.html";

export type MintResult =
  | { ok: true; token: string }
  | { ok: false; reason: "no-backend" | "signed-out" | "server" | "network"; message: string };

export function buildBookingUrl(token: string): string {
  return `${BOOKING_PUBLIC_BASE}?b=${encodeURIComponent(token)}`;
}

export async function mintBookingToken(): Promise<MintResult> {
  if (!BACKEND_URL) {
    return { ok: false, reason: "no-backend", message: "Booking links need a network connection." };
  }
  try {
    const { data: sess } = await supabase.auth.getSession();
    const jwt = sess.session?.access_token;
    if (!jwt) {
      return { ok: false, reason: "signed-out", message: "Please sign in to create a booking link." };
    }
    const res = await fetch(`${BACKEND_URL}/api/booking/mint`, {
      method: "POST",
      headers: { "Content-Type": "application/json", Authorization: `Bearer ${jwt}` },
    });
    const out = await res.json();
    if (!res.ok) {
      return { ok: false, reason: "server", message: out.error || "Please try again." };
    }
    return { ok: true, token: out.token as string };
  } catch {
    return { ok: false, reason: "network", message: "Please check your connection and try again." };
  }
}
```

- [ ] **Step 4: Run the test to verify it passes.** Run: `npx jest __tests__/bookingLink.test.ts`
Expected: PASS (5 tests).

- [ ] **Step 5: Full gate, then commit.**

```bash
npm run typecheck && npm test && npm run lint
git add utils/bookingLink.ts __tests__/bookingLink.test.ts
git commit -m "feat: client mint wrapper + booking URL builder"
```

---

### Task 9: Push registration + notification tap routing

**Files:**
- Create: `utils/pushToken.ts`
- Modify: `App.tsx` (sign-in chain + the notification-response listener at ~line 389)
- Test: `__tests__/pushToken.test.ts`

**Interfaces:**
- Consumes: `expo-notifications` (`getPermissionsAsync`, `getExpoPushTokenAsync`) — already in the binary; `Constants.expoConfig.extra.eas.projectId`; `loadSettings`/`saveSettings` from `utils/storage`.
- Produces: `registerPushToken(): Promise<void>` — silent no-op on any failure; `Settings.pushToken` maintained only-on-change. Tap routing for `data.type === "booking_request"`.

- [ ] **Step 1: Write the failing test.** Create `__tests__/pushToken.test.ts`:

```ts
// __tests__/pushToken.test.ts
// Push registration must be harmless everywhere it can't work (Expo Go, no
// entitlement, no permission, offline): silent no-op, never a throw, never a
// prompt (the local-reminders flow owns the permission ask). Saves only on
// change — every settings save re-enqueues the whole blob.

import { registerPushToken } from '../utils/pushToken';
import * as Notifications from 'expo-notifications';
import { loadSettings, saveSettings } from '../utils/storage';

jest.mock('expo-notifications', () => ({
  getPermissionsAsync: jest.fn(),
  getExpoPushTokenAsync: jest.fn(),
}));
jest.mock('expo-constants', () => ({
  expoConfig: { extra: { backendUrl: 'https://backend.unit.test', eas: { projectId: 'proj-123' } } },
}));
jest.mock('../utils/storage', () => ({
  loadSettings: jest.fn(),
  saveSettings: jest.fn(),
}));

const perms = Notifications.getPermissionsAsync as jest.Mock;
const getToken = Notifications.getExpoPushTokenAsync as jest.Mock;
const load = loadSettings as jest.Mock;
const save = saveSettings as jest.Mock;

beforeEach(() => {
  jest.clearAllMocks();
  perms.mockResolvedValue({ granted: true });
  getToken.mockResolvedValue({ data: 'ExponentPushToken[abc]' });
  load.mockResolvedValue({ businessName: 'X' });
  save.mockResolvedValue(undefined);
});

describe('registerPushToken', () => {
  it('saves a new token into settings.pushToken', async () => {
    await registerPushToken();
    expect(getToken).toHaveBeenCalledWith({ projectId: 'proj-123' });
    const saved = save.mock.calls[0][0];
    expect(saved.pushToken.token).toBe('ExponentPushToken[abc]');
    expect(['ios', 'android']).toContain(saved.pushToken.platform);
    expect(typeof saved.pushToken.updatedAt).toBe('string');
  });

  it('does nothing without permission — and never prompts', async () => {
    perms.mockResolvedValue({ granted: false });
    await registerPushToken();
    expect(getToken).not.toHaveBeenCalled();
    expect(save).not.toHaveBeenCalled();
  });

  it('does not save when the stored token is already current', async () => {
    load.mockResolvedValue({ pushToken: { token: 'ExponentPushToken[abc]', platform: 'ios', updatedAt: 't' } });
    await registerPushToken();
    expect(save).not.toHaveBeenCalled();
  });

  it('silently no-ops when getExpoPushTokenAsync throws (Expo Go / no entitlement)', async () => {
    getToken.mockRejectedValue(new Error('no push capability'));
    await expect(registerPushToken()).resolves.toBeUndefined();
    expect(save).not.toHaveBeenCalled();
  });
});
```

- [ ] **Step 2: Run it to verify it fails.** Run: `npx jest __tests__/pushToken.test.ts`
Expected: FAIL — module not found.

- [ ] **Step 3: Implement.** Create `utils/pushToken.ts`:

```ts
// utils/pushToken.ts
// Registers the device's Expo push token into the synced settings blob so
// the backend can send owner alerts (first use: booking requests, spec §7).
// Graceful-degradation contract: in Expo Go, without the iOS push
// entitlement, without permission, or offline, this is a SILENT no-op — the
// pipeline lights up at the next EAS build without any code change. Never
// prompts (the invoice-reminder flow owns the permission ask), and saves
// only on change (a settings save re-enqueues the whole blob).

import { Platform } from "react-native";
import * as Notifications from "expo-notifications";
import Constants from "expo-constants";
import { loadSettings, saveSettings } from "./storage";

export async function registerPushToken(): Promise<void> {
  try {
    const perms = await Notifications.getPermissionsAsync();
    if (!perms.granted) return;

    const projectId = (Constants.expoConfig?.extra as { eas?: { projectId?: string } } | undefined)?.eas?.projectId;
    const token = (await Notifications.getExpoPushTokenAsync(projectId ? { projectId } : undefined)).data;
    if (!token) return;

    const settings = await loadSettings();
    if (settings.pushToken?.token === token) return;
    await saveSettings({
      ...settings,
      pushToken: {
        token,
        platform: Platform.OS === "android" ? "android" : "ios",
        updatedAt: new Date().toISOString(),
      },
    });
  } catch {
    // Expected wherever push isn't available; alerts fall back to email.
  }
}
```

- [ ] **Step 4: Run the test to verify it passes.** Run: `npx jest __tests__/pushToken.test.ts`
Expected: PASS (4 tests).

- [ ] **Step 5: Wire into App.tsx.** (a) Import: `import { registerPushToken } from "./utils/pushToken";` (b) Extend the same sign-in chain from Task 2 with a final link:

```ts
      .then(() => registerPushToken())
      .catch(() => {});
```

(b2) Spec §7 also requires registration on app foreground: in `context/AuthContext.tsx`, add `registerPushToken()` right after the `applyBookingRequests()` call added in Task 2 (same fire-and-forget error style) — a token invalidated while the app was backgrounded re-registers on the next foreground.

(c) In the notification-response listener (~line 389, after the `recurring_invoice` block), add — note the existing blocks' `track(...)` calls use the analytics helper already imported in App.tsx; match them:

```ts
      if (data?.type === "booking_request" && navigationRef.isReady()) {
        track("booking_request_opened", {});
        navigationRef.navigate("Main", {
          screen: "Jobs",
          params: { screen: "JobList" },
        });
      }
```

- [ ] **Step 6: Full gate, then commit.**

```bash
npm run typecheck && npm test && npm run lint
git add utils/pushToken.ts App.tsx __tests__/pushToken.test.ts
git commit -m "feat: push-token registration pipeline + booking notification tap routing"
```

---

### Task 10: Settings UI — Booking link section

**Files:**
- Modify: `screens/SettingsScreen.tsx`
- Test: `__tests__/bookingLinkSettings.test.tsx`

**Interfaces:**
- Consumes: `mintBookingToken`, `buildBookingUrl` (Task 8); `loadSettings`/`saveSettings`; RN `Share.share`; the screen's existing section/card components and `createStyles(colors, shadow)` factory.
- Produces: the owner-facing controls: create link / share / Accepting-requests toggle / new link.

- [ ] **Step 1: Read the screen first.** Open `screens/SettingsScreen.tsx` and locate (a) the Stripe-Connect (payments) section — the precedent for a section whose actions apply IMMEDIATELY rather than through the screen's draft/dirty save path — and (b) how sections/cards/rows are composed and themed. The booking section must follow the immediate-action precedent: it calls `loadSettings`/`saveSettings` directly at action time, keeps its own local state, and must NOT mark the screen dirty (verify against the screen's dirty-tracking mechanism — see `__tests__/settingsDirty.test.js` — and confirm the new section does not trip the `beforeRemove` guard).

- [ ] **Step 2: Write the failing test.** Create `__tests__/bookingLinkSettings.test.tsx`, modeling render/mocking conventions on `__tests__/settingsDirty.test.js` (reuse its mock setup verbatim where applicable — RNTL async `render`, navigation mocks, storage mocks). Cases:

```tsx
// __tests__/bookingLinkSettings.test.tsx
// Settings → Booking link: mint saves {token, enabled:true} through
// saveSettings; the toggle flips enabled in place; "new link" replaces the
// token. Mock '../utils/bookingLink' (mintBookingToken → {ok:true, token:
// 'f'.repeat(48)}) and '../utils/storage' the way settingsDirty.test.js does.
//
// 1. renders "Create my booking link" when settings.bookingLink is absent
// 2. tapping it calls mintBookingToken and saveSettings with
//    bookingLink = { token: 'f'.repeat(48), enabled: true }
// 3. with a bookingLink present, renders the URL text (buildBookingUrl) and
//    the "Accepting requests" toggle ON
// 4. flipping the toggle saves the same token with enabled: false
// 5. mint failure ({ok:false, reason:'network', message:'...'}) shows an
//    Alert (jest.spyOn(Alert, 'alert')) and saves nothing
```

Write the five cases as real RNTL tests following that file's idioms exactly (its `beforeEach` storage-mock reset, its `findByText` async queries). The mocked `loadSettings` must return `defaultSettings()`-shaped data with and without `bookingLink` per case.

- [ ] **Step 3: Run it to verify it fails.** Run: `npx jest __tests__/bookingLinkSettings.test.tsx`
Expected: FAIL — the section doesn't exist yet.

- [ ] **Step 4: Implement the section.** Add a "Booking link" section to `screens/SettingsScreen.tsx` (placed directly after the payments section), following the screen's existing section composition and the `createStyles(colors, shadow)` factory. Handlers:

```tsx
const handleCreateBookingLink = async () => {
  const out = await mintBookingToken();
  if (!out.ok) { Alert.alert("Couldn't create link", out.message); return; }
  const current = await loadSettings();
  await saveSettings({ ...current, bookingLink: { token: out.token, enabled: true } });
  setBookingLink({ token: out.token, enabled: true }); // local section state
};

const handleToggleBooking = async (enabled: boolean) => {
  const current = await loadSettings();
  if (!current.bookingLink) return;
  await saveSettings({ ...current, bookingLink: { ...current.bookingLink, enabled } });
  setBookingLink({ ...current.bookingLink, enabled });
};

const handleShareBookingLink = async (token: string) => {
  await Share.share({ message: buildBookingUrl(token) });
};

const handleNewBookingLink = () => {
  Alert.alert(
    "Get a new link?",
    "Your current booking link will stop working immediately. Anywhere you've shared it will show an invalid-link message.",
    [
      { text: "Cancel", style: "cancel" },
      { text: "Get new link", style: "destructive", onPress: () => { void handleCreateBookingLink(); } },
    ]
  );
};
```

Section content: absent state → one-line explainer ("Share one link; new job requests land in Jobs as leads.") + "Create my booking link" button. Present state → the URL (selectable Text), "Share link" button, "Accepting requests" Switch bound to `enabled`, "Get a new link" row. Copy tone matches the screen's existing sections. Initialize the section's local state from the screen's already-loaded settings.

- [ ] **Step 5: Run the test to verify it passes.** Run: `npx jest __tests__/bookingLinkSettings.test.tsx`
Expected: PASS (5 tests). Also run `npx jest __tests__/settingsDirty.test.js __tests__/settingsValidation.test.js` — both must still pass untouched (the new section must not affect dirty tracking or validation).

- [ ] **Step 6: Full gate, then commit.**

```bash
npm run typecheck && npm test && npm run lint
git add screens/SettingsScreen.tsx __tests__/bookingLinkSettings.test.tsx
git commit -m "feat: Settings booking-link section — create, share, toggle, rotate"
```

---

### Task 11: book.html (tradeready-legal repo — commit, HOLD push)

**Files:**
- Create: `C:\Users\Chadr\OneDrive\Documents\TraderPro App\tradeready-legal\book.html`

**Interfaces:**
- Consumes: `GET /api/booking/config?b=`, `POST /api/booking/submit` at `https://backend-tradeready1.vercel.app/api/booking` (same API base pattern as estimate.html:40).
- Produces: the public form page. **Committed on tradeready-legal `main` but NOT pushed** — publishing is launch-chain step 4, after the backend deploy (CORS ordering).

- [ ] **Step 1: Create the page.** Full content — conventions copied from `estimate.html` (inline styles, `esc()`, `banner()`, no framework):

```html
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>Request a quote — TradeReady</title>
  <style>
    *, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }
    body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
           font-size: 16px; line-height: 1.6; color: #1a1a1a; background: #f9f9f9; padding: 2rem 1rem; }
    .page { max-width: 560px; margin: 0 auto; background: #fff; border-radius: 12px;
            padding: 2rem; box-shadow: 0 1px 4px rgba(0,0,0,.08); }
    .brand { font-size: 1.4rem; font-weight: 800; color: #2563eb; margin-bottom: 1rem; }
    h1 { font-size: 1.25rem; margin-bottom: .25rem; }
    .muted { color: #6b7280; font-size: .9rem; margin-bottom: 1rem; }
    label { font-size: .9rem; font-weight: 600; display: block; margin: 1rem 0 .35rem; }
    input, textarea { width: 100%; padding: .7rem; border: 1px solid #d1d5db; border-radius: 8px; font-size: 1rem; }
    textarea { min-height: 110px; resize: vertical; }
    button { width: 100%; margin-top: 1.5rem; padding: .85rem; border: none; border-radius: 8px;
             font-size: 1rem; font-weight: 600; cursor: pointer; background: #2563eb; color: #fff; }
    button:disabled { opacity: .6; cursor: default; }
    .banner { padding: 1rem; border-radius: 8px; text-align: center; font-weight: 600; }
    .ok { background: #ecfdf5; color: #065f46; }
    .err { background: #fef2f2; color: #991b1b; }
    .field-err { color: #b91c1c; font-size: .9rem; margin-top: .75rem; display: none; }
    /* Honeypot: hidden from humans, present for bots. Not display:none —
       some bots skip invisible fields; off-screen is the sweet spot. */
    .hp { position: absolute; left: -9999px; top: -9999px; }
    .footer { margin-top: 2rem; padding-top: 1rem; border-top: 1px solid #e5e7eb; font-size: .8rem; color: #9ca3af; }
  </style>
</head>
<body>
<div class="page">
  <div class="brand">TradeReady</div>
  <div id="content"><p class="muted">Loading…</p></div>
  <div class="footer">Your details go only to this business so they can follow up on your request.</div>
</div>

<script>
  var API = 'https://backend-tradeready1.vercel.app/api/booking';
  var params = new URLSearchParams(location.search);
  var token = params.get('b');
  var content = document.getElementById('content');

  function esc(s) { var d = document.createElement('div'); d.textContent = s == null ? '' : String(s); return d.innerHTML; }
  function banner(cls, msg) { content.innerHTML = '<div class="banner ' + cls + '">' + esc(msg) + '</div>'; }

  if (!token) { banner('err', 'This link is missing information. Please ask for a new link.'); }
  else { load(); }

  async function load() {
    try {
      var res = await fetch(API + '/config?b=' + encodeURIComponent(token));
      if (!res.ok) { banner('err', 'This link is invalid.'); return; }
      render(await res.json());
    } catch (e) { banner('err', 'Could not load this page. Please check your connection.'); }
  }

  function render(cfg) {
    var name = cfg.businessName || 'this business';
    content.innerHTML =
      '<h1>' + esc(name) + ' — Request a quote</h1>' +
      '<p class="muted">Tell us what you need and how to reach you.</p>' +
      '<form id="f">' +
      '<label for="name">Your name</label><input id="name" maxlength="100" autocomplete="name">' +
      '<label for="phone">Phone</label><input id="phone" maxlength="50" autocomplete="tel" inputmode="tel">' +
      '<label for="email">Email</label><input id="email" maxlength="200" autocomplete="email" inputmode="email">' +
      '<label for="address">Job address (optional)</label><input id="address" maxlength="300" autocomplete="street-address">' +
      '<label for="details">What do you need done?</label><textarea id="details" maxlength="2000"></textarea>' +
      '<label for="timing">Preferred timing (optional)</label><input id="timing" maxlength="200" placeholder="e.g. weekday mornings, ASAP">' +
      '<div class="hp" aria-hidden="true"><label for="website">Website</label><input id="website" tabindex="-1" autocomplete="off"></div>' +
      '<div id="fieldErr" class="field-err"></div>' +
      '<button id="sendBtn" type="submit">Send request</button>' +
      '</form>';
    document.getElementById('f').addEventListener('submit', function (e) { e.preventDefault(); submit(name); });
  }

  function val(id) { return document.getElementById(id).value.trim(); }
  function showErr(msg) {
    var el = document.getElementById('fieldErr');
    el.textContent = msg;
    el.style.display = 'block';
  }

  async function submit(businessName) {
    var payload = {
      b: token,
      name: val('name'), phone: val('phone'), email: val('email'),
      address: val('address'), details: val('details'), preferredTiming: val('timing'),
      website: document.getElementById('website').value,
    };
    if (!payload.name) { showErr('Please tell us your name.'); return; }
    if (!payload.details) { showErr('Please describe what you need done.'); return; }
    if (!payload.phone && !payload.email) { showErr('Please give a phone or email so we can reach you.'); return; }

    var btn = document.getElementById('sendBtn');
    btn.disabled = true; btn.textContent = 'Sending…';
    try {
      var res = await fetch(API + '/submit', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(payload),
      });
      var out = await res.json().catch(function () { return {}; });
      if (!res.ok) {
        btn.disabled = false; btn.textContent = 'Send request';
        showErr(out.error || 'Something went wrong. Please try again.');
        return;
      }
      banner('ok', 'Thanks — ' + businessName + ' got your request and will get back to you.');
    } catch (e) {
      btn.disabled = false; btn.textContent = 'Send request';
      showErr('Could not send. Please check your connection and try again.');
    }
  }
</script>
</body>
</html>
```

- [ ] **Step 2: Offline sanity check.** Open the file directly in a browser (`file://` URL, no params): the page must show "This link is missing information." — proving the script runs and the no-token state renders. (The full flow is only checkable after the backend deploy — launch-chain step 5.)

- [ ] **Step 3: Commit on tradeready-legal main — DO NOT PUSH.**

```bash
cd "C:/Users/Chadr/OneDrive/Documents/TraderPro App/tradeready-legal" && git status --short
git add book.html
git commit -m "Add public request-a-quote page for the booking link"
```

Confirm `git status` showed no unexpected staged files first, and confirm afterward that the commit is local-only (`git log origin/main..main --oneline` lists it). **Pushing this publishes the page — that is launch-chain step 4, owner-gated, and must follow the backend deploy.**

---

### Task 12: Docs, final gate, and branch wrap-up

**Files:**
- Modify: `README.md` (Features list + Known Limitations)
- Modify: `ARCHITECTURE.md` (backend endpoints + data model notes)
- Test: full gate

**Interfaces:**
- Consumes: everything above.
- Produces: docs matching reality (house rule: `tradeready-docs-and-writing`); a merge-ready branch.

- [ ] **Step 1: README.** In the features area, add a "Booking link" bullet: public request-a-quote page; submissions become lead jobs with customer records; email alert; push alert once push credentials are live. In **Known limitations**, add: booking link and push token live in the settings blob — a stale device's settings save can clobber them (same last-write-wins class as other settings fields; re-mint/re-register heals). Match the section's existing voice; describe only what is true at this commit (nothing about the portal).

- [ ] **Step 2: ARCHITECTURE.md.** Add `/api/booking/mint|config|submit` to the backend endpoint inventory (one dispatcher function, 11 of 12), and `bookingRequests` to the synced-collections list with one line on the device-converts flow (`utils/storage/bookingConversion.ts`).

- [ ] **Step 3: Full gate.** Run: `npm run typecheck && npm test && npm run lint`
Expected: 0 errors / all suites pass (baseline 2000 + the ~44 tests added by Tasks 1–10) / 0 warnings.

- [ ] **Step 4: Commit.**

```bash
git add README.md ARCHITECTURE.md
git commit -m "docs: booking link + push pipeline in README and ARCHITECTURE"
```

- [ ] **Step 5: Report, don't merge.** The branch stays unmerged; merging, the Supabase migration, the Vercel deploy, the legal-repo push, and the owner smoke are the launch chain (spec §13) and belong to the session lead + owner, not this plan.

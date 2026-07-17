# Estimate-Approval Loop Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a customer view an estimate on a hosted link and tap Approve/Decline; the decision flows back through the existing sync layer, advances the job in the status pipeline, and stamps a server-authoritative consent timestamp with a typed-name signature.

**Architecture:** Server-authoritative writes into the existing Supabase `jobs` JSON blob (service-role, token-gated Vercel endpoints — the exact pattern as `backend/api/stripe/webhook.js`), reconciled to the device by the existing `pullRemote` poll (app-foreground/save/sign-in). The device — never the server — performs the pipeline status transition, via an idempotent flag-free reconciler modeled on `migrateCustomerIdentity`. A JWT-authed `create-link` endpoint mints the token with Node `crypto` (no app dependency added).

**Tech Stack:** Expo 54 / React Native 0.81 / React 19 / TypeScript (app); Vercel serverless (Node, CommonJS `.js`) + Supabase REST (backend); static HTML/CSS/vanilla JS (GitHub Pages viewer). Jest for tests.

## Global Constraints

- **Two repos.** App + backend live in `tradeready/` (git repo). The public viewer lives in `tradeready-legal/` (separate git repo; GitHub Pages, `.nojekyll`, no build step). Commit each in its own repo.
- **Phase-gate everything.** Each phase ends at a **green gate** and **STOPS for owner go-ahead** before the next. Gate = `npm run typecheck` && `npm test` && `npm run lint` run from `tradeready\` (PowerShell). Never commit on a red gate (tsc errors, failing tests, or any lint warning — lint runs `--max-warnings=0`).
- **No new dependencies, no SDK bump.** Nothing in this plan adds an npm package or changes Expo SDK. If a task seems to need one, STOP and raise it.
- **Commit only at green gates, and end every commit message with:** `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`. Conventional prefixes (`feat:`, `test:`, `docs:`, `refactor:`).
- **Status transitions derive from `JOB_STATUSES.next`** (architecture §5). The one sanctioned off-`.next` assignment (`declined`) is confined to `utils/jobStatus.ts`.
- **Server writes are additive and confined to `job.approval.*`.** The backend never writes `job.status`. `consentAt` is always stamped server-side (authoritative clock).
- **Test files:** `__tests__/<name>.test.js`, CommonJS-style imports like the sibling `__tests__/jobStatus.test.js` / `__tests__/customerIdentity.test.js`.
- **Public origin:** `https://czilla57.github.io/tradeready-legal/`. **Backend origin:** `https://backend-tradeready1.vercel.app` (app reads it from `Constants.expoConfig?.extra?.backendUrl`).

---

## File Structure

**App (`tradeready/`):**
- `types/models.ts` — add `"declined"` to `JobStatus`; add `EstimateApproval`; add `Job.approval?`.
- `utils/theme.ts` — add `statusDeclined` to `lightColors` + `darkColors`.
- `utils/pricingEngine.ts` — add `declined` to `JOB_STATUSES`.
- `utils/jobStatusDisplay.ts` — add `declined` to `JOB_STATUS_DISPLAY`.
- `utils/conversionFunnel.ts` — add `declined` to `STATUS_ORDINAL`.
- `components/money/ConversionFunnelCard.tsx` — add `declined` to `STATUS_COLOR_KEY`.
- `utils/jobStatus.ts` — add `applyEstimateDecision()`.
- `utils/estimateSnapshot.ts` *(new)* — `buildEstimateSnapshot()` (pure).
- `utils/storage/estimateApprovals.ts` *(new)* — `applyDecisionsToJobs()` (pure) + `applyEstimateDecisions()` (async).
- `utils/storage/index.ts` — export the reconciler.
- `App.tsx` — wire reconciler into the session `useEffect`.
- `context/AuthContext.tsx` — wire reconciler after foreground sync.
- `utils/invoiceHelpers.ts` — extend `generateEstimateMessage`/`buildGenericEstimateMessage` with `approvalLink?`.
- `screens/SendEstimateScreen.tsx` — "Send for approval" flow.
- `screens/JobDetailScreen.tsx` — approval-state surface + declined re-send reset.

**Backend (`tradeready/backend/`):**
- `lib/estimateStore.js` *(new)* — Supabase job read/merge/upsert + `constantTimeEqual`.
- `api/estimate/create-link.js` *(new)* — POST, JWT-authed, mints token, writes approval scaffold.
- `api/estimate/view.js` *(new)* — GET, token-gated, sanitized read.
- `api/estimate/respond.js` *(new)* — POST, token-gated, decision + consent write.

**Viewer (`tradeready-legal/`):**
- `estimate.html` *(new)* — static approval page.

**Tests (`tradeready/__tests__/`):**
- `jobStatus.test.js` — extend for `applyEstimateDecision`.
- `estimateApprovals.test.js` *(new)*.
- `estimateSnapshot.test.js` *(new)*.
- `estimateRespond.test.js` *(new)* — pure decision state-machine.

---

# PHASE 1 — Data model + `declined` pipeline

*Owner-gated pipeline change (architecture §4/§5). STOP at the end of Phase 1.*

### Task 1: Add the `declined` status + `EstimateApproval` type

**Files:**
- Modify: `types/models.ts:18-26` (JobStatus union), `types/models.ts:112-116` (Job interface)

**Interfaces:**
- Produces: `JobStatus` now includes `"declined"`; `EstimateApproval` interface; `Job.approval?: EstimateApproval`.

- [ ] **Step 1: Add `"declined"` to the `JobStatus` union**

In `types/models.ts`, change the union (currently ends `| "paid";`) to:

```ts
export type JobStatus =
  | "lead"
  | "estimate_sent"
  | "approved"
  | "scheduled"
  | "in_progress"
  | "complete"
  | "invoiced"
  | "paid"
  | "declined";
```

- [ ] **Step 2: Add the `EstimateApproval` interface + `Job.approval` field**

Immediately above `export interface Job {` in `types/models.ts`, add:

```ts
/**
 * Estimate-approval record. Absent until the estimate is "sent for approval".
 * `snapshot` freezes the estimate as sent so the customer approves exactly what
 * they saw and the backend never re-runs pricing math. `decision`/`consentAt`/
 * signature fields are written SERVER-SIDE (service role) when the customer acts;
 * the device only reads them and performs the status transition locally.
 */
export interface EstimateApprovalSnapshot {
  businessName: string;
  customerName: string;
  jobTitle: string;
  lineItems: { label: string; amount: number }[];
  total: number;
  currency: string;
}

export interface EstimateApproval {
  token: string;
  sentAt: DateString;
  snapshot: EstimateApprovalSnapshot;
  decision?: "approved" | "declined";
  consentAt?: DateString;
  signerName?: string;
  declineReason?: string;
  ip?: string;
  userAgent?: string;
}
```

Then add this line inside `interface Job` after `occurrenceNumber?: number;`:

```ts
  approval?: EstimateApproval;
```

- [ ] **Step 3: Typecheck (expect exhaustiveness failures — that is the signal)**

Run: `npm run typecheck`
Expected: FAIL. tsc reports missing `declined` in four `Record<JobStatus, …>` objects: `utils/pricingEngine.ts` (`JOB_STATUSES`), `utils/jobStatusDisplay.ts` (`JOB_STATUS_DISPLAY`), `utils/conversionFunnel.ts` (`STATUS_ORDINAL`), `components/money/ConversionFunnelCard.tsx` (`STATUS_COLOR_KEY`). Tasks 2–3 resolve all four. (No commit yet — the tree does not typecheck.)

### Task 2: Add the `statusDeclined` theme color + pipeline entry

**Files:**
- Modify: `utils/theme.ts` (lightColors ~line 37, darkColors ~line 76), `utils/pricingEngine.ts:313-320` (JOB_STATUSES)

**Interfaces:**
- Consumes: `JobStatus` includes `"declined"` (Task 1).
- Produces: `ColorScheme` gains `statusDeclined`; `JOB_STATUSES.declined = { label: "Declined", color: "danger", next: null }`.

- [ ] **Step 1: Add `statusDeclined` to both palettes**

In `utils/theme.ts`, in `lightColors` immediately after `statusPaid: "#34C759",` add:

```ts
  statusDeclined:   "#EF4444",   // red — declined estimate
```

In `darkColors` immediately after `statusPaid: "#30d158",` add:

```ts
  statusDeclined:   "#f87171",   // red — declined estimate (dark)
```

(`ColorScheme = typeof lightColors`, so the type updates automatically.)

- [ ] **Step 2: Add `declined` to `JOB_STATUSES`**

In `utils/pricingEngine.ts`, inside the `JOB_STATUSES` object after the `paid:` line, add:

```ts
  // Branch off estimate_sent — reached only via a customer decline, never via the
  // linear `.next` walk. `next: null` so JobDetail's "advance" action treats it as
  // an endpoint (re-sending a revised estimate is a separate explicit reset).
  declined: { label: "Declined", color: "danger", next: null },
```

(`color: "danger"` is already a valid `BadgeColor` — no change needed in `components/UI.tsx`.)

- [ ] **Step 3: Typecheck (two consumers remain)**

Run: `npm run typecheck`
Expected: FAIL, now only in `utils/conversionFunnel.ts` and `components/money/ConversionFunnelCard.tsx`. Task 3 resolves both.

### Task 3: Resolve remaining `JobStatus` consumers

**Files:**
- Modify: `utils/jobStatusDisplay.ts:23-32`, `utils/conversionFunnel.ts:13-22`, `components/money/ConversionFunnelCard.tsx:8-17`

**Interfaces:**
- Produces: all four `Record<JobStatus,…>` consumers exhaustive; funnel treats a declined job as "estimate sent, not won".

- [ ] **Step 1: `JOB_STATUS_DISPLAY` (Today-tab badge palette)**

In `utils/jobStatusDisplay.ts`, add after the `paid:` line inside `JOB_STATUS_DISPLAY`:

```ts
  declined:      { label: "Declined",      color: colors.statusDeclined },
```

- [ ] **Step 2: `STATUS_ORDINAL` (funnel)**

In `utils/conversionFunnel.ts`, add after the `paid: 7,` line inside `STATUS_ORDINAL`:

```ts
  // A declined job DID reach "estimate sent" but not "approved", so it counts in
  // the estimate_sent denominator and lowers win rate — the honest analytic for a
  // lost deal. (Deliberate, reversible: set to -1 to exclude it entirely.)
  declined: 1,
```

`FUNNEL_STAGES` is a plain array and stays unchanged — `declined` is not a forward stage, so it never renders as its own bar.

- [ ] **Step 3: `STATUS_COLOR_KEY` (funnel card)**

In `components/money/ConversionFunnelCard.tsx`, add after the `paid:` line inside `STATUS_COLOR_KEY`:

```ts
  declined: 'statusDeclined',
```

(Never read for rendering — `declined` is not a funnel stage — but required for exhaustiveness.)

- [ ] **Step 4: Typecheck passes**

Run: `npm run typecheck`
Expected: PASS (0 errors).

- [ ] **Step 5: Run the existing suites that touch these files**

Run: `npx jest jobStatusDisplay conversionFunnel revenueForecast pricingEngine`
Expected: PASS (existing tests unaffected — no declined jobs in fixtures).

### Task 4: `applyEstimateDecision()` transition logic

**Files:**
- Modify: `utils/jobStatus.ts` (add function beside `advanceStatusForSchedule`)
- Test: `__tests__/jobStatus.test.js`

**Interfaces:**
- Produces: `applyEstimateDecision(status: JobStatus, decision: "approved" | "declined"): JobStatus`.

- [ ] **Step 1: Write the failing tests**

Append to `__tests__/jobStatus.test.js`:

```js
const { applyEstimateDecision } = require('../utils/jobStatus');

describe('applyEstimateDecision', () => {
  it('advances estimate_sent -> approved (via the pipeline)', () => {
    expect(applyEstimateDecision('estimate_sent', 'approved')).toBe('approved');
  });
  it('advances lead -> approved defensively', () => {
    expect(applyEstimateDecision('lead', 'approved')).toBe('approved');
  });
  it('sets estimate_sent -> declined', () => {
    expect(applyEstimateDecision('estimate_sent', 'declined')).toBe('declined');
  });
  it('never regresses a job already past estimate_sent', () => {
    for (const s of ['approved', 'scheduled', 'in_progress', 'complete', 'invoiced', 'paid']) {
      expect(applyEstimateDecision(s, 'declined')).toBe(s);
      expect(applyEstimateDecision(s, 'approved')).toBe(s);
    }
  });
});
```

- [ ] **Step 2: Run to verify it fails**

Run: `npx jest jobStatus`
Expected: FAIL — `applyEstimateDecision is not a function`.

- [ ] **Step 3: Implement**

Append to `utils/jobStatus.ts`:

```ts
/**
 * Apply a customer's estimate decision to a job's status. Only acts before the
 * tradesperson has taken the job forward — never regresses scheduled…paid
 * (mirrors advanceStatusForSchedule's no-regress guarantee). "approved" derives
 * from the pipeline; "declined" is the one sanctioned off-`.next` branch, living
 * here so no screen ever hardcodes it.
 */
export function applyEstimateDecision(
  status: JobStatus,
  decision: "approved" | "declined",
): JobStatus {
  if (status !== "lead" && status !== "estimate_sent") return status;
  if (decision === "approved") return JOB_STATUSES.estimate_sent.next ?? status;
  return "declined";
}
```

- [ ] **Step 4: Run to verify pass**

Run: `npx jest jobStatus`
Expected: PASS.

- [ ] **Step 5: Full gate**

Run: `npm run typecheck` then `npm test` then `npm run lint`
Expected: all green.

- [ ] **Step 6: Commit (after owner go-ahead)**

```bash
git add types/models.ts utils/theme.ts utils/pricingEngine.ts utils/jobStatusDisplay.ts \
  utils/conversionFunnel.ts components/money/ConversionFunnelCard.tsx utils/jobStatus.ts \
  __tests__/jobStatus.test.js
git commit -m "feat: add declined job status and estimate-decision transition

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

**⛔ STOP — Phase 1 complete. Await owner go-ahead before Phase 2.**

---

# PHASE 2 — Device reconciler

*Pure-local; no network. STOP at the end of Phase 2.*

### Task 5: `applyDecisionsToJobs()` pure core

**Files:**
- Create: `utils/storage/estimateApprovals.ts`
- Test: `__tests__/estimateApprovals.test.js`

**Interfaces:**
- Consumes: `applyEstimateDecision` (Task 4); `Job` with `approval?` (Task 1).
- Produces: `applyDecisionsToJobs(jobs: Job[]): { jobs: Job[]; changed: boolean }`.

- [ ] **Step 1: Write the failing tests**

Create `__tests__/estimateApprovals.test.js`:

```js
const { applyDecisionsToJobs } = require('../utils/storage/estimateApprovals');

function job(over) {
  return { id: 'j1', status: 'estimate_sent', ...over };
}

describe('applyDecisionsToJobs', () => {
  it('advances an approved decision through the pipeline', () => {
    const { jobs, changed } = applyDecisionsToJobs([
      job({ approval: { token: 't', sentAt: '2026-07-17', snapshot: {}, decision: 'approved' } }),
    ]);
    expect(changed).toBe(true);
    expect(jobs[0].status).toBe('approved');
  });

  it('sets a declined decision', () => {
    const { jobs, changed } = applyDecisionsToJobs([
      job({ approval: { token: 't', sentAt: '2026-07-17', snapshot: {}, decision: 'declined' } }),
    ]);
    expect(changed).toBe(true);
    expect(jobs[0].status).toBe('declined');
  });

  it('is idempotent — a second pass reports no change', () => {
    const first = applyDecisionsToJobs([
      job({ approval: { token: 't', sentAt: '2026-07-17', snapshot: {}, decision: 'approved' } }),
    ]);
    const second = applyDecisionsToJobs(first.jobs);
    expect(second.changed).toBe(false);
    expect(second.jobs[0].status).toBe('approved');
  });

  it('ignores jobs without an approval decision', () => {
    const { changed } = applyDecisionsToJobs([
      job({}),
      job({ id: 'j2', approval: { token: 't', sentAt: 'x', snapshot: {} } }),
    ]);
    expect(changed).toBe(false);
  });

  it('never regresses a job already advanced', () => {
    const { changed } = applyDecisionsToJobs([
      job({ status: 'scheduled', approval: { token: 't', sentAt: 'x', snapshot: {}, decision: 'approved' } }),
    ]);
    expect(changed).toBe(false);
  });
});
```

- [ ] **Step 2: Run to verify it fails**

Run: `npx jest estimateApprovals`
Expected: FAIL — cannot find module `../utils/storage/estimateApprovals`.

- [ ] **Step 3: Implement the pure core + async wrapper**

Create `utils/storage/estimateApprovals.ts`:

```ts
// Reconciles server-written estimate decisions into the local job pipeline.
// Idempotent and flag-free (modeled on migrateCustomerIdentity): the server
// writes only job.approval.decision; the DEVICE performs the status transition
// through the pipeline. Safe to run on every sign-in and every foreground sync —
// it writes only when something actually changed (a save re-enqueues the whole
// collection, so a no-op run must not write).

import { loadJobs, saveJobs } from "./collections";
import { applyEstimateDecision } from "../jobStatus";
import type { Job } from "../../types/models";

export function applyDecisionsToJobs(jobs: Job[]): { jobs: Job[]; changed: boolean } {
  let changed = false;
  const next = jobs.map((j) => {
    const decision = j.approval?.decision;
    if (decision !== "approved" && decision !== "declined") return j;
    const status = applyEstimateDecision(j.status, decision);
    if (status === j.status) return j;
    changed = true;
    return { ...j, status };
  });
  return { jobs: changed ? next : jobs, changed };
}

export async function applyEstimateDecisions(): Promise<void> {
  const jobs = await loadJobs();
  const { jobs: updated, changed } = applyDecisionsToJobs(jobs);
  if (changed) await saveJobs(updated);
}
```

- [ ] **Step 4: Run to verify pass**

Run: `npx jest estimateApprovals`
Expected: PASS (all 5).

- [ ] **Step 5: Export from the storage barrel**

In `utils/storage/index.ts`, add after the other named exports:

```ts
export { applyEstimateDecisions } from "./estimateApprovals";
```

- [ ] **Step 6: Commit (after owner go-ahead)**

```bash
git add utils/storage/estimateApprovals.ts utils/storage/index.ts __tests__/estimateApprovals.test.js
git commit -m "feat: add estimate-decision reconciler (pure core + async wrapper)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

### Task 6: Wire the reconciler into sign-in and foreground sync

**Files:**
- Modify: `App.tsx:55` (import) and `App.tsx:309-313` (session useEffect); `context/AuthContext.tsx` (import + AppState handler ~line 76)

**Interfaces:**
- Consumes: `applyEstimateDecisions` (Task 5).

- [ ] **Step 1: Wire into the App.tsx session useEffect**

In `App.tsx`, extend the storage import on line 55 to include the reconciler:

```ts
import { loadSettings, migrateCustomerIdentity, migrateSampleDataIds, applyEstimateDecisions } from "./utils/storage";
```

Then change the migration chain (lines ~309-313) to also run the reconciler:

```ts
    migrateCustomerIdentity()
      .catch(() => {})
      .then(() => migrateSampleDataIds())
      .catch(() => {})
      .then(() => applyEstimateDecisions())
      .catch(() => {});
```

- [ ] **Step 2: Wire into the AuthContext foreground sync**

In `context/AuthContext.tsx`, add to the imports:

```ts
import { applyEstimateDecisions } from '../utils/storage';
```

In the `AppState` `'change'` handler (currently calling `syncIfOnline(session.user.id)`), chain the reconciler so a decision pulled on foreground is applied the same cycle:

```ts
      if (state === 'active' && session?.user?.id) {
        syncIfOnline(session.user.id).then(() => applyEstimateDecisions()).catch(() => {});
        syncNotifications();
        checkAndGenerateRecurringJobs();
      }
```

- [ ] **Step 3: Full gate**

Run: `npm run typecheck` then `npm test` then `npm run lint`
Expected: all green. (If `syncIfOnline` is not thenable in your build, wrap: `Promise.resolve(syncIfOnline(session.user.id)).then(...)`.)

- [ ] **Step 4: Commit (after owner go-ahead)**

```bash
git add App.tsx context/AuthContext.tsx
git commit -m "feat: run estimate-decision reconciler on sign-in and foreground sync

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

**⛔ STOP — Phase 2 complete. The app now reconciles decisions once the cloud carries them. Await owner go-ahead before Phase 3.**

---

# PHASE 3 — Backend endpoints

*Vercel serverless (Node CommonJS). Deployed + verified against a seeded job. STOP at the end of Phase 3.*

### Task 7: Shared Supabase job store + constant-time compare

**Files:**
- Create: `backend/lib/estimateStore.js`
- Test: `__tests__/estimateRespond.test.js` (pure decision helper, added in Task 9; this task ships the store used by all three endpoints)

**Interfaces:**
- Produces: `fetchJob(jobId)`, `fetchJobForUser(jobId, userId)`, `upsertJob(id, userId, data)`, `constantTimeEqual(a, b)`.

- [ ] **Step 1: Implement the store**

Create `backend/lib/estimateStore.js`:

```js
// Shared Supabase access for the estimate-approval endpoints. Uses the service
// role key (bypasses owner-scoped RLS) exactly like backend/api/stripe/webhook.js.
// NOT routed by Vercel (lives under lib/, not api/).

const crypto = require('crypto');

const SUPABASE_URL = process.env.SUPABASE_URL;
const SUPABASE_SERVICE_ROLE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY;

function headers() {
  return {
    Authorization: `Bearer ${SUPABASE_SERVICE_ROLE_KEY}`,
    apikey: SUPABASE_SERVICE_ROLE_KEY,
  };
}

// Returns { user_id, data } or null.
async function fetchJob(jobId) {
  const res = await fetch(
    `${SUPABASE_URL}/rest/v1/jobs?id=eq.${encodeURIComponent(jobId)}&select=user_id,data`,
    { headers: headers() }
  );
  if (!res.ok) throw new Error(`Supabase fetch ${res.status}: ${await res.text()}`);
  const rows = await res.json();
  return rows.length ? rows[0] : null;
}

// Returns { user_id, data } only if the row belongs to userId; else null.
async function fetchJobForUser(jobId, userId) {
  const res = await fetch(
    `${SUPABASE_URL}/rest/v1/jobs?id=eq.${encodeURIComponent(jobId)}&user_id=eq.${encodeURIComponent(userId)}&select=user_id,data`,
    { headers: headers() }
  );
  if (!res.ok) throw new Error(`Supabase fetch ${res.status}: ${await res.text()}`);
  const rows = await res.json();
  return rows.length ? rows[0] : null;
}

async function upsertJob(id, userId, data) {
  const res = await fetch(`${SUPABASE_URL}/rest/v1/jobs`, {
    method: 'POST',
    headers: { ...headers(), 'Content-Type': 'application/json', Prefer: 'resolution=merge-duplicates' },
    body: JSON.stringify({
      id,
      user_id: userId,
      data,
      updated_at: new Date().toISOString(),
      deleted: false,
    }),
  });
  if (!res.ok) throw new Error(`Supabase upsert ${res.status}: ${await res.text()}`);
}

// Length-safe constant-time string compare (both must be non-empty strings).
function constantTimeEqual(a, b) {
  if (typeof a !== 'string' || typeof b !== 'string' || a.length === 0 || b.length === 0) return false;
  const ba = Buffer.from(a);
  const bb = Buffer.from(b);
  if (ba.length !== bb.length) return false;
  return crypto.timingSafeEqual(ba, bb);
}

module.exports = { fetchJob, fetchJobForUser, upsertJob, constantTimeEqual };
```

- [ ] **Step 2: Sanity-check the module loads**

Run: `node -e "require('./backend/lib/estimateStore.js'); console.log('ok')"`
Expected: prints `ok` (no syntax/require errors).

- [ ] **Step 3: Commit (after owner go-ahead)**

```bash
git add backend/lib/estimateStore.js
git commit -m "feat: add shared Supabase store for estimate endpoints

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

### Task 8: `create-link` endpoint (JWT-authed, mints token)

**Files:**
- Create: `backend/api/estimate/create-link.js`

**Interfaces:**
- Consumes: `fetchJobForUser`, `upsertJob` (Task 7); `createRateLimiter` (`backend/lib/guards.js`).
- Produces: `POST /api/estimate/create-link` → `{ url, token, sentAt }`.

- [ ] **Step 1: Implement**

Create `backend/api/estimate/create-link.js`:

```js
// POST /api/estimate/create-link
// Mints a secure approval token (Node crypto) and writes {token, sentAt, snapshot}
// into the caller's job blob (service role). JWT-authed + rate-limited, mirroring
// create-payment-link.js. The device never needs a secure RNG.

const crypto = require('crypto');
const { fetchJobForUser, upsertJob } = require('../../lib/estimateStore');
const { createRateLimiter } = require('../../lib/guards');

const SUPABASE_URL = process.env.SUPABASE_URL;
const SUPABASE_ANON_KEY = process.env.SUPABASE_ANON_KEY;
const PUBLIC_BASE = 'https://czilla57.github.io/tradeready-legal/estimate.html';

const allow = createRateLimiter({ limit: 10 });

module.exports = async function handler(req, res) {
  res.setHeader('Access-Control-Allow-Origin', 'https://tradeready.app');
  res.setHeader('Access-Control-Allow-Methods', 'POST, OPTIONS');
  res.setHeader('Access-Control-Allow-Headers', 'Content-Type, Authorization');
  if (req.method === 'OPTIONS') return res.status(200).end();
  if (req.method !== 'POST') return res.status(405).json({ error: 'Method not allowed' });

  if (!SUPABASE_URL || !SUPABASE_ANON_KEY || !process.env.SUPABASE_SERVICE_ROLE_KEY) {
    return res.status(500).json({ error: 'Server misconfiguration.' });
  }

  const auth = req.headers['authorization'];
  if (!auth || !auth.startsWith('Bearer ')) return res.status(401).json({ error: 'Unauthorized' });
  const userRes = await fetch(`${SUPABASE_URL}/auth/v1/user`, {
    headers: { Authorization: auth, apikey: SUPABASE_ANON_KEY },
  });
  if (!userRes.ok) return res.status(401).json({ error: 'Invalid or expired session.' });
  const userId = (await userRes.json())?.id;
  if (!userId) return res.status(401).json({ error: 'Unauthorized' });

  if (!allow(userId)) return res.status(429).json({ error: 'Too many requests. Please wait a moment.' });

  const { jobId, snapshot } = req.body || {};
  if (!jobId || typeof jobId !== 'string') return res.status(400).json({ error: 'jobId is required' });
  if (!snapshot || typeof snapshot !== 'object') return res.status(400).json({ error: 'snapshot is required' });

  let row;
  try {
    row = await fetchJobForUser(jobId, userId);
  } catch (err) {
    console.error('[estimate/create-link] fetch failed:', err.message);
    return res.status(500).json({ error: 'Database error' });
  }
  if (!row) {
    return res.status(422).json({ error: 'Estimate not synced yet. Open the app while online and try again.' });
  }

  const existing = row.data?.approval || {};
  // Reuse an outstanding token so re-sending doesn't break a link already out.
  const token = existing.token || crypto.randomBytes(24).toString('hex');
  const sentAt = new Date().toISOString();
  const nextData = {
    ...row.data,
    approval: { ...existing, token, sentAt, snapshot },
  };

  try {
    await upsertJob(jobId, userId, nextData);
  } catch (err) {
    console.error('[estimate/create-link] upsert failed:', err.message);
    return res.status(500).json({ error: 'Database error' });
  }

  const url = `${PUBLIC_BASE}?j=${encodeURIComponent(jobId)}&t=${encodeURIComponent(token)}`;
  return res.status(200).json({ url, token, sentAt });
};
```

- [ ] **Step 2: Sanity-check it loads**

Run: `node -e "require('./backend/api/estimate/create-link.js'); console.log('ok')"`
Expected: prints `ok`.

- [ ] **Step 3: Commit (after owner go-ahead)**

```bash
git add backend/api/estimate/create-link.js
git commit -m "feat: add estimate create-link endpoint (server-mint token)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

### Task 9: `respond` endpoint + decision state-machine

**Files:**
- Create: `backend/api/estimate/respond.js`
- Test: `__tests__/estimateRespond.test.js`

**Interfaces:**
- Consumes: `fetchJob`, `upsertJob`, `constantTimeEqual` (Task 7).
- Produces: `POST /api/estimate/respond` → `{ ok, decision, consentAt }`; pure `nextApproval(existing, body, meta)`.

- [ ] **Step 1: Write the failing state-machine test**

Create `__tests__/estimateRespond.test.js`:

```js
const { nextApproval } = require('../backend/api/estimate/respond');

const base = { token: 't', sentAt: 'x', snapshot: {} };
const meta = { consentAt: '2026-07-17T00:00:00.000Z', ip: '1.2.3.4', userAgent: 'ua' };

describe('nextApproval', () => {
  it('records an approval with server consent + signer name', () => {
    const out = nextApproval(base, { decision: 'approved', signerName: 'Sam Doe' }, meta);
    expect(out.decision).toBe('approved');
    expect(out.consentAt).toBe(meta.consentAt);
    expect(out.signerName).toBe('Sam Doe');
  });

  it('records a decline with reason', () => {
    const out = nextApproval(base, { decision: 'declined', declineReason: 'Too high' }, meta);
    expect(out.decision).toBe('declined');
    expect(out.declineReason).toBe('Too high');
  });

  it('locks once approved — further changes are ignored', () => {
    const approved = nextApproval(base, { decision: 'approved', signerName: 'Sam' }, meta);
    const out = nextApproval(approved, { decision: 'declined' }, { ...meta, consentAt: 'LATER' });
    expect(out).toBe(approved); // unchanged reference
  });

  it('allows declined -> approved (customer changed their mind)', () => {
    const declined = nextApproval(base, { decision: 'declined' }, meta);
    const out = nextApproval(declined, { decision: 'approved', signerName: 'Sam' }, { ...meta, consentAt: 'L2' });
    expect(out.decision).toBe('approved');
    expect(out.consentAt).toBe('L2');
  });
});
```

- [ ] **Step 2: Run to verify it fails**

Run: `npx jest estimateRespond`
Expected: FAIL — cannot find module (respond.js not created yet).

- [ ] **Step 3: Implement**

Create `backend/api/estimate/respond.js`:

```js
// POST /api/estimate/respond
// The customer's Approve/Decline. Token-gated (no user auth — the token is the
// capability). Stamps consentAt SERVER-SIDE and merges only approval.* into the
// job blob (service role). The device performs the status transition on pull.

const { fetchJob, upsertJob, constantTimeEqual } = require('../../lib/estimateStore');
const { createRateLimiter } = require('../../lib/guards');

const ALLOWED_ORIGIN = 'https://czilla57.github.io';
const allow = createRateLimiter({ limit: 10 });

// Pure decision merge — exported for unit tests. Returns the SAME reference when
// locked (already approved) so callers can skip a needless DB write.
function nextApproval(existing, body, meta) {
  if (existing && existing.decision === 'approved') return existing; // terminal lock
  const decision = body.decision === 'approved' ? 'approved' : 'declined';
  return {
    ...existing,
    decision,
    consentAt: meta.consentAt,
    signerName: decision === 'approved' ? String(body.signerName || '').slice(0, 200) : (existing && existing.signerName),
    declineReason: decision === 'declined' ? String(body.declineReason || '').slice(0, 500) || undefined : undefined,
    ip: meta.ip,
    userAgent: meta.userAgent,
  };
}

async function handler(req, res) {
  res.setHeader('Access-Control-Allow-Origin', ALLOWED_ORIGIN);
  res.setHeader('Access-Control-Allow-Methods', 'POST, OPTIONS');
  res.setHeader('Access-Control-Allow-Headers', 'Content-Type');
  if (req.method === 'OPTIONS') return res.status(200).end();
  if (req.method !== 'POST') return res.status(405).json({ error: 'Method not allowed' });

  const ip = (req.headers['x-forwarded-for'] || req.socket?.remoteAddress || 'unknown').split(',')[0].trim();
  if (!allow(ip)) return res.status(429).json({ error: 'Too many requests.' });

  const { jobId, token, decision, signerName, declineReason } = req.body || {};
  if (!jobId || !token) return res.status(400).json({ error: 'Missing link parameters.' });
  if (decision !== 'approved' && decision !== 'declined') return res.status(400).json({ error: 'Invalid decision.' });
  if (decision === 'approved' && !String(signerName || '').trim()) {
    return res.status(400).json({ error: 'Please type your name to approve.' });
  }

  let row;
  try {
    row = await fetchJob(jobId);
  } catch (err) {
    console.error('[estimate/respond] fetch failed:', err.message);
    return res.status(500).json({ error: 'Database error' });
  }
  const existing = row && row.data && row.data.approval;
  if (!row || !existing || !constantTimeEqual(existing.token, String(token))) {
    return res.status(404).json({ error: 'This link is invalid or has expired.' });
  }

  const merged = nextApproval(existing, { decision, signerName, declineReason }, {
    consentAt: new Date().toISOString(),
    ip,
    userAgent: String(req.headers['user-agent'] || '').slice(0, 300),
  });

  if (merged !== existing) {
    try {
      await upsertJob(jobId, row.user_id, { ...row.data, approval: merged });
    } catch (err) {
      console.error('[estimate/respond] upsert failed:', err.message);
      return res.status(500).json({ error: 'Database error' });
    }
  }

  return res.status(200).json({ ok: true, decision: merged.decision, consentAt: merged.consentAt });
}

handler.nextApproval = nextApproval;
module.exports = handler;
module.exports.nextApproval = nextApproval;
```

- [ ] **Step 4: Run to verify pass**

Run: `npx jest estimateRespond`
Expected: PASS (all 4).

- [ ] **Step 5: Commit (after owner go-ahead)**

```bash
git add backend/api/estimate/respond.js __tests__/estimateRespond.test.js
git commit -m "feat: add estimate respond endpoint with consent state-machine

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

### Task 10: `view` endpoint (sanitized read)

**Files:**
- Create: `backend/api/estimate/view.js`

**Interfaces:**
- Consumes: `fetchJob`, `constantTimeEqual` (Task 7).
- Produces: `GET /api/estimate/view?j&t` → sanitized snapshot + decision state.

- [ ] **Step 1: Implement**

Create `backend/api/estimate/view.js`:

```js
// GET /api/estimate/view?j=<jobId>&t=<token>
// Sanitized, token-gated read for the public viewer. Returns ONLY this estimate's
// frozen snapshot + decision state — never other jobs or extra PII.

const { fetchJob, constantTimeEqual } = require('../../lib/estimateStore');
const { createRateLimiter } = require('../../lib/guards');

const ALLOWED_ORIGIN = 'https://czilla57.github.io';
const allow = createRateLimiter({ limit: 30 });

module.exports = async function handler(req, res) {
  res.setHeader('Access-Control-Allow-Origin', ALLOWED_ORIGIN);
  res.setHeader('Access-Control-Allow-Methods', 'GET, OPTIONS');
  res.setHeader('Access-Control-Allow-Headers', 'Content-Type');
  if (req.method === 'OPTIONS') return res.status(200).end();
  if (req.method !== 'GET') return res.status(405).json({ error: 'Method not allowed' });

  const ip = (req.headers['x-forwarded-for'] || req.socket?.remoteAddress || 'unknown').split(',')[0].trim();
  if (!allow(ip)) return res.status(429).json({ error: 'Too many requests.' });

  const jobId = req.query.j;
  const token = req.query.t;
  if (!jobId || !token) return res.status(400).json({ error: 'Missing link parameters.' });

  let row;
  try {
    row = await fetchJob(String(jobId));
  } catch (err) {
    console.error('[estimate/view] fetch failed:', err.message);
    return res.status(500).json({ error: 'Database error' });
  }
  const a = row && row.data && row.data.approval;
  if (!row || !a || !constantTimeEqual(a.token, String(token))) {
    return res.status(404).json({ error: 'This link is invalid or has expired.' });
  }

  return res.status(200).json({
    ...a.snapshot,
    decision: a.decision || null,
    consentAt: a.consentAt || null,
    signerName: a.signerName || null,
    signatureRequired: true,
  });
};
```

- [ ] **Step 2: Sanity-check it loads**

Run: `node -e "require('./backend/api/estimate/view.js'); console.log('ok')"`
Expected: prints `ok`.

- [ ] **Step 3: Deploy + manual verification**

Deploy the backend (per `tradeready-run-and-operate`: push to the backend's Vercel project). Seed by running Phase 5's app flow OR insert a test job row with an `approval.token` via the Supabase dashboard. Then:

```bash
# 404 on bad token
curl -s "https://backend-tradeready1.vercel.app/api/estimate/view?j=<jobId>&t=WRONG" -i | head -1
# 200 + snapshot on correct token
curl -s "https://backend-tradeready1.vercel.app/api/estimate/view?j=<jobId>&t=<token>"
# approve
curl -s -X POST "https://backend-tradeready1.vercel.app/api/estimate/respond" \
  -H "Content-Type: application/json" \
  -d '{"jobId":"<jobId>","token":"<token>","decision":"approved","signerName":"Test Customer"}'
# idempotent re-POST returns the same consentAt (locked)
```

Expected: `404` then `200` with the snapshot; approve returns `{ ok:true, decision:"approved", consentAt:... }`; re-POST returns the same `consentAt`.

- [ ] **Step 4: Commit (after owner go-ahead)**

```bash
git add backend/api/estimate/view.js
git commit -m "feat: add estimate view endpoint (sanitized token-gated read)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

**⛔ STOP — Phase 3 complete. Endpoints live + verified. Await owner go-ahead before Phase 4.**

---

# PHASE 4 — Public viewer (separate repo: `tradeready-legal/`)

*Static page. Manual end-to-end verification. STOP at the end of Phase 4.*

### Task 11: `estimate.html` approval page

**Files:**
- Create: `tradeready-legal/estimate.html`

- [ ] **Step 1: Create the page**

Create `tradeready-legal/estimate.html` (matches the visual language of `privacy.html`):

```html
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>Estimate — TradeReady</title>
  <style>
    *, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }
    body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
           font-size: 16px; line-height: 1.6; color: #1a1a1a; background: #f9f9f9; padding: 2rem 1rem; }
    .page { max-width: 560px; margin: 0 auto; background: #fff; border-radius: 12px;
            padding: 2rem; box-shadow: 0 1px 4px rgba(0,0,0,.08); }
    .brand { font-size: 1.4rem; font-weight: 800; color: #2563eb; margin-bottom: 1rem; }
    h1 { font-size: 1.25rem; margin-bottom: .25rem; }
    .muted { color: #6b7280; font-size: .9rem; }
    .row { display: flex; justify-content: space-between; padding: .5rem 0; border-bottom: 1px solid #f0f0f0; }
    .total { font-weight: 700; font-size: 1.1rem; border-top: 2px solid #e5e7eb; margin-top: .5rem; padding-top: .75rem; }
    .actions { margin-top: 1.5rem; display: flex; flex-direction: column; gap: .75rem; }
    label { font-size: .9rem; font-weight: 600; display: block; margin-bottom: .35rem; }
    input, textarea { width: 100%; padding: .7rem; border: 1px solid #d1d5db; border-radius: 8px; font-size: 1rem; }
    button { padding: .85rem; border: none; border-radius: 8px; font-size: 1rem; font-weight: 600; cursor: pointer; }
    .approve { background: #16a34a; color: #fff; }
    .decline { background: #fff; color: #b91c1c; border: 1px solid #fecaca; }
    .hidden { display: none; }
    .banner { padding: 1rem; border-radius: 8px; text-align: center; font-weight: 600; }
    .ok { background: #ecfdf5; color: #065f46; }
    .info { background: #eff6ff; color: #1e40af; }
    .err { background: #fef2f2; color: #991b1b; }
    .footer { margin-top: 2rem; padding-top: 1rem; border-top: 1px solid #e5e7eb; font-size: .8rem; color: #9ca3af; }
  </style>
</head>
<body>
<div class="page">
  <div class="brand">TradeReady</div>
  <div id="content"><p class="muted">Loading your estimate…</p></div>
  <div class="footer">By approving, you consent to an electronic signature record (your typed name, the time, and your device) being stored with this estimate.</div>
</div>

<script>
  var API = 'https://backend-tradeready1.vercel.app/api/estimate';
  var params = new URLSearchParams(location.search);
  var jobId = params.get('j');
  var token = params.get('t');
  var content = document.getElementById('content');

  function money(n) { return '$' + Number(n || 0).toLocaleString(undefined, { minimumFractionDigits: 0, maximumFractionDigits: 2 }); }
  function esc(s) { var d = document.createElement('div'); d.textContent = s == null ? '' : String(s); return d.innerHTML; }
  function banner(cls, msg) { content.innerHTML = '<div class="banner ' + cls + '">' + esc(msg) + '</div>'; }

  if (!jobId || !token) { banner('err', 'This link is missing information. Please ask for a new link.'); }
  else { load(); }

  async function load() {
    try {
      var res = await fetch(API + '/view?j=' + encodeURIComponent(jobId) + '&t=' + encodeURIComponent(token));
      if (!res.ok) { banner('err', 'This link is invalid or has expired.'); return; }
      render(await res.json());
    } catch (e) { banner('err', 'Could not load the estimate. Please check your connection.'); }
  }

  function render(est) {
    if (est.decision === 'approved') {
      banner('ok', 'You approved this estimate' + (est.consentAt ? ' on ' + new Date(est.consentAt).toLocaleDateString() : '') + '. Thank you!');
      return;
    }
    var lines = (est.lineItems || []).map(function (li) {
      return '<div class="row"><span>' + esc(li.label) + '</span><span>' + money(li.amount) + '</span></div>';
    }).join('');
    var declinedNote = est.decision === 'declined'
      ? '<div class="banner info" style="margin-bottom:1rem">You previously declined this. You can still approve it below.</div>' : '';
    content.innerHTML =
      declinedNote +
      '<h1>' + esc(est.jobTitle) + '</h1>' +
      '<p class="muted">From ' + esc(est.businessName) + ' &middot; For ' + esc(est.customerName) + '</p>' +
      '<div style="margin-top:1rem">' + lines +
      '<div class="row total"><span>Total estimate</span><span>' + money(est.total) + '</span></div></div>' +
      '<div class="actions">' +
      '<label for="signer">Type your full name to approve</label>' +
      '<input id="signer" placeholder="Your full name" autocomplete="name">' +
      '<button class="approve" id="approveBtn">Approve estimate</button>' +
      '<button class="decline" id="declineBtn">Decline</button>' +
      '</div>';
    document.getElementById('approveBtn').onclick = function () { respond('approved'); };
    document.getElementById('declineBtn').onclick = function () { respond('declined'); };
  }

  async function respond(decision) {
    var signerName = (document.getElementById('signer') || {}).value || '';
    if (decision === 'approved' && !signerName.trim()) { alert('Please type your name to approve.'); return; }
    var reason = decision === 'declined' ? (prompt('Optional: reason for declining?') || '') : '';
    banner('info', 'Submitting…');
    try {
      var res = await fetch(API + '/respond', {
        method: 'POST', headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ jobId: jobId, token: token, decision: decision, signerName: signerName, declineReason: reason }),
      });
      var out = await res.json();
      if (!res.ok) { banner('err', out.error || 'Something went wrong. Please try again.'); return; }
      banner(decision === 'approved' ? 'ok' : 'info',
        decision === 'approved' ? 'Approved — thank you! Your tradesperson has been notified.' : 'You declined this estimate. Thank you for letting us know.');
    } catch (e) { banner('err', 'Could not submit. Please check your connection and try again.'); }
  }
</script>
</body>
</html>
```

- [ ] **Step 2: Verify locally (structure)**

Open the file in a browser with `?j=x&t=y` appended — it should show the error banner (no valid job), proving the JS parses and runs.

- [ ] **Step 3: Deploy + end-to-end**

Commit/push `tradeready-legal` (GitHub Pages auto-deploys). Using a real seeded job + token (from Phase 3 or Phase 5), open `https://czilla57.github.io/tradeready-legal/estimate.html?j=<jobId>&t=<token>`; verify the estimate renders, Approve requires a name, and the confirmation shows. Re-open the link → shows "You approved this estimate on <date>".

- [ ] **Step 4: Commit in the tradeready-legal repo (after owner go-ahead)**

```bash
# from tradeready-legal/
git add estimate.html
git commit -m "feat: add customer estimate approval page

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

**⛔ STOP — Phase 4 complete. The full backend + viewer loop works. Await owner go-ahead before Phase 5.**

---

# PHASE 5 — App send flow

*Wires the app into the loop. STOP at the end of Phase 5.*

### Task 12: `buildEstimateSnapshot()` util

**Files:**
- Create: `utils/estimateSnapshot.ts`
- Test: `__tests__/estimateSnapshot.test.js`

**Interfaces:**
- Consumes: `computeEstimateBreakdown` (`utils/pricingEngine`), `Job`/`Customer`/`Settings`.
- Produces: `buildEstimateSnapshot(job, customer, settings): EstimateApprovalSnapshot`.

- [ ] **Step 1: Write the failing test**

Create `__tests__/estimateSnapshot.test.js`:

```js
const { buildEstimateSnapshot } = require('../utils/estimateSnapshot');

const job = {
  title: 'Kitchen sink', customerName: 'Sam', estimateTotal: 500,
  laborHours: 4, laborRate: 75, materials: [{ name: 'trap', cost: 20, qty: 1 }],
  materialMarkup: 0, overhead: 0, margin: 0,
};
const customer = { name: 'Sam Doe' };
const settings = { businessName: 'Ace Plumbing' };

describe('buildEstimateSnapshot', () => {
  it('captures business, customer, title, total and a labor line', () => {
    const snap = buildEstimateSnapshot(job, customer, settings);
    expect(snap.businessName).toBe('Ace Plumbing');
    expect(snap.customerName).toBe('Sam Doe');
    expect(snap.jobTitle).toBe('Kitchen sink');
    expect(snap.total).toBe(500);
    expect(snap.currency).toBe('USD');
    expect(snap.lineItems.find((l) => l.label.toLowerCase().includes('labor'))).toBeTruthy();
  });
});
```

- [ ] **Step 2: Run to verify it fails**

Run: `npx jest estimateSnapshot`
Expected: FAIL — cannot find module.

- [ ] **Step 3: Implement**

Create `utils/estimateSnapshot.ts`:

```ts
// Freezes an estimate into the shape the public viewer renders, using the single
// source of pricing math (computeEstimateBreakdown). Pure + unit-tested.

import { computeEstimateBreakdown } from "./pricingEngine";
import type { Job, Customer, Settings, EstimateApprovalSnapshot } from "../types/models";

export function buildEstimateSnapshot(
  job: Job,
  customer: Pick<Customer, "name">,
  settings: Pick<Settings, "businessName">,
): EstimateApprovalSnapshot {
  const { laborCost, materialCost, overheadLine, hasMaterials } = computeEstimateBreakdown(job);
  const lineItems: { label: string; amount: number }[] = [
    { label: `Labor (${job.laborHours} hrs @ $${job.laborRate}/hr)`, amount: laborCost },
  ];
  if (hasMaterials) {
    lineItems.push({ label: `Materials (${job.materials.length} item${job.materials.length !== 1 ? "s" : ""})`, amount: materialCost });
  }
  if (overheadLine > 0) lineItems.push({ label: "Overhead & operating costs", amount: overheadLine });

  return {
    businessName: settings.businessName || "Your tradesperson",
    customerName: customer.name || job.customerName,
    jobTitle: job.title,
    lineItems,
    total: job.estimateTotal,
    currency: "USD",
  };
}
```

- [ ] **Step 4: Run to verify pass**

Run: `npx jest estimateSnapshot`
Expected: PASS.

- [ ] **Step 5: Commit (after owner go-ahead)**

```bash
git add utils/estimateSnapshot.ts __tests__/estimateSnapshot.test.js
git commit -m "feat: add estimate snapshot builder

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

### Task 13: Add `approvalLink` to the estimate message generator

**Files:**
- Modify: `utils/invoiceHelpers.ts:166-171` (params), `:173-185+` (generic builder), `:216-236+` (AI prompt)

**Interfaces:**
- Produces: `generateEstimateMessage({ …, approvalLink? })` and `buildGenericEstimateMessage({ …, approvalLink? })` include the link as a call-to-action.

- [ ] **Step 1: Add `approvalLink` to the params interface**

In `utils/invoiceHelpers.ts`, change `interface EstimateMessageParams` to add the field:

```ts
interface EstimateMessageParams {
  job: Job;
  customer: Customer;
  channel: 'text' | 'email';
  biz: Partial<Settings>;
  approvalLink?: string;
}
```

- [ ] **Step 2: Use it in the generic (fallback) builder**

In `buildGenericEstimateMessage`, destructure `approvalLink` and, in the `text` branch, replace the `Reply YES…` line so it prefers the link when present:

```ts
function buildGenericEstimateMessage({ job, customer, channel, biz, approvalLink }: EstimateMessageParams): string {
  const { laborCost, materialCost, overheadLine, hasMaterials } = computeEstimateBreakdown(job);

  if (channel === 'text') {
    const parts = [
      `Hi ${customer.name}, ${biz.businessName} here.`,
      `Estimate for "${job.title}":`,
      `Labor: ${formatQuote(laborCost)}`,
    ];
    if (hasMaterials) parts.push(`Materials: ${formatQuote(materialCost)}`);
    parts.push(`Total: ${formatQuote(job.estimateTotal)}.`);
    parts.push(approvalLink ? `View & approve: ${approvalLink}` : `Reply YES to approve or call ${biz.phone}.`);
    return parts.join(' ');
  }
  // …existing email branch: append the link on its own line when present…
```

In the email branch of the same function, before the sign-off, add (only if the branch builds an array of lines — adapt to the existing structure):

```ts
  if (approvalLink) emailParts.push(`\nView and approve your estimate here:\n${approvalLink}`);
```

- [ ] **Step 3: Use it in the AI prompt**

In `generateEstimateMessage`, add `approvalLink` to the destructured params and pass it to the fallback, then append a line to the `prompt` string when present:

```ts
export async function generateEstimateMessage({
  job, customer, channel, biz, apiKey, approvalLink,
}: EstimateMessageParams & { apiKey?: string }): Promise<string> {
  const fallback = () => buildGenericEstimateMessage({ job, customer, channel, biz, approvalLink });
  if (!apiKey) return fallback();
  // …after building `prompt`, before the API call:
  const promptWithLink = approvalLink
    ? `${prompt}\n\nEnd with a clear call to action to review and approve online at this link (include it verbatim): ${approvalLink}`
    : prompt;
  // …use promptWithLink in the generateMessage() call, and pass approvalLink into the catch-path fallback too.
```

Ensure the `generateMessage({ prompt: promptWithLink, apiKey, fallback, … })` call uses `promptWithLink`.

- [ ] **Step 4: Extend the existing test**

In `__tests__/invoiceHelpers.test.js`, add a case asserting the generic builder includes the link:

```js
it('includes the approval link in the generic estimate message', () => {
  const msg = buildGenericEstimateMessage({
    job: { title: 'X', laborHours: 1, laborRate: 1, materials: [], materialMarkup: 0, overhead: 0, margin: 0, estimateTotal: 1 },
    customer: { name: 'Sam' }, channel: 'text', biz: { businessName: 'Ace', phone: '5551234' },
    approvalLink: 'https://example.test/e?j=1&t=2',
  });
  expect(msg).toContain('https://example.test/e?j=1&t=2');
});
```

(If `buildGenericEstimateMessage` is not currently exported, export it for the test.)

- [ ] **Step 5: Run to verify pass + gate**

Run: `npx jest invoiceHelpers` then `npm run typecheck` && `npm run lint`
Expected: PASS / green.

- [ ] **Step 6: Commit (after owner go-ahead)**

```bash
git add utils/invoiceHelpers.ts __tests__/invoiceHelpers.test.js
git commit -m "feat: include approval link in estimate messages

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

### Task 14: "Send for approval" action in SendEstimateScreen

**Files:**
- Modify: `screens/SendEstimateScreen.tsx`

**Interfaces:**
- Consumes: `buildEstimateSnapshot` (Task 12); `supabase` (`utils/supabase`); backend `create-link`; `generateEstimateMessage` `approvalLink` (Task 13).

- [ ] **Step 1: Add imports + backend constant**

At the top of `screens/SendEstimateScreen.tsx` add:

```tsx
import Constants from "expo-constants";
import { Alert } from "react-native";
import { supabase } from "../utils/supabase";
import { buildEstimateSnapshot } from "../utils/estimateSnapshot";

const BACKEND_URL = (Constants.expoConfig?.extra as any)?.backendUrl ?? "";
```

- [ ] **Step 2: Add state for the link**

Inside the component, beside the other `useState` calls:

```tsx
const [approvalLink, setApprovalLink] = useState<string>("");
const [linking, setLinking] = useState<boolean>(false);
```

- [ ] **Step 3: Add the handler**

Add this function inside the component (above the `return`):

```tsx
async function createApprovalLink(): Promise<string | null> {
  if (!data) return null;
  if (!BACKEND_URL) { Alert.alert("Not available", "Approval links need a network connection."); return null; }
  setLinking(true);
  try {
    // Ensure the job exists in the cloud so the backend can attach the token.
    const snapshot = buildEstimateSnapshot(data.job, data.customer, data.settings);
    const jobs = await loadJobs();
    const withSent = jobs.map((j): Job => (j.id === jobId ? { ...j, status: "estimate_sent" } : j));
    await saveJobs(withSent);

    const { data: sess } = await supabase.auth.getSession();
    const jwt = sess.session?.access_token;
    if (!jwt) { Alert.alert("Sign in required", "Please sign in to send an approval link."); return null; }

    const res = await fetch(`${BACKEND_URL}/api/estimate/create-link`, {
      method: "POST",
      headers: { "Content-Type": "application/json", Authorization: `Bearer ${jwt}` },
      body: JSON.stringify({ jobId, snapshot }),
    });
    const out = await res.json();
    if (!res.ok) { Alert.alert("Couldn't create link", out.error || "Please try again."); return null; }

    // Mirror the server write locally so JobDetail reflects it immediately.
    const linked = (await loadJobs()).map((j): Job =>
      j.id === jobId ? { ...j, status: "estimate_sent", approval: { token: out.token, sentAt: out.sentAt, snapshot } } : j
    );
    await saveJobs(linked);
    setApprovalLink(out.url);
    track("estimate_sent");
    return out.url as string;
  } catch {
    Alert.alert("Couldn't create link", "Please check your connection and try again.");
    return null;
  } finally {
    setLinking(false);
  }
}

async function sendForApproval() {
  const url = approvalLink || (await createApprovalLink());
  if (!url || !data) return;
  const raw = await generateEstimateMessage({
    job: data.job, customer: data.customer, channel, biz: data.settings,
    apiKey: (data.settings as any).anthropicKey, approvalLink: url,
  });
  const body = channel === "email" && raw.startsWith("Subject:") ? raw.split("\n").slice(2).join("\n").trim() : raw;
  if (channel === "email") {
    await composeEmail({ recipients: (data.customer as any).email ? [(data.customer as any).email] : [], subject: subject || `Estimate for ${data.job.title}`, body });
  } else {
    await composeSMS({ recipients: (data.customer as any).phone ? [(data.customer as any).phone] : [], body });
  }
}
```

Add `generateEstimateMessage` to the existing import from `../utils/invoiceHelpers`.

- [ ] **Step 4: Add the button + link display**

In the JSX, above the existing "Mark estimate as sent" button, add:

```tsx
<Button
  label={approvalLink ? `Send approval request via ${channel === "email" ? "Mail" : "Messages"}` : "Create approval link & send"}
  onPress={sendForApproval}
  loading={linking}
  style={{ marginBottom: spacing.sm }}
/>
{approvalLink ? (
  <TouchableOpacity onPress={() => Clipboard.setStringAsync(approvalLink)} accessibilityRole="button" accessibilityLabel="Copy approval link">
    <Text style={styles.markHint}>Tap to copy link: {approvalLink}</Text>
  </TouchableOpacity>
) : null}
```

- [ ] **Step 5: Gate**

Run: `npm run typecheck` && `npm test` && `npm run lint`
Expected: green.

- [ ] **Step 6: Commit (after owner go-ahead)**

```bash
git add screens/SendEstimateScreen.tsx
git commit -m "feat: send estimate approval link from SendEstimateScreen

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

### Task 15: JobDetail approval surface + declined re-send reset

**Files:**
- Modify: `screens/JobDetailScreen.tsx`

**Interfaces:**
- Consumes: `Job.approval`, `JOB_STATUSES` display label.

- [ ] **Step 1: Show approval state**

In `screens/JobDetailScreen.tsx`, where job meta is rendered, add a block (adapt to the screen's existing `Card`/`Text` styles):

```tsx
{job.approval?.decision === "approved" && (
  <Text style={styles.metaLine}>
    ✓ Approved{job.approval.consentAt ? ` ${new Date(job.approval.consentAt).toLocaleDateString()}` : ""}
    {job.approval.signerName ? ` by ${job.approval.signerName}` : ""}
  </Text>
)}
{job.approval?.decision === "declined" && (
  <Text style={styles.metaLine}>
    ✗ Declined{job.approval.consentAt ? ` ${new Date(job.approval.consentAt).toLocaleDateString()}` : ""}
    {job.approval.declineReason ? ` — “${job.approval.declineReason}”` : ""}
  </Text>
)}
{job.approval && !job.approval.decision && (
  <Text style={styles.metaLine}>⧗ Sent for approval {new Date(job.approval.sentAt).toLocaleDateString()}</Text>
)}
```

If `styles.metaLine` doesn't exist, reuse the screen's existing muted-line style.

- [ ] **Step 2: Add a re-send reset for declined jobs**

Where JobDetail renders status actions, when `job.status === "declined"`, offer a button that resets to `estimate_sent` and routes to SendEstimate:

```tsx
{job.status === "declined" && (
  <Button
    label="Revise & re-send estimate"
    variant="secondary"
    onPress={async () => {
      const jobs = await loadJobs();
      const reset = jobs.map((j): Job =>
        j.id === job.id ? { ...j, status: "estimate_sent", approval: j.approval ? { ...j.approval, decision: undefined, consentAt: undefined, declineReason: undefined } : undefined } : j
      );
      await saveJobs(reset);
      navigation.navigate("SendEstimate", { jobId: job.id });
    }}
  />
)}
```

Ensure `loadJobs`, `saveJobs`, `Button`, and `Job` are imported (most are already used in this screen).

- [ ] **Step 3: Gate**

Run: `npm run typecheck` && `npm test` && `npm run lint`
Expected: green.

- [ ] **Step 4: Commit (after owner go-ahead)**

```bash
git add screens/JobDetailScreen.tsx
git commit -m "feat: show estimate approval state and declined re-send in JobDetail

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

**⛔ STOP — Phase 5 complete. Full loop wired end-to-end. Await owner go-ahead before Phase 6.**

---

# PHASE 6 — End-to-end verification + docs

### Task 16: Device E2E + documentation

**Files:**
- Modify: `README.md`, `ARCHITECTURE.md`, `tradeready-legal/terms.html`, `tradeready-legal/privacy.html`

- [ ] **Step 1: Full end-to-end on a build**

On an EAS build (or Expo Go with backend reachable), sign in, open a job → SendEstimate → "Create approval link & send". Copy the link, open it in a browser, Approve with a typed name. Return to the app, background/foreground it, and confirm the job advances to **Approved** and JobDetail shows the consent date + signer. Repeat for **Decline** (job shows Declined; "Revise & re-send" resets it). Confirm approved→scheduled still fires when a scheduled date is later added.

- [ ] **Step 2: Update README sync-model + known-limitations**

In `README.md`, in the "Sync model and known limitations" section, add a bullet noting the new **server-authoritative write path** (estimate approvals are written to Supabase by the backend service role and reconciled to the device by `pullRemote`, inheriting the last-write-wins envelope).

- [ ] **Step 3: Update ARCHITECTURE.md**

Add a short "Estimate approval loop" subsection: token-gated Vercel endpoints, server writes confined to `job.approval.*`, device-owned pipeline transition via `applyEstimateDecisions`, poll-based reconciliation.

- [ ] **Step 4: Update legal copy (tradeready-legal repo)**

In `privacy.html`, note that when a customer approves an estimate, their typed name, timestamp, IP, and user-agent are stored as an electronic-consent record. In `terms.html`, add an electronic-signature / estimate-acceptance clause.

- [ ] **Step 5: Full gate + commit (after owner go-ahead)**

Run: `npm run typecheck` && `npm test` && `npm run lint` (expect green).

```bash
git add README.md ARCHITECTURE.md
git commit -m "docs: document estimate approval loop and consent write path

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
# in tradeready-legal/:
git add privacy.html terms.html
git commit -m "docs: add electronic-consent and e-signature language

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

**⛔ STOP — Phase 6 complete. Feature shipped.**

---

## Deferred (post-v1, out of scope here)

- **Drawn signature** — canvas pad → PNG in a Supabase Storage bucket (public-read policy), `EstimateApproval.signatureRef`. New infra; separate spec.
- **Push-on-approval** — Expo remote push so the tradesperson learns of an approval instantly instead of on next foreground. The app has no remote-push pipeline today.

## Self-Review

- **Spec coverage:** data model (T1), declined pipeline + colors (T1–3), transition logic (T4), reconciler + wiring (T5–6), backend view/respond/create-link + security (T7–10), public viewer (T11), app send flow + snapshot + message link (T12–14), JobDetail surface + declined reset (T15), poll reconciliation (T6 wiring), docs + E2E (T16). Deferred items match the spec. ✓
- **Server-mint decision** (owner-chosen) reflected: token minted in `create-link.js` via `crypto.randomBytes`; no app dependency added. ✓
- **Type consistency:** `EstimateApproval`/`EstimateApprovalSnapshot` used identically across models, snapshot builder, endpoints, and screens; `applyEstimateDecision` signature matches between `jobStatus.ts`, its tests, and the reconciler. ✓
- **Placeholder scan:** every code step shows complete code; the only "adapt to existing structure" notes are in T13/T15 where they touch large existing files — each still specifies the exact lines to add. ✓

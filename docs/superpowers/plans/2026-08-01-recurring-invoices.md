# Recurring Invoices (Maintenance Plans) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Generate an invoice for a customer on a schedule (pause/resume, end conditions), surfaced through a local "review & send" notification — never auto-sent — mirroring the recurring-jobs pattern.

**Architecture:** Extract the shared recurrence math out of `utils/recurringJobs.ts` into `utils/recurrence.ts` and keep two thin engines. A new LOCAL-ONLY `recurringInvoices` AsyncStorage collection holds `RecurringInvoice` rules; `utils/recurringInvoices.ts` runs a catch-up generation loop from `AuthContext` (sign-in + app-foreground, beside the jobs engine). Generated invoices are ordinary `Invoice` records (they sync normally) linked back to their rule via two approved optional fields. The declarative `syncNotifications()` sweep gains a `rinv_` branch; two new screens live in the Invoices stack.

**Tech Stack:** Expo 54 / React Native 0.81 / React 19, strict TypeScript, Jest (jest-expo), AsyncStorage, expo-notifications, React Navigation (typed).

**Spec (owner-approved, do not redesign):** `docs/superpowers/specs/2026-07-31-recurring-invoices-design.md`

## Global Constraints

- **Repo root** (run every command from here; the path contains a space — always quote): `"C:\Users\Chadr\OneDrive\Documents\TraderPro App\tradeready"`
- **Branch:** `feat/recurring-invoices` off `master` (branch creation + committing this plan doc is Task 1's first steps). Do NOT push; do NOT merge — the owner smokes and merges.
- **JS-ONLY branch:** NO dependency changes, NO app.json changes, NO native code.
- **Only approved persisted-shape changes:** optional `recurringInvoiceId?: string` + `occurrenceNumber?: number` on `Invoice`, and new local-only AsyncStorage key `recurringInvoices` (not synced, wiped by `clearAllUserData` — it removes `Object.values(KEYS)` — covered by `sampleMigration`). Nothing else touches persisted shapes.
- **Gate before EVERY commit**, from repo root: `npm run typecheck` (0 errors), `npm test` (all pass; baseline at branch time: **1433 tests / 90 suites**), `npm run lint` (0 warnings). Never commit red.
- **Commit style:** imperative subject with `feat:`/`fix:`/`chore:`/`docs:`/`refactor:` prefix, one coherent change per commit.
- **Generated invoice ids:** `inv${Date.now()}` — all-digits after the `inv` prefix (`invoiceIssueDate` in `utils/pdfTemplates.ts:167` parses it); uniqueness in catch-up batches via a monotonic counter added to the ms value; rule linkage ONLY via `recurringInvoiceId`, NEVER in id suffixes.
- **Extraction tasks are behavior-preserving:** the existing `__tests__/recurringJobs.test.ts` must pass UNCHANGED (that is the proof of preservation). Note: neither invoice screen has a screen-level test suite — for the `nextInvoiceNumber` extraction, preservation is proven by the new unit tests + a green full gate.
- **The RecurringInvoicesScreen action sheet HAS Edit** (deliberate divergence from RecurringJobsScreen — do not "fix" to parity); cancel is soft-deactivate with confirm, wording exactly: "No more invoices will be generated. Invoices already created are not affected."
- **Notification:** identifier `rinv_${rule.id}`, 9:00am on `nextDueDate`, title `` `Maintenance invoice ready — ${rule.customerName}` ``, body "Open to review & send.", data `{ type: 'recurring_invoice', ruleId }`, Android channel `invoice-reminders` (reused, no new channel — note that, matching every existing branch of the sweep, no per-notification `channelId` is passed).
- **No network in the generator** (local-first invariant). Payment links are minted on demand by the existing send/outreach flow.
- Customer creation goes ONLY through `getOrCreateCustomer` (`utils/storage/customers.ts:122`).

## File Structure

| File | Action | Responsibility |
|---|---|---|
| `utils/recurrence.ts` | create | Shared cadence step + generalized end-condition check |
| `utils/recurringJobs.ts` | modify | Re-import the shared helpers; engine loop unchanged |
| `types/models.ts` | modify | `RecurringInvoice` interface; 2 optional Invoice fields |
| `utils/storage/keys.ts` | modify | Add `recurringInvoices` key |
| `utils/storage/recurringInvoices.ts` | create | `loadRecurringInvoices` / `saveRecurringInvoices` |
| `utils/storage/index.ts` | modify | Barrel re-export |
| `utils/storage/sampleMigration.ts` | modify | Generalize rule relink; heal invoice rules too |
| `utils/invoiceNumber.ts` | create | Single home for `nextInvoiceNumber` |
| `screens/AddInvoiceScreen.tsx` | modify | Use extracted `nextInvoiceNumber` |
| `screens/CreateInvoiceFromJobScreen.tsx` | modify | Use extracted `nextInvoiceNumber` |
| `utils/recurringInvoices.ts` | create | Generation engine (mirror of jobs engine) |
| `context/AuthContext.tsx` | modify | Run invoice engine beside jobs engine |
| `utils/notifications.ts` | modify | `rinv_` branch in the sweep |
| `App.tsx` | modify | Tap routing; header icon; 2 stack registrations |
| `types/navigation.ts` | modify | 2 new InvoiceStack routes |
| `screens/RecurringInvoicesScreen.tsx` | create | Rule list + action sheet (WITH Edit) |
| `screens/AddRecurringInvoiceScreen.tsx` | create | Create/edit modal |
| `__tests__/recurrence.test.ts` | create | Cadence math + end conditions |
| `__tests__/recurringInvoicesStorage.test.ts` | create | Storage round-trip |
| `__tests__/invoiceNumber.test.ts` | create | Extraction unit tests |
| `__tests__/recurringInvoices.test.ts` | create | Generator suite |
| `__tests__/sampleMigration.test.js` | modify | +1 test (generic relink) |
| `__tests__/storage.test.js` | modify | Pin `recurringInvoices` in the sign-out wipe |
| `__tests__/notifications.test.js` | modify | +4 tests (rinv branch) |
| `README.md`, `docs/post-launch-feature-roadmap.md` | modify | Docs (Task 9) |

---

### Task 1: Branch + shared recurrence helpers (`utils/recurrence.ts`)

**Files:**
- Create: `docs/superpowers/plans/2026-08-01-recurring-invoices.md` (this file — commit it)
- Create: `utils/recurrence.ts`
- Create: `__tests__/recurrence.test.ts`
- Modify: `utils/recurringJobs.ts` (whole file replaced below; today lines 4–18 hold the two helpers being moved)
- MUST NOT touch: `__tests__/recurringJobs.test.ts`

**Interfaces:**
- Consumes: `RecurrenceCadence`, `RecurrenceEndCondition`, `DateString` from `types/models.ts` (lines 378–379, 56 — already exist).
- Produces (later tasks import these from `../utils/recurrence` / `./recurrence`):
  - `calculateNextDate(from: DateString, cadence: RecurrenceCadence): DateString`
  - `interface RecurrenceState { endCondition: RecurrenceEndCondition; endCount?: number; endDate?: DateString; occurrenceCount: number; nextDueDate: DateString; }`
  - `isEndConditionMet(rule: RecurrenceState): boolean`
  - `utils/recurringJobs.ts` continues to re-export `calculateNextDate` (consumed by `screens/AddJobScreen.tsx:23` and the existing test — both unchanged).

- [ ] **Step 1: Create the branch and commit the plan**

From repo root (PowerShell; quote the path if you `cd`):

```powershell
git status            # expect: clean tree, on master
git checkout -b feat/recurring-invoices
git add docs/superpowers/plans/2026-08-01-recurring-invoices.md
git commit -m "docs: add recurring-invoices implementation plan"
```

Expected: new branch `feat/recurring-invoices`, one commit with the plan doc.

- [ ] **Step 2: Write the failing test**

Create `__tests__/recurrence.test.ts`:

```ts
// __tests__/recurrence.test.ts
// Direct tests for the shared recurrence helpers extracted from
// utils/recurringJobs.ts (2026-08-01). The jobs engine's own suite
// (recurringJobs.test.ts) stays byte-identical — its passing unchanged is the
// proof the extraction preserved behavior.

import { calculateNextDate, isEndConditionMet } from '../utils/recurrence';
import type { RecurrenceState } from '../utils/recurrence';

function state(overrides: Partial<RecurrenceState> = {}): RecurrenceState {
  return {
    endCondition: 'never',
    occurrenceCount: 0,
    nextDueDate: '2026-07-08',
    ...overrides,
  };
}

describe('calculateNextDate (shared home)', () => {
  test('daily advances by 1 day', () => {
    expect(calculateNextDate('2026-07-08', 'daily')).toBe('2026-07-09');
  });

  test('weekly advances by 7 days', () => {
    expect(calculateNextDate('2026-07-08', 'weekly')).toBe('2026-07-15');
  });

  test('monthly advances by 1 month', () => {
    expect(calculateNextDate('2026-07-08', 'monthly')).toBe('2026-08-08');
  });

  test('quarterly advances by 3 months', () => {
    expect(calculateNextDate('2026-07-08', 'quarterly')).toBe('2026-10-08');
  });

  test('annually advances by 1 year', () => {
    expect(calculateNextDate('2026-07-08', 'annually')).toBe('2027-07-08');
  });

  test('monthly from Jan 31 overflows into March (JS Date behavior, accepted)', () => {
    expect(calculateNextDate('2026-01-31', 'monthly')).toMatch(/^2026-03-0[23]$/);
  });
});

describe('isEndConditionMet', () => {
  test("'never' is never met", () => {
    expect(isEndConditionMet(state({ occurrenceCount: 9999 }))).toBe(false);
  });

  test("'count' is met when occurrenceCount reaches endCount", () => {
    expect(
      isEndConditionMet(state({ endCondition: 'count', endCount: 3, occurrenceCount: 3 }))
    ).toBe(true);
  });

  test("'count' is not met below endCount", () => {
    expect(
      isEndConditionMet(state({ endCondition: 'count', endCount: 3, occurrenceCount: 2 }))
    ).toBe(false);
  });

  test("'date' is met when nextDueDate is past endDate", () => {
    expect(
      isEndConditionMet(state({ endCondition: 'date', endDate: '2026-07-07' }))
    ).toBe(true);
  });

  test("'date' is NOT met on the end date itself (boundary: that day still generates)", () => {
    expect(
      isEndConditionMet(state({ endCondition: 'date', endDate: '2026-07-08' }))
    ).toBe(false);
  });
});
```

- [ ] **Step 3: Run it to verify it fails**

Run: `npx jest __tests__/recurrence.test.ts`
Expected: FAIL — `Cannot find module '../utils/recurrence'`.

- [ ] **Step 4: Create `utils/recurrence.ts`** (code moved verbatim from `utils/recurringJobs.ts:4-18`, end-condition check generalized to the fields both rule types share):

```ts
// utils/recurrence.ts
// Shared recurrence math for the two thin scheduling engines
// (utils/recurringJobs.ts and utils/recurringInvoices.ts). Extracted from
// recurringJobs.ts on 2026-08-01 — behavior-preserving; the jobs engine's
// suite (recurringJobs.test.ts) pins the math unchanged.

import type { DateString, RecurrenceCadence, RecurrenceEndCondition } from '../types/models';

export function calculateNextDate(from: DateString, cadence: RecurrenceCadence): DateString {
  const d = new Date(from + 'T00:00:00');
  if (cadence === 'daily') d.setDate(d.getDate() + 1);
  else if (cadence === 'weekly') d.setDate(d.getDate() + 7);
  else if (cadence === 'monthly') d.setMonth(d.getMonth() + 1);
  else if (cadence === 'quarterly') d.setMonth(d.getMonth() + 3);
  else if (cadence === 'annually') d.setFullYear(d.getFullYear() + 1);
  return d.toISOString().split('T')[0];
}

/**
 * The recurrence fields RecurringJob and RecurringInvoice share. Both rule
 * types satisfy this structurally, so the engines pass their rules straight in.
 */
export interface RecurrenceState {
  endCondition: RecurrenceEndCondition;
  endCount?: number;
  endDate?: DateString;
  occurrenceCount: number;
  nextDueDate: DateString;
}

export function isEndConditionMet(rule: RecurrenceState): boolean {
  if (rule.endCondition === 'count') return rule.occurrenceCount >= rule.endCount!;
  if (rule.endCondition === 'date') return rule.nextDueDate > rule.endDate!;
  return false;
}
```

- [ ] **Step 5: Run the new test to verify it passes**

Run: `npx jest __tests__/recurrence.test.ts`
Expected: PASS — 11 tests.

- [ ] **Step 6: Rewire `utils/recurringJobs.ts`** — replace the ENTIRE file with (engine body byte-identical to today's lines 20–86; only the helper definitions are replaced by imports and a re-export):

```ts
import { Job } from '../types/models';
import { loadJobs, saveJobs, loadRecurringJobs, saveRecurringJobs } from './storage';
import { calculateNextDate, isEndConditionMet } from './recurrence';

// Re-exported so existing consumers (AddJobScreen.tsx:23,
// recurringJobs.test.ts:1) keep importing the cadence math from here.
export { calculateNextDate };

let generating = false;

export async function checkAndGenerateRecurringJobs(): Promise<void> {
  if (generating) return;
  generating = true;
  try {
    const today = new Date().toISOString().split('T')[0];
    const [recurringJobs, jobs] = await Promise.all([loadRecurringJobs(), loadJobs()]);
    const newJobs: Job[] = [];
    let anyUpdated = false;

    for (const rule of recurringJobs) {
      if (!rule.isActive) continue;

      while (rule.nextDueDate <= today) {
        if (isEndConditionMet(rule)) {
          rule.isActive = false;
          anyUpdated = true;
          break;
        }

        const newJob: Job = {
          id: `j${Date.now()}_${rule.id}_${rule.occurrenceCount + 1}`,
          customerId: rule.customerId,
          customerName: rule.customerName,
          title: rule.title,
          description: rule.description,
          address: rule.address,
          notes: rule.notes,
          estimateTotal: rule.estimateTotal,
          laborHours: rule.laborHours,
          laborRate: rule.laborRate,
          materials: rule.materials,
          materialMarkup: rule.materialMarkup,
          overhead: rule.overhead,
          margin: rule.margin,
          status: 'scheduled',
          scheduledDate: rule.nextDueDate,
          scheduledStartTime: null,
          scheduledEndTime: null,
          invoiceId: null,
          createdAt: today,
          recurringJobId: rule.id,
          occurrenceNumber: rule.occurrenceCount + 1,
        };

        newJobs.push(newJob);
        rule.occurrenceCount++;
        rule.lastGeneratedDate = rule.nextDueDate;
        rule.nextDueDate = calculateNextDate(rule.nextDueDate, rule.cadence);
        anyUpdated = true;

        if (isEndConditionMet(rule)) {
          rule.isActive = false;
          break;
        }
      }
    }

    if (newJobs.length > 0 || anyUpdated) {
      await saveJobs([...jobs, ...newJobs]);
      await saveRecurringJobs(recurringJobs);
    }
  } finally {
    generating = false;
  }
}
```

- [ ] **Step 7: Prove the extraction preserved behavior**

Run: `npx jest __tests__/recurringJobs.test.ts __tests__/recurrence.test.ts`
Expected: BOTH PASS. `git diff --stat __tests__/recurringJobs.test.ts` must show ZERO changes.

- [ ] **Step 8: Gate**

Run (each must be green): `npm run typecheck` → 0 errors; `npm test` → all pass (1444 tests / 91 suites: baseline + 11); `npm run lint` → 0 warnings.

- [ ] **Step 9: Commit**

```powershell
git add utils/recurrence.ts utils/recurringJobs.ts __tests__/recurrence.test.ts
git commit -m "refactor: extract shared recurrence helpers to utils/recurrence.ts"
```

---

### Task 2: `RecurringInvoice` model + local storage + sample-id healing

**Files:**
- Modify: `types/models.ts` (Invoice fields near line 311; new interface after `RecurringJob`, line 405)
- Modify: `utils/storage/keys.ts:13`
- Create: `utils/storage/recurringInvoices.ts`
- Modify: `utils/storage/index.ts:21`
- Modify: `utils/storage/sampleMigration.ts` (generalize `relinkDanglingRuleCustomers` at line 40; extend `migrateSampleDataIds` at line 63)
- Create: `__tests__/recurringInvoicesStorage.test.ts`
- Modify: `__tests__/sampleMigration.test.js` (append one test)
- Modify: `__tests__/storage.test.js` (extend `mustBeRemoved`, line 110)

**Interfaces:**
- Consumes: `KEYS` map pattern (`utils/storage/keys.ts`), `RecurringJob` storage-module pattern (`utils/storage/recurringJobs.ts` — 17-line mirror source), `relinkDanglingRuleCustomers` (currently `RecurringJob[]`-typed), `resolveCustomer` (unchanged), `RecurrenceCadence`/`RecurrenceEndCondition`/`DateString` from Task 1's world.
- Produces:
  - `interface RecurringInvoice` in `types/models.ts` (exact shape below — every later task uses it).
  - `Invoice.recurringInvoiceId?: string` and `Invoice.occurrenceNumber?: number`.
  - `loadRecurringInvoices(): Promise<RecurringInvoice[]>` and `saveRecurringInvoices(rules: RecurringInvoice[]): Promise<void>`, exported from the `utils/storage` barrel.
  - `relinkDanglingRuleCustomers<T extends { customerId: string; customerName: string }>(rules: T[], customers: Customer[], idMap: Record<string, string>): { changed: boolean; records: T[] }` (generic — existing jobs-rule call site unchanged).

- [ ] **Step 1: Write the failing storage test**

Create `__tests__/recurringInvoicesStorage.test.ts`:

```ts
// __tests__/recurringInvoicesStorage.test.ts
// The recurringInvoices collection is LOCAL-ONLY (mirror of recurringJobs):
// plain AsyncStorage under KEYS.recurringInvoices, never enqueued to sync.

import AsyncStorage from '@react-native-async-storage/async-storage';
import { loadRecurringInvoices, saveRecurringInvoices } from '../utils/storage';
import type { RecurringInvoice } from '../types/models';

// Isolate the storage barrel from sync/notification side-effects, exactly as
// __tests__/storage.test.js and __tests__/sampleMigration.test.js do.
jest.mock('../utils/sync', () => ({
  enqueue: jest.fn(),
  enqueueCollectionChanges: jest.fn(),
  trySync: jest.fn(),
  pruneQueueRecords: jest.fn(),
}));
jest.mock('../utils/notifications', () => ({ syncNotifications: jest.fn() }));

const rule: RecurringInvoice = {
  id: 'ri1700000000000',
  customerId: 'c1',
  customerName: 'Riverside Bakery',
  description: 'Monthly maintenance',
  amount: 150,
  dueDays: 30,
  cadence: 'monthly',
  endCondition: 'never',
  occurrenceCount: 0,
  lastGeneratedDate: null,
  nextDueDate: '2026-08-01',
  isActive: true,
  createdAt: '2026-08-01',
};

beforeEach(() => {
  jest.clearAllMocks();
  (AsyncStorage.getItem as jest.Mock).mockResolvedValue(null);
  (AsyncStorage.setItem as jest.Mock).mockResolvedValue(undefined);
});

describe('recurringInvoices storage', () => {
  test('loadRecurringInvoices returns [] when nothing is stored', async () => {
    expect(await loadRecurringInvoices()).toEqual([]);
  });

  test('saveRecurringInvoices writes JSON under the recurringInvoices key', async () => {
    await saveRecurringInvoices([rule]);
    expect(AsyncStorage.setItem).toHaveBeenCalledWith(
      'recurringInvoices',
      JSON.stringify([rule])
    );
  });

  test('loadRecurringInvoices round-trips a saved rule', async () => {
    (AsyncStorage.getItem as jest.Mock).mockResolvedValue(JSON.stringify([rule]));
    const loaded = await loadRecurringInvoices();
    expect(loaded).toHaveLength(1);
    expect(loaded[0]).toEqual(rule);
  });

  test('corrupt JSON degrades to [] instead of throwing', async () => {
    (AsyncStorage.getItem as jest.Mock).mockResolvedValue('{not json');
    expect(await loadRecurringInvoices()).toEqual([]);
  });
});
```

- [ ] **Step 2: Run it to verify it fails**

Run: `npx jest __tests__/recurringInvoicesStorage.test.ts`
Expected: FAIL — babel-jest strips types, so it fails at runtime: `loadRecurringInvoices is not a function` (the barrel doesn't export it yet).

- [ ] **Step 3: Add the model.** In `types/models.ts`, inside `interface Invoice`, insert AFTER the `jobId?: string;` member (line 311) and BEFORE the trailing `// NOTE: there is no `created` field.` comment:

```ts
  /**
   * FK to RecurringInvoice.id when this invoice was generated by a
   * maintenance-plan rule (utils/recurringInvoices.ts). Mirrors
   * Job.recurringJobId. Additive-optional — absent on every other invoice;
   * JSON-blob sync means no backend migration (storage-and-sync recipe).
   */
  recurringInvoiceId?: string;
  /** 1-based occurrence index within the rule (mirrors Job.occurrenceNumber). */
  occurrenceNumber?: number;
```

Then, immediately AFTER the closing `}` of `interface RecurringJob` (line 405), add:

```ts
/**
 * A recurring-invoice rule (maintenance plan). LOCAL-ONLY, like RecurringJob
 * and Trip: stored under the `recurringInvoices` AsyncStorage key, NOT synced
 * (not in COLLECTION_TABLES), cleared on sign-out by clearAllUserData, lost on
 * device change — the same accepted limitation recurring jobs carry. The
 * invoices it generates are normal records and sync like any other invoice.
 */
export interface RecurringInvoice {
  id: string;                       // ri<timestamp>
  customerId: string;
  /** Denormalized display copy (Job.customerName pattern). */
  customerName: string;
  /** Becomes invoice.desc on each generated invoice. */
  description: string;
  amount: number;
  /** Net terms in days; default 30 (= AddInvoiceScreen defaultDueDate). */
  dueDays: number;
  cadence: RecurrenceCadence;
  endCondition: RecurrenceEndCondition;
  endCount?: number;
  endDate?: DateString;
  occurrenceCount: number;
  lastGeneratedDate: DateString | null;
  /** Next occurrence (generation) date, "YYYY-MM-DD". */
  nextDueDate: DateString;
  isActive: boolean;
  createdAt: DateString;
}
```

- [ ] **Step 4: Add the key.** In `utils/storage/keys.ts`, after `recurringJobs: "recurringJobs",` (line 13) add:

```ts
  recurringInvoices: "recurringInvoices",
```

(`clearAllUserData` in `utils/storage/lifecycle.ts:71` removes `...Object.values(KEYS)`, so the sign-out wipe picks this up automatically.)

- [ ] **Step 5: Create `utils/storage/recurringInvoices.ts`** (exact mirror of `utils/storage/recurringJobs.ts`):

```ts
import AsyncStorage from "@react-native-async-storage/async-storage";
import { KEYS } from "./keys";
import type { RecurringInvoice } from "../../types/models";

export async function loadRecurringInvoices(): Promise<RecurringInvoice[]> {
  try {
    const raw = await AsyncStorage.getItem(KEYS.recurringInvoices);
    return raw ? JSON.parse(raw) : [];
  } catch {
    return [];
  }
}

export async function saveRecurringInvoices(rules: RecurringInvoice[]): Promise<void> {
  await AsyncStorage.setItem(KEYS.recurringInvoices, JSON.stringify(rules));
}
```

- [ ] **Step 6: Barrel export.** In `utils/storage/index.ts`, after `export { loadRecurringJobs, saveRecurringJobs } from "./recurringJobs";` (line 21) add:

```ts
export { loadRecurringInvoices, saveRecurringInvoices } from "./recurringInvoices";
```

- [ ] **Step 7: Run the storage test to verify it passes**

Run: `npx jest __tests__/recurringInvoicesStorage.test.ts`
Expected: PASS — 4 tests.

- [ ] **Step 8: Pin the sign-out wipe.** In `__tests__/storage.test.js`, extend the `mustBeRemoved` array (lines 110–121) — add one line after `"customerNotes",`:

```js
      "recurringInvoices",
```

Run: `npx jest __tests__/storage.test.js` → PASS (the key now exists in `KEYS`).

- [ ] **Step 9: Write the failing sample-migration test.** Append to `__tests__/sampleMigration.test.js`, inside the existing `describe("relinkDanglingRuleCustomers", ...)` block, after the last test:

```js
  test("also heals recurring-INVOICE rules (generic over both rule shapes)", () => {
    const { changed, records } = relinkDanglingRuleCustomers(
      [{ id: "ri_1", customerId: "c1", customerName: "Riverside Bakery", amount: 120, dueDays: 30 }],
      customers,
      { c1: "c1-snew" },
    );
    expect(changed).toBe(true);
    expect(records[0].customerId).toBe("c1-snew");
    expect(records[0].amount).toBe(120); // non-job fields pass through untouched
  });
```

Run: `npx jest __tests__/sampleMigration.test.js`
Expected: this new test PASSES already in JS (the function never touched job-only fields) — that is fine; the load-bearing change is the TypeScript signature (Step 10) plus the `migrateSampleDataIds` wiring, which `npm run typecheck` gates. If it passes, continue.

- [ ] **Step 10: Generalize + wire the migration.** In `utils/storage/sampleMigration.ts`:

10a. Replace the import block lines
`import { saveRecurringJobs } from "./recurringJobs";` and
`import type { Customer, Job, Invoice, RecurringJob } from "../../types/models";`
with:

```ts
import { saveRecurringJobs } from "./recurringJobs";
import { saveRecurringInvoices } from "./recurringInvoices";
```
and
```ts
import type { Customer, Job, Invoice, RecurringJob, RecurringInvoice } from "../../types/models";
```

10b. Replace the `relinkDanglingRuleCustomers` signature (lines 40–44) — body unchanged:

```ts
export function relinkDanglingRuleCustomers<
  T extends { customerId: string; customerName: string },
>(
  rules: T[],
  customers: Customer[],
  idMap: Record<string, string>,
): { changed: boolean; records: T[] } {
```

(The `records` map's returns — `rule`, `{ ...rule, customerId: ... }` — already type as `T`.)

10c. In `migrateSampleDataIds`, replace the opening `Promise.all` destructure (lines 64–69) with:

```ts
  const [customers, jobs, invoices, rules, invoiceRules] = await Promise.all([
    readRaw<Customer>(KEYS.customers),
    readRaw<Job>(KEYS.jobs),
    readRaw<Invoice>(KEYS.invoices),
    readRaw<RecurringJob>(KEYS.recurringJobs),
    readRaw<RecurringInvoice>(KEYS.recurringInvoices),
  ]);
```

10d. Immediately after the existing recurring-JOB rule block (`const r = rules ? ... : null; if (r?.changed) await saveRecurringJobs(r.records);`, lines 88–91), add:

```ts
  // Recurring-invoice rules have the same exposure (a rule can be created
  // against a seed customer before migration) and the same local-only,
  // no-queue-side-effect save.
  const ri = invoiceRules
    ? relinkDanglingRuleCustomers(invoiceRules, (c?.records ?? customers) || [], idMap)
    : null;
  if (ri?.changed) await saveRecurringInvoices(ri.records);
```

- [ ] **Step 11: Run the touched suites**

Run: `npx jest __tests__/sampleMigration.test.js __tests__/storage.test.js __tests__/recurringInvoicesStorage.test.ts`
Expected: ALL PASS.

- [ ] **Step 12: Gate** — `npm run typecheck` (0), `npm test` (all pass; +5 tests vs Task 1), `npm run lint` (0).

- [ ] **Step 13: Commit**

```powershell
git add types/models.ts utils/storage/keys.ts utils/storage/recurringInvoices.ts utils/storage/index.ts utils/storage/sampleMigration.ts __tests__/recurringInvoicesStorage.test.ts __tests__/sampleMigration.test.js __tests__/storage.test.js
git commit -m "feat: add RecurringInvoice model, local storage, and sample-id healing"
```

---

### Task 3: Extract `nextInvoiceNumber` to `utils/invoiceNumber.ts`

**Files:**
- Create: `utils/invoiceNumber.ts`
- Create: `__tests__/invoiceNumber.test.ts`
- Modify: `screens/AddInvoiceScreen.tsx` (delete local `autoInvoiceNumber` at lines 156–162; call site line 87; import line 16 area)
- Modify: `screens/CreateInvoiceFromJobScreen.tsx` (delete local `nextInvoiceNumber` at lines 65–72; call sites lines 144 and 246 keep the same call text; add import)

**Interfaces:**
- Consumes: `Invoice` from `types/models.ts`.
- Produces: `nextInvoiceNumber(invoices: Invoice[]): string` from `utils/invoiceNumber.ts` — Task 4's generator imports it.
- Behavior contract (must not change): digit-scan of every `invoice.number`, max + 1, rendered `INV-%04d`; empty list → `INV-0001`. The two screen-local copies differ only cosmetically (`CreateInvoiceFromJobScreen` guards `(inv.number || "")` and passes radix 10; `AddInvoiceScreen` does neither). Keep the GUARDED form — identical output for every well-formed record, strictly safer on malformed ones.

- [ ] **Step 1: Write the failing test**

Create `__tests__/invoiceNumber.test.ts`:

```ts
// __tests__/invoiceNumber.test.ts
// nextInvoiceNumber was extracted 2026-08-01 from two identical screen-local
// copies (AddInvoiceScreen.autoInvoiceNumber, CreateInvoiceFromJobScreen.
// nextInvoiceNumber) so the recurring-invoice generator isn't a third copy.
// These tests pin the shared rule: digit-scan max + 1, INV-%04d.

import { nextInvoiceNumber } from '../utils/invoiceNumber';
import type { Invoice } from '../types/models';

function inv(number: string): Invoice {
  return {
    id: 'x',
    customer: 'A',
    number,
    amount: 100,
    due: '2026-01-01',
    email: '',
    phone: '',
    desc: '',
    paid: false,
  };
}

describe('nextInvoiceNumber', () => {
  test('empty list starts at INV-0001', () => {
    expect(nextInvoiceNumber([])).toBe('INV-0001');
  });

  test('max + 1 across gaps', () => {
    expect(nextInvoiceNumber([inv('INV-0002'), inv('INV-0007')])).toBe('INV-0008');
  });

  test('non-numeric numbers are ignored', () => {
    expect(nextInvoiceNumber([inv('DRAFT'), inv('INV-0003')])).toBe('INV-0004');
  });

  test('all-non-numeric list starts at INV-0001', () => {
    expect(nextInvoiceNumber([inv('DRAFT'), inv('FINAL')])).toBe('INV-0001');
  });

  test('a missing number field does not throw (legacy-data guard)', () => {
    const legacy = { ...inv('INV-0005'), number: undefined } as unknown as Invoice;
    expect(nextInvoiceNumber([legacy, inv('INV-0002')])).toBe('INV-0003');
  });

  test('pads to 4 digits and grows past 9999', () => {
    expect(nextInvoiceNumber([inv('INV-0009')])).toBe('INV-0010');
    expect(nextInvoiceNumber([inv('INV-9999')])).toBe('INV-10000');
  });

  test('digit-scan concatenates ALL digit runs (existing behavior, pinned)', () => {
    // "A1B2" scans to 12 — both original copies did this; the extraction must
    // not "fix" it.
    expect(nextInvoiceNumber([inv('A1B2')])).toBe('INV-0013');
  });
});
```

- [ ] **Step 2: Run it to verify it fails**

Run: `npx jest __tests__/invoiceNumber.test.ts`
Expected: FAIL — `Cannot find module '../utils/invoiceNumber'`.

- [ ] **Step 3: Create `utils/invoiceNumber.ts`:**

```ts
// utils/invoiceNumber.ts
// Single home for the next-invoice-number rule: scan the digits of every
// existing invoice.number, take max + 1, render INV-%04d. Extracted
// 2026-08-01 from the two identical screen-local copies
// (AddInvoiceScreen.autoInvoiceNumber, CreateInvoiceFromJobScreen.
// nextInvoiceNumber) so the recurring-invoice generator isn't a third copy
// (architecture-contract reuse rule).

import type { Invoice } from "../types/models";

export function nextInvoiceNumber(invoices: Invoice[]): string {
  const nums = invoices
    .map((inv) => parseInt((inv.number || "").replace(/\D/g, ""), 10))
    .filter(Boolean);
  const next = nums.length ? Math.max(...nums) + 1 : 1;
  return `INV-${String(next).padStart(4, "0")}`;
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `npx jest __tests__/invoiceNumber.test.ts`
Expected: PASS — 7 tests.

- [ ] **Step 5: Point `AddInvoiceScreen` at it.**

5a. Add the import after line 17 (`import { syncNotifications } ...`):

```ts
import { nextInvoiceNumber } from "../utils/invoiceNumber";
```

5b. Change the call site (line 87) from
`number: number.trim() || autoInvoiceNumber(invoices),` to:

```ts
      number: number.trim() || nextInvoiceNumber(invoices),
```

5c. Delete the whole local helper (lines 156–162):

```ts
function autoInvoiceNumber(invoices: Invoice[]): string {
  const nums = invoices
    .map((i) => parseInt(i.number.replace(/\D/g, "")))
    .filter(Boolean);
  const next = nums.length ? Math.max(...nums) + 1 : 1;
  return `INV-${String(next).padStart(4, "0")}`;
}
```

- [ ] **Step 6: Point `CreateInvoiceFromJobScreen` at it.**

6a. Add the import after line 40 (`import Field from "../components/Field";`):

```ts
import { nextInvoiceNumber } from "../utils/invoiceNumber";
```

6b. Delete the local helper (lines 64–72, including its comment line):

```ts
// Auto-generate the next invoice number from existing invoices
function nextInvoiceNumber(invoices: Invoice[]): string {
  const nums = invoices
    .map((inv) => parseInt((inv.number || "").replace(/\D/g, ""), 10))
    .filter(Boolean);
  const next = nums.length ? Math.max(...nums) + 1 : 1;
  return `INV-${String(next).padStart(4, "0")}`;
}
```

The two call sites (`setNumber(nextInvoiceNumber(invoices));` at ~line 144 and `number: number.trim() || nextInvoiceNumber(invoices),` at ~line 246) keep the same name and need NO edit.

- [ ] **Step 7: Gate** — `npm run typecheck` (0 — this is the real extraction proof for the screens, which have no test suites of their own), `npm test` (all pass), `npm run lint` (0).

- [ ] **Step 8: Commit**

```powershell
git add utils/invoiceNumber.ts __tests__/invoiceNumber.test.ts screens/AddInvoiceScreen.tsx screens/CreateInvoiceFromJobScreen.tsx
git commit -m "refactor: extract nextInvoiceNumber to utils/invoiceNumber.ts"
```

---

### Task 4: Generation engine — `utils/recurringInvoices.ts`

**Files:**
- Create: `utils/recurringInvoices.ts`
- Create: `__tests__/recurringInvoices.test.ts`

**Interfaces:**
- Consumes: `calculateNextDate`, `isEndConditionMet` from `utils/recurrence.ts` (Task 1); `loadRecurringInvoices`/`saveRecurringInvoices` + `loadInvoices`/`saveInvoices`/`loadCustomers`/`resolveCustomer` from the `utils/storage` barrel (Task 2 + existing); `nextInvoiceNumber` from `utils/invoiceNumber.ts` (Task 3); `RecurringInvoice`, `Invoice` types.
- Produces: `checkAndGenerateRecurringInvoices(): Promise<void>` — Task 5 wires it into `AuthContext`.
- Side-effect contract: saving through `saveInvoices` (utils/storage/collections.ts:25) already enqueues sync AND re-runs `syncNotifications()` — no extra wiring needed for dunning on generated invoices. `isJobDunningEligible` (utils/jobStatus.ts:137) passes invoices with no `jobId` through — correct: a generated maintenance invoice is billable immediately.

- [ ] **Step 1: Write the failing test**

Create `__tests__/recurringInvoices.test.ts`:

```ts
import { checkAndGenerateRecurringInvoices } from '../utils/recurringInvoices';
import { invoiceIssueDate } from '../utils/pdfTemplates';
import type { RecurringInvoice, Invoice, Customer } from '../types/models';
import {
  loadInvoices,
  saveInvoices,
  loadCustomers,
  loadRecurringInvoices,
  saveRecurringInvoices,
} from '../utils/storage';

jest.mock('../utils/storage', () => ({
  loadInvoices: jest.fn(),
  saveInvoices: jest.fn(),
  loadCustomers: jest.fn(),
  loadRecurringInvoices: jest.fn(),
  saveRecurringInvoices: jest.fn(),
  // resolveCustomer is pure; its real behavior is pinned by
  // __tests__/customerIdentity.test.js. Reimplemented inline so this mock
  // factory doesn't drag the real storage graph (sync/supabase) into the test.
  resolveCustomer: jest.fn(
    (customers: any[], link: { customerId?: string | null; customerName?: string | null }) =>
      customers.find((c) => c.id === link.customerId) ??
      customers.find(
        (c) => c.name.trim().toLowerCase() === (link.customerName || '').trim().toLowerCase(),
      ) ??
      null,
  ),
}));

const mockLoadInvoices = loadInvoices as jest.MockedFunction<typeof loadInvoices>;
const mockSaveInvoices = saveInvoices as jest.MockedFunction<typeof saveInvoices>;
const mockLoadCustomers = loadCustomers as jest.MockedFunction<typeof loadCustomers>;
const mockLoadRecurringInvoices =
  loadRecurringInvoices as jest.MockedFunction<typeof loadRecurringInvoices>;
const mockSaveRecurringInvoices =
  saveRecurringInvoices as jest.MockedFunction<typeof saveRecurringInvoices>;

const alice: Customer = {
  id: 'c1', name: 'Alice', email: 'alice@x.com', phone: '555-0001', address: '', notes: '',
};

function makeRule(overrides: Partial<RecurringInvoice> = {}): RecurringInvoice {
  return {
    id: 'ri_test',
    customerId: 'c1',
    customerName: 'Alice',
    description: 'Monthly maintenance',
    amount: 150,
    dueDays: 30,
    cadence: 'weekly',
    endCondition: 'never',
    occurrenceCount: 0,
    lastGeneratedDate: null,
    nextDueDate: '2026-07-08',
    isActive: true,
    createdAt: '2026-06-01',
    ...overrides,
  };
}

beforeEach(() => {
  jest.useFakeTimers();
  jest.setSystemTime(new Date('2026-07-08T12:00:00'));
  jest.clearAllMocks();
  mockLoadInvoices.mockResolvedValue([]);
  mockLoadCustomers.mockResolvedValue([alice]);
  mockSaveInvoices.mockResolvedValue(undefined);
  mockSaveRecurringInvoices.mockResolvedValue(undefined);
});

afterEach(() => {
  jest.useRealTimers();
});

describe('checkAndGenerateRecurringInvoices', () => {
  test('generates 1 invoice when the rule is due today, with every field derived', async () => {
    mockLoadRecurringInvoices.mockResolvedValue([makeRule()]);

    await checkAndGenerateRecurringInvoices();

    expect(mockSaveInvoices).toHaveBeenCalledTimes(1);
    const saved: Invoice[] = mockSaveInvoices.mock.calls[0][0];
    expect(saved).toHaveLength(1);
    const inv = saved[0];
    expect(inv.id).toMatch(/^inv\d+$/);            // all-digits after the prefix
    expect(inv.customer).toBe('Alice');
    expect(inv.customerId).toBe('c1');
    expect(inv.number).toBe('INV-0001');
    expect(inv.amount).toBe(150);
    expect(inv.due).toBe('2026-08-07');            // occurrence 07-08 + 30 net days
    expect(inv.email).toBe('alice@x.com');         // snapshot at generation time
    expect(inv.phone).toBe('555-0001');
    expect(inv.desc).toBe('Monthly maintenance');
    expect(inv.paid).toBe(false);
    expect(inv.recurringInvoiceId).toBe('ri_test');
    expect(inv.occurrenceNumber).toBe(1);

    const rules: RecurringInvoice[] = mockSaveRecurringInvoices.mock.calls[0][0];
    expect(rules[0].occurrenceCount).toBe(1);
    expect(rules[0].lastGeneratedDate).toBe('2026-07-08');
    expect(rules[0].nextDueDate).toBe('2026-07-15');
  });

  test('generated invoices carry NO jobId, payments, or lineItems', async () => {
    mockLoadRecurringInvoices.mockResolvedValue([makeRule()]);

    await checkAndGenerateRecurringInvoices();

    const inv = mockSaveInvoices.mock.calls[0][0][0];
    expect('jobId' in inv).toBe(false);
    expect('payments' in inv).toBe(false);
    expect('lineItems' in inv).toBe(false);
  });

  test('catch-up generates every missed weekly occurrence with unique, parseable ids', async () => {
    jest.setSystemTime(new Date('2026-07-22T12:00:00'));
    mockLoadRecurringInvoices.mockResolvedValue([makeRule({ nextDueDate: '2026-07-01' })]);

    await checkAndGenerateRecurringInvoices();

    const saved: Invoice[] = mockSaveInvoices.mock.calls[0][0];
    expect(saved).toHaveLength(4); // 07-01, 07-08, 07-15, 07-22

    // Unique ids inside one same-millisecond batch (monotonic counter)…
    expect(new Set(saved.map((i) => i.id)).size).toBe(4);
    // …that all stay parseable by the PDF issue-date recovery.
    const FAR = new Date('2030-01-01T00:00:00.000Z');
    for (const i of saved) {
      expect(i.id).toMatch(/^inv\d+$/);
      expect(invoiceIssueDate(i.id, FAR)).not.toBe(FAR.toISOString()); // no fallback
    }

    expect(saved.map((i) => i.number)).toEqual(['INV-0001', 'INV-0002', 'INV-0003', 'INV-0004']);
    expect(saved.map((i) => i.occurrenceNumber)).toEqual([1, 2, 3, 4]);
    // due = occurrence date + 30 (NOT generation date) — catch-up invoices
    // date from when the money was owed and may appear already overdue.
    expect(saved.map((i) => i.due)).toEqual(['2026-07-31', '2026-08-07', '2026-08-14', '2026-08-21']);

    const rules: RecurringInvoice[] = mockSaveRecurringInvoices.mock.calls[0][0];
    expect(rules[0].occurrenceCount).toBe(4);
    expect(rules[0].nextDueDate).toBe('2026-07-29');
  });

  test('invoice numbering continues from existing invoices', async () => {
    mockLoadInvoices.mockResolvedValue([
      { id: 'old', customer: 'B', number: 'INV-0007', amount: 1, due: '2026-01-01', email: '', phone: '', desc: '', paid: true },
    ]);
    mockLoadRecurringInvoices.mockResolvedValue([makeRule()]);

    await checkAndGenerateRecurringInvoices();

    const saved: Invoice[] = mockSaveInvoices.mock.calls[0][0];
    expect(saved).toHaveLength(2); // existing + 1 generated, single batched save
    expect(saved[1].number).toBe('INV-0008');
  });

  test('end condition count: deactivates without generating', async () => {
    mockLoadRecurringInvoices.mockResolvedValue([
      makeRule({ endCondition: 'count', endCount: 3, occurrenceCount: 3 }),
    ]);

    await checkAndGenerateRecurringInvoices();

    expect(mockSaveInvoices).toHaveBeenCalledTimes(1);
    expect(mockSaveInvoices.mock.calls[0][0]).toHaveLength(0);
    expect(mockSaveRecurringInvoices.mock.calls[0][0][0].isActive).toBe(false);
  });

  test('end condition date: past end date deactivates without generating', async () => {
    mockLoadRecurringInvoices.mockResolvedValue([
      makeRule({ endCondition: 'date', endDate: '2026-07-07' }),
    ]);

    await checkAndGenerateRecurringInvoices();

    expect(mockSaveInvoices.mock.calls[0][0]).toHaveLength(0);
    expect(mockSaveRecurringInvoices.mock.calls[0][0][0].isActive).toBe(false);
  });

  test("end condition never: stays active", async () => {
    mockLoadRecurringInvoices.mockResolvedValue([makeRule()]);

    await checkAndGenerateRecurringInvoices();

    expect(mockSaveRecurringInvoices.mock.calls[0][0][0].isActive).toBe(true);
  });

  test('rule not yet due: no saves at all', async () => {
    mockLoadRecurringInvoices.mockResolvedValue([makeRule({ nextDueDate: '2026-07-15' })]);

    await checkAndGenerateRecurringInvoices();

    expect(mockSaveInvoices).not.toHaveBeenCalled();
    expect(mockSaveRecurringInvoices).not.toHaveBeenCalled();
  });

  test('paused rule is skipped entirely', async () => {
    mockLoadRecurringInvoices.mockResolvedValue([makeRule({ isActive: false })]);

    await checkAndGenerateRecurringInvoices();

    expect(mockSaveInvoices).not.toHaveBeenCalled();
    expect(mockSaveRecurringInvoices).not.toHaveBeenCalled();
  });

  test('customer gone: contact snapshot is blank (backfillInvoiceContacts heals later)', async () => {
    mockLoadCustomers.mockResolvedValue([]);
    mockLoadRecurringInvoices.mockResolvedValue([makeRule()]);

    await checkAndGenerateRecurringInvoices();

    const inv = mockSaveInvoices.mock.calls[0][0][0];
    expect(inv.email).toBe('');
    expect(inv.phone).toBe('');
    expect(inv.customer).toBe('Alice'); // denormalized name still works
  });

  test('re-entry guard: a concurrent second call is a no-op', async () => {
    let release!: (rules: RecurringInvoice[]) => void;
    mockLoadRecurringInvoices.mockReturnValueOnce(
      new Promise<RecurringInvoice[]>((res) => { release = res; })
    );

    const first = checkAndGenerateRecurringInvoices();
    const second = checkAndGenerateRecurringInvoices(); // guard returns immediately
    release([]);
    await Promise.all([first, second]);

    expect(mockLoadRecurringInvoices).toHaveBeenCalledTimes(1);
  });
});
```

- [ ] **Step 2: Run it to verify it fails**

Run: `npx jest __tests__/recurringInvoices.test.ts`
Expected: FAIL — `Cannot find module '../utils/recurringInvoices'`.

- [ ] **Step 3: Create `utils/recurringInvoices.ts`:**

```ts
// utils/recurringInvoices.ts
// Recurring-invoice (maintenance plan) generation engine — a thin mirror of
// utils/recurringJobs.ts over the shared helpers in utils/recurrence.ts.
//
// LOCAL-FIRST INVARIANT: no network in here. Payment links are minted on
// demand by the existing send/outreach flow, exactly like every other
// invoice. Saving through saveInvoices enqueues sync and re-runs
// syncNotifications() automatically, so overdue-dunning applies to generated
// invoices with no extra wiring (isJobDunningEligible passes no-jobId
// invoices through — correct: a maintenance invoice is billable immediately).

import { DateString, Invoice } from '../types/models';
import {
  loadInvoices,
  saveInvoices,
  loadCustomers,
  loadRecurringInvoices,
  saveRecurringInvoices,
  resolveCustomer,
} from './storage';
import { calculateNextDate, isEndConditionMet } from './recurrence';
import { nextInvoiceNumber } from './invoiceNumber';

// Occurrence date + net terms. Same Date construction as calculateNextDate.
function addDays(from: DateString, days: number): DateString {
  const d = new Date(from + 'T00:00:00');
  d.setDate(d.getDate() + days);
  return d.toISOString().split('T')[0];
}

// Invoice ids must stay ALL-DIGITS after the `inv` prefix so invoiceIssueDate
// (utils/pdfTemplates.ts) recovers the issue date from them. A catch-up batch
// can mint several invoices in one millisecond — the monotonic bump keeps ids
// unique without breaking the digits-only rule. Rule linkage lives ONLY in
// recurringInvoiceId, never in the id.
let lastIdMs = 0;
function nextGeneratedInvoiceId(): string {
  let ms = Date.now();
  if (ms <= lastIdMs) ms = lastIdMs + 1;
  lastIdMs = ms;
  return `inv${ms}`;
}

let generating = false;

export async function checkAndGenerateRecurringInvoices(): Promise<void> {
  if (generating) return;
  generating = true;
  try {
    const today = new Date().toISOString().split('T')[0];
    const [rules, invoices, customers] = await Promise.all([
      loadRecurringInvoices(),
      loadInvoices(),
      loadCustomers(),
    ]);
    const newInvoices: Invoice[] = [];
    let anyUpdated = false;

    for (const rule of rules) {
      if (!rule.isActive) continue;

      // Contact snapshot at generation time; blank if the customer is gone —
      // backfillInvoiceContacts heals later, as with any invoice.
      const customer = resolveCustomer(customers, {
        customerId: rule.customerId,
        customerName: rule.customerName,
      });

      while (rule.nextDueDate <= today) {
        if (isEndConditionMet(rule)) {
          rule.isActive = false;
          anyUpdated = true;
          break;
        }

        const newInvoice: Invoice = {
          id: nextGeneratedInvoiceId(),
          customer: rule.customerName,
          customerId: rule.customerId,
          number: nextInvoiceNumber([...invoices, ...newInvoices]),
          amount: rule.amount,
          // due = occurrence date + net terms (NOT generation date): catch-up
          // invoices for missed periods date from when the money was owed and
          // may appear already overdue — correct, mirrors catch-up jobs
          // appearing in the past.
          due: addDays(rule.nextDueDate, rule.dueDays),
          email: customer?.email ?? '',
          phone: customer?.phone ?? '',
          desc: rule.description,
          paid: false,
          recurringInvoiceId: rule.id,
          occurrenceNumber: rule.occurrenceCount + 1,
        };

        newInvoices.push(newInvoice);
        rule.occurrenceCount++;
        rule.lastGeneratedDate = rule.nextDueDate;
        rule.nextDueDate = calculateNextDate(rule.nextDueDate, rule.cadence);
        anyUpdated = true;

        if (isEndConditionMet(rule)) {
          rule.isActive = false;
          break;
        }
      }
    }

    if (newInvoices.length > 0 || anyUpdated) {
      await saveInvoices([...invoices, ...newInvoices]);
      await saveRecurringInvoices(rules);
    }
  } finally {
    generating = false;
  }
}
```

- [ ] **Step 4: Run the suite to verify it passes**

Run: `npx jest __tests__/recurringInvoices.test.ts`
Expected: PASS — 11 tests.

- [ ] **Step 5: Gate** — `npm run typecheck` (0), `npm test` (all pass), `npm run lint` (0).

- [ ] **Step 6: Commit**

```powershell
git add utils/recurringInvoices.ts __tests__/recurringInvoices.test.ts
git commit -m "feat: add recurring-invoice generation engine"
```

---

### Task 5: Run the engine from `AuthContext`

**Files:**
- Modify: `context/AuthContext.tsx` (import block line 8; the `useEffect` at lines 73–85)

**Interfaces:**
- Consumes: `checkAndGenerateRecurringInvoices` from `utils/recurringInvoices.ts` (Task 4).
- Produces: nothing new — generation now runs on sign-in and on every AppState `active`, immediately beside `checkAndGenerateRecurringJobs()`. There is no AuthContext test suite (existing convention); the gate + review verify this task.

- [ ] **Step 1: Add the import.** After line 8 (`import { checkAndGenerateRecurringJobs } from '../utils/recurringJobs';`) add:

```ts
import { checkAndGenerateRecurringInvoices } from '../utils/recurringInvoices';
```

- [ ] **Step 2: Wire both call sites.** Replace the whole `useEffect` (currently lines 73–85) with:

```ts
  useEffect(() => {
    if (session?.user?.id) {
      checkAndGenerateRecurringJobs();
      checkAndGenerateRecurringInvoices();
    }
    const sub = AppState.addEventListener('change', state => {
      if (state === 'active' && session?.user?.id) {
        syncIfOnline(session.user.id).then(() => applyEstimateDecisions()).catch(() => {});
        syncNotifications();
        checkAndGenerateRecurringJobs();
        checkAndGenerateRecurringInvoices();
      }
    });
    return () => sub.remove();
  }, [session]);
```

- [ ] **Step 3: Gate** — `npm run typecheck` (0), `npm test` (all pass, count unchanged from Task 4), `npm run lint` (0 — the effect's dependency array is unchanged, so no exhaustive-deps drift).

- [ ] **Step 4: Commit**

```powershell
git add context/AuthContext.tsx
git commit -m "feat: run recurring-invoice generation on sign-in and app foreground"
```

---

### Task 6: Notification sweep branch + tap routing

**Files:**
- Modify: `utils/notifications.ts` (type import line 4; `Promise.all` block lines 49–58; new loop after the appointments loop, i.e. after line 124 and before the `catch`)
- Modify: `App.tsx` (storage import line 57; new `Invoice` type import; new branch in the response listener after the `appointment_confirm` block, lines 352–358)
- Modify: `__tests__/notifications.test.js` (`seedStorage` lines 23–31; new describe block at end of file)

**Interfaces:**
- Consumes: `RecurringInvoice` type (Task 2); the `recurringInvoices` AsyncStorage key (read RAW with a string literal, exactly like the sweep's other four reads); `openInvoiceId` param on `InvoiceList` (`types/navigation.ts:52` — already exists); `loadInvoices` from the storage barrel.
- Produces: scheduled notifications `identifier: rinv_${rule.id}` with `data: { type: 'recurring_invoice', ruleId }`; a listener branch that navigates to Invoices → InvoiceList (with `openInvoiceId` when the generated invoice is found). Task 7's screen relies on nothing here; this task is independently complete.
- Android channel note: `setupNotifications` (utils/notifications.ts:19–34) is NOT touched — the `invoice-reminders` channel already exists and, matching every existing branch of this sweep, no per-notification `channelId` is passed.

- [ ] **Step 1: Write the failing tests.** In `__tests__/notifications.test.js`:

1a. Replace the `seedStorage` helper (lines 22–31) with:

```js
// Populates AsyncStorage mock so syncNotifications reads the right invoices/settings/jobs/customers/recurring-invoice rules.
function seedStorage(invoices, settings = { rules: [{ days: 1 }] }, jobs = [], customers = [], recurringInvoices = []) {
  AsyncStorage.getItem.mockImplementation((key) => {
    if (key === "invoices") return Promise.resolve(JSON.stringify(invoices));
    if (key === "settings") return Promise.resolve(JSON.stringify(settings));
    if (key === "jobs") return Promise.resolve(JSON.stringify(jobs));
    if (key === "customers") return Promise.resolve(JSON.stringify(customers));
    if (key === "recurringInvoices") return Promise.resolve(JSON.stringify(recurringInvoices));
    return Promise.resolve(null);
  });
}
```

1b. Append a new describe block at the end of the file:

```js
// ── Recurring-invoice (maintenance plan) reminders ───────────────────────────

describe("syncNotifications — recurring-invoice rules", () => {
  function riRule(overrides = {}) {
    return {
      id: "ri1", customerId: "c1", customerName: "Alice",
      description: "Monthly maintenance", amount: 150, dueDays: 30,
      cadence: "monthly", endCondition: "never",
      occurrenceCount: 0, lastGeneratedDate: null,
      nextDueDate: dateInDays(5), isActive: true, createdAt: dateInDays(-30),
      ...overrides,
    };
  }

  test("schedules one rinv_ notification per active rule with the exact content", async () => {
    seedStorage([], { rules: [] }, [], [], [riRule()]);

    await syncNotifications();

    expect(Notifications.scheduleNotificationAsync).toHaveBeenCalledTimes(1);
    const [call] = Notifications.scheduleNotificationAsync.mock.calls;
    expect(call[0].identifier).toBe("rinv_ri1");
    expect(call[0].content.title).toBe("Maintenance invoice ready — Alice");
    expect(call[0].content.body).toBe("Open to review & send.");
    expect(call[0].content.data).toEqual({ type: "recurring_invoice", ruleId: "ri1" });
  });

  test("paused rules schedule nothing", async () => {
    seedStorage([], { rules: [] }, [], [], [riRule({ isActive: false })]);

    await syncNotifications();

    expect(Notifications.scheduleNotificationAsync).not.toHaveBeenCalled();
  });

  test("a rule whose 9am fire time is already past is skipped", async () => {
    seedStorage([], { rules: [] }, [], [], [riRule({ nextDueDate: dateInDays(-1) })]);

    await syncNotifications();

    expect(Notifications.scheduleNotificationAsync).not.toHaveBeenCalled();
  });

  test("shares the 60-notification cap with invoice reminders", async () => {
    const sixty = Array.from({ length: 60 }, (_, i) => ({
      id: `i${i}`, customer: "A", number: `INV-${i}`, paid: false, amount: 100, due: dateInDays(30),
    }));
    seedStorage(sixty, { rules: [{ days: 1 }] }, [], [], [riRule()]);

    await syncNotifications();

    expect(Notifications.scheduleNotificationAsync).toHaveBeenCalledTimes(60);
    const ids = Notifications.scheduleNotificationAsync.mock.calls.map((c) => c[0].identifier);
    expect(ids.some((id) => id.startsWith("rinv_"))).toBe(false);
  });
});
```

- [ ] **Step 2: Run to verify the new tests fail**

Run: `npx jest __tests__/notifications.test.js`
Expected: the 4 new tests FAIL (no notification scheduled / wrong counts); every pre-existing test still PASSES (the seedStorage change only adds a key).

- [ ] **Step 3: Implement the sweep branch.** In `utils/notifications.ts`:

3a. Line 4 — add `RecurringInvoice` to the type import:

```ts
import type { Invoice, Settings, ReminderRule, Job, Customer, RecurringInvoice } from '../types/models';
```

3b. Replace the load block (lines 49–58) with:

```ts
    const [invoicesRaw, settingsRaw, jobsRaw, customersRaw, recurringInvoicesRaw] = await Promise.all([
      AsyncStorage.getItem('invoices'),
      AsyncStorage.getItem('settings'),
      AsyncStorage.getItem('jobs'),
      AsyncStorage.getItem('customers'),
      AsyncStorage.getItem('recurringInvoices'),
    ]);
    const invoices: Invoice[] = invoicesRaw ? JSON.parse(invoicesRaw) : [];
    const settings: Partial<Settings> = settingsRaw ? JSON.parse(settingsRaw) : {};
    const jobs: Job[] = jobsRaw ? JSON.parse(jobsRaw) : [];
    const customers: Customer[] = customersRaw ? JSON.parse(customersRaw) : [];
    const recurringInvoiceRules: RecurringInvoice[] = recurringInvoicesRaw
      ? JSON.parse(recurringInvoicesRaw)
      : [];
```

3c. After the appointments `for` loop closes (line 124) and BEFORE the `} catch {`, insert:

```ts
    // Maintenance-plan (recurring invoice) "review & send" reminders — one
    // per ACTIVE rule, 9:00am on the rule's next generation date. Own
    // identifier namespace (rinv_) beside inv_/appt_; shares the 60 cap.
    // Android reuses the invoice-reminders channel: like every branch above,
    // no per-notification channelId is passed and setupNotifications creates
    // no new channel. The notification is an invitation to open the app —
    // generation itself happens on next open (AuthContext), not here.
    for (const rule of recurringInvoiceRules) {
      if (count >= 60) break;
      if (!rule.isActive) continue;

      const fireDate = new Date(rule.nextDueDate);
      fireDate.setHours(9, 0, 0, 0);
      const secondsUntil = Math.floor((fireDate.getTime() - now.getTime()) / 1000);
      if (secondsUntil <= 0) continue;

      await Notifications.scheduleNotificationAsync({
        identifier: `rinv_${rule.id}`,
        content: {
          title: `Maintenance invoice ready — ${rule.customerName}`,
          body: 'Open to review & send.',
          data: { type: 'recurring_invoice', ruleId: rule.id },
        },
        trigger: { seconds: secondsUntil } as Notifications.NotificationTriggerInput,
      });
      count++;
    }
```

(`new Date(rule.nextDueDate)` + `setHours(9, ...)` deliberately mirrors the invoice branch's `new Date(inv.due)` construction at lines 78–80 — do not "improve" the date handling independently of that branch.)

- [ ] **Step 4: Run to verify all notifications tests pass**

Run: `npx jest __tests__/notifications.test.js`
Expected: PASS — all pre-existing + 4 new.

- [ ] **Step 5: Tap routing in `App.tsx`.**

5a. Line 57 — add `loadInvoices`:

```ts
import { loadSettings, loadInvoices, migrateCustomerIdentity, migrateSampleDataIds, applyEstimateDecisions } from "./utils/storage";
```

5b. After the navigation-types import block (line 28 `} from "./types/navigation";`), add:

```ts
import type { Invoice } from "./types/models";
```

5c. Inside the `addNotificationResponseReceivedListener` callback, after the `appointment_confirm` `if` block (lines 352–358) and before the callback's closing `});`, add:

```ts
      if (data?.type === "recurring_invoice" && data?.ruleId && navigationRef.isReady()) {
        const ruleId = String(data.ruleId);
        // Generation happens on app open (AuthContext), not at tap time — by
        // the time this runs the invoice usually exists; fall back to the
        // plain list when it doesn't yet.
        loadInvoices()
          .then((invoices) => {
            const latest = invoices
              .filter((inv) => inv.recurringInvoiceId === ruleId)
              .reduce<Invoice | null>(
                (best, inv) =>
                  !best || (inv.occurrenceNumber ?? 0) > (best.occurrenceNumber ?? 0) ? inv : best,
                null
              );
            if (!navigationRef.isReady()) return;
            navigationRef.navigate("Main", {
              screen: "Invoices",
              params: {
                screen: "InvoiceList",
                params: latest ? { openInvoiceId: latest.id } : undefined,
              },
            });
          })
          .catch(() => {});
      }
```

(No test file covers the App.tsx listener — true for all three existing branches; owner device smoke covers taps.)

- [ ] **Step 6: Gate** — `npm run typecheck` (0), `npm test` (all pass), `npm run lint` (0).

- [ ] **Step 7: Commit**

```powershell
git add utils/notifications.ts App.tsx __tests__/notifications.test.js
git commit -m "feat: schedule maintenance-invoice notifications and route taps to the invoice list"
```

---

### Task 7: `RecurringInvoicesScreen` + InvoiceList header icon

**Files:**
- Modify: `types/navigation.ts` (`InvoiceStackParamList`, lines 49–55)
- Create: `screens/RecurringInvoicesScreen.tsx`
- Modify: `App.tsx` (screen import after line 52; `InvoicesTab` lines 159–174)

**Interfaces:**
- Consumes: `loadRecurringInvoices`/`saveRecurringInvoices` (Task 2), `syncNotifications` (existing), `formatMoney(amount: number): string` (`utils/format.ts:20`), `Badge`/`EmptyState` (`components/UI.tsx`), `Fab` (`components/Fab.tsx` — props `{ onPress: () => void; accessibilityLabel: string }`), `useRefresh(reload, screen)` (`hooks/useRefresh.ts:5`), `useTheme`, `createStyles` factory pattern.
- Produces:
  - Routes in `InvoiceStackParamList`: `RecurringInvoices: undefined;` and `AddRecurringInvoice: { ruleId?: string };` (BOTH added now so this screen's Edit/Fab navigation typechecks; the Add screen itself lands in Task 8).
  - `screens/RecurringInvoicesScreen.tsx` default export, registered as `RecurringInvoices`.
  - KNOWN MID-BRANCH GAP: until Task 8, tapping Edit or the Fab targets an unregistered route (dev console warning, prod no-op). Do not smoke that path before Task 8.

- [ ] **Step 1: Extend the navigation types.** In `types/navigation.ts`, replace `InvoiceStackParamList` (lines 49–55) with:

```ts
export type InvoiceStackParamList = {
  // openInvoiceId lets other tabs (Today's overdue rows) deep-link straight
  // into a specific invoice's detail modal; the screen clears it after opening.
  InvoiceList: { openInvoiceId?: string } | undefined;
  AddInvoice: { invoiceId?: string; prefill?: Record<string, unknown> };
  Outreach: { invoiceId: string };
  RecurringInvoices: undefined;
  AddRecurringInvoice: { ruleId?: string };
};
```

- [ ] **Step 2: Create `screens/RecurringInvoicesScreen.tsx`:**

```tsx
// screens/RecurringInvoicesScreen.tsx
// Maintenance-plan (recurring invoice) manager — mirror of RecurringJobsScreen
// over RecurringInvoice rules.
//
// DELIBERATE DIVERGENCE from the mirror: this action sheet HAS an Edit action
// (RecurringJobsScreen's sheet is pause/cancel only) because maintenance-plan
// amounts change (price increases) and cancel-and-recreate would reset the
// occurrence history. Do not "fix" this back to parity.
//
// Cancel follows the jobs precedent exactly: soft-deactivate behind a
// destructive confirm. Generated invoices are real receivables — never touched.

import React, { useState, useCallback, useMemo } from "react";
import {
  View,
  Text,
  FlatList,
  TouchableOpacity,
  Alert,
  StyleSheet,
} from "react-native";
import { SafeAreaView } from "react-native-safe-area-context";
import { useFocusEffect } from "@react-navigation/native";
import { loadRecurringInvoices, saveRecurringInvoices } from "../utils/storage";
import { syncNotifications } from "../utils/notifications";
import { Badge, EmptyState } from "../components/UI";
import { Fab } from "../components/Fab";
import { formatMoney } from "../utils/format";
import { spacing, radius, fontSize, fonts } from "../utils/theme";
import type { ColorScheme, ShadowScheme } from "../utils/theme";
import { useTheme } from "../hooks/useTheme";
import { useRefresh } from "../hooks/useRefresh";
import type { RecurringInvoice } from "../types/models";
import type { InvoiceStackScreenProps } from "../types/navigation";

const CADENCE_LABELS: Record<string, string> = {
  daily: "Daily",
  weekly: "Weekly",
  monthly: "Monthly",
  quarterly: "Quarterly",
  annually: "Annually",
};

export default function RecurringInvoicesScreen({ navigation }: InvoiceStackScreenProps<'RecurringInvoices'>) {
  const { colors, shadow } = useTheme();
  const styles = useMemo(() => createStyles(colors, shadow), [colors, shadow]);
  const [rules, setRules] = useState<RecurringInvoice[]>([]);

  useFocusEffect(
    useCallback(() => {
      loadRecurringInvoices().then(setRules);
    }, [])
  );

  const { refreshing, onRefresh } = useRefresh(async () => {
    setRules(await loadRecurringInvoices());
  }, 'RecurringInvoicesScreen');

  function formatEndCondition(rule: RecurringInvoice): string {
    if (rule.endCondition === "count") return `Ends after ${rule.endCount} invoices`;
    if (rule.endCondition === "date") return `Ends ${rule.endDate}`;
    return "No end date";
  }

  async function setActive(rule: RecurringInvoice, isActive: boolean) {
    const updated = rules.map((r) => (r.id === rule.id ? { ...r, isActive } : r));
    await saveRecurringInvoices(updated);
    setRules(updated);
    // Fire-and-forget: rules aren't saved through saveInvoices, so the sweep
    // doesn't rerun on its own — mirror AddInvoiceScreen's explicit call.
    syncNotifications();
  }

  function handleRowPress(rule: RecurringInvoice) {
    Alert.alert(
      rule.customerName,
      `${CADENCE_LABELS[rule.cadence]} · ${formatMoney(rule.amount)} · ${formatEndCondition(rule)}`,
      [
        {
          text: rule.isActive ? "Pause plan" : "Resume plan",
          onPress: () => { setActive(rule, !rule.isActive); },
        },
        {
          // Deliberate divergence from RecurringJobsScreen — see header comment.
          text: "Edit plan",
          onPress: () => navigation.navigate("AddRecurringInvoice", { ruleId: rule.id }),
        },
        {
          text: "Cancel plan",
          style: "destructive" as const,
          onPress: () => {
            Alert.alert(
              "Cancel maintenance plan?",
              "No more invoices will be generated. Invoices already created are not affected.",
              [
                { text: "Keep plan", style: "cancel" },
                {
                  text: "Cancel plan",
                  style: "destructive",
                  onPress: () => { setActive(rule, false); },
                },
              ]
            );
          },
        },
        { text: "Dismiss", style: "cancel" as const },
      ]
    );
  }

  function renderRule({ item: rule }: { item: RecurringInvoice }) {
    return (
      <TouchableOpacity
        style={styles.ruleCard}
        onPress={() => handleRowPress(rule)}
        activeOpacity={0.8}
        accessibilityRole="button"
        accessibilityLabel={`${rule.customerName}, ${formatMoney(rule.amount)} ${CADENCE_LABELS[rule.cadence]}, ${rule.isActive ? "active" : "paused"}`}
      >
        <View style={styles.cardTop}>
          <View style={{ flex: 1, marginRight: spacing.sm }}>
            <Text style={styles.ruleTitle} numberOfLines={1}>{rule.customerName}</Text>
            <Text style={styles.ruleDesc} numberOfLines={1}>{rule.description || "Maintenance plan"}</Text>
          </View>
          <Badge
            label={rule.isActive ? "Active" : "Paused"}
            color={rule.isActive ? "success" : "muted"}
          />
        </View>
        <View style={styles.cardBottom}>
          <Text style={styles.ruleMeta}>
            {CADENCE_LABELS[rule.cadence]} · {formatMoney(rule.amount)} · {rule.occurrenceCount} {rule.occurrenceCount === 1 ? "invoice" : "invoices"} generated
          </Text>
          <Text style={styles.ruleMeta}>{formatEndCondition(rule)}</Text>
        </View>
        {rule.isActive && (
          <Text style={styles.ruleNext}>Next: {rule.nextDueDate}</Text>
        )}
      </TouchableOpacity>
    );
  }

  return (
    <SafeAreaView style={styles.container} edges={["bottom"]}>
      <FlatList
        refreshing={refreshing}
        onRefresh={onRefresh}
        data={rules}
        keyExtractor={(r) => r.id}
        renderItem={renderRule}
        contentContainerStyle={styles.list}
        ListEmptyComponent={
          <EmptyState message={"No maintenance plans yet. Tap + to bill a customer on a schedule."} />
        }
      />
      <Fab
        onPress={() => navigation.navigate("AddRecurringInvoice", {})}
        accessibilityLabel="Add maintenance plan"
      />
    </SafeAreaView>
  );
}

function createStyles(colors: ColorScheme, shadow: ShadowScheme) {
  return StyleSheet.create({
    container: { flex: 1, backgroundColor: colors.background },
    list: { padding: spacing.md, paddingBottom: 120 },
    ruleCard: {
      backgroundColor: colors.surface,
      borderRadius: radius.md,
      padding: spacing.md,
      marginBottom: spacing.sm,
      borderWidth: StyleSheet.hairlineWidth,
      borderColor: colors.border,
      ...shadow.card,
    },
    cardTop: {
      flexDirection: "row",
      alignItems: "center",
      marginBottom: spacing.xs,
    },
    ruleTitle: {
      fontFamily: fonts.bodySemiBold,
      fontSize: fontSize.md,
      color: colors.textPrimary,
    },
    ruleDesc: {
      fontFamily: fonts.bodyRegular,
      fontSize: fontSize.sm,
      color: colors.textSecondary,
      marginTop: 2,
    },
    cardBottom: {
      flexDirection: "row",
      justifyContent: "space-between",
      marginTop: spacing.xs,
    },
    ruleMeta: {
      fontFamily: fonts.mono,
      fontSize: 10,
      color: colors.textMuted,
    },
    ruleNext: {
      fontFamily: fonts.mono,
      fontSize: 10,
      color: colors.accent,
      marginTop: spacing.xs,
    },
  });
}
```

- [ ] **Step 3: Register + header icon in `App.tsx`.**

3a. After line 52 (`import ExportDataScreen ...`) add:

```ts
import RecurringInvoicesScreen    from "./screens/RecurringInvoicesScreen";
```

3b. Replace the `InvoicesTab` body's navigator children (lines 168–172) with — this is the exact JobList header pattern from lines 120–137 (`colors` is already in scope in `InvoicesTab`; `TouchableOpacity` and `Ionicons` are already imported):

```tsx
    <InvoiceStack.Navigator screenOptions={navOpts}>
      <InvoiceStack.Screen
        name="InvoiceList"
        component={InvoicesScreen}
        options={({ navigation }) => ({
          title: "Invoices",
          headerRight: () => (
            <TouchableOpacity
              onPress={() => navigation.navigate("RecurringInvoices")}
              hitSlop={{ top: 8, bottom: 8, left: 8, right: 8 }}
              style={{ paddingLeft: 8 }}
              accessibilityRole="button"
              accessibilityLabel="Recurring invoices"
            >
              <Ionicons name="repeat-outline" size={22} color={colors.accent} />
            </TouchableOpacity>
          ),
        })}
      />
      <InvoiceStack.Screen name="AddInvoice"  component={AddInvoiceScreen} options={{ presentation: "modal" }} />
      <InvoiceStack.Screen name="Outreach"    component={OutreachScreen}   options={{ title: "Outreach" }} />
      <InvoiceStack.Screen
        name="RecurringInvoices"
        component={RecurringInvoicesScreen}
        options={{ title: "Recurring Invoices" }}
      />
    </InvoiceStack.Navigator>
```

- [ ] **Step 4: Gate** — `npm run typecheck` (0), `npm test` (all pass), `npm run lint` (0).

- [ ] **Step 5: Commit**

```powershell
git add types/navigation.ts screens/RecurringInvoicesScreen.tsx App.tsx
git commit -m "feat: add RecurringInvoicesScreen behind an InvoiceList header icon"
```

---

### Task 8: `AddRecurringInvoiceScreen` (create + edit) + registration

**Files:**
- Create: `screens/AddRecurringInvoiceScreen.tsx`
- Modify: `App.tsx` (screen import; one more `InvoiceStack.Screen` registration)

**Interfaces:**
- Consumes: `getOrCreateCustomer(fields): Promise<Customer | null>` (`utils/storage/customers.ts:122` — the ONLY sanctioned customer-creation path; upsert backfills blank contact fields, never clobbers), `loadRecurringInvoices`/`saveRecurringInvoices` (Task 2), `loadCustomers`, `syncNotifications`, shared `Field` (`components/Field.tsx` — props `label/value/onChangeText/placeholder/keyboardType/autoCapitalize/multiline/flex`), `DateTimePickerSheet` (`components/DateTimePickerSheet.tsx` — props `visible/mode/value/title/onChange/onClose`, parent owns string↔Date conversion), `Button` (`components/UI.tsx`), route `AddRecurringInvoice: { ruleId?: string }` (Task 7).
- Produces: the create/edit modal. New rules: `id: ri${Date.now()}`, `occurrenceCount: 0`, `lastGeneratedDate: null`, `nextDueDate = start date` (the FIRST invoice generates ON the start date — unlike AddJobScreen, no record is created at rule creation, so the count starts at 0, not 1). Edits preserve `id`/`occurrenceCount`/`lastGeneratedDate`/`isActive`/`createdAt`. NO generation kick here: a past/today start date generates on the next engine run (spec §8, mirrors recurring jobs).

- [ ] **Step 1: Create `screens/AddRecurringInvoiceScreen.tsx`:**

```tsx
// screens/AddRecurringInvoiceScreen.tsx
// Create / edit a maintenance plan (RecurringInvoice rule). Modal in the
// Invoices stack: navigation.navigate("AddRecurringInvoice", { ruleId }) to
// edit, ...("AddRecurringInvoice", {}) to create.
//
// No invoice is created here. The engine (utils/recurringInvoices.ts)
// generates on its next run — a start date of today or in the past produces
// invoices on the next app open/foreground, mirroring recurring jobs.

import React, { useState, useEffect, useMemo } from "react";
import {
  View,
  Text,
  ScrollView,
  TouchableOpacity,
  StyleSheet,
  Alert,
  KeyboardAvoidingView,
  Platform,
} from "react-native";
import { SafeAreaView } from "react-native-safe-area-context";
import { Ionicons } from "@expo/vector-icons";
import { loadRecurringInvoices, saveRecurringInvoices, loadCustomers, getOrCreateCustomer } from "../utils/storage";
import { syncNotifications } from "../utils/notifications";
import { Button } from "../components/UI";
import Field from "../components/Field";
import { DateTimePickerSheet } from "../components/DateTimePickerSheet";
import { spacing, radius, fontSize, fonts } from "../utils/theme";
import type { ColorScheme, ShadowScheme } from "../utils/theme";
import { useTheme } from "../hooks/useTheme";
import type { RecurrenceCadence, RecurrenceEndCondition, RecurringInvoice } from "../types/models";
import type { InvoiceStackScreenProps } from "../types/navigation";

function todayStr(): string {
  return new Date().toISOString().split("T")[0];
}

function dateObjFromStr(str: string): Date {
  if (!str) return new Date();
  const [y, m, d] = str.split("-").map(Number);
  return new Date(y, m - 1, d);
}

function toDateStr(date: Date): string {
  const y = date.getFullYear();
  const m = String(date.getMonth() + 1).padStart(2, "0");
  const d = String(date.getDate()).padStart(2, "0");
  return `${y}-${m}-${d}`;
}

function displayDate(str: string): string | null {
  if (!str) return null;
  return dateObjFromStr(str).toLocaleDateString("en-US", {
    weekday: "long", month: "long", day: "numeric",
  });
}

export default function AddRecurringInvoiceScreen({ route, navigation }: InvoiceStackScreenProps<'AddRecurringInvoice'>) {
  const { colors, shadow } = useTheme();
  const styles = useMemo(() => createStyles(colors, shadow), [colors, shadow]);
  const { ruleId } = route.params || {};
  const isEditing = !!ruleId;

  const [customer, setCustomer] = useState<string>("");
  const [email, setEmail] = useState<string>("");
  const [phone, setPhone] = useState<string>("");
  const [amount, setAmount] = useState<string>("");
  const [desc, setDesc] = useState<string>("");
  const [dueDays, setDueDays] = useState<string>("30");
  const [cadence, setCadence] = useState<RecurrenceCadence>("monthly");
  const [startDate, setStartDate] = useState<string>(todayStr());
  const [endCondition, setEndCondition] = useState<RecurrenceEndCondition>("never");
  const [endCount, setEndCount] = useState<string>("");
  const [endDate, setEndDate] = useState<string>("");
  const [showStartDatePicker, setShowStartDatePicker] = useState<boolean>(false);
  const [showEndDatePicker, setShowEndDatePicker] = useState<boolean>(false);
  const [existingRule, setExistingRule] = useState<RecurringInvoice | null>(null);
  const [saving, setSaving] = useState<boolean>(false);

  useEffect(() => {
    navigation.setOptions({ title: isEditing ? "Edit Maintenance Plan" : "New Maintenance Plan" });
    if (!isEditing) return;
    (async () => {
      const [rules, customers] = await Promise.all([loadRecurringInvoices(), loadCustomers()]);
      const rule = rules.find((r) => r.id === ruleId);
      if (!rule) {
        Alert.alert("Error", "Maintenance plan not found.");
        navigation.goBack();
        return;
      }
      setExistingRule(rule);
      setCustomer(rule.customerName);
      setAmount(String(rule.amount));
      setDesc(rule.description);
      setDueDays(String(rule.dueDays));
      setCadence(rule.cadence);
      setStartDate(rule.nextDueDate);
      setEndCondition(rule.endCondition);
      setEndCount(rule.endCount != null ? String(rule.endCount) : "");
      setEndDate(rule.endDate ?? "");
      const record = customers.find((c) => c.id === rule.customerId);
      setEmail(record?.email ?? "");
      setPhone(record?.phone ?? "");
    })();
  }, [ruleId, isEditing, navigation]);

  async function handleSave() {
    if (!customer.trim()) {
      Alert.alert("Missing info", "Customer name is required.");
      return;
    }
    const parsedAmount = parseFloat(amount);
    if (!amount.trim() || isNaN(parsedAmount) || parsedAmount <= 0) {
      Alert.alert("Missing info", "Please enter a valid invoice amount.");
      return;
    }
    const parsedDueDays = parseInt(dueDays, 10);
    if (!dueDays.trim() || isNaN(parsedDueDays) || parsedDueDays < 0) {
      Alert.alert("Missing info", "Enter payment terms in days (e.g. 30).");
      return;
    }
    if (endCondition === "count" && (!endCount.trim() || parseInt(endCount, 10) < 1)) {
      Alert.alert("End count required", "Please enter a number of invoices greater than 0.");
      return;
    }
    if (endCondition === "date" && !endDate) {
      Alert.alert("End date required", "Please select an end date for the plan.");
      return;
    }

    setSaving(true);
    // The only sanctioned customer-creation path: upsert by normalized name;
    // blank contact fields backfill, existing values are never clobbered.
    const record = await getOrCreateCustomer({
      name: customer.trim(),
      email: email.trim(),
      phone: phone.trim(),
    });
    const rules = await loadRecurringInvoices();

    const shared = {
      customerId: record?.id ?? "",
      customerName: customer.trim(),
      description: desc.trim(),
      amount: parsedAmount,
      dueDays: parsedDueDays,
      cadence,
      endCondition,
      endCount: endCondition === "count" ? (parseInt(endCount, 10) || 1) : undefined,
      endDate: endCondition === "date" ? endDate : undefined,
      nextDueDate: startDate,
    };

    let updated: RecurringInvoice[];
    if (isEditing && existingRule) {
      // Edit preserves the plan's history (id, occurrenceCount,
      // lastGeneratedDate, isActive, createdAt) — the reason the action sheet
      // offers Edit instead of cancel-and-recreate.
      updated = rules.map((r) => (r.id === existingRule.id ? { ...r, ...shared } : r));
    } else {
      const rule: RecurringInvoice = {
        id: `ri${Date.now()}`,
        ...shared,
        occurrenceCount: 0,
        lastGeneratedDate: null,
        isActive: true,
        createdAt: todayStr(),
      };
      updated = [...rules, rule];
    }

    await saveRecurringInvoices(updated);
    // Fire-and-forget: rules aren't saved through saveInvoices, so the sweep
    // doesn't rerun on its own — mirror AddInvoiceScreen's explicit call.
    syncNotifications();
    setSaving(false);
    navigation.goBack();
  }

  return (
    <SafeAreaView style={styles.container} edges={["bottom"]}>
      <KeyboardAvoidingView
        behavior={Platform.OS === "ios" ? "padding" : undefined}
        style={{ flex: 1 }}
      >
        <ScrollView contentContainerStyle={styles.scroll} keyboardShouldPersistTaps="handled">
          <Field label="Customer name *" value={customer} onChangeText={setCustomer} placeholder="Jane's Bakery" />
          <Field label="Customer email" value={email} onChangeText={setEmail} placeholder="jane@example.com" keyboardType="email-address" autoCapitalize="none" />
          <Field label="Customer phone" value={phone} onChangeText={setPhone} placeholder="(555) 123-4567" keyboardType="phone-pad" />
          <View style={styles.row}>
            <Field label="Amount ($) *" value={amount} onChangeText={setAmount} placeholder="150" keyboardType="decimal-pad" flex />
            <View style={{ width: spacing.md }} />
            <Field label="Due (days)" value={dueDays} onChangeText={setDueDays} placeholder="30" keyboardType="number-pad" flex />
          </View>
          <Field label="Description of work" value={desc} onChangeText={setDesc} placeholder="Monthly maintenance visit" multiline />

          <Text style={styles.fieldLabel}>Repeats</Text>
          <View style={styles.chipRow}>
            {(["daily", "weekly", "monthly", "quarterly", "annually"] as RecurrenceCadence[]).map((c) => (
              <TouchableOpacity
                key={c}
                style={[styles.chip, cadence === c && styles.chipSelected]}
                onPress={() => setCadence(c)}
                accessibilityRole="radio"
                accessibilityLabel={`Repeats ${c}`}
                accessibilityState={{ selected: cadence === c }}
              >
                <Text style={[styles.chipText, cadence === c && styles.chipTextSelected]}>
                  {c.charAt(0).toUpperCase() + c.slice(1)}
                </Text>
              </TouchableOpacity>
            ))}
          </View>

          <View style={styles.fieldGroup}>
            <Text style={styles.fieldLabel}>{isEditing ? "Next invoice date" : "First invoice date"}</Text>
            <TouchableOpacity
              style={styles.pickerBtn}
              onPress={() => setShowStartDatePicker(true)}
              accessibilityRole="button"
              accessibilityLabel={`${isEditing ? "Next" : "First"} invoice date: ${displayDate(startDate)}`}
            >
              <Text style={styles.pickerBtnText}>{displayDate(startDate)}</Text>
              <Ionicons name="calendar-outline" size={16} color={colors.textMuted} style={styles.pickerIcon} />
            </TouchableOpacity>
          </View>

          <Text style={styles.fieldLabel}>Ends</Text>
          <View style={styles.chipRow}>
            {(["never", "count", "date"] as RecurrenceEndCondition[]).map((ec) => (
              <TouchableOpacity
                key={ec}
                style={[styles.chip, endCondition === ec && styles.chipSelected]}
                onPress={() => setEndCondition(ec)}
                accessibilityRole="radio"
                accessibilityLabel={ec === "never" ? "Never ends" : ec === "count" ? "Ends after a number of invoices" : "Ends by date"}
                accessibilityState={{ selected: endCondition === ec }}
              >
                <Text style={[styles.chipText, endCondition === ec && styles.chipTextSelected]}>
                  {ec === "never" ? "Never" : ec === "count" ? "After N invoices" : "By date"}
                </Text>
              </TouchableOpacity>
            ))}
          </View>

          {endCondition === "count" && (
            <Field label="Number of invoices" value={endCount} onChangeText={setEndCount} placeholder="e.g. 12" keyboardType="number-pad" />
          )}

          {endCondition === "date" && (
            <View style={styles.fieldGroup}>
              <View style={styles.pickerLabelRow}>
                <Text style={styles.fieldLabel}>End date</Text>
                {endDate ? (
                  <TouchableOpacity
                    onPress={() => setEndDate("")}
                    accessibilityRole="button"
                    accessibilityLabel="Clear end date"
                  >
                    <Text style={styles.pickerClear}>Clear</Text>
                  </TouchableOpacity>
                ) : null}
              </View>
              <TouchableOpacity
                style={styles.pickerBtn}
                onPress={() => setShowEndDatePicker(true)}
                accessibilityRole="button"
                accessibilityLabel={endDate ? `End date: ${displayDate(endDate)}` : "Select end date"}
              >
                <Text style={endDate ? styles.pickerBtnText : styles.pickerBtnPlaceholder}>
                  {endDate ? displayDate(endDate) : "Select end date…"}
                </Text>
                <Ionicons name="calendar-outline" size={16} color={colors.textMuted} style={styles.pickerIcon} />
              </TouchableOpacity>
            </View>
          )}

          <View style={styles.actions}>
            <Button label="Cancel" variant="ghost" onPress={() => navigation.goBack()} style={{ flex: 1 }} />
            <View style={{ width: spacing.sm }} />
            <Button label={isEditing ? "Save changes" : "Create plan"} onPress={handleSave} loading={saving} style={{ flex: 2 }} />
          </View>
        </ScrollView>
      </KeyboardAvoidingView>

      <DateTimePickerSheet
        visible={showStartDatePicker}
        mode="date"
        title={isEditing ? "Next Invoice Date" : "First Invoice Date"}
        value={dateObjFromStr(startDate)}
        onChange={(date: Date) => setStartDate(toDateStr(date))}
        onClose={() => setShowStartDatePicker(false)}
      />
      <DateTimePickerSheet
        visible={showEndDatePicker}
        mode="date"
        title="End Date"
        value={dateObjFromStr(endDate || todayStr())}
        onChange={(date: Date) => setEndDate(toDateStr(date))}
        onClose={() => setShowEndDatePicker(false)}
      />
    </SafeAreaView>
  );
}

function createStyles(colors: ColorScheme, shadow: ShadowScheme) {
  return StyleSheet.create({
    container: { flex: 1, backgroundColor: colors.background },
    scroll: { padding: spacing.md, paddingTop: spacing.lg, paddingBottom: 160 },
    row: { flexDirection: "row" },
    fieldGroup: { marginBottom: spacing.sm },
    fieldLabel: {
      fontFamily: fonts.bodySemiBold,
      fontSize: fontSize.sm,
      color: colors.textSecondary,
      marginBottom: 5,
    },
    chipRow: {
      flexDirection: "row",
      flexWrap: "wrap",
      gap: spacing.xs,
      marginBottom: spacing.sm,
    },
    chip: {
      paddingHorizontal: spacing.sm,
      paddingVertical: 6,
      borderRadius: radius.sm,
      borderWidth: 1,
      borderColor: colors.border,
      backgroundColor: colors.surface,
    },
    chipSelected: {
      borderColor: colors.accent,
      backgroundColor: colors.accent,
    },
    chipText: {
      fontFamily: fonts.bodyMedium,
      fontSize: fontSize.sm,
      color: colors.textSecondary,
    },
    chipTextSelected: {
      fontFamily: fonts.bodySemiBold,
      color: colors.surface,
    },
    pickerLabelRow: {
      flexDirection: "row",
      justifyContent: "space-between",
      alignItems: "center",
      marginBottom: 5,
    },
    pickerClear: {
      fontFamily: fonts.mono,
      fontSize: 10,
      color: colors.accent,
      textTransform: "uppercase",
      letterSpacing: 0.4,
    },
    pickerBtn: {
      backgroundColor: colors.surface,
      borderRadius: radius.md,
      height: 44,
      paddingHorizontal: spacing.md,
      flexDirection: "row",
      alignItems: "center",
      justifyContent: "space-between",
      borderWidth: StyleSheet.hairlineWidth,
      borderColor: colors.border,
    },
    pickerBtnText: {
      fontFamily: fonts.bodyRegular,
      fontSize: fontSize.md,
      color: colors.textPrimary,
      flex: 1,
    },
    pickerBtnPlaceholder: {
      fontFamily: fonts.bodyRegular,
      fontSize: fontSize.md,
      color: colors.textMuted,
      flex: 1,
    },
    pickerIcon: { marginLeft: spacing.sm },
    actions: { flexDirection: "row", marginTop: spacing.lg },
  });
}
```

- [ ] **Step 2: Register in `App.tsx`.**

2a. After the Task 7 import (`import RecurringInvoicesScreen ...`) add:

```ts
import AddRecurringInvoiceScreen  from "./screens/AddRecurringInvoiceScreen";
```

2b. In `InvoicesTab`, after the `RecurringInvoices` screen registration added in Task 7, add:

```tsx
      <InvoiceStack.Screen
        name="AddRecurringInvoice"
        component={AddRecurringInvoiceScreen}
        options={{ presentation: "modal" }}
      />
```

- [ ] **Step 3: Gate** — `npm run typecheck` (0), `npm test` (all pass), `npm run lint` (0).

- [ ] **Step 4: Commit**

```powershell
git add screens/AddRecurringInvoiceScreen.tsx App.tsx
git commit -m "feat: add AddRecurringInvoiceScreen (create + edit maintenance plans)"
```

---

### Task 9: Docs + final verification

**Files:**
- Modify: `docs/post-launch-feature-roadmap.md` (row at line 30; Phase 6 section at line 124)
- Modify: `README.md` (utils map after line 130; screens map after line 201; known-limitations after the mileage paragraph ending line 377)

**Interfaces:**
- Consumes: everything shipped in Tasks 1–8.
- Produces: docs in sync; the branch left UNMERGED and UNPUSHED for owner smoke. Skill-drift flags to carry into the phase report (do not edit skills yourself unless directed): `tradeready-config-and-flags` (new AsyncStorage key `recurringInvoices`), `tradeready-architecture-contract` (new shared primitives `utils/recurrence.ts`, `utils/invoiceNumber.ts`).

- [ ] **Step 1: Roadmap status.** In `docs/post-launch-feature-roadmap.md`:

1a. Replace line 30:

```
| 6 | Recurring invoices (maintenance plans) | 🔥 | Med | RecurringJobs engine, invoice model | backlog |
```

with:

```
| 6 | Recurring invoices (maintenance plans) | 🔥 | Med | RecurringJobs engine, invoice model | **BUILT** — on feat/recurring-invoices |
```

1b. Immediately after the `## Phase 6 — Recurring invoices (maintenance plans)` heading (line 124), insert:

```
> **STATUS: BUILT 2026-08-01** on `feat/recurring-invoices`. As designed in
> `docs/superpowers/specs/2026-07-31-recurring-invoices-design.md`: standalone
> per-customer rules (amount + cadence + end conditions + pause/resume),
> shared recurrence helpers extracted to `utils/recurrence.ts`, generation on
> sign-in/app-foreground, review-and-send notification (`rinv_` namespace) —
> never auto-sent; payment links mint on demand in the existing send flow.
```

- [ ] **Step 2: README file maps.**

2a. After the `recurringJobs.ts` line (line 130) add:

```
  recurrence.ts                  ← Shared recurrence math (cadence step + end conditions)
  recurringInvoices.ts           ← Recurring invoice (maintenance plan) engine
  invoiceNumber.ts               ← Next-invoice-number rule (INV-%04d)
```

2b. After the `RecurringJobsScreen.tsx` line (line 201) add:

```
  RecurringInvoicesScreen.tsx    ← Maintenance-plan (recurring invoice) manager
  AddRecurringInvoiceScreen.tsx  ← Add / edit maintenance plan
```

- [ ] **Step 3: README known limitations.** After the mileage-trips paragraph (ends line 377, "...one entry in `COLLECTION_TABLES`."), insert a new paragraph:

```
**Recurring-invoice rules are device-local only.** Maintenance-plan rules
(`RecurringInvoice` records, behind the repeat icon on the Invoices tab) are
stored in AsyncStorage only, the same as recurring jobs and mileage trips —
not synced, cleared on sign-out. The invoices they generate are normal
records and sync like any other invoice.
```

- [ ] **Step 4: Full-suite verification (record actuals).**

Run all three, from repo root:
- `npm run typecheck` → 0 errors
- `npm test` → ALL pass. Expect roughly **+38 tests / +4 suites** over the 1433/90 baseline (≈1471 tests / 94 suites) — record the ACTUAL numbers; they become the branch's gate line in the report.
- `npm run lint` → 0 warnings

Then sanity-check the branch shape:

```powershell
git log --oneline master..HEAD
```

Expected: 9 commits (plan doc, recurrence extraction, model+storage, invoiceNumber extraction, engine, AuthContext wiring, notifications+routing, list screen, add/edit screen) plus this docs commit = 10 total.

- [ ] **Step 5: Commit**

```powershell
git add docs/post-launch-feature-roadmap.md README.md
git commit -m "docs: mark roadmap item 6 (recurring invoices) built; document local-only rules"
```

- [ ] **Step 6: STOP.** Do not merge, do not push, do not OTA. Report to the owner with: the gate numbers, the owner smoke checklist from spec §9 (create plan → backdate start → reopen app → invoices generated + notification; send flow → payment link mints on demand; pause stops generation; cancel keeps generated invoices; edit changes amount without resetting history), and the two skill-drift flags listed in this task's Interfaces block.

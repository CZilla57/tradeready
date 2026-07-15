# Invoice Contact-Info Backfill Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fill an invoice's blank denormalized `email`/`phone` from its linked customer, so contact info added to a customer *after* an invoice exists reaches that invoice — repairing manual outreach and the Phase 2 auto-email cron, both of which send to `invoice.email`.

**Architecture:** One pure helper (`backfillInvoiceContacts`) built on the codebase's "backfill blank, never clobber" rule, wired into two existing paths: the idempotent sign-in healing pass (`migrateCustomerIdentity`, heals all existing + cloud-pulled data) and the customer edit save (`AddCustomerScreen`, immediate propagation). Local-first: backfills are AsyncStorage writes that sync in the background; no backend migration; no data-shape change.

**Tech Stack:** React Native / Expo / TypeScript, AsyncStorage, Jest (jest-expo).

## Global Constraints

- **Branch:** `fix/invoice-contact-backfill` (already created off `master`; spec commit `b0e2738`). Do not push without owner approval.
- **No new dependencies; no Expo SDK change.**
- **Verify gate GREEN before every commit:** `npm run typecheck` (0 errors), `npm test` (all pass), `npm run lint` (`--max-warnings=0`).
- **Backfill semantics (exact):** fill `invoice.email`/`invoice.phone` only when the invoice's value is blank/absent AND the linked customer's value is non-blank. **Never overwrite** a non-blank invoice value. Match the invoice's customer by `invoice.customerId` first, else by normalized (trimmed+lowercased) name of `invoice.customer`. Cover **both** email and phone.
- **No backend/Supabase migration and no `types/models.ts` shape change** — `email`/`phone` already exist on `Invoice`; sync stores JSON blobs.
- Reads never wait on network (local-first invariant): the backfill writes AsyncStorage via `saveInvoices`; sync stays off the render path.
- All changed source files stay `.ts`/`.tsx`.

---

## File Structure

- `utils/storage/customers.ts` — add the pure `backfillInvoiceContacts` helper; import `Invoice`; wire the helper into `migrateCustomerIdentity`.
- `__tests__/invoiceContactBackfill.test.js` — unit tests for the pure helper (new).
- `__tests__/customerIdentity.test.js` — extend to cover the migration's new backfill step.
- `screens/AddCustomerScreen.tsx` — backfill after a customer is saved.
- `types/models.ts` — one-line doc note on the `Invoice` contact fields.

---

### Task 1: Pure `backfillInvoiceContacts` helper + unit tests

**Files:**
- Modify: `utils/storage/customers.ts` (add the export + import `Invoice`)
- Test: `__tests__/invoiceContactBackfill.test.js` (create)

**Interfaces:**
- Produces: `backfillInvoiceContacts(invoices: Invoice[], customers: Customer[]) → { invoices: Invoice[]; changed: boolean }`. Tasks 2 and 3 consume it.

- [ ] **Step 1: Write the failing tests**

Create `__tests__/invoiceContactBackfill.test.js`:

```js
// __tests__/invoiceContactBackfill.test.js
// Pure customer→invoice contact backfill: fills a blank invoice email/phone from
// the linked customer, never clobbering a non-blank invoice value.
import { backfillInvoiceContacts } from "../utils/storage";

const cust = (over = {}) => ({ id: "c1", name: "Jane Smith", email: "jane@x.com", phone: "555-1234", address: "", notes: "", ...over });
const inv = (over = {}) => ({ id: "i1", customerId: "c1", customer: "Jane Smith", number: "INV-1", amount: 100, due: "2026-06-01", paid: false, email: "", phone: "", desc: "", ...over });

describe("backfillInvoiceContacts", () => {
  test("fills blank email/phone from the customer matched by customerId", () => {
    const { invoices, changed } = backfillInvoiceContacts([inv()], [cust()]);
    expect(changed).toBe(true);
    expect(invoices[0].email).toBe("jane@x.com");
    expect(invoices[0].phone).toBe("555-1234");
  });

  test("matches by normalized name when the invoice has no customerId", () => {
    const { invoices, changed } = backfillInvoiceContacts(
      [inv({ customerId: undefined, customer: "  jane smith " })],
      [cust()]
    );
    expect(changed).toBe(true);
    expect(invoices[0].email).toBe("jane@x.com");
  });

  test("never clobbers a non-blank invoice value; fills the blank one", () => {
    const { invoices, changed } = backfillInvoiceContacts([inv({ email: "custom@x.com" })], [cust()]);
    expect(changed).toBe(true);
    expect(invoices[0].email).toBe("custom@x.com"); // preserved
    expect(invoices[0].phone).toBe("555-1234");     // filled
  });

  test("leaves an invoice with no matching customer unchanged", () => {
    const { invoices, changed } = backfillInvoiceContacts([inv({ customerId: "cX", customer: "Ghost" })], [cust()]);
    expect(changed).toBe(false);
    expect(invoices[0].email).toBe("");
  });

  test("does nothing when the customer's field is also blank", () => {
    const { changed } = backfillInvoiceContacts([inv()], [cust({ email: "", phone: "" })]);
    expect(changed).toBe(false);
  });

  test("returns changed:false when nothing is fillable (idempotence guard)", () => {
    const { changed } = backfillInvoiceContacts([inv({ email: "jane@x.com", phone: "555-1234" })], [cust()]);
    expect(changed).toBe(false);
  });
});
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `npm test -- invoiceContactBackfill`
Expected: FAIL — `backfillInvoiceContacts` is not exported yet (`TypeError: ... is not a function`).

- [ ] **Step 3: Import `Invoice` in customers.ts**

In `utils/storage/customers.ts`, change the models import:

```ts
import type { Customer, CustomerNotes } from "../../types/models";
```

to:

```ts
import type { Customer, CustomerNotes, Invoice } from "../../types/models";
```

- [ ] **Step 4: Add the pure helper**

In `utils/storage/customers.ts`, add this exported function (place it just above `migrateCustomerIdentity` / the `MigrationResult` interface):

```ts
// Backfill blank invoice contact fields (email/phone) from the linked customer —
// the customer→invoice half of the denormalization sync. Pure, no I/O. Mirrors
// upsertCustomerInList's "backfill blank, never clobber" rule. Matches the
// invoice's customer by customerId first, then by normalized name.
export function backfillInvoiceContacts(
  invoices: Invoice[],
  customers: Customer[],
): { invoices: Invoice[]; changed: boolean } {
  const byId = new Map(customers.map((c) => [c.id, c]));
  const byName = new Map<string, Customer>();
  for (const c of customers) {
    const key = normalizeName(c.name);
    if (key && !byName.has(key)) byName.set(key, c);
  }

  let changed = false;
  const next = invoices.map((inv) => {
    const cust: Customer | undefined =
      (inv.customerId ? byId.get(inv.customerId) : undefined) ||
      byName.get(normalizeName(inv.customer));
    if (!cust) return inv;

    const email = !inv.email && cust.email ? cust.email : inv.email;
    const phone = !inv.phone && cust.phone ? cust.phone : inv.phone;
    if (email === inv.email && phone === inv.phone) return inv;

    changed = true;
    return { ...inv, email, phone };
  });

  return { invoices: changed ? next : invoices, changed };
}
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `npm test -- invoiceContactBackfill`
Expected: PASS (all 6 tests).

- [ ] **Step 6: Run the full gate**

Run: `npm run typecheck` → 0 errors.
Run: `npm test` → all pass.
Run: `npm run lint` → 0 warnings.

- [ ] **Step 7: Commit**

```bash
git add utils/storage/customers.ts __tests__/invoiceContactBackfill.test.js
git commit -m "feat: add backfillInvoiceContacts helper (customer->invoice blank contact fill)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 2: Wire the backfill into `migrateCustomerIdentity`

**Files:**
- Modify: `utils/storage/customers.ts` (`migrateCustomerIdentity`)
- Test: `__tests__/customerIdentity.test.js` (extend the existing `migrateCustomerIdentity` describe block)

**Interfaces:**
- Consumes (Task 1): `backfillInvoiceContacts` (same module, no import needed).

- [ ] **Step 1: Write the failing tests**

In `__tests__/customerIdentity.test.js`, inside the existing `describe("migrateCustomerIdentity", ...)` block, add:

```js
  test("backfills blank invoice contact fields from the linked customer", async () => {
    seed({
      customers: [{ id: "c1", name: "Jane Smith", email: "jane@x.com", phone: "555-1234", address: "", notes: "" }],
      invoices: [{ id: "i1", customerId: "c1", customer: "Jane Smith", email: "", phone: "", amount: 100, paid: false }],
      jobs: [],
      customerNotes: {},
    });

    const result = await migrateCustomerIdentity();
    expect(result.invoicesChanged).toBe(true);

    const [inv] = await loadInvoices();
    expect(inv.email).toBe("jane@x.com");
    expect(inv.phone).toBe("555-1234");
  });

  test("invoice-contact backfill is idempotent on a second run", async () => {
    seed({
      customers: [{ id: "c1", name: "Jane Smith", email: "jane@x.com", phone: "555-1234", address: "", notes: "" }],
      invoices: [{ id: "i1", customerId: "c1", customer: "Jane Smith", email: "", phone: "", amount: 100, paid: false }],
      jobs: [],
      customerNotes: {},
    });

    await migrateCustomerIdentity();
    const second = await migrateCustomerIdentity();
    expect(second.invoicesChanged).toBe(false);
  });
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `npm test -- customerIdentity`
Expected: the new "backfills blank invoice contact fields" test FAILS — `inv.email` is still `""` because the migration doesn't backfill yet. (The idempotence test may pass trivially for now; it will remain green after the change.)

- [ ] **Step 3: Make `nextInvoices` reassignable**

In `utils/storage/customers.ts`, in `migrateCustomerIdentity`, change the step-1 declaration from `const` to `let`:

```ts
  let invoicesChanged = false;
  const nextInvoices = invoices.map((inv) => {
```

to:

```ts
  let invoicesChanged = false;
  let nextInvoices = invoices.map((inv) => {
```

- [ ] **Step 4: Add the backfill step before the saves**

In `migrateCustomerIdentity`, find the save block:

```ts
  if (customersChanged) await saveCustomers(nextCustomers);
  if (invoicesChanged) await saveInvoices(nextInvoices);
  if (jobsChanged) await saveJobs(nextJobs);
```

Insert the backfill step immediately **before** it:

```ts
  // 4. Backfill blank invoice contact fields (email/phone) from the linked
  //    customer — the customer→invoice direction steps 1–3 don't cover (step 1
  //    only flows invoice→customer, then freezes the invoice once it has a
  //    customerId). Runs after customerId stamping so invoices are linked.
  const backfilled = backfillInvoiceContacts(nextInvoices, nextCustomers);
  if (backfilled.changed) {
    nextInvoices = backfilled.invoices;
    invoicesChanged = true;
  }

  if (customersChanged) await saveCustomers(nextCustomers);
  if (invoicesChanged) await saveInvoices(nextInvoices);
  if (jobsChanged) await saveJobs(nextJobs);
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `npm test -- customerIdentity`
Expected: PASS — including the existing tests (the new backfill only fills blanks, so the pre-existing migration assertions are unaffected) and both new tests.

- [ ] **Step 6: Run the full gate**

Run: `npm run typecheck` → 0. `npm test` → all pass. `npm run lint` → 0 warnings.

- [ ] **Step 7: Commit**

```bash
git add utils/storage/customers.ts __tests__/customerIdentity.test.js
git commit -m "feat: migrateCustomerIdentity backfills blank invoice contacts from the customer

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 3: Backfill on customer save (`AddCustomerScreen`) + doc note

**Files:**
- Modify: `screens/AddCustomerScreen.tsx` (imports + backfill after save)
- Modify: `types/models.ts` (one-line doc note on `Invoice`)

**Interfaces:**
- Consumes (Task 1): `backfillInvoiceContacts`, plus `loadInvoices`/`saveInvoices` — all from `../utils/storage`.

- [ ] **Step 1: Extend the storage import**

In `screens/AddCustomerScreen.tsx`, change:

```ts
import { loadCustomers, saveCustomers } from "../utils/storage";
```

to:

```ts
import { loadCustomers, saveCustomers, loadInvoices, saveInvoices, backfillInvoiceContacts } from "../utils/storage";
```

- [ ] **Step 2: Backfill after the customer is saved**

In `AddCustomerScreen.tsx`, in `handleSave`, find the end of the `if (isEditing) { … } else { … }` block, immediately followed by the analytics call:

```ts
      }

      if (!isEditing || !hasRecord) {
        track('customer_created');
      }
```

Insert the backfill between them:

```ts
      }

      // Adding/fixing a customer's contact info should reach their existing
      // invoices' denormalized email/phone (used by OutreachScreen + the Phase 2
      // auto-email cron). Blank-only, never clobbers — see utils/storage/customers.ts.
      // No-op for a brand-new customer with no invoices yet.
      const allInvoices = await loadInvoices();
      const savedCustomers = await loadCustomers();
      const { invoices: fixedInvoices, changed } = backfillInvoiceContacts(allInvoices, savedCustomers);
      if (changed) await saveInvoices(fixedInvoices);

      if (!isEditing || !hasRecord) {
        track('customer_created');
      }
```

- [ ] **Step 3: Add the doc note in models.ts**

In `types/models.ts`, in the `Invoice` interface, add a comment above the `email` field. Find:

```ts
  due: DateString;
  email: string;
  phone: string;
```

Replace with:

```ts
  due: DateString;
  /**
   * Denormalized snapshot of the customer's contact info at creation. Blank
   * fields are backfilled from the linked customer by
   * backfillInvoiceContacts (customers.ts) — via migrateCustomerIdentity on
   * sign-in and on customer save. Non-blank values are never overwritten.
   */
  email: string;
  phone: string;
```

- [ ] **Step 4: Run the full gate**

Run: `npm run typecheck` → 0 errors (the new imports are used; `changed`/`fixedInvoices` are used).
Run: `npm test` → all pass (503+ tests; no screen unit test added — the pure helper is covered by Task 1).
Run: `npm run lint` → 0 warnings.

- [ ] **Step 5: Manual verification note (device/dev build — screen flow not unit-tested)**

Not runnable in this environment; for a later device/dev pass: create a customer with no email → create an invoice for them → edit the customer to add an email + Save → the invoice's Outreach screen now shows that email as the recipient (and, once synced, the auto-email cron would find it eligible).

- [ ] **Step 6: Commit**

```bash
git add screens/AddCustomerScreen.tsx types/models.ts
git commit -m "feat: backfill invoice contacts on customer save; document Invoice contact snapshot

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Definition of Done

- `backfillInvoiceContacts` implemented, exported, and unit-tested (blank-fill by id and by name; never clobbers; unmatched left alone; idempotent).
- `migrateCustomerIdentity` fills blank invoice email/phone from the linked customer, idempotently (existing/cloud data heals on next sign-in), with test coverage.
- Saving a customer immediately backfills their invoices' blank contacts.
- `Invoice` contact-field behavior documented in `types/models.ts`.
- Verify gate green (typecheck 0 / tests pass / lint 0) at every commit; no new dependencies; no backend migration; nothing pushed without owner approval.

## Deviations / notes

- `AddCustomerScreen` has no unit test (consistent with the repo — screen JSX isn't unit-tested here); its logic delegates to the Task-1-tested pure helper. Verified via the full gate + manual device pass.
- Blank-only scope (not propagating changed non-blank values) and healing paid invoices too are intentional per the spec's "Out of scope" section.

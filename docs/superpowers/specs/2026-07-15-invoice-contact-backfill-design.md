# Invoice Contact-Info Backfill — Design

**Date:** 2026-07-15
**Status:** Approved (design), pending implementation plan
**Repo:** `tradeready/` (new branch off `master`, e.g. `fix/invoice-contact-backfill`).

## Problem

`invoice.email` / `invoice.phone` are **denormalized snapshots** of the linked
customer's contact info, captured when the invoice is created. If a customer is
created without an email and the email is added to the customer **later**, the
already-created invoices keep their blank snapshot — nothing ever refreshes it.

Because the whole app sends to the invoice's own stored contact fields
(`OutreachScreen` sends to `invoice.email`; the Phase 2 auto-email cron reads
`invoice.data->>'email'` from Supabase), a blank invoice email silently breaks
**both** manual and automated collection for that invoice, even though the
customer record shows the email correctly. This was found during Phase 2
go-live: a `{scanned:0}` cron run traced to an invoice whose customer email was
added after the invoice existed.

## Root cause (confirmed in code)

- `migrateCustomerIdentity()` (`utils/storage/customers.ts`) — the idempotent
  sign-in healing pass — only flows contact info **invoice → customer** (step 1
  backfills the *customer's* blank fields from the invoice via
  `upsertCustomerInList`, stamps `invoice.customerId`, and then **skips that
  invoice on every future run**). There is no **customer → invoice** direction.
- `AddCustomerScreen.handleSave` (edit branch, ~lines 152–160) updates only the
  `customers` collection; it never touches that customer's existing invoices.

So once an invoice has a `customerId`, its blank `email`/`phone` is frozen.

## Fix

Add the missing **customer → invoice** backfill to the existing machinery,
following the codebase's established **"backfill blank, never clobber"** rule
(`upsertCustomerInList`). No new concepts.

### 1. New pure helper — `utils/storage/customers.ts`

```ts
export function backfillInvoiceContacts(
  invoices: Invoice[],
  customers: Customer[],
): { invoices: Invoice[]; changed: boolean }
```

- Build lookups: customers by `id`, and by normalized (trimmed+lowercased) name.
- For each invoice, resolve its customer by `invoice.customerId` first, else by
  `normalizeName(invoice.customer)`.
- If a customer is found: when `invoice.email` is blank/absent **and** the
  customer's `email` is non-blank, fill it; same for `phone`. **Never** overwrite
  a non-blank invoice value; leave unmatched invoices untouched.
- Return a new array only for changed invoices (map-in-place style) plus a
  `changed` flag. Pure, no I/O — mirrors `upsertCustomerInList`, so both callers
  reuse it and it is cheaply unit-testable. Idempotent: once filled, a re-run
  finds nothing blank → `changed:false` → no write.

### 2. Healing pass — extend `migrateCustomerIdentity()`

After the existing step 1 (which stamps `customerId`, so invoices are linked)
and before the final saves, run `backfillInvoiceContacts(nextInvoices,
nextCustomers)`; fold its `changed` into the existing `invoicesChanged` and use
its returned invoices in the existing `saveInvoices(...)`. This auto-heals **all
existing and cloud-pulled data** — including the current blank invoice — on the
next sign-in, idempotently, with no new flag (the pass is deliberately
flag-free so cloud-pulled records still get healed).

### 3. Edit path — `AddCustomerScreen.handleSave`

After the customer is saved (all branches — including the "promote an
invoice-derived customer" branch, which by definition has existing invoices),
run `backfillInvoiceContacts(await loadInvoices(), <saved customers>)` and
`saveInvoices(...)` if `changed`. This makes adding/fixing a customer's contact
info **immediately** propagate to that customer's unpaid invoices in the same
session (no sign-in wait). The helper is a no-op for a brand-new customer with
no invoices, so running it unconditionally after save is safe.

### 4. Sync & reach

Both callers write through `saveInvoices`, which enqueues the change and
fire-and-forget `trySync()`s it to Supabase (and calls `syncNotifications()`).
So the filled contact info reaches: the Phase 2 cron (`invoice.data->>'email'`),
the manual `OutreachScreen` send path, and any other consumer of
`invoice.email`. Reads never wait on network — the backfill is a local
AsyncStorage write; sync stays off the render path (local-first invariant
preserved).

### 5. Tests

- `__tests__/` unit tests for `backfillInvoiceContacts`: fills a blank invoice
  email/phone from a customer matched by `customerId`; fills when matched only
  by normalized name (no `customerId`); **never** clobbers a non-blank invoice
  value; leaves an invoice with no matching customer unchanged; returns
  `changed:false` when nothing is fillable (idempotence guard).
- Extend `__tests__/customerIdentity.test.js` to assert `migrateCustomerIdentity`
  now fills a blank `invoice.email`/`phone` from the linked customer, and that a
  second run is a no-op (`invoicesChanged:false`).

## Out of scope (deliberate)

- **Propagating a *changed* (non-blank → different) email/phone** to existing
  invoices. This fix fills **blanks only**; correcting a customer's already-set
  contact info will not rewrite invoices that already carry the old value —
  that is the "never clobber" trade-off. A "keep unpaid invoices in sync with
  the customer" behavior would be a separate, more aggressive follow-up.
- **Paid/historical invoices are healed too** (blank-fill is harmless and
  simpler than filtering by status) — this is intentional, not an oversight.
- No backend/Supabase migration and no `types/models.ts` shape change — `email`
  and `phone` already exist on `Invoice`; the sync tables store JSON blobs.
- The customer-rename split residual (section 6 of the architecture contract)
  is unrelated and untouched.

# Web portal editing status and remaining work

Status: **broad editing surface shipped on the merged baseline as of 2026-09-02**.

This document records what the portal can change, the safeguards already implemented, and the work that remains. Read `web/README.md` first for the product surface and local-development instructions.

## Why web editing needs special handling

TradeReady stores each synced business record as an owner-scoped JSON blob:

```text
{ id, user_id, data jsonb, updated_at, deleted }
```

The mobile app, web portal, Stripe webhooks, and Cloudflare Worker can update the same records. Supabase row-level security (RLS) enforces ownership, but it does not merge concurrent JSON changes. Every web operation must preserve fields it does not own and reconcile derived values before it replaces a blob.

## Shipped editing architecture

The current implementation includes these foundations:

- **Dedicated write module**: `web/src/lib/writeRepository.ts` is the only web module allowed to mutate business tables
- **Domain operations**: the module exports named operations instead of a generic table writer
- **Write-boundary validation**: every create and edit operation checks its invariants before it fetches or writes data
- **Server timestamps**: the `set_updated_at` database trigger stamps all twelve synced tables with the database clock
- **Database-based pull cursor**: mobile cursor version 2 advances from returned database timestamps, overlaps five minutes, and drains deterministic 500-row pages
- **Field-scoped conflict detection**: edit operations compare the rendered baseline, submitted fields, and current server row before writing
- **Fresh-row blob merges**: customer, expense, and pricebook saves apply user-changed fields to the current server row
- **Owner checks**: writes include the authenticated `user_id` in their filters
- **Tombstones**: deletion sets `deleted: true` instead of issuing a database `DELETE`
- **Post-write refresh**: screens reload affected collections after successful mutations
- **Failure visibility**: forms remain open and display an error when validation or a write fails
- **Mutation tests**: repository and screen tests cover validation, failure paths, preservation rules, concurrency, and derived values

Web writes no longer send `updated_at`; the database trigger owns the column for inserts, updates, and tombstones. Mobile can stop sending its redundant timestamp later without coordinating with the web portal.

## Shipped product surfaces

The editing rollout is complete for the planned browser-first scope:

| Domain | Shipped operations | Important boundary |
| --- | --- | --- |
| Invoices | Create manual invoice; edit six invoice-owned fields; record payment; mark balance paid; void payment; delete | Manual invoices do not include the mobile create-from-job billable snapshot |
| Customers | Create; edit contact details and notes; archive; delete | Jobs and invoices keep their denormalized customer data after deletion |
| Jobs | Create unpriced lead; edit operational details and schedule; archive; delete | New jobs start as leads and use pricing defaults from Settings |
| Job status | Start a scheduled job; mark an in-progress job complete | The portal does not run mobile auto-invoice or review-request side effects |
| Estimate pricing | Edit labor, materials, direct costs, markup, overhead, and margin | Editing stops after a customer approval decision exists |
| Calendar | Assign a date and optional time range to an unscheduled job | No drag-and-drop calendar editor |
| Pricebook | Create, edit, or delete services; author materials and pricing | Direct-cost authoring remains limited to job estimates |
| Expenses | Create, edit, or delete | Receipt and import metadata round-trip without a web editor |
| Settings | Edit profile, pricing, invoicing, automation, schedule, blackouts, and payment notes | Stripe provider setup and booking configuration remain mobile-owned |
| Maintenance plans | Create; edit recurrence and invoice settings; pause; resume; delete | Customer relinking is not supported |
| Recurring jobs | Create; edit pricing, materials, and recurrence; pause; resume; delete | Direct-cost lines round-trip but are not editable here |

Today remains a derived dashboard. Money totals are derived, while expense records are editable.

## Shipped data-integrity safeguards

The portal applies stronger controls where server or mobile processes also edit a record.

### Validate every mutation at the write boundary

Screens provide inline validation for the owner, but `writeRepository.ts` is the authoritative boundary. Its validation helpers reject invalid amounts, pricing inputs, materials, recurrence limits, settings patches, and schedules before any fetch or write.

Typed inputs do not replace runtime validation. A future caller cannot persist malformed values by bypassing a screen.

### Detect field-level editing conflicts

Each edit receives the baseline entity displayed by the screen. The write layer compares that baseline with the submitted values and a freshly fetched server row.

`StaleWriteError` rejects the operation only when both the owner and another writer changed the same field to different values. Server-only changes continue through the existing merge behavior. Customer, expense, and pricebook saves also merge user-changed fields onto the fresh row instead of replacing it with the stale form snapshot.

Pure creates and boolean toggles do not use the three-way guard. A create has no baseline, and the current toggle operations apply their explicit target state to a fresh row.

### Preserve invoice payment history

Invoice writes load the authoritative row, merge payment ledgers, and recalculate `paid` and `paidAt`. `updateInvoiceDetails` assigns only these form-owned fields:

- `number`
- `amount`
- `due`
- `description`
- `email`
- `phone`

Payment history, line items, delivery state, payment-link metadata, recurrence metadata, and customer links remain server-owned during this edit.

### Protect estimate consent

`updateJobPricing` reloads the job and rejects pricing changes after `approval.decision` becomes approved or declined. The final Supabase update also requires the JSON approval decision to remain absent. This condition closes the race between the reload and the write.

The editor changes pricing fields only. Approval, change orders, time sessions, status, invoice links, and other job fields survive from the server row.

### Protect recurring generation state

Recurring forms retain the originally displayed `nextDueDate`. The write operation compares that original value with the submitted value:

- If the form did not change the date, a newer server date wins
- If the form changed the date, the submitted date wins

This rule prevents an open browser form from restoring an older generation cursor and creating duplicate work. Recurring operations also preserve `occurrenceCount` and `lastGeneratedDate`.

### Reconcile derived pricing state

Web-safe pricing utilities recalculate estimate totals for jobs, recurring jobs, and pricebook services. Invoice utilities reconcile payment-derived fields.

Changing `laborHours` clears a stale `laborBreakdown`. Schedule assignment advances an approved job to scheduled without regressing later statuses.

### Preserve settings and secrets

`saveSettings` merges onto the current server blob and removes every field listed in `SECURE_FIELDS`. `saveSchedule` deep-merges the nested schedule so mobile-owned booking fields survive web edits.

## Current concurrency boundary

The portal has no offline write queue or row-level version lock. A failed browser request remains failed until the owner retries it.

Field-scoped optimistic concurrency now detects the primary lost-update case: another writer changes a field that the owner also changed. Server-only changes to unrelated fields continue through the fresh-row merge. Operations that intentionally own a group of fields can still replace server changes within that owned group, and open tabs do not update through Supabase Realtime.

Do not add a generic `write(table, id, data)` helper. New mutations must meet this definition of done:

1. Add a typed domain operation in `writeRepository.ts`
2. Validate runtime values before fetching or writing
3. Accept the rendered baseline for an edit and detect same-field conflicts
4. Load the current row when another client or backend can update the record
5. Assign only the fields owned by the form
6. Reconcile derived values and append-only history
7. Preserve tombstone and owner-scoping semantics
8. Disable repeat submission, show failures, and refresh after success
9. Add repository and screen tests for validation, races, and hidden-field preservation

## Remaining product work

The remaining work is primarily backend-dependent workflow or a new product surface.

### Estimate and invoice workflow

The portal can author an estimate before a customer decision, but it cannot complete these Cloudflare Worker-backed actions:

- Send an estimate and create its customer approval link
- Record a change order
- Revise pricing after a declined or approved decision
- Drive consent-coupled status transitions
- Create an invoice from a job's tracked time, estimate lines, and approved change orders

A create-from-job invoice needs a browser-safe port of the billable-breakdown rules in `utils/autoInvoice.ts`. It must preserve the same accounting snapshot as mobile.

### Mobile-only and unsurfaced areas

The current web portal does not show or edit these areas:

- Trips and mileage
- AI Coach
- Job photos
- Booking requests and their server-appended history
- Stripe onboarding and provider selection
- Online-booking slot settings

If booking requests become editable, treat their history like the invoice payment ledger: load the current server record and merge append-only events.

### Optional hardening and cleanup

The following items improve resilience but do not block the current editing surface:

- Add stronger atomic database conditions to any domain where field-scoped client checks are insufficient
- Stop sending client-generated `updated_at` values from mobile now that the database trigger owns timestamps
- Add direct-cost authoring to pricebook and recurring-job editors if owners need it
- Add multi-tab or Realtime refresh if stale open tabs become a support issue

## Files that constrain future work

| File | Contract |
| --- | --- |
| `utils/sync.ts` | Whole-blob push, tombstones, and paged database-timestamp pull cursor |
| `utils/syncMerge.ts` | Invoice-ledger and booking-history union rules |
| `utils/storage/keys.ts` | Credential fields that must never enter synced settings |
| `utils/autoInvoice.ts` | Mobile create-from-job billable-breakdown rules |
| `web/src/lib/repository.ts` | Read-only Supabase access |
| `web/src/lib/writeRepository.ts` | Validation, conflict detection, and all web business-data mutations |
| `web/src/lib/readOnly.arch.test.ts` | Static enforcement of the read/write boundary |
| `web/src/lib/DataContext.tsx` | Scoped loading and post-write refresh |
| `web/src/ui/invoiceMath.ts` | Invoice payment and paid-state reconciliation |
| `web/src/ui/pricingMath.ts` | Browser-safe estimate calculations |
| `web/src/ui/changeOrderMath.ts` | Change-order amount calculations for display |
| `supabase/migrations/20260803_local_collections_sync.sql` | Synced tables and owner RLS policies |
| `supabase/migrations/20260831_updated_at_server_authority.sql` | Database-owned `updated_at` trigger |

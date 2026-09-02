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
- **Server timestamps**: the `set_updated_at` database trigger stamps all twelve synced tables with the database clock
- **Database-based pull cursor**: mobile cursor version 2 advances from returned database timestamps, overlaps five minutes, and drains deterministic 500-row pages
- **Owner checks**: writes include the authenticated `user_id` in their filters
- **Tombstones**: deletion sets `deleted: true` instead of issuing a database `DELETE`
- **Post-write refresh**: screens reload affected collections after successful mutations
- **Failure visibility**: forms remain open and display an error when a write fails
- **Mutation tests**: repository and screen tests cover validation, failure paths, preservation rules, and derived values

The database trigger makes client-supplied `updated_at` values redundant. Removing those values from web and mobile writes remains optional cleanup.

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

Changing `laborHours` clears a stale `laborBreakdown` unless the stored breakdown still matches. Schedule assignment advances an approved job to scheduled without regressing later statuses.

### Preserve settings and secrets

`saveSettings` merges onto the current server blob and removes every field listed in `SECURE_FIELDS`. `saveSchedule` deep-merges the nested schedule so mobile-owned booking fields survive web edits.

## Current concurrency boundary

The portal has no offline write queue and no universal optimistic concurrency token. A failed browser request remains failed until the owner retries it.

High-risk operations use a current server row, and estimate pricing has an atomic approval condition. Other whole-record edits can still be last-write-wins when two clients change the same record at nearly the same time. Future hardening should add an `updated_at` precondition or a server-side patch function where a domain needs conflict detection.

Do not add a generic `write(table, id, data)` helper. New mutations must meet this definition of done:

1. Add a typed domain operation in `writeRepository.ts`
2. Load the current row when another client or backend can update fields on that record
3. Assign only the fields owned by the form
4. Reconcile derived values and append-only history
5. Preserve tombstone and owner-scoping semantics
6. Disable repeat submission, show failures, and refresh after success
7. Add repository and screen tests for validation, races, and hidden-field preservation

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

- Add optimistic concurrency checks to domains that still use last-write-wins saves
- Stop sending client-generated `updated_at` values now that the database trigger owns timestamps
- Add direct-cost authoring to pricebook and recurring-job editors if owners need it
- Add multi-tab or realtime refresh if stale open tabs become a support issue

## Files that constrain future work

| File | Contract |
| --- | --- |
| `utils/sync.ts` | Whole-blob push, tombstones, and paged database-timestamp pull cursor |
| `utils/syncMerge.ts` | Invoice-ledger and booking-history union rules |
| `utils/storage/keys.ts` | Credential fields that must never enter synced settings |
| `utils/autoInvoice.ts` | Mobile create-from-job billable-breakdown rules |
| `web/src/lib/repository.ts` | Read-only Supabase access |
| `web/src/lib/writeRepository.ts` | Only allowed web business-data mutation module |
| `web/src/lib/readOnly.arch.test.ts` | Static enforcement of the read/write boundary |
| `web/src/lib/DataContext.tsx` | Scoped loading and post-write refresh |
| `web/src/ui/invoiceMath.ts` | Invoice payment and paid-state reconciliation |
| `web/src/ui/pricingMath.ts` | Browser-safe estimate calculations |
| `web/src/ui/changeOrderMath.ts` | Change-order amount calculations for display |
| `supabase/migrations/20260803_local_collections_sync.sql` | Synced tables and owner RLS policies |
| `supabase/migrations/20260831_updated_at_server_authority.sql` | Database-owned `updated_at` trigger |

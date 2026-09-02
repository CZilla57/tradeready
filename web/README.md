# TradeReady web portal

The TradeReady web portal gives a business owner browser access to the same account and business records used by the mobile app. The target production origin is `https://app.gettradereadyapp.com`.

The portal is a Vite, React, and TypeScript single-page application (SPA). It does not run the React Native app. It reuses the canonical models in `../types/models.ts` and browser-safe utilities in `../utils/*` through the `@shared` alias.

## How the portal shares data with mobile

The portal authenticates against the same Supabase project as the mobile app. Each synced collection uses owner-scoped rows:

```text
{ id, user_id, data jsonb, updated_at, deleted }
```

The `settings` table uses `user_id` as its key. Supabase row-level security (RLS) restricts every read and write to `auth.uid() = user_id`. The public Supabase publishable key identifies the project; the authenticated session and RLS policies enforce ownership.

Browser and mobile sessions are separate. Both clients read and write the same cloud records after they authenticate.

## Current product surface

The portal supports these routes and actions:

| Area | Read surface | Editing surface |
| --- | --- | --- |
| Authentication | Existing session and recovery state | Email signup, email/password sign-in, Google OAuth, Apple OAuth, password reset |
| Today | Scheduled work, collected revenue, and outstanding totals | Derived dashboard only |
| Calendar | Weekly schedule, work-day shading, blackouts, and unscheduled jobs | Assign a date and optional time range to an unscheduled job |
| Jobs | Filters, status timeline, customer, invoice, materials, direct costs, and pricing | Create a lead; edit operational details, schedule, pricing, materials, and direct costs; advance supported statuses; archive or delete |
| Estimates | Estimate-stage jobs, sent line items, approval state, signer, change orders, and billable total | Edit pricing before a customer approval decision exists |
| Invoices | Filters, status, payment ledger, and line items | Create a manual invoice; edit invoice details; record, void, or complete payments; delete |
| Customers | Contact details, notes, job history, invoice history, revenue, and amount owed | Create, edit, archive, or delete |
| Money | Collected revenue, expenses, net income, outstanding balances, and a six-month chart | Create, edit, or delete expenses |
| Recurring | Recurring jobs and maintenance plans with cadence, generation state, and next due date | Create, edit, pause, resume, or delete |
| Pricebook | Services, materials, labor, pricing, and margins | Create, edit, or delete services |
| Settings | Business profile, pricing, invoicing, schedule, payments, and automation | Edit profile, pricing defaults, invoicing options, payment notes, work schedule, blackouts, and automation toggles |

The authenticated route map lives in `src/App.tsx`. All business-data mutations live in `src/lib/writeRepository.ts`.

## Data-integrity rules for editing

The mobile sync model replaces complete JSON blobs. A browser edit built from stale state could overwrite data created by another device or a backend process. The portal uses these rules to reduce that risk:

- **Typed operations**: screens call domain functions such as `updateInvoiceDetails` and `scheduleJob`; there is no generic table writer
- **Separate read and write modules**: `repository.ts` contains reads, while `writeRepository.ts` is the only allowed Supabase business-data mutation module
- **Owner-scoped writes**: every operation includes both the record ID and the authenticated owner ID
- **Server-row refreshes**: high-risk invoice, job, recurring, schedule, and settings operations load the current row before applying owned fields
- **Ledger preservation**: invoice writes merge payment activity and reconcile `paid` and `paidAt`
- **Consent protection**: estimate pricing checks the current approval decision and applies an atomic database condition before writing
- **Recurring cursor protection**: an unchanged form cannot restore an older `nextDueDate` after generation advances it
- **Derived-value reconciliation**: invoice totals, estimate totals, schedule-coupled status, and labor breakdown state are updated with their source inputs
- **Soft deletion**: deletes write a `deleted: true` tombstone so mobile sync can remove the record without resurrecting it later
- **Secret stripping**: settings writes preserve unknown fields and remove every field listed in `SECURE_FIELDS`

The architecture test in `src/lib/readOnly.arch.test.ts` enforces the single-write-module boundary. Mutation behavior is covered in `src/lib/writeRepository.test.ts` and the related screen tests.

### Current concurrency boundary

The portal does not have the mobile app's durable offline mutation queue. Web writes require a connection, disable repeat submission while saving, show failures, and reload the affected collection after success.

The portal also does not have universal optimistic concurrency control. High-risk operations refresh the server row, and estimate pricing adds an atomic approval guard. Lower-risk whole-record edits can still use last-write-wins behavior when two clients edit the same record at the same time. See `EDITING_ROADMAP.md` for the remaining hardening work.

## Password recovery

The recovery flow prevents a password-recovery session from entering the business portal before the password changes:

1. **Forgot password?** calls `resetPasswordForEmail` with `<origin>/reset-password`
2. Supabase returns the browser to `/reset-password` and creates a recovery session
3. `AuthContext` stores recovery state in React state and `localStorage` so reloads and reopened tabs remain in recovery mode
4. `App` routes every path to the password screen until the password changes or the session ends
5. A successful update signs the account out and redirects to `/login`

Invalid or expired recovery links show an error and direct the visitor back to the reset request form.

## Features not available on the web

The current portal does not surface these mobile or backend-dependent areas:

- Mileage and Trips
- AI Coach
- Job photos
- Booking requests
- Sending an estimate or creating its customer approval link
- Authoring change orders
- Creating an invoice from a job's full billable breakdown
- Mobile automations that run when a job is marked complete, including auto-invoice and review scheduling

Manual invoices are available. They do not replace the mobile create-from-job workflow because that workflow snapshots tracked time, estimate lines, and approved change orders.

## Run the portal locally

Install the standalone web dependencies and start Vite:

```powershell
npm.cmd --prefix web install
npm.cmd --prefix web run dev
```

Vite serves the portal at `http://localhost:5173`. Sign in with a TradeReady account that has synced data.

Use these commands to verify a change:

```powershell
npm.cmd --prefix web run lint
npm.cmd --prefix web test
npm.cmd --prefix web run typecheck
npm.cmd --prefix web run build
```

The `web` package has its own ESLint, Vitest, TypeScript, and Vite configuration. The repository gate runs these checks independently from the Expo and React Native checks.

### Data-loading behavior

`DataContext` loads each Supabase collection independently. A failed pricebook request, for example, does not block a screen that only needs jobs or invoices.

Each screen declares the resources it needs through `useResources`. Initial failures show a scoped retry action. Refresh failures keep previously loaded data visible. Signing out clears all account data and invalidates requests started under the previous session.

`vite.config.ts` supplies `esbuild.tsconfigRaw` as a string. This prevents Vite from resolving the Expo root TypeScript configuration while compiling browser-safe shared utilities.

## Deploy the portal

`npm.cmd --prefix web run build` creates the static SPA in `web/dist`. The host must serve `index.html` for unknown paths so client-side routes and `/reset-password` work on a fresh visit.

Configure these external services before production use:

1. Point `app.gettradereadyapp.com` to the host that serves `web/dist`
2. Add `https://app.gettradereadyapp.com` and `https://app.gettradereadyapp.com/reset-password` to the Supabase Auth redirect allowlist
3. Configure the Google and Apple OAuth providers in Supabase and their provider dashboards for the production origin and Supabase callback URL
4. Verify email/password sign-in, both OAuth providers, password recovery, one read flow, and one write flow against a test account

The portal needs only the public Supabase project URL and publishable key in its browser bundle. Never add a service-role key or provider secret to `web/src`.

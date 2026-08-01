# Manual Review-Request Path on Job Detail — Design

**Date:** 2026-07-31
**Status:** Approved by owner (brainstorm 2026-07-31); ready for implementation planning.

## Problem

The review-request feature (Settings → "Automatically prompt customers for a Google review after you complete a job") has exactly one entry point: the local notification scheduled when a job is advanced to `complete` from JobDetailScreen. If that notification is missed, dismissed, never scheduled (toggle off, customer had no phone/email at the time, job completed before the feature existed), or the moment has passed, there is no way to send a review request at all:

- JobDetailScreen's `paid` status action is an inert ghost button (`"Job complete — Paid ✓"`, empty `onPress`) — `screens/JobDetailScreen.tsx:546-550`.
- ReviewRequestScreen renders **blank** (`return null`) for any job without a stored `ReviewRequestRecord`, because `message` only builds from a record — `screens/ReviewRequestScreen.tsx:54-68,119`.
- The screen's own Skip alert promises "You can always send it later from the job detail" — a path that was never built.
- `getPendingReviewRequests()` in `utils/reviewRequest.ts` is exported but unused (out of scope here; noted for a possible future Today-tab card).

Now that jobs actually reach `paid` (FA-038 fix, merged `d236a94`), the dead end is user-visible.

## Owner decisions (locked)

1. **Placement:** repurpose the inert paid status button as the CTA **and** add a secondary action visible at `complete`/`invoiced`.
2. **Re-send:** keep the one-shot block — once sent, the screen only shows the sent card; no send-again.
3. **Approach:** reuse ReviewRequestScreen with a no-record fallback; no inline-compose duplication; no Today-tab pending card (deferred).

## Design

### 1. JobDetailScreen entry points

- **`PrimaryAction` `paid` entry** (`screens/JobDetailScreen.tsx:546-550`): replace the inert entry.
  - Not yet sent → `{ label: "Request a review", onPress: () => navigation.navigate("ReviewRequest", { jobId: job.id, source: "job_detail" }), variant: "primary" }`.
  - Already sent (`record.sentAt` set) → label `"Review request sent ✓"`, variant `"ghost"`, still navigates (screen shows the sent card).
  - `PrimaryAction` gains a `reviewSent: boolean` prop.
- **New `ReviewRequestAction` component** (same file, mirroring `DepositAction`'s shape at `screens/JobDetailScreen.tsx:566-589`): renders a secondary `"Request review →"` button when `job.status` is `complete` or `invoiced` **and** the request has not been sent; hidden otherwise (including once sent). Navigates identically.
- **Sent-state loading:** JobDetail's focus-effect `load()` additionally fetches `getReviewRequestRecord(jobId)` and stores `reviewSent` in state (`!!record?.sentAt`). It already loads jobs/customers/invoices; this is one more parallel local read.
- **The manual path ignores `settings.reviewRequestEnabled`.** That toggle governs only the automatic notification; a manual tap must always work. It uses the same `reviewRequestTemplate` and `googleReviewLink`.

### 2. ReviewRequestScreen no-record fallback

- Load `loadJobs()` and `loadCustomers()` alongside settings and the record.
  - **Record exists:** behave exactly as today (record snapshot drives name/phone/email; sent state from `sentAt`).
  - **No record:** find the job by `jobId`, resolve its customer with the shared `resolveCustomer(customers, job)` from `utils/storage`, and populate name/phone/email from the **current** customer record. Build the message with the customer's name.
  - **No record and job or customer unresolvable:** render the shared `EmptyState` ("Job not found" / "This job has no customer to ask") instead of today's silent `return null`. The `return null` guard remains only for the initial loading frame.
- **Sending with no record creates one.** `markReviewRequestSent` gains an optional second parameter:
  `markReviewRequestSent(jobId, fallback?: { customerId, customerName, customerPhone, customerEmail })` — when no record matches `jobId` and `fallback` is provided, append `{ jobId, ...fallback, scheduledAt: now, sentAt: now }`; when a record exists, update `sentAt` as today. The screen passes the fallback only in the no-record case.
- Customer with neither phone nor email: existing behavior already handles it (no send buttons; Copy message still available). Copying does not mark sent — unchanged.

### 3. Reconciliation with the auto flow

- **Cancel the pending auto-notification on send:** inside `markReviewRequestSent`, call `Notifications.cancelScheduledNotificationAsync(\`review_${jobId}\`)` (the identifier used at `utils/reviewRequest.ts:81`), wrapped so a failure cannot break the save (`.catch(() => {})`). Cancelling an unscheduled/already-fired identifier is a no-op. This prevents the "Time to ask for a review!" nag after a manual send inside the delay window.
- **Analytics source:** `ReviewRequest` route params become `{ jobId: string; source?: "notification" | "job_detail" }` (`types/navigation.ts:46`). App.tsx's notification-response handler passes `source: "notification"` (`App.tsx:316-320`); JobDetail passes `"job_detail"`. `track('review_request_sent', { channel, source })` — `source` defaults to `"notification"` when the param is absent (old scheduled notifications carry no param).
- Everything else in the auto flow is untouched: scheduling still happens only on the JobDetail advance-to-`complete` transition, with the same guards.

### 4. Constraints

- Local-first: every read/write in this feature is AsyncStorage; no network on any path (architecture contract §1).
- No persisted synced-shape changes: `ReviewRequestRecord` stays local-only under the `review_requests` AsyncStorage key; Settings shape unchanged; `types/models.ts` untouched.
- No new dependencies; no `utils/sync.ts` changes; no `eslint-disable`/`@ts-ignore`.
- No navigation registration changes — `ReviewRequest` is already in JobStack (`App.tsx:150`), and JobDetail lives in the same stack.
- Shared primitives only: `Button`, `EmptyState`, `resolveCustomer`, `composeSMS`/`composeEmail` (already used by the screen).

### 5. Testing

- Extend `__tests__/reviewRequest.test.js` (exists):
  - `markReviewRequestSent` with fallback creates a record when none exists (sentAt set, fields copied).
  - `markReviewRequestSent` without fallback still updates an existing record and leaves others alone.
  - `markReviewRequestSent` cancels the scheduled notification with identifier `review_<jobId>` (expo-notifications is already mocked in jest.setup.js — verify the mock exposes `cancelScheduledNotificationAsync`; add it if absent).
  - `buildReviewMessage`/`reviewMessageMissingLink` behavior unchanged (existing cases keep passing).
- No screen render tests (repo precedent: screens have no RNTL harness).
- Full gate green before every commit: `npm run typecheck` 0 / `npm test` all pass (1358 baseline) / `npm run lint` 0.

### 6. Device smoke checklist (owner, Expo Go)

1. Paid job → "Request a review" (primary) → preview shows current customer info → Send via SMS/Email opens composer → return: JobDetail button now reads "Review request sent ✓" (ghost).
2. Complete or invoiced job → secondary "Request review →" visible → send → button disappears; re-entering the screen shows the sent card (one-shot block).
3. Pre-FA-038 paid job that never had a notification scheduled (no record) → screen shows a real preview (not blank), send works.
4. Clear `googleReviewLink` in Settings with the template still containing `{googleReviewLink}` → screen shows the "Add your Google review link" warning card, send blocked (existing behavior, now reachable manually).
5. Mark a job complete, then send the review manually within the delay window → the auto notification never arrives.
6. Auto flow regression: complete a job (toggle on, customer has phone), wait out the delay → notification arrives and still opens the screen correctly.

## Out of scope (explicitly)

- Today-tab pending-reviews card (`getPendingReviewRequests` stays unused).
- Send-again / multi-nudge flows.
- Syncing review records across devices.
- Any change to the auto-scheduling trigger conditions.

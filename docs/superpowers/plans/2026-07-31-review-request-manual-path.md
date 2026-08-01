# Manual Review-Request Path Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give paid/complete/invoiced jobs a manual "Request review" path on JobDetail, and fix ReviewRequestScreen's blank render for jobs that never had an auto-request scheduled.

**Architecture:** Reuse the existing ReviewRequestScreen (already registered in JobStack) as the single review-sending surface. JobDetail gains two entry points: the inert paid status button becomes the CTA, and a `DepositAction`-style secondary button covers `complete`/`invoiced`. The screen gains a no-record fallback that builds the preview from the job's current customer (`resolveCustomer`), and `markReviewRequestSent` becomes an upsert that also cancels the pending auto-notification so a manual send can't be followed by the automatic nag. Spec: `docs/superpowers/specs/2026-07-31-review-request-paid-jobs-design.md`.

**Tech Stack:** TypeScript, React Native (Expo 54), Jest plain `.js` unit tests (no RNTL), expo-notifications local notifications, AsyncStorage (local-only records).

## Global Constraints

- Gate green before every commit, from `C:\Users\Chadr\OneDrive\Documents\TraderPro App\tradeready`: `npm run typecheck` 0 errors / `npm test` all pass (1358 baseline + new) / `npm run lint` 0 warnings.
- NO dependency, SDK, or `app.json` changes. No `eslint-disable` / `@ts-ignore` / `@ts-expect-error`.
- NO synced data-shape changes: `types/models.ts` untouched; `ReviewRequestRecord` stays local-only under the `review_requests` AsyncStorage key; `utils/sync.ts` untouched.
- No navigation registration changes — `ReviewRequest` is already in JobStack (App.tsx:150); JobDetail is in the same stack.
- The manual path must work regardless of `settings.reviewRequestEnabled` (that toggle governs only the automatic notification).
- One-shot block stays: once `sentAt` is set, ReviewRequestScreen shows only the sent card (owner decision — no send-again).
- Shared primitives only: `Button`, `EmptyState` (`{ message: string }`), `resolveCustomer(customers, link)` from `utils/storage`, existing `composeSMS`/`composeEmail` usage in the screen.
- Commit messages: imperative `feat:`/`docs:` subject, ending with `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`. Do not push.
- Feature is NOT done until the owner's device smoke passes (checklist in Task 3).

---

### Task 1: `markReviewRequestSent` upsert + auto-notification cancel (TDD)

**Files:**
- Modify: `jest.setup.js:19-31` (expo-notifications mock — add one function)
- Test: `__tests__/reviewRequest.test.js` (extend — currently covers only the two pure helpers)
- Modify: `utils/reviewRequest.ts:103-109` (replace `markReviewRequestSent`)

**Interfaces:**
- Consumes: `loadRecords`/`saveRecords` internals of `utils/reviewRequest.ts` (file-private, unchanged); `Notifications.scheduleNotificationAsync` identifier convention `` `review_${job.id}` `` (utils/reviewRequest.ts:81).
- Produces: `markReviewRequestSent(jobId: string, fallback?: Pick<ReviewRequestRecord, "customerId" | "customerName" | "customerPhone" | "customerEmail">): Promise<void>` — Task 2's screen relies on the optional `fallback` creating a record when none exists, and on the cancel-notification side effect.

- [ ] **Step 1: Add `cancelScheduledNotificationAsync` to the expo-notifications jest mock**

In `jest.setup.js`, the expo-notifications mock (lines 19-31) has `cancelAllScheduledNotificationsAsync` but not the single-id variant. Add one line after `scheduleNotificationAsync` (line 27):

```js
  cancelScheduledNotificationAsync: jest.fn(() => Promise.resolve()),
```

- [ ] **Step 2: Write the failing tests**

Append a new describe block to `__tests__/reviewRequest.test.js`. Note the AsyncStorage mock in jest.setup.js is a stub (`getItem` resolves `null` by default), so each test primes the read with `mockResolvedValueOnce` and asserts on the `setItem` payload — this exercises the real upsert logic against controlled storage:

```js
describe("markReviewRequestSent", () => {
  const AsyncStorage = require("@react-native-async-storage/async-storage");
  const Notifications = require("expo-notifications");
  const { markReviewRequestSent } = require("../utils/reviewRequest");

  const rec = (jobId, overrides = {}) => ({
    jobId,
    customerId: "c1",
    customerName: "Sam",
    customerPhone: "555-0100",
    customerEmail: "sam@example.com",
    scheduledAt: "2026-07-30T10:00:00.000Z",
    sentAt: null,
    ...overrides,
  });

  const savedRecords = () =>
    JSON.parse(AsyncStorage.setItem.mock.calls.at(-1)[1]);

  beforeEach(() => {
    jest.clearAllMocks();
  });

  test("sets sentAt on the matching record and leaves others untouched", async () => {
    AsyncStorage.getItem.mockResolvedValueOnce(
      JSON.stringify([rec("j1"), rec("j2")]),
    );
    await markReviewRequestSent("j1");
    const out = savedRecords();
    expect(out).toHaveLength(2);
    expect(out[0].sentAt).toEqual(expect.any(String));
    expect(out[1].sentAt).toBeNull();
    expect(AsyncStorage.setItem.mock.calls.at(-1)[0]).toBe("review_requests");
  });

  test("creates a sent record from the fallback when none exists (manual send)", async () => {
    AsyncStorage.getItem.mockResolvedValueOnce(null);
    await markReviewRequestSent("j9", {
      customerId: "c9",
      customerName: "Pat",
      customerPhone: "555-0199",
      customerEmail: "pat@example.com",
    });
    const out = savedRecords();
    expect(out).toHaveLength(1);
    expect(out[0]).toMatchObject({
      jobId: "j9",
      customerId: "c9",
      customerName: "Pat",
      customerPhone: "555-0199",
      customerEmail: "pat@example.com",
    });
    expect(out[0].sentAt).toEqual(expect.any(String));
    expect(out[0].scheduledAt).toEqual(expect.any(String));
  });

  test("no matching record and no fallback appends nothing", async () => {
    AsyncStorage.getItem.mockResolvedValueOnce(JSON.stringify([rec("j1")]));
    await markReviewRequestSent("j9");
    const out = savedRecords();
    expect(out).toHaveLength(1);
    expect(out[0].jobId).toBe("j1");
    expect(out[0].sentAt).toBeNull();
  });

  test("cancels the pending auto-notification for the job", async () => {
    AsyncStorage.getItem.mockResolvedValueOnce(JSON.stringify([rec("j1")]));
    await markReviewRequestSent("j1");
    expect(Notifications.cancelScheduledNotificationAsync).toHaveBeenCalledWith(
      "review_j1",
    );
  });

  test("a failed cancel does not block marking sent", async () => {
    Notifications.cancelScheduledNotificationAsync.mockRejectedValueOnce(
      new Error("no such notification"),
    );
    AsyncStorage.getItem.mockResolvedValueOnce(JSON.stringify([rec("j1")]));
    await expect(markReviewRequestSent("j1")).resolves.toBeUndefined();
    expect(savedRecords()[0].sentAt).toEqual(expect.any(String));
  });
});
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `npm test -- reviewRequest.test`
Expected: FAIL — the fallback test saves an empty array (current implementation only maps), and the two cancel tests fail with "cancelScheduledNotificationAsync … not been called" / mock not invoked, because the current implementation never cancels.

- [ ] **Step 4: Replace `markReviewRequestSent` in `utils/reviewRequest.ts`**

Replace lines 103-109 (the current map-only implementation) with:

```ts
/**
 * Mark a job's review request sent. Upserts: when no record exists (manual
 * send for a job that never had an auto-request scheduled — toggle off, no
 * contact info at completion time, or completed before the feature existed),
 * `fallback` supplies the customer snapshot and a sent record is created so
 * the one-shot block applies to manual sends too. Also cancels the pending
 * auto-notification for the job, so a manual send inside the delay window
 * isn't followed by the "Time to ask for a review!" nag; cancelling an
 * unscheduled or already-fired identifier is a safe no-op.
 */
export async function markReviewRequestSent(
  jobId: string,
  fallback?: Pick<
    ReviewRequestRecord,
    "customerId" | "customerName" | "customerPhone" | "customerEmail"
  >,
): Promise<void> {
  await Notifications.cancelScheduledNotificationAsync(`review_${jobId}`).catch(
    () => {},
  );

  const records = await loadRecords();
  const now = new Date().toISOString();
  const exists = records.some((r) => r.jobId === jobId);
  const updated = exists
    ? records.map((r) => (r.jobId === jobId ? { ...r, sentAt: now } : r))
    : fallback
      ? [...records, { jobId, ...fallback, scheduledAt: now, sentAt: now }]
      : records;
  await saveRecords(updated);
}
```

(`Notifications` is already imported at the top of the file; `ReviewRequestRecord` is the interface at lines 7-15 — no import changes needed.)

- [ ] **Step 5: Run the focused tests to verify they pass**

Run: `npm test -- reviewRequest.test`
Expected: PASS — all existing pure-helper cases plus the 5 new ones.

- [ ] **Step 6: Run the full gate**

Run: `npm run typecheck` then `npm test` then `npm run lint`
Expected: 0 errors / all pass (1358 + 5 = 1363 expected; adjust if the actual count differs, but ALL must pass) / 0 warnings. The typecheck also proves the widened signature breaks no caller (the only existing caller is ReviewRequestScreen, and the new param is optional).

- [ ] **Step 7: Commit**

```bash
git add jest.setup.js __tests__/reviewRequest.test.js utils/reviewRequest.ts
git commit -m "feat: upsert review-request record on send and cancel pending nag

markReviewRequestSent now creates a sent record from a customer
fallback when none exists (manual sends for jobs that never had an
auto-request scheduled) and cancels the job's pending auto-notification
so a manual send inside the delay window is not followed by the
automatic reminder.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 2: ReviewRequestScreen no-record fallback + source param

**Files:**
- Modify: `types/navigation.ts:46`
- Modify: `App.tsx:316-321` (notification-response handler — one param added)
- Modify: `screens/ReviewRequestScreen.tsx` (imports, load effect, send handlers, not-found state)

**Interfaces:**
- Consumes: `markReviewRequestSent(jobId, fallback?)` from Task 1; `resolveCustomer(customers, link)` from `utils/storage` (returns `Customer | null`, joins by id then normalized name); `EmptyState({ message })` from `components/UI`.
- Produces: route contract `ReviewRequest: { jobId: string; source?: "notification" | "job_detail" }` — Task 3 navigates with `source: "job_detail"`.

**Why no new automated test:** the changes are screen plumbing around the Task-1-tested upsert plus pure helpers already covered; screens have no render-test harness (repo precedent). The full gate plus device smoke covers them.

- [ ] **Step 1: Widen the route params**

In `types/navigation.ts` line 46, change:

```ts
  ReviewRequest: { jobId: string };
```

to:

```ts
  ReviewRequest: { jobId: string; source?: "notification" | "job_detail" };
```

- [ ] **Step 2: Tag the notification path**

In `App.tsx` (lines 316-321), the review_request branch currently navigates with `params: { jobId: String(data.jobId) }`. Change only the inner params object:

```ts
      if (data?.type === "review_request" && data?.jobId && navigationRef.isReady()) {
        navigationRef.navigate("Main", {
          screen: "Jobs",
          params: { screen: "ReviewRequest", params: { jobId: String(data.jobId), source: "notification" } },
        });
      }
```

- [ ] **Step 3: Screen — imports and state**

In `screens/ReviewRequestScreen.tsx`:

Line 13, extend the storage import:

```ts
import { loadSettings, loadJobs, loadCustomers, resolveCustomer } from "../utils/storage";
```

Line 20, extend the UI import:

```ts
import { Button, Card, Divider, EmptyState } from "../components/UI";
```

Line 34, read the new param:

```ts
  const { jobId, source } = route.params;
```

After the existing `const [copied, setCopied] = useState(false);` (line 43), add:

```ts
  const [notFound, setNotFound] = useState(false);
  const [fallbackCustomer, setFallbackCustomer] = useState<{
    customerId: string;
    customerName: string;
    customerPhone: string;
    customerEmail: string;
  } | null>(null);
```

- [ ] **Step 4: Screen — no-record fallback in the load effect**

Replace the whole `useEffect` body (lines 45-70) with:

```ts
  useEffect(() => {
    (async () => {
      const [s, record] = await Promise.all([
        loadSettings(),
        getReviewRequestRecord(jobId),
      ]);
      setSettings(s);
      setMissingLink(reviewMessageMissingLink(s.reviewRequestTemplate, s.googleReviewLink));

      if (record) {
        setCustomerName(record.customerName);
        setCustomerPhone(record.customerPhone);
        setCustomerEmail(record.customerEmail);
        if (record.sentAt) setSent(true);

        setMessage(
          buildReviewMessage(
            s.reviewRequestTemplate,
            s.businessName,
            record.customerName,
            s.googleReviewLink,
          ),
        );
        return;
      }

      // Manual path: no record was ever scheduled (toggle off, no contact
      // info at completion time, or the job predates the feature). Build the
      // preview from the job's CURRENT customer so contact edits made since
      // completion are honored; sending creates the record (Task 1 upsert).
      const [jobs, customers] = await Promise.all([loadJobs(), loadCustomers()]);
      const job = jobs.find((j) => j.id === jobId);
      const cust = job ? resolveCustomer(customers, job) : null;
      if (!job || !cust) {
        setNotFound(true);
        return;
      }

      setFallbackCustomer({
        customerId: cust.id,
        customerName: cust.name,
        customerPhone: cust.phone,
        customerEmail: cust.email,
      });
      setCustomerName(cust.name);
      setCustomerPhone(cust.phone);
      setCustomerEmail(cust.email);
      setMessage(
        buildReviewMessage(
          s.reviewRequestTemplate,
          s.businessName,
          cust.name,
          s.googleReviewLink,
        ),
      );
    })();
  }, [jobId]);
```

- [ ] **Step 5: Screen — send handlers pass the fallback and the analytics source**

In `handleSendSMS` (lines 72-83), change the two lines:

```ts
      await markReviewRequestSent(jobId, fallbackCustomer ?? undefined);
      setSent(true);
      track('review_request_sent', { channel: 'sms', source: source ?? 'notification' });
```

In `handleSendEmail` (lines 85-97), likewise:

```ts
      await markReviewRequestSent(jobId, fallbackCustomer ?? undefined);
      setSent(true);
      track('review_request_sent', { channel: 'email', source: source ?? 'notification' });
```

(Only the `markReviewRequestSent` call and the `track` call change in each handler; the compose calls and alerts stay as they are.)

- [ ] **Step 6: Screen — replace the silent blank with a real not-found state**

Directly before the existing guard `if (!settings || !message) return null;` (line 119), add:

```tsx
  if (notFound) {
    return (
      <SafeAreaView style={styles.container} edges={["bottom"]}>
        <EmptyState message="This job or its customer no longer exists, so there's no one to send a review request to." />
      </SafeAreaView>
    );
  }
```

The `return null` guard now only covers the initial loading frame (settings/record fetch in flight).

- [ ] **Step 7: Run the full gate**

Run: `npm run typecheck` then `npm test` then `npm run lint`
Expected: 0 / all pass (1363) / 0. Typecheck proves the route-param widening breaks no navigate call (the only pre-existing navigator to this route is App.tsx, updated in Step 2).

- [ ] **Step 8: Commit**

```bash
git add types/navigation.ts App.tsx screens/ReviewRequestScreen.tsx
git commit -m "feat: build review request from current customer when unscheduled

ReviewRequestScreen rendered blank for any job without a scheduled
record. It now falls back to the job's current customer via
resolveCustomer, shows a real empty state when the job or customer is
gone, and tags review_request_sent with its source (notification vs
job_detail) via a new optional route param.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 3: JobDetail entry points (paid CTA + complete/invoiced action)

**Files:**
- Modify: `screens/JobDetailScreen.tsx` (import, state, load effect, `PrimaryAction`, new `ReviewRequestAction`, render)

**Interfaces:**
- Consumes: route contract `ReviewRequest: { jobId, source?: "notification" | "job_detail" }` from Task 2; `getReviewRequestRecord(jobId): Promise<ReviewRequestRecord | null>` from `utils/reviewRequest` (record's `sentAt` is non-null once sent).
- Produces: nothing consumed later; the owner smoke exercises it.

**Why no new automated test:** screen plumbing; no render-test harness (repo precedent). Gate + device smoke.

- [ ] **Step 1: Import and state**

Line 26 currently imports only the scheduler; extend it:

```ts
import { scheduleReviewRequest, getReviewRequestRecord } from "../utils/reviewRequest";
```

After `const [loadError, setLoadError] = useState<boolean>(false);` (line 602), add:

```ts
  const [reviewSent, setReviewSent] = useState<boolean>(false);
```

- [ ] **Step 2: Load the sent state in the focus effect**

In the focus effect's `load()`, extend the `Promise.all` (lines 612-616) from three reads to four, and set the flag after `setCustomer`. The block currently reads:

```ts
          const [jobs, customers, invoices] = await Promise.all([
            loadJobs(),
            loadCustomers(),
            loadInvoices(),
          ]);
          if (!active) return;
```

Replace with:

```ts
          const [jobs, customers, invoices, reviewRecord] = await Promise.all([
            loadJobs(),
            loadCustomers(),
            loadInvoices(),
            getReviewRequestRecord(jobId),
          ]);
          if (!active) return;
```

And after `setCustomer(resolveCustomer(customers, j));` (line 643), add:

```ts
          setReviewSent(!!reviewRecord?.sentAt);
```

(Everything between — the FA-038 sweep with its guarded `saveJobs` — stays exactly as it is.)

- [ ] **Step 3: PrimaryAction — the paid CTA**

Widen the component's props (line 497):

```ts
function PrimaryAction({ job, reviewSent, navigation, onAdvance }: { job: Job; reviewSent: boolean; navigation: JobStackScreenProps<'JobDetail'>['navigation']; onAdvance: () => void }) {
```

Replace the `paid` entry of the `actions` map (lines 546-550, currently the inert `"Job complete — Paid ✓"` with an empty `onPress`) with:

```ts
    paid: {
      label: reviewSent ? "Review request sent ✓" : "Request a review",
      onPress: () =>
        navigation.navigate("ReviewRequest", { jobId: job.id, source: "job_detail" }),
      variant: reviewSent ? "ghost" : "primary",
    },
```

- [ ] **Step 4: New ReviewRequestAction component**

Add directly after the `DepositAction` function (after line 589), mirroring its shape:

```tsx
// Manual review-request path for jobs that finished but aren't paid yet —
// covers asking before payment and recovering a missed auto-notification.
// Paid jobs get the PrimaryAction CTA instead; once sent, this hides.
function ReviewRequestAction({ job, reviewSent, navigation }: { job: Job; reviewSent: boolean; navigation: JobStackScreenProps<'JobDetail'>['navigation'] }) {
  if (job.status !== "complete" && job.status !== "invoiced") return null;
  if (reviewSent) return null;

  return (
    <Button
      label="Request review →"
      variant="secondary"
      onPress={() =>
        navigation.navigate("ReviewRequest", { jobId: job.id, source: "job_detail" })
      }
      style={{ marginBottom: spacing.sm }}
    />
  );
}
```

- [ ] **Step 5: Render both entry points**

At the render site (lines 863-869), pass the new prop and mount the new action after `DepositAction`:

```tsx
        <PrimaryAction
          job={job}
          reviewSent={reviewSent}
          navigation={navigation}
          onAdvance={advanceStatus}
        />

        <DepositAction job={job} navigation={navigation} />

        <ReviewRequestAction job={job} reviewSent={reviewSent} navigation={navigation} />
```

- [ ] **Step 6: Run the full gate**

Run: `npm run typecheck` then `npm test` then `npm run lint`
Expected: 0 / all pass (1363) / 0.

- [ ] **Step 7: Commit**

```bash
git add screens/JobDetailScreen.tsx
git commit -m "feat: add manual review-request entry points on job detail

The inert paid-status button becomes a Request-a-review CTA (ghost
sent-state once the request went out), and complete/invoiced jobs get
a secondary Request review action, so a missed auto-notification is
recoverable at any stage after the work is done.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

- [ ] **Step 8: Owner device smoke (Expo Go) — feature is not done until this passes**

1. Paid job → "Request a review" (primary) → preview shows the customer's current info → Send via SMS/Email opens the composer → back on JobDetail the button reads "Review request sent ✓" (ghost).
2. Complete or invoiced job → secondary "Request review →" visible → send → button disappears; re-entering the screen shows the sent card (one-shot block).
3. A pre-existing paid job that never had a notification scheduled (no record) → screen shows a real preview (not blank), send works.
4. Clear the Google review link in Settings (template still has `{googleReviewLink}`) → screen shows the "Add your Google review link" warning, send blocked.
5. Mark a job complete, send the review manually within the delay window → the auto notification never arrives.
6. Auto-flow regression: complete a job (toggle on, customer has a phone number), wait out the delay → notification arrives and opens the screen as before.

---

## Self-review (done at plan time)

- **Spec coverage:** paid CTA + sent-state label ✓ (Task 3 Step 3), complete/invoiced secondary action hidden once sent ✓ (Task 3 Step 4), sent-state loading in JobDetail ✓ (Task 3 Step 2), manual path ignores `reviewRequestEnabled` ✓ (no gating added anywhere), no-record fallback via `resolveCustomer` with current contact info ✓ (Task 2 Step 4), EmptyState instead of blank ✓ (Task 2 Step 6), upsert-on-send ✓ (Task 1 Step 4), one-shot block preserved ✓ (sent path untouched), notification cancel ✓ (Task 1 Step 4), analytics `source` with notification default ✓ (Task 2 Steps 1/2/5), spec's out-of-scope list untouched (no Today card, no send-again, no sync).
- **Placeholder scan:** none.
- **Type consistency:** `markReviewRequestSent(jobId, fallback?)` signature identical in Task 1 Produces, Task 1 Step 4, and Task 2 Step 5; route params `{ jobId, source? }` identical in Task 2 Step 1, App.tsx Step 2, and both Task 3 navigate calls; `reviewSent: boolean` prop consistent across PrimaryAction/ReviewRequestAction/render.
- **Verified against repo:** jest expo-notifications mock lacks `cancelScheduledNotificationAsync` (jest.setup.js:19-31 — Step 1 adds it); AsyncStorage mock is a null-stub (jest.setup.js:85-94 — tests prime reads explicitly); `EmptyState` takes `{ message }` (components/UI.tsx:133); `resolveCustomer` accepts `{ customerId?, customerName? }` links so passing a `Job` is type-compatible (utils/storage/customers.ts:106-117); JobDetail render site at lines 863-869.

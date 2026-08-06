# Auto-Email Invoice (opt-in) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** When a job is marked complete with both opt-in toggles on, the auto-created invoice (which already includes approved change orders) is emailed to the customer automatically by a 15-minute backend sweep — no send screen, no Mail composer.

**Architecture:** Client stamps `autoEmailRequestedAt` on the auto-created invoice and fire-and-forget mints a payment link; the stamped invoice syncs to Supabase; a new Cloudflare Workers cron (every 15 min) selects stamped, unpaid, fresh, un-claimed invoices and sends a deterministic plain-text email via Resend with a one-and-done claim in a new `auto_invoice_email_log` table. Spec: `docs/superpowers/specs/2026-08-06-auto-email-invoice-design.md` (owner-approved).

**Tech Stack:** Expo 54 / RN 0.81 / TypeScript (app), CommonJS libs under `backend-workers/lib/` + Hono on Cloudflare Workers (backend), Supabase Postgres (sync + log table), Resend (email), Jest (`jest-expo`).

## Global Constraints

- Repo root for ALL paths and commands: `C:\dev\tradeready\tradeready` (git branch `master`). Concurrent sessions run in this repo — run `git status` before each commit and stage ONLY the files this task names.
- Gate before EVERY commit, from the repo root: `npm run typecheck` (0 errors), `npm test` (all pass), `npm run lint` (0 warnings). Never commit on red (tradeready-change-control rule 2).
- NO dependency changes, no `package.json`/`app.json` edits, no Expo SDK changes (rule 3). Everything here uses existing deps.
- Backend work goes in `backend-workers/` ONLY. The Vercel `backend/` folder is being decommissioned — do not touch it.
- New settings/invoice fields are opt-in, absent-means-false (truthy read) — same convention as `autoInvoiceOnComplete`. Do NOT copy the `estimateFollowUpsEnabled` absent-means-ON convention.
- Local-first invariant: nothing on the mark-complete path may await a network call. The mint is fire-and-forget.
- Unattended email discipline (mirrors `backend-workers/lib/reminderEmail.js`): deterministic template, no AI, `sanitizeFromPhrase` for the From header, pay link only when amount-matched AND `isAllowedPaymentLink` passes.
- Email sender for this feature: `invoices@gettradereadyapp.com` (same verified Resend domain as `reminders@`).
- Freshness window: 7 days. Daily per-user cap: 25. Cron cadence: `*/15 * * * *`.
- Commit messages: imperative mood, `feat:`/`chore:`/`docs:` prefix, content-bearing subject.

---

### Task 1: Data shapes + stamping in `createAutoInvoiceForJob`

Adds the two persisted fields (owner-approved), stamps the invoice when the new toggle is on and the customer has an email, and changes the flow's return type to a result object. JobDetailScreen is updated minimally so the gate stays green (behavior unchanged in this task — the queued-branch UX is Task 2).

**Files:**
- Modify: `types/models.ts` (Invoice interface ~line 357; Settings interface ~line 657)
- Modify: `utils/storage/defaults.ts` (~line 235)
- Modify: `utils/autoInvoice.ts` (`createAutoInvoiceForJob`, ~lines 231–279)
- Modify: `screens/JobDetailScreen.tsx` (~lines 803–810)
- Test: `__tests__/autoInvoice.test.ts`

**Interfaces:**
- Consumes: existing `createAutoInvoiceForJob`, `prefillInvoiceDraftFromJob` in `utils/autoInvoice.ts`.
- Produces: `Settings.autoEmailInvoiceOnComplete: boolean`; `Invoice.autoEmailRequestedAt?: string`; and

```ts
export interface AutoInvoiceResult {
  invoiceId: string;
  number: string;
  /** True when the invoice was stamped for the backend email sweep. */
  autoEmailQueued: boolean;
  /** The address the auto-email will go to ("" when not queued). */
  email: string;
}
// createAutoInvoiceForJob(jobId: string): Promise<AutoInvoiceResult | null>
```

Tasks 2–4 rely on these exact names.

- [ ] **Step 1: Write the failing tests**

First, hoist the storage harness to file scope so later tasks' describe blocks can reuse it: move `let store`, `seed(...)`, `janeRecord`, the `beforeEach(...)` (mock reset + AsyncStorage getItem/setItem implementations), `storedJobs()`, and `storedInvoices()` OUT of the `describe("createAutoInvoiceForJob", ...)` block to module scope, directly above it. Nothing else changes — the existing tests keep passing (the earlier pure-function describes don't touch AsyncStorage, so a file-scope beforeEach is harmless for them).

Then: the `createAutoInvoiceForJob` describe block asserts on the current `string | null` return. Update the three affected existing tests and add a new describe block.

Replace the happy-path test's first assertions:

```ts
  test("happy path: saves the invoice and advances the job to invoiced", async () => {
    const job = makeJob({ timeSessions: [closedSession(5.5)] });
    seed([job], [], [janeRecord], { autoInvoiceOnComplete: true });

    const result = await createAutoInvoiceForJob("j1");

    expect(result).toBeTruthy();
    const invoiceId = result!.invoiceId;
    expect(result!.number).toBe("INV-0001");
    const invoices = storedInvoices();
    expect(invoices).toHaveLength(1);
    expect(invoices[0]).toMatchObject({
      id: invoiceId,
      customer: "Jane Smith",
      customerId: "c1",
      number: "INV-0001",
      amount: 1093.5,
      email: "jane@example.com",
      phone: "555-0100",
      desc: "Water heater swap",
      paid: false,
      jobId: "j1",
    });
    expect(invoices[0].lineItems).toHaveLength(3);

    const savedJob = storedJobs().find((j) => j.id === "j1");
    expect(savedJob?.status).toBe("invoiced");
    expect(savedJob?.invoiceId).toBe(invoiceId);
  });
```

In the "a still-running timer is clocked out and billed" test, replace the two `invoiceId` lines the same way:

```ts
    const result = await createAutoInvoiceForJob("j1");

    expect(result).toBeTruthy();
```

In "no matching customer record → one is created and linked":

```ts
    const result = await createAutoInvoiceForJob("j1");

    expect(result).toBeTruthy();
```

Then append a new describe block after the `createAutoInvoiceForJob` block (inside the same file, reusing `makeJob`, `seed`, `janeRecord`, `storedInvoices`):

```ts
// ── auto-email stamping (2026-08-06 spec) ─────────────────────────────────────
// Fully-automatic emailing: when BOTH toggles are on and the resolved customer
// record has an email, the saved invoice carries autoEmailRequestedAt and the
// result reports autoEmailQueued so JobDetail can skip the send screen.

describe("createAutoInvoiceForJob auto-email stamping", () => {
  test("both toggles on + customer email → stamped and queued", async () => {
    seed([makeJob()], [], [janeRecord], {
      autoInvoiceOnComplete: true,
      autoEmailInvoiceOnComplete: true,
    });

    const result = await createAutoInvoiceForJob("j1");

    expect(result).toMatchObject({ autoEmailQueued: true, email: "jane@example.com" });
    const stamped = storedInvoices()[0].autoEmailRequestedAt;
    expect(stamped).toBeTruthy();
    expect(Number.isFinite(Date.parse(stamped as string))).toBe(true);
  });

  test("email toggle off (or absent) → no stamp, not queued", async () => {
    seed([makeJob()], [], [janeRecord], { autoInvoiceOnComplete: true });

    const result = await createAutoInvoiceForJob("j1");

    expect(result).toMatchObject({ autoEmailQueued: false, email: "" });
    expect(storedInvoices()[0].autoEmailRequestedAt).toBeUndefined();
  });

  test("customer without an email → no stamp (manual send screen path)", async () => {
    const noEmail = { id: "c1", name: "Jane Smith", email: "", phone: "555-0100" } as Customer;
    seed([makeJob()], [], [noEmail], {
      autoInvoiceOnComplete: true,
      autoEmailInvoiceOnComplete: true,
    });

    const result = await createAutoInvoiceForJob("j1");

    expect(result).toMatchObject({ autoEmailQueued: false, email: "" });
    expect(storedInvoices()[0].autoEmailRequestedAt).toBeUndefined();
  });
});
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `npx jest __tests__/autoInvoice.test.ts`
Expected: FAIL — the updated tests fail because `createAutoInvoiceForJob` returns a string (e.g. `result!.invoiceId` is `undefined`; `autoEmailQueued` matcher fails). Type errors may also surface via ts-jest transform — that's the same signal.

- [ ] **Step 3: Add the two model fields**

In `types/models.ts`, inside `interface Invoice`, directly after the `paymentLinkAmount?: number;` line (~357):

```ts
  /**
   * ISO timestamp stamped by createAutoInvoiceForJob when the owner opted in
   * to fully-automatic emailing (Settings.autoEmailInvoiceOnComplete) and the
   * customer had an email at creation. The backend's 15-minute sweep emails
   * stamped invoices once (auto_invoice_email_log one-and-done) while the
   * stamp is ≤7 days old; a manual send from Outreach clears it. Absent =
   * never requested. 2026-08-06 spec.
   */
  autoEmailRequestedAt?: string;
```

Inside `interface Settings`, directly after `autoInvoiceOnComplete: boolean;` (~657):

```ts
  /**
   * When true (and autoInvoiceOnComplete is on), the auto-created invoice is
   * emailed to the customer by the backend sweep within ~15 minutes instead
   * of opening the send screen; with no customer email on file the send
   * screen opens as before. Opt-in; absent → false (same truthy-read
   * convention as autoInvoiceOnComplete). 2026-08-06 spec.
   */
  autoEmailInvoiceOnComplete: boolean;
```

In `utils/storage/defaults.ts`, directly after the `autoInvoiceOnComplete: false,` line (~235):

```ts
    autoEmailInvoiceOnComplete: false, // opt-in; backend emails the auto-created invoice (2026-08-06 spec)
```

- [ ] **Step 4: Implement stamping + result object in `utils/autoInvoice.ts`**

Add the exported interface above `createAutoInvoiceForJob`:

```ts
export interface AutoInvoiceResult {
  invoiceId: string;
  number: string;
  /** True when the invoice was stamped for the backend email sweep. */
  autoEmailQueued: boolean;
  /** The address the auto-email will go to ("" when not queued). */
  email: string;
}
```

Change the function signature and the tail of the function (from the `draft` line to the end). The doc comment's "Returns the new invoice id" sentence becomes "Returns the result (invoice id + auto-email disposition)". New body from the draft onward:

```ts
  const draft = prefillInvoiceDraftFromJob(job, invoices, settings, record);
  if (!(draft.amount > 0)) return null;

  // Fully-automatic emailing (2026-08-06 spec): stamp the invoice for the
  // backend's 15-min sweep only when the owner opted in AND we actually have
  // an address. No email on file → the caller keeps today's send-screen path.
  const autoEmailQueued = !!settings.autoEmailInvoiceOnComplete && !!draft.email.trim();

  const lineItems = buildInvoiceLineItems(job);
  const invoice: Invoice = {
    id: `inv${Date.now()}`,
    customer: draft.customer.trim(),
    customerId: record?.id ?? job.customerId ?? "",
    number: draft.number,
    amount: draft.amount,
    due: draft.due,
    email: draft.email,
    phone: draft.phone,
    desc: draft.desc,
    paid: false,
    jobId,
    ...(lineItems.length > 0 ? { lineItems } : {}),
    ...(autoEmailQueued ? { autoEmailRequestedAt: new Date().toISOString() } : {}),
  };
  await saveInvoices([...invoices, invoice]);

  const jobChanges = jobChangesAfterInvoiceSave("create", invoice.id, false);
  const finalJob = { ...job, ...jobChanges };
  await saveJobs(jobs.map((j) => (j.id === jobId ? finalJob : j)));

  track("invoice_created", {
    source: "auto_on_complete",
    usedTrackedTime: draft.usedTrackedTime,
    autoEmailQueued,
  });
  return {
    invoiceId: invoice.id,
    number: invoice.number,
    autoEmailQueued,
    email: autoEmailQueued ? draft.email : "",
  };
}
```

Signature line: `export async function createAutoInvoiceForJob(jobId: string): Promise<AutoInvoiceResult | null> {`

- [ ] **Step 5: Minimal JobDetailScreen adaptation (no behavior change yet)**

In `screens/JobDetailScreen.tsx` (~803–810), replace the auto-invoice block's body:

```ts
      try {
        const result = await createAutoInvoiceForJob(job.id);
        if (result) {
          setJob((prev) =>
            prev ? { ...prev, ...jobChangesAfterInvoiceSave("create", result.invoiceId, false) } : prev
          );
          navigation.navigate("Outreach", { invoiceId: result.invoiceId });
        }
      } catch (error: unknown) {
        reportError(error, { context: "autoInvoiceOnComplete" });
      }
```

- [ ] **Step 6: Run the full gate**

Run: `npm run typecheck` then `npx jest __tests__/autoInvoice.test.ts` then `npm test` then `npm run lint`
Expected: typecheck 0 errors; the autoInvoice suite passes (all existing + 3 new tests); full suite passes; lint 0 warnings.

- [ ] **Step 7: Commit**

```bash
git add types/models.ts utils/storage/defaults.ts utils/autoInvoice.ts screens/JobDetailScreen.tsx __tests__/autoInvoice.test.ts
git commit -m "feat: stamp auto-created invoices for backend auto-email (opt-in fields + result object)"
```

---

### Task 2: JobDetailScreen queued-branch UX (skip the send screen)

**Files:**
- Modify: `screens/JobDetailScreen.tsx` (the block Task 1 just touched, ~803–812)

**Interfaces:**
- Consumes: `AutoInvoiceResult` (`invoiceId`, `number`, `autoEmailQueued`, `email`) from Task 1. `Alert` is already imported in this file (line 13).
- Produces: nothing new — screen-only branch.

- [ ] **Step 1: Implement the branch**

Replace the `if (result) { ... }` body from Task 1 with:

```ts
        if (result) {
          setJob((prev) =>
            prev ? { ...prev, ...jobChangesAfterInvoiceSave("create", result.invoiceId, false) } : prev
          );
          if (result.autoEmailQueued) {
            // Fully-automatic mode (2026-08-06 spec): no send screen. The
            // backend sweep emails the stamped invoice within ~15 minutes;
            // deleting the invoice before then cancels the send.
            Alert.alert(
              "Invoice on its way",
              `Invoice ${result.number} created — it'll be emailed to ${result.email} within about 15 minutes.`,
              [
                {
                  text: "View invoice",
                  onPress: () => navigation.navigate("Outreach", { invoiceId: result.invoiceId }),
                },
                { text: "OK" },
              ]
            );
          } else {
            navigation.navigate("Outreach", { invoiceId: result.invoiceId });
          }
        }
```

No new automated test: this is a thin presentation branch over the util result that Task 1's tests pin; JobDetailScreen has no existing RNTL suite (repo precedent — the original auto-invoice navigation shipped the same way). Verification is the gate + owner device smoke.

- [ ] **Step 2: Run the full gate**

Run: `npm run typecheck` then `npm test` then `npm run lint`
Expected: all green (no test-count change).

- [ ] **Step 3: Commit**

```bash
git add screens/JobDetailScreen.tsx
git commit -m "feat: skip send screen with confirmation alert when auto-email is queued"
```

---

### Task 3: Fire-and-forget payment-link mint at creation

**Files:**
- Modify: `utils/autoInvoice.ts`
- Test: `__tests__/autoInvoice.test.ts`

**Interfaces:**
- Consumes: `resolvePaymentLink(invoice, provider, providerKey, requestedAmount): Promise<string>` and `getProviderKey(settings, provider?): string` from `utils/invoiceHelpers.ts`; `reportError` from `utils/analytics.ts` (already mocked in the test file).
- Produces: `mintAutoInvoicePaymentLink(invoiceId: string): Promise<void>` (exported from `utils/autoInvoice.ts`; never rejects). Called fire-and-forget inside `createAutoInvoiceForJob` when `autoEmailQueued`.

Design note (deviation recorded per change-control): the spec says "extract the small mint-and-persist step shared with OutreachScreen's `handleGenerateLink`". Investigation shows OutreachScreen's persist step is entangled with deposit-request UI state (`depositAsk`, `depositRequest` clearing — `OutreachScreen.tsx:217–230`), so a shared extraction would thread screen state through a util for no dedup win. The genuinely shared primitives — `resolvePaymentLink` / `getProviderKey` — are reused directly; OutreachScreen is NOT modified in this task. Flag this in the phase report.

- [ ] **Step 1: Write the failing tests**

In `__tests__/autoInvoice.test.ts`, add with the other `jest.mock` calls at the top:

```ts
// requireActual is load-bearing: utils/storage/settings.ts imports
// isSquarePaymentLink from this same module — a bare factory would replace
// it with undefined and break every loadSettings call in this suite.
jest.mock("../utils/invoiceHelpers", () => ({
  ...jest.requireActual("../utils/invoiceHelpers"),
  resolvePaymentLink: jest.fn(),
  getProviderKey: jest.fn().mockReturnValue(""),
}));
```

And with the other imports:

```ts
import { resolvePaymentLink } from "../utils/invoiceHelpers";
```

Append a describe block:

```ts
// ── payment-link mint at creation (2026-08-06 spec) ──────────────────────────
// Queued auto-invoices get a best-effort link mint so the backend email can
// include a pay link (it only ever includes a cached link matching the
// balance). Fire-and-forget: failures degrade to a link-less email.

describe("auto-invoice payment-link mint", () => {
  const flushAsync = () => new Promise((r) => setTimeout(r, 0));

  test("queued invoice gets paymentLinkUrl/Amount cached for the full amount", async () => {
    (resolvePaymentLink as jest.Mock).mockResolvedValue("https://buy.stripe.com/test_abc");
    seed([makeJob()], [], [janeRecord], {
      autoInvoiceOnComplete: true,
      autoEmailInvoiceOnComplete: true,
      provider: "stripe",
    });

    const result = await createAutoInvoiceForJob("j1");
    await flushAsync();

    expect(result?.autoEmailQueued).toBe(true);
    const inv = storedInvoices()[0];
    expect(inv.paymentLinkUrl).toBe("https://buy.stripe.com/test_abc");
    expect(inv.paymentLinkAmount).toBe(inv.amount);
  });

  test("not queued → no mint attempted", async () => {
    (resolvePaymentLink as jest.Mock).mockResolvedValue("https://buy.stripe.com/test_abc");
    seed([makeJob()], [], [janeRecord], { autoInvoiceOnComplete: true, provider: "stripe" });

    await createAutoInvoiceForJob("j1");
    await flushAsync();

    expect(resolvePaymentLink).not.toHaveBeenCalled();
    expect(storedInvoices()[0].paymentLinkUrl).toBeUndefined();
  });

  test("mint failure degrades silently: invoice saved, no link, error reported", async () => {
    (resolvePaymentLink as jest.Mock).mockRejectedValue(new Error("offline"));
    seed([makeJob()], [], [janeRecord], {
      autoInvoiceOnComplete: true,
      autoEmailInvoiceOnComplete: true,
      provider: "stripe",
    });

    const result = await createAutoInvoiceForJob("j1");
    await flushAsync();

    expect(result?.autoEmailQueued).toBe(true);
    expect(storedInvoices()[0].paymentLinkUrl).toBeUndefined();
    const { reportError } = jest.requireMock("../utils/analytics");
    expect(reportError).toHaveBeenCalled();
  });
});
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `npx jest __tests__/autoInvoice.test.ts`
Expected: FAIL — `resolvePaymentLink` never called / `paymentLinkUrl` undefined in the first test (`mintAutoInvoicePaymentLink` doesn't exist yet).

- [ ] **Step 3: Implement the mint**

In `utils/autoInvoice.ts`, add imports:

```ts
import { resolvePaymentLink, getProviderKey } from "./invoiceHelpers";
import { track, reportError } from "./analytics";
```

(`track` is already imported — merge into the existing import line.)

Add the exported function after `createAutoInvoiceForJob`:

```ts
/**
 * Best-effort payment-link mint for a freshly auto-created invoice, so the
 * backend auto-email can include a pay link (the email only ever includes a
 * cached link whose minted amount matches the balance — minting at creation
 * makes that true by construction). Fire-and-forget: never awaited on the
 * completion path, never throws. Offline / unconfigured / mint error → the
 * email goes out link-less (honest degradation, 2026-08-06 spec).
 *
 * Deliberately NOT shared with OutreachScreen's handleGenerateLink: that
 * screen's persist step is entangled with deposit-request UI state; the
 * shared primitive is resolvePaymentLink itself (architecture contract §9).
 */
export async function mintAutoInvoicePaymentLink(invoiceId: string): Promise<void> {
  try {
    const [invoices, settings] = await Promise.all([loadInvoices(), loadSettings()]);
    const invoice = invoices.find((i) => i.id === invoiceId);
    if (!invoice || !settings.provider) return;
    const link = await resolvePaymentLink(
      invoice,
      settings.provider,
      getProviderKey(settings, settings.provider),
      invoice.amount,
    );
    if (!link) return;
    // Re-read before writing: the mint awaited the network, and another save
    // may have landed meanwhile.
    const fresh = await loadInvoices();
    await saveInvoices(
      fresh.map((i) =>
        i.id === invoiceId ? { ...i, paymentLinkUrl: link, paymentLinkAmount: invoice.amount } : i,
      ),
    );
  } catch (err: unknown) {
    reportError(err, { context: "autoInvoiceMintLink" });
  }
}
```

Inside `createAutoInvoiceForJob`, directly before the `track(...)` call:

```ts
  if (autoEmailQueued) {
    // Fire-and-forget (local-first: completion never waits on the network).
    // mintAutoInvoicePaymentLink catches internally and never rejects.
    void mintAutoInvoicePaymentLink(invoice.id);
  }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `npx jest __tests__/autoInvoice.test.ts`
Expected: PASS (all tests, including the three new ones).

- [ ] **Step 5: Run the full gate and commit**

Run: `npm run typecheck` then `npm test` then `npm run lint`
Expected: all green.

```bash
git add utils/autoInvoice.ts __tests__/autoInvoice.test.ts
git commit -m "feat: mint payment link at auto-invoice creation so the auto-email can include it"
```

---

### Task 4: Clear the stamp on manual send (double-send guard)

**Files:**
- Modify: `utils/autoInvoice.ts`
- Modify: `screens/OutreachScreen.tsx` (`sendEmail` ~316–353, `sendSMS` ~355–358, plus its `utils/messaging` import)
- Test: `__tests__/autoInvoice.test.ts`

**Interfaces:**
- Consumes: `composeEmailWithOutcome` / `composeSMSWithOutcome` from `utils/messaging.ts` (both return `{ opened: boolean; outcome: "sent" | "notSent" | "unknown" }`; `"notSent"` = explicit cancel/draft-save).
- Produces: `clearAutoEmailRequest(invoiceId: string): Promise<void>` exported from `utils/autoInvoice.ts` (no-op when the invoice is missing or unstamped).

- [ ] **Step 1: Write the failing tests**

Append to `__tests__/autoInvoice.test.ts` (add `clearAutoEmailRequest` to the `../utils/autoInvoice` import):

```ts
// ── clearAutoEmailRequest (manual-send double-send guard) ────────────────────

describe("clearAutoEmailRequest", () => {
  const stamped = {
    id: "invA",
    customer: "Jane Smith",
    number: "INV-0001",
    amount: 100,
    due: "2026-08-20",
    email: "jane@example.com",
    phone: "",
    desc: "",
    paid: false,
    autoEmailRequestedAt: "2026-08-06T10:00:00.000Z",
  } as Invoice;

  test("clears the stamp on a stamped invoice", async () => {
    seed([], [stamped], [], {});

    await clearAutoEmailRequest("invA");

    expect(storedInvoices()[0].autoEmailRequestedAt).toBeUndefined();
    expect(storedInvoices()[0].number).toBe("INV-0001");
  });

  test("no-op (no save) when the invoice has no stamp", async () => {
    const plain = { ...stamped, id: "invB" } as Invoice;
    delete plain.autoEmailRequestedAt;
    seed([], [plain], [], {});
    (AsyncStorage.setItem as jest.Mock).mockClear();

    await clearAutoEmailRequest("invB");

    expect(AsyncStorage.setItem).not.toHaveBeenCalled();
  });

  test("no-op when the invoice does not exist", async () => {
    seed([], [], [], {});
    (AsyncStorage.setItem as jest.Mock).mockClear();

    await clearAutoEmailRequest("ghost");

    expect(AsyncStorage.setItem).not.toHaveBeenCalled();
  });
});
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `npx jest __tests__/autoInvoice.test.ts`
Expected: FAIL — `clearAutoEmailRequest` is not exported.

- [ ] **Step 3: Implement the util**

In `utils/autoInvoice.ts`, after `mintAutoInvoicePaymentLink`:

```ts
/**
 * Clears a pending auto-email request — called after a successful MANUAL
 * send from Outreach so the backend sweep doesn't email a second copy
 * (2026-08-06 spec). No-op when the invoice is gone or unstamped; a
 * post-sweep manual send needs no guard (the one-and-done log row already
 * blocks a second backend send).
 */
export async function clearAutoEmailRequest(invoiceId: string): Promise<void> {
  const invoices = await loadInvoices();
  const invoice = invoices.find((i) => i.id === invoiceId);
  if (!invoice?.autoEmailRequestedAt) return;
  await saveInvoices(
    invoices.map((i) => {
      if (i.id !== invoiceId) return i;
      const next = { ...i };
      delete next.autoEmailRequestedAt;
      return next;
    }),
  );
}
```

- [ ] **Step 4: Wire OutreachScreen**

In `screens/OutreachScreen.tsx`:

Change the messaging import (line 14) to:

```ts
import { composeEmailWithOutcome, composeSMSWithOutcome } from "../utils/messaging";
```

Add to the existing `../utils/autoInvoice` import if one exists; otherwise add:

```ts
import { clearAutoEmailRequest } from "../utils/autoInvoice";
```

In `sendEmail`, replace the `composeEmail` call and the `opened` handling:

```ts
      const { opened, outcome } = await composeEmailWithOutcome({
        recipients: [invoice.email],
        subject: subject || `Payment reminder: ${invoice.number}`,
        // The editor keeps plain text; at send time the body is escaped and
        // any payment URL becomes a labeled anchor (utils/emailHtml).
        body: emailHtmlFromText(message),
        isHtml: true,
        attachments: pdfUri ? [pdfUri] : undefined,
      });
      if (outcome !== "notSent") {
        // A manual send supersedes a pending auto-email (2026-08-06 spec).
        // "unknown" counts as sent — same conservative read as the one-shot
        // flows; an explicit cancel keeps the auto-email alive.
        clearAutoEmailRequest(invoice.id).catch(() => {});
      }
```

(The existing `if (opened && !pdfUri)` alert block below stays exactly as it is — `opened` is still in scope from the destructure.)

Replace `sendSMS`:

```ts
  async function sendSMS() {
    if (!invoice) return;
    const { outcome } = await composeSMSWithOutcome({ recipients: [invoice.phone], body: message });
    if (outcome !== "notSent") {
      // Texting the invoice manually also supersedes the pending auto-email.
      clearAutoEmailRequest(invoice.id).catch(() => {});
    }
  }
```

- [ ] **Step 5: Run the full gate and commit**

Run: `npm run typecheck` then `npm test` then `npm run lint`
Expected: all green.

```bash
git add utils/autoInvoice.ts screens/OutreachScreen.tsx __tests__/autoInvoice.test.ts
git commit -m "feat: clear pending auto-email when the invoice is sent manually"
```

---

### Task 5: Settings sub-toggle

**Files:**
- Modify: `screens/SettingsNotificationsScreen.tsx` (the "Auto-invoice completed jobs" card, ~lines 169–182)

**Interfaces:**
- Consumes: `s`, `update` from the screen's existing `useSettingsDraft` call; `Settings.autoEmailInvoiceOnComplete` from Task 1; existing styles `card`, `toggleRow`, `toggleLabel`, `keyNote`; `spacing` (already imported).
- Produces: nothing — UI only.

- [ ] **Step 1: Implement the sub-toggle**

Replace the card:

```tsx
          <View style={styles.card}>
            <View style={styles.toggleRow}>
              <Text style={styles.toggleLabel}>Auto-invoice completed jobs</Text>
              <Switch
                value={!!s.autoInvoiceOnComplete}
                onValueChange={(v) => update("autoInvoiceOnComplete", v)}
                trackColor={{ true: colors.accent }}
                accessibilityLabel="Auto-invoice completed jobs"
              />
            </View>
            <Text style={styles.keyNote}>
              When you mark a job complete, create the invoice automatically, billing tracked time when the timer was used.
            </Text>
            {!!s.autoInvoiceOnComplete && (
              <>
                <View style={[styles.toggleRow, { marginTop: spacing.sm }]}>
                  <Text style={styles.toggleLabel}>Email it automatically</Text>
                  <Switch
                    value={!!s.autoEmailInvoiceOnComplete}
                    onValueChange={(v) => update("autoEmailInvoiceOnComplete", v)}
                    trackColor={{ true: colors.accent }}
                    accessibilityLabel="Email the auto-created invoice automatically"
                  />
                </View>
                <Text style={styles.keyNote}>
                  Skip the send screen — the invoice is emailed to the customer within about 15 minutes, with a payment link when one can be made. If the customer has no email on file, the send screen opens instead.
                </Text>
              </>
            )}
          </View>
```

Notes: hiding the sub-toggle when the parent is off does NOT clear the stored value (deliberate — spec). The backend also re-checks the toggle at send time, so a hidden stale `true` with the parent off can never email anything (no new invoices get stamped).

No RNTL suite exists for this screen (repo precedent: the parent toggle shipped without one) — verification is the gate + owner device smoke.

- [ ] **Step 2: Run the full gate and commit**

Run: `npm run typecheck` then `npm test` then `npm run lint`
Expected: all green.

```bash
git add screens/SettingsNotificationsScreen.tsx
git commit -m "feat: add 'Email it automatically' sub-toggle to auto-invoice settings"
```

---

### Task 6: Supabase migration for `auto_invoice_email_log`

**Files:**
- Create: `supabase/migrations/20260806_auto_invoice_email_log.sql`

**Interfaces:**
- Produces: table `public.auto_invoice_email_log` with `unique (user_id, invoice_id)` — the one-and-done claim guard Task 9's runner inserts into. Column names below are load-bearing for Task 9.

- [ ] **Step 1: Write the migration**

```sql
-- Fully-automatic invoice emailing (2026-08-06 spec): one-and-done audit +
-- send-once guard for the 15-minute invoice-email sweep. Sibling of
-- 20260715_auto_reminder_log.sql; schema of record for
-- backend-workers/lib/sendInvoiceEmails.js.
-- Applied out-of-band via the Supabase SQL editor (no CLI runner in this repo).
-- The cron writes rows with the service role (bypasses RLS); the app reads its
-- own rows (owner-read policy below — unused in V1, reserved for the in-app
-- "Emailed on <date>" follow-up).
create table if not exists public.auto_invoice_email_log (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null references auth.users(id) on delete cascade,
  invoice_id text not null,
  to_email   text,
  sent_at    timestamptz not null default now(),
  status     text not null default 'pending', -- 'pending' | 'sent' | 'failed'
  error      text,
  unique (user_id, invoice_id)
);

alter table public.auto_invoice_email_log enable row level security;

create policy "read own invoice email log"
  on public.auto_invoice_email_log for select
  using (auth.uid() = user_id);
```

- [ ] **Step 2: Commit**

The gate is unaffected (SQL isn't compiled/tested), but run `git status` to confirm only this file is staged.

```bash
git add supabase/migrations/20260806_auto_invoice_email_log.sql
git commit -m "feat: add auto_invoice_email_log migration (one-and-done claim for invoice auto-email)"
```

**NOTE for the phase report:** the owner must apply this in the Supabase SQL editor BEFORE the Worker deploy (rollout step 1). The runner fails per-invoice with a logged "claim failed" if the table is missing — loud, not silent.

---

### Task 7: Backend selector — `selectInvoicesToAutoEmail` (pure)

**Files:**
- Create: `backend-workers/lib/selectInvoicesToAutoEmail.js` (CommonJS, like every file in `backend-workers/lib/`)
- Test: `__tests__/selectInvoicesToAutoEmail.test.js`

**Interfaces:**
- Consumes: `isFullyPaid` from `backend-workers/lib/paymentMath.js`; `isPlausibleEmail` from `backend-workers/lib/selectInvoicesToRemind.js` (exported).
- Produces: `selectInvoicesToAutoEmail({ invoices, settings, alreadyHandledInvoiceIds, today }) → Invoice[]` and `MAX_REQUEST_AGE_DAYS = 7`. Task 9's runner calls this exact signature.

- [ ] **Step 1: Write the failing tests**

Create `__tests__/selectInvoicesToAutoEmail.test.js`:

```js
// __tests__/selectInvoicesToAutoEmail.test.js
// The invoice auto-email selector (2026-08-06 spec): only client-stamped,
// unpaid, fresh, plausibly-addressed, un-claimed invoices — and only while
// the owner's toggle is on at send time. Mirrors the reminder selector's
// fail-closed discipline.

const {
  selectInvoicesToAutoEmail,
  MAX_REQUEST_AGE_DAYS,
} = require("../backend-workers/lib/selectInvoicesToAutoEmail");

const TODAY = new Date("2026-08-06T16:00:00.000Z");
const FRESH = "2026-08-06T15:00:00.000Z"; // 1h old
const STALE = "2026-07-29T15:00:00.000Z"; // 8 days old

function inv(overrides = {}) {
  return {
    id: "invA",
    customer: "Jane Smith",
    number: "INV-0001",
    amount: 500,
    due: "2026-09-05",
    email: "jane@example.com",
    phone: "",
    desc: "Water heater swap",
    paid: false,
    autoEmailRequestedAt: FRESH,
    ...overrides,
  };
}

const settings = { autoEmailInvoiceOnComplete: true };

function run(invoices, over = {}) {
  return selectInvoicesToAutoEmail({
    invoices,
    settings,
    alreadyHandledInvoiceIds: [],
    today: TODAY,
    ...over,
  });
}

describe("selectInvoicesToAutoEmail", () => {
  test("fresh stamped unpaid invoice with an email sends", () => {
    expect(run([inv()])).toHaveLength(1);
  });

  test("owner toggle off / absent / missing settings → nothing sends", () => {
    expect(run([inv()], { settings: { autoEmailInvoiceOnComplete: false } })).toHaveLength(0);
    expect(run([inv()], { settings: {} })).toHaveLength(0);
    expect(run([inv()], { settings: undefined })).toHaveLength(0);
  });

  test("no stamp → never considered (manual invoices are untouchable)", () => {
    expect(run([inv({ autoEmailRequestedAt: undefined })])).toHaveLength(0);
  });

  test("freshness: >7-day-old stamp never sends; just-inside sends; unparseable fails closed", () => {
    expect(run([inv({ autoEmailRequestedAt: STALE })])).toHaveLength(0);
    const justInside = new Date(TODAY.getTime() - (MAX_REQUEST_AGE_DAYS * 86400000 - 3600000)).toISOString();
    expect(run([inv({ autoEmailRequestedAt: justInside })])).toHaveLength(1);
    expect(run([inv({ autoEmailRequestedAt: "not-a-date" })])).toHaveLength(0);
  });

  test("future-dated stamp (clock skew) counts as fresh", () => {
    expect(run([inv({ autoEmailRequestedAt: "2026-08-06T17:00:00.000Z" })])).toHaveLength(1);
  });

  test("paid invoices are skipped — ledger, legacy flag, and zero-balance alike", () => {
    expect(run([inv({ paid: true })])).toHaveLength(0);
    expect(
      run([inv({ payments: [{ id: "p1", amount: 500, method: "card", receivedAt: "2026-08-06" }] })])
    ).toHaveLength(0);
  });

  test("malformed amount balances to zero and fails closed", () => {
    expect(run([inv({ amount: "not-a-number" })])).toHaveLength(0);
  });

  test("implausible email → skipped (open-relay guard, mirrors reminder rules)", () => {
    for (const email of ["", "no-at-sign", "a@b", "a@b.c, c@d.e", "a@b.c\r\nBcc: x@y.z"]) {
      expect(run([inv({ email })])).toHaveLength(0);
    }
  });

  test("already-claimed ids are excluded (one-and-done)", () => {
    expect(run([inv()], { alreadyHandledInvoiceIds: ["invA"] })).toHaveLength(0);
  });

  test("null/undefined entries and empty input are tolerated", () => {
    expect(run([null, undefined, inv()])).toHaveLength(1);
    expect(run([])).toHaveLength(0);
    expect(selectInvoicesToAutoEmail({ invoices: undefined, settings, alreadyHandledInvoiceIds: [], today: TODAY })).toHaveLength(0);
  });
});
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `npx jest __tests__/selectInvoicesToAutoEmail.test.js`
Expected: FAIL with "Cannot find module '../backend-workers/lib/selectInvoicesToAutoEmail'".

- [ ] **Step 3: Implement the selector**

Create `backend-workers/lib/selectInvoicesToAutoEmail.js`:

```js
// backend-workers/lib/selectInvoicesToAutoEmail.js
// Pure. Given ONE user's invoices + settings + the invoice ids already
// claimed in auto_invoice_email_log, returns the invoices whose auto-email
// should send now (2026-08-06 spec). No I/O.
//
// Only invoices the CLIENT stamped (autoEmailRequestedAt, written by
// utils/autoInvoice.ts createAutoInvoiceForJob when the owner opted in and
// the customer had an email) are ever considered — a manually created
// invoice, or the pre-existing backlog on first opt-in, can never be emailed
// by this sweep.

const { isFullyPaid } = require("./paymentMath");
const { isPlausibleEmail } = require("./selectInvoicesToRemind");

// A stamped invoice that reaches the sweep later than this never sends: a
// long-offline device syncing up weeks-old invoices must not blast stale
// email at customers. Stale ones are simply excluded on every run (no log
// row) — cheap at this scale, and it keeps the log's status enum identical
// to auto_reminder_log's.
const MAX_REQUEST_AGE_DAYS = 7;

function selectInvoicesToAutoEmail({ invoices, settings, alreadyHandledInvoiceIds, today = new Date() }) {
  // Checked at SEND time, not stamp time: turning the toggle off halts
  // anything still pending.
  if (!settings || !settings.autoEmailInvoiceOnComplete) return [];
  const handled = new Set(alreadyHandledInvoiceIds || []);
  const now = today.getTime();
  const maxAgeMs = MAX_REQUEST_AGE_DAYS * 86400000;

  return (invoices || []).filter((invoice) => {
    if (!invoice || !invoice.autoEmailRequestedAt) return false;
    const stamped = Date.parse(invoice.autoEmailRequestedAt);
    // Unparseable → fail closed. Future-dated (clock skew) counts as fresh.
    if (!Number.isFinite(stamped) || now - stamped > maxAgeMs) return false;
    // Derive from the ledger, not the stored flag (same rationale as the
    // reminder selector): a customer who paid on the spot before the sweep
    // must not be emailed a bill — and a malformed amount balances to zero,
    // which correctly fails closed here.
    if (isFullyPaid(invoice)) return false;
    if (!isPlausibleEmail(invoice.email)) return false;
    return !handled.has(invoice.id);
  });
}

module.exports = { selectInvoicesToAutoEmail, MAX_REQUEST_AGE_DAYS };
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `npx jest __tests__/selectInvoicesToAutoEmail.test.js`
Expected: PASS (10 tests).

- [ ] **Step 5: Run the full gate and commit**

Run: `npm run typecheck` then `npm test` then `npm run lint`
Expected: all green.

```bash
git add backend-workers/lib/selectInvoicesToAutoEmail.js __tests__/selectInvoicesToAutoEmail.test.js
git commit -m "feat: add invoice auto-email selector (stamped, unpaid, fresh, un-claimed)"
```

---

### Task 8: Backend email builder — `buildInvoiceEmail` (pure)

**Files:**
- Create: `backend-workers/lib/invoiceEmail.js`
- Test: `__tests__/invoiceEmailHardening.test.js`

**Interfaces:**
- Consumes: `formatMoney` from `backend-workers/lib/overdue.js`; `balanceDue`, `amountPaid`, `PAID_EPSILON` from `backend-workers/lib/paymentMath.js`; `isAllowedPaymentLink`, `sanitizeFromPhrase` from `backend-workers/lib/reminderEmail.js`.
- Produces: `buildInvoiceEmail({ invoice, settings }) → { from, to, subject, text, reply_to? }` (the exact Resend payload shape) and `SENDER = "invoices@gettradereadyapp.com"`. Task 9's runner calls this exact signature.

- [ ] **Step 1: Write the failing tests**

Create `__tests__/invoiceEmailHardening.test.js`:

```js
// __tests__/invoiceEmailHardening.test.js
// The auto-invoice email template (2026-08-06 spec) and its abuse guards —
// sibling of reminderEmailHardening.test.js. Unattended mail from the
// verified domain: sanitized From, header-safe subject, pay link only when
// amount-matched AND allowlisted.

const { buildInvoiceEmail, SENDER } = require("../backend-workers/lib/invoiceEmail");

function inv(overrides = {}) {
  return {
    id: "invA",
    customer: "Jane Smith",
    number: "INV-0001",
    amount: 500,
    due: "2026-09-05",
    email: "jane@example.com",
    phone: "",
    desc: "Water heater swap",
    paid: false,
    lineItems: [
      { description: "Labor — 4 hrs @ $85/hr", amount: 340, category: "labor" },
      { description: "Materials (2 items)", amount: 100, category: "materials" },
      { description: "Change order — Extra valve", amount: 60, category: "other" },
    ],
    ...overrides,
  };
}

const settings = {
  businessName: "Smith Plumbing",
  contactName: "Sam Smith",
  email: "sam@smithplumbing.com",
  phone: "555-0100",
  paymentNotes: "We accept check, card, or bank transfer.",
};

describe("buildInvoiceEmail", () => {
  test("payload shape: from/to/subject/text/reply_to", () => {
    const email = buildInvoiceEmail({ invoice: inv(), settings });
    expect(email.from).toBe(`Smith Plumbing via TradeReady <${SENDER}>`);
    expect(email.to).toEqual(["jane@example.com"]);
    expect(email.subject).toBe("Invoice INV-0001 from Smith Plumbing");
    expect(email.reply_to).toBe("sam@smithplumbing.com");
    expect(email.text).toContain("Hi Jane Smith");
    expect(email.text).toContain("INV-0001");
    expect(email.text).toContain("$500.00");
    expect(email.text).toContain("due 2026-09-05");
    expect(email.text).toContain("We accept check");
  });

  test("line items are listed — including the change-order line", () => {
    const { text } = buildInvoiceEmail({ invoice: inv(), settings });
    expect(text).toContain("Labor — 4 hrs @ $85/hr: $340.00");
    expect(text).toContain("Materials (2 items): $100.00");
    expect(text).toContain("Change order — Extra valve: $60.00");
  });

  test("no lineItems → no breakdown lines, total still present", () => {
    const { text } = buildInvoiceEmail({ invoice: inv({ lineItems: undefined }), settings });
    expect(text).not.toContain("  - ");
    expect(text).toContain("$500.00");
  });

  test("malformed line-item entries are tolerated", () => {
    const { text } = buildInvoiceEmail({
      invoice: inv({ lineItems: [null, { amount: 10 }, { description: "Thing" }] }),
      settings,
    });
    expect(text).toContain("Item: $10.00");
    expect(text).toContain("Thing: $0.00");
  });

  test("partial payment names both numbers", () => {
    const { text } = buildInvoiceEmail({
      invoice: inv({ payments: [{ id: "p1", amount: 200, method: "card", receivedAt: "2026-08-05" }] }),
      settings,
    });
    expect(text).toContain("$300.00 of $500.00");
  });

  test("From-phrase sanitization: quotes/angles/CRLF stripped; empty → bare sender", () => {
    // sanitizeFromPhrase DELETES ["<>\r\n] (no space substitution), then
    // collapses whitespace — so `z>\r\nBcc` fuses to `zBcc`. What matters is
    // that no header-capable character survives in the display phrase.
    const hostile = { ...settings, businessName: 'Evil" <x@y.z>\r\nBcc: a@b.c' };
    expect(buildInvoiceEmail({ invoice: inv(), settings: hostile }).from).toBe(
      `Evil x@y.zBcc: a@b.c via TradeReady <${SENDER}>`
    );
    expect(buildInvoiceEmail({ invoice: inv(), settings: { ...settings, businessName: '"<>\r\n' } }).from).toBe(
      `TradeReady <${SENDER}>`
    );
  });

  test("subject is header-safe: CR/LF in synced data cannot smuggle a header", () => {
    const { subject } = buildInvoiceEmail({
      invoice: inv({ number: "INV-1\r\nBcc: a@b.c" }),
      settings,
    });
    expect(subject).not.toMatch(/[\r\n]/);
  });

  test("no reply_to when the owner has no email", () => {
    const { reply_to } = buildInvoiceEmail({ invoice: inv(), settings: { ...settings, email: "" } });
    expect(reply_to).toBeUndefined();
  });

  test("pay link included ONLY when amount matches the balance AND host is allowlisted https", () => {
    const linked = inv({ paymentLinkUrl: "https://buy.stripe.com/abc", paymentLinkAmount: 500 });
    expect(buildInvoiceEmail({ invoice: linked, settings }).text).toContain("https://buy.stripe.com/abc");

    // Amount mismatch (e.g. minted before an edit) → line dropped.
    const mismatched = inv({ paymentLinkUrl: "https://buy.stripe.com/abc", paymentLinkAmount: 400 });
    expect(buildInvoiceEmail({ invoice: mismatched, settings }).text).not.toContain("buy.stripe.com");

    // Disallowed host (legacy Square token link) → dropped.
    const square = inv({ paymentLinkUrl: "https://squareup.com/pay/SECRET", paymentLinkAmount: 500 });
    expect(buildInvoiceEmail({ invoice: square, settings }).text).not.toContain("squareup.com");

    // http (not https) → dropped.
    const insecure = inv({ paymentLinkUrl: "http://buy.stripe.com/abc", paymentLinkAmount: 500 });
    expect(buildInvoiceEmail({ invoice: insecure, settings }).text).not.toContain("buy.stripe.com");
  });

  test("dropping the link never drops the email", () => {
    const square = inv({ paymentLinkUrl: "https://squareup.com/pay/SECRET", paymentLinkAmount: 500 });
    const email = buildInvoiceEmail({ invoice: square, settings });
    expect(email.to).toEqual(["jane@example.com"]);
    expect(email.text).toContain("$500.00");
  });
});
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `npx jest __tests__/invoiceEmailHardening.test.js`
Expected: FAIL with "Cannot find module '../backend-workers/lib/invoiceEmail'".

- [ ] **Step 3: Implement the builder**

Create `backend-workers/lib/invoiceEmail.js`:

```js
// backend-workers/lib/invoiceEmail.js
// Pure. Builds the Resend payload for one auto-emailed invoice (2026-08-06
// spec). Template-only — deterministic, no AI (unattended mail the user never
// previews). No I/O. Sibling of reminderEmail.js, reusing its hardened
// pieces: sanitizeFromPhrase for the From header, and the pay-link rule
// (amount matches the balance this email quotes + allowlisted https host —
// see reminderEmail.js for the phishing rationale). A failing link check
// drops the LINE, never the email.

const { formatMoney } = require("./overdue");
const { balanceDue, amountPaid, PAID_EPSILON } = require("./paymentMath");
const { isAllowedPaymentLink, sanitizeFromPhrase } = require("./reminderEmail");

const SENDER = "invoices@gettradereadyapp.com";

// The subject is a mail header built from user-synced data — strip CR/LF
// (header smuggling), collapse whitespace, cap the length.
function sanitizeSubject(value) {
  return String(value || "")
    .replace(/[\r\n]+/g, " ")
    .replace(/\s+/g, " ")
    .trim()
    .slice(0, 120);
}

function buildInvoiceEmail({ invoice, settings }) {
  const paid = amountPaid(invoice);
  const balance = balanceDue(invoice);
  // A partly-paid invoice (e.g. a deposit) names both numbers so the customer
  // sees their payment credited — same phrasing family as reminderEmail.js.
  const amount = paid > 0 && balance > 0
    ? `${formatMoney(balance)} of ${formatMoney(invoice.amount)} after payments received`
    : formatMoney(balance);
  const biz = settings.businessName || "your contractor";

  // Breakdown from the client-built lineItems (labor / materials / overhead /
  // approved change orders). Absent or empty → no breakdown block; the email
  // never fabricates one.
  const items = Array.isArray(invoice.lineItems) ? invoice.lineItems : [];
  const breakdown = items.length
    ? "\n" +
      items
        .filter(Boolean)
        .map((li) => `  - ${String(li.description || "Item")}: ${formatMoney(li.amount)}`)
        .join("\n") +
      "\n"
    : "";

  // Cached pay link only when minted for the balance this email quotes AND on
  // an allowlisted https host (rule shared with reminderEmail.js). An absent
  // or unparseable paymentLinkAmount fails the match — honest degradation.
  const linkAmount = typeof invoice.paymentLinkAmount === "number"
    ? invoice.paymentLinkAmount
    : parseFloat(String(invoice.paymentLinkAmount));
  const linkCurrent =
    invoice.paymentLinkUrl &&
    isAllowedPaymentLink(invoice.paymentLinkUrl) &&
    Number.isFinite(linkAmount) &&
    Math.abs(linkAmount - balance) <= PAID_EPSILON;
  const linkLine = linkCurrent
    ? `\nYou can pay securely here: ${invoice.paymentLinkUrl}\n`
    : "";
  const notes = settings.paymentNotes ? `\n${settings.paymentNotes}\n` : "";
  const forWork = invoice.desc ? ` for ${invoice.desc}` : "";

  const text = `Hi ${invoice.customer},

Thanks for your business! Here's your invoice${forWork}.

Invoice ${invoice.number} — ${amount}, due ${invoice.due}.
${breakdown}${linkLine}
Questions about this invoice? Just reply to this email or contact ${biz}.
${notes}
Best regards,
${settings.contactName || ""}
${settings.businessName || ""}
${settings.phone || ""}`.replace(/\n{3,}/g, "\n\n");

  // Header-safe From phrase; a name that sanitizes away to nothing degrades
  // to the neutral bare sender rather than an empty display name.
  const fromPhrase = sanitizeFromPhrase(settings.businessName);
  const email = {
    from: fromPhrase ? `${fromPhrase} via TradeReady <${SENDER}>` : `TradeReady <${SENDER}>`,
    to: [invoice.email],
    subject: sanitizeSubject(`Invoice ${invoice.number} from ${fromPhrase || "TradeReady"}`),
    text,
  };
  if (settings.email) email.reply_to = settings.email;
  return email;
}

module.exports = { buildInvoiceEmail, SENDER };
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `npx jest __tests__/invoiceEmailHardening.test.js`
Expected: PASS (10 tests).

- [ ] **Step 5: Run the full gate and commit**

Run: `npm run typecheck` then `npm test` then `npm run lint`
Expected: all green.

```bash
git add backend-workers/lib/invoiceEmail.js __tests__/invoiceEmailHardening.test.js
git commit -m "feat: add auto-invoice email template with reminder-grade header and link hardening"
```

---

### Task 9: Batch runner, cron route, scheduled routing, wrangler trigger

Glue mirroring the proven `sendReminders.js` pattern verbatim (claim-insert one-and-done, per-invoice isolation, best-effort markLog, daily cap). No unit test for the runner itself — matching the repo's treatment of `sendReminders.js`, whose logic lives in the tested pure libs.

**Files:**
- Create: `backend-workers/lib/sendInvoiceEmails.js`
- Modify: `backend-workers/src/routes/cron.js`
- Modify: `backend-workers/src/index.js`
- Modify: `backend-workers/wrangler.toml`

**Interfaces:**
- Consumes: `selectInvoicesToAutoEmail` (Task 7), `buildInvoiceEmail` (Task 8), table `auto_invoice_email_log` (Task 6).
- Produces: `runInvoiceEmails(env) → { scanned, sent, failed, capped }`; HTTP route `/api/cron/send-invoice-emails`; cron `*/15 * * * *`.

- [ ] **Step 1: Create the runner**

Create `backend-workers/lib/sendInvoiceEmails.js`:

```js
// 15-minute invoice auto-email batch (2026-08-06 spec) — structural sibling
// of sendReminders.js: this is the business logic both the Workers
// scheduled() trigger (*/15 cron) and the manual HTTP fallback route
// (src/routes/cron.js) call. Emails each client-stamped auto-invoice once
// (idempotency + audit via auto_invoice_email_log) for owners who opted in
// (settings.autoEmailInvoiceOnComplete).
//
// Required bindings:
//   SUPABASE_URL
//   SUPABASE_SERVICE_ROLE_KEY — service role (bypasses RLS to scan all users)
//   RESEND_API_KEY            — Resend REST API key (sender domain already verified)

const { selectInvoicesToAutoEmail } = require("./selectInvoicesToAutoEmail");
const { buildInvoiceEmail } = require("./invoiceEmail");

// Same rationale as sendReminders.js's cap: sends are one-and-done per
// invoice, so honest volume is bounded by NEW auto-invoices in a day; 25
// covers a solo operator's busiest day while capping the blast radius of a
// hostile account. Counted from log rows stamped today (UTC) — the claim
// insert defaults sent_at to now(), so pending/failed attempts count too.
const MAX_INVOICE_EMAILS_PER_USER_PER_DAY = 25;

function sbFetch(env, path, init = {}) {
  return fetch(`${env.SUPABASE_URL}/rest/v1/${path}`, {
    ...init,
    headers: {
      Authorization: `Bearer ${env.SUPABASE_SERVICE_ROLE_KEY}`,
      apikey: env.SUPABASE_SERVICE_ROLE_KEY,
      "Content-Type": "application/json",
      ...(init.headers || {}),
    },
  });
}

// Best-effort status write for an already-claimed log row. NEVER throws — a
// failure to record status must not flip a delivered email to 'failed', abort
// the batch, or double-count.
async function markLog(env, logId, patch) {
  try {
    const r = await sbFetch(env, `auto_invoice_email_log?id=eq.${logId}`, {
      method: "PATCH",
      body: JSON.stringify(patch),
    });
    if (!r.ok) console.error("[send-invoice-emails] status write non-2xx", logId, r.status);
  } catch (e) {
    console.error("[send-invoice-emails] status write threw", logId, e.message);
  }
}

// Runs one sweep. Returns { scanned, sent, failed, capped }; throws on a
// fatal (whole-batch) error — callers map that to a 500 / scheduled-run log.
async function runInvoiceEmails(env) {
  if (!env.SUPABASE_URL || !env.SUPABASE_SERVICE_ROLE_KEY || !env.RESEND_API_KEY) {
    throw new Error("Server misconfiguration: SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, RESEND_API_KEY required.");
  }

  const today = new Date();
  let scanned = 0;
  let sent = 0;
  let failed = 0;
  let capped = 0;

  const [invRows, setRows, logRows] = await Promise.all([
    // All non-deleted invoices; the selector filters to stamped+fresh+unpaid.
    // No jobs fetch (unlike sendReminders.js): a deposit-finalize job never
    // enters this path — shouldAutoInvoice refuses jobs with an invoiceId.
    sbFetch(env, "invoices?deleted=is.false&select=id,user_id,data").then((r) => r.json()),
    sbFetch(env, "settings?select=user_id,data").then((r) => r.json()),
    sbFetch(env, "auto_invoice_email_log?select=user_id,invoice_id,sent_at").then((r) => r.json()),
  ]);

  const settingsByUser = new Map((setRows || []).map((r) => [r.user_id, r.data]));
  const dayStart = new Date(today);
  dayStart.setUTCHours(0, 0, 0, 0);
  const handledByUser = new Map();
  const todayCountByUser = new Map();
  for (const row of logRows || []) {
    if (!handledByUser.has(row.user_id)) handledByUser.set(row.user_id, new Set());
    handledByUser.get(row.user_id).add(row.invoice_id);
    const stamped = Date.parse(row.sent_at);
    if (Number.isFinite(stamped) && stamped >= dayStart.getTime()) {
      todayCountByUser.set(row.user_id, (todayCountByUser.get(row.user_id) || 0) + 1);
    }
  }

  const invByUser = new Map();
  for (const row of invRows || []) {
    const invoice = { ...row.data, id: row.id };
    if (!invByUser.has(row.user_id)) invByUser.set(row.user_id, []);
    invByUser.get(row.user_id).push(invoice);
  }

  for (const [userId, invoices] of invByUser) {
    const settings = settingsByUser.get(userId);
    const alreadyHandled = [...(handledByUser.get(userId) || [])];
    const toSend = selectInvoicesToAutoEmail({ invoices, settings, alreadyHandledInvoiceIds: alreadyHandled, today });
    let claimedToday = todayCountByUser.get(userId) || 0;
    let deferred = 0;

    for (const invoice of toSend) {
      // Daily cap: everything past the ceiling waits — no log row is written,
      // so a later run picks it up (within the 7-day freshness window).
      if (claimedToday >= MAX_INVOICE_EMAILS_PER_USER_PER_DAY) {
        deferred++;
        continue;
      }
      scanned++;
      // Per-invoice isolation: a network throw on the claim must not abort
      // the whole batch.
      try {
        // CLAIM: insert first as 'pending'. A conflict on (user_id, invoice_id)
        // returns [] → already handled by a prior run (one-and-done), skip.
        const claimRes = await sbFetch(env, "auto_invoice_email_log?on_conflict=user_id,invoice_id", {
          method: "POST",
          headers: { Prefer: "return=representation,resolution=ignore-duplicates" },
          body: JSON.stringify({ user_id: userId, invoice_id: invoice.id, to_email: invoice.email, status: "pending" }),
        });
        if (!claimRes.ok) {
          // e.g. table missing (migration not applied) or a permissions error —
          // surface it instead of silently treating it as a duplicate.
          failed++;
          console.error("[send-invoice-emails] claim failed", invoice.id, claimRes.status, await claimRes.text());
          continue;
        }
        const claimed = await claimRes.json().catch(() => []);
        if (!Array.isArray(claimed) || claimed.length === 0) continue; // already claimed
        const logId = claimed[0].id;
        claimedToday++;

        // SEND, then record the outcome via best-effort markLog (never throws).
        try {
          const email = buildInvoiceEmail({ invoice, settings });
          const r = await fetch("https://api.resend.com/emails", {
            method: "POST",
            headers: { Authorization: `Bearer ${env.RESEND_API_KEY}`, "Content-Type": "application/json" },
            body: JSON.stringify(email),
          });
          if (!r.ok) throw new Error(`Resend ${r.status}: ${await r.text()}`);
          sent++;
          await markLog(env, logId, { status: "sent", sent_at: new Date().toISOString() });
        } catch (sendErr) {
          failed++;
          console.error("[send-invoice-emails] send failed", invoice.id, sendErr.message);
          await markLog(env, logId, { status: "failed", error: String(sendErr.message).slice(0, 500) });
        }
      } catch (invErr) {
        failed++;
        console.error("[send-invoice-emails] invoice error", invoice.id, invErr.message);
      }
    }

    if (deferred > 0) {
      capped += deferred;
      console.error("[send-invoice-emails] daily cap reached", userId, "deferred", deferred);
    }
  }

  return { scanned, sent, failed, capped };
}

module.exports = { runInvoiceEmails, MAX_INVOICE_EMAILS_PER_USER_PER_DAY };
```

- [ ] **Step 2: Add the manual-run route**

In `backend-workers/src/routes/cron.js`, add below the existing import:

```js
import { runInvoiceEmails } from '../../lib/sendInvoiceEmails.js';
```

And append after `cronSendRemindersHandler`:

```js
// GET /api/cron/send-invoice-emails — manual-run HTTP fallback for the
// invoice auto-email sweep (2026-08-06 spec), same shape and guards as the
// reminder handler above. The PRODUCTION trigger is the Workers */15 cron.
export async function cronSendInvoiceEmailsHandler(c) {
  if (!c.env.CRON_SECRET) {
    console.error('[send-invoice-emails] CRON_SECRET not configured');
    return c.json({ error: 'Cron not configured' }, 500);
  }
  if (c.req.header('authorization') !== `Bearer ${c.env.CRON_SECRET}`) {
    return c.json({ error: 'Unauthorized' }, 401);
  }
  if (!c.env.SUPABASE_URL || !c.env.SUPABASE_SERVICE_ROLE_KEY || !c.env.RESEND_API_KEY) {
    return c.json({ error: 'Server misconfiguration: SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, RESEND_API_KEY required.' }, 500);
  }

  try {
    const counts = await runInvoiceEmails(c.env);
    return c.json(counts, 200);
  } catch (err) {
    console.error('[send-invoice-emails] fatal', err.message);
    return c.json({ error: 'Invoice email run failed' }, 500);
  }
}
```

- [ ] **Step 3: Wire index.js — route + per-cron scheduled dispatch**

In `backend-workers/src/index.js`:

Add to the imports:

```js
import { runInvoiceEmails } from '../lib/sendInvoiceEmails.js';
```

Change the cron.js import line to:

```js
import { cronSendRemindersHandler, cronSendInvoiceEmailsHandler } from './routes/cron.js';
```

After the `app.all('/api/cron/send-reminders', ...)` line add:

```js
app.all('/api/cron/send-invoice-emails', cronSendInvoiceEmailsHandler);
```

Replace the `scheduled` handler:

```js
  // Workers Cron Triggers (wrangler.toml [triggers]) dispatched by pattern:
  // */15 → the invoice auto-email sweep; the daily 15:00 UTC trigger keeps
  // running the payment reminders. At 15:00 both fire — disjoint batches
  // over different log tables, harmless. Only Cloudflare's scheduler can
  // invoke this, so the CRON_SECRET bearer check lives solely on the manual
  // HTTP fallback routes.
  async scheduled(event, env, ctx) {
    if (event.cron === '*/15 * * * *') {
      ctx.waitUntil(
        runInvoiceEmails(env).catch((err) =>
          console.error('[send-invoice-emails] scheduled run failed:', err.message)
        )
      );
      return;
    }
    ctx.waitUntil(
      runReminders(env).catch((err) =>
        console.error('[send-reminders] scheduled run failed:', err.message)
      )
    );
  },
```

- [ ] **Step 4: Add the cron trigger**

In `backend-workers/wrangler.toml`, replace the `[triggers]` block:

```toml
[triggers]
# Daily 15:00 UTC: payment reminders (same schedule vercel.json's crons ran).
# Every 15 min: the invoice auto-email sweep (2026-08-06 spec) — dispatched
# by pattern in src/index.js scheduled().
crons = ["0 15 * * *", "*/15 * * * *"]
```

- [ ] **Step 5: Run the full gate and commit**

Run: `npm run typecheck` then `npm test` then `npm run lint`
Expected: all green (lint covers `backend-workers/**/*.js`; nothing here is in tsc scope; no test-count change).

```bash
git add backend-workers/lib/sendInvoiceEmails.js backend-workers/src/routes/cron.js backend-workers/src/index.js backend-workers/wrangler.toml
git commit -m "feat: add 15-min invoice auto-email sweep (cron trigger, runner, manual fallback route)"
```

**NOTE for the phase report:** deployment (`npx wrangler deploy` from `backend-workers/`) is a separate operational step for the owner/next phase, AFTER the Task 6 migration is applied. No new secrets are needed.

---

### Task 10: Documentation

**Files:**
- Modify: `ARCHITECTURE.md`
- Modify: `docs/superpowers/specs/2026-08-06-auto-email-invoice-design.md` (Status line only)

**Interfaces:** none — prose only.

- [ ] **Step 1: Update ARCHITECTURE.md**

Find the Current State text that documents auto-invoice on complete (search for `autoInvoiceOnComplete` or "Auto-invoice"). Append this sentence to that feature's description (or, if no such entry exists, add a bullet to the invoicing/automation feature list):

```markdown
Opt-in second tier (`autoEmailInvoiceOnComplete`, 2026-08-06): the auto-created invoice is emailed to the customer by a 15-minute Workers cron (Resend, `invoices@gettradereadyapp.com`, one-and-done via `auto_invoice_email_log`) — including approved change-order lines and a payment link when one was minted at creation; with no customer email on file the send screen opens as before.
```

- [ ] **Step 2: Flip the spec status**

In `docs/superpowers/specs/2026-08-06-auto-email-invoice-design.md`, change the Status line:

```markdown
**Date:** 2026-08-06 · **Status:** owner-approved; built per docs/superpowers/plans/2026-08-06-auto-email-invoice.md (pending owner smoke + Worker deploy + migration + OTA)
```

- [ ] **Step 3: Run the gate (docs-only sanity) and commit**

Run: `npm run typecheck` then `npm run lint`
Expected: green (docs cannot affect them; this is the pre-commit habit).

```bash
git add ARCHITECTURE.md docs/superpowers/specs/2026-08-06-auto-email-invoice-design.md
git commit -m "docs: record auto-email-invoice tier in ARCHITECTURE and flip spec status"
```

---

## Post-plan operational checklist (owner / later phase — NOT part of these tasks)

1. Apply `supabase/migrations/20260806_auto_invoice_email_log.sql` in the Supabase SQL editor.
2. Deploy the Worker: `npx wrangler deploy` from `backend-workers/` (verify the two cron triggers appear in the deploy output).
3. Client changes ride the next OTA train (post-1.1.0 approval, subject to the standing trip-sync/privacy-label ordering gates).
4. Smoke: flip both toggles on a device, complete a job with a customer that has an email, confirm the alert, then confirm the email arrives within ~15 min and `auto_invoice_email_log` shows `status='sent'`.

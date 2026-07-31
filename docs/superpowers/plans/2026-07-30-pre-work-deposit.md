# Pre-Work Deposit Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the owner request and collect a deposit as soon as a job is `"approved"` (not just after it's marked `"complete"`), by creating the `Invoice` early and reusing the existing payment-ledger and deposit-request machinery unchanged.

**Architecture:** Extract three pure decision functions into `utils/jobStatus.ts` (`canRequestDeposit`, `invoiceScreenMode`, `jobChangesAfterInvoiceSave`, `invoiceScreenCopy`), unit-test them directly, then wire `screens/JobDetailScreen.tsx` and `screens/CreateInvoiceFromJobScreen.tsx` to call them. No data-shape changes, no navigation-type changes, no ledger changes.

**Tech Stack:** Expo / React Native 0.81 / TypeScript, Jest (business-logic unit tests only — this repo has no screen-level RNTL tests, and this plan does not add the first one).

## Global Constraints

- No new `Job` or `Invoice` fields — `Job.invoiceId: string | null` already exists and is reused as-is.
- No new dependencies, no navigation param-type changes (`CreateInvoiceFromJob: { jobId: string }` and `Outreach: { invoiceId: string }` are unchanged).
- Gate must stay green throughout: baseline confirmed on this branch (`feat/pre-work-deposit`, off `master`) is **tsc 0 errors, lint 0 warnings, 1286 tests / 81 suites**. Every task ends with `npm run typecheck`, `npm test`, `npm run lint` all clean.
- Follow existing repo convention: business logic lives in `utils/`, is unit-tested there; screens stay thin callers and are not separately unit-tested (matching `utils/jobStatus.ts`'s existing doc comment: "kept out of the screens so it's unit-tested").
- Commit after each task, per `tradeready-change-control`.

---

### Task 1: Pure decision helpers in `utils/jobStatus.ts`

**Files:**
- Modify: `utils/jobStatus.ts`
- Test: `__tests__/jobStatus.test.js`

**Interfaces:**
- Produces (consumed by Tasks 2 and 3):
  - `canRequestDeposit(status: JobStatus): boolean`
  - `type InvoiceScreenMode = "create" | "requestDeposit" | "finalize"`
  - `invoiceScreenMode(status: JobStatus, hasInvoice: boolean): InvoiceScreenMode | null`
  - `jobChangesAfterInvoiceSave(mode: InvoiceScreenMode, invoiceId: string): Partial<Job>`
  - `invoiceScreenCopy(mode: InvoiceScreenMode): { title: string; cta: string }`

- [ ] **Step 1: Write the failing tests**

Append to `__tests__/jobStatus.test.js` (after the existing `canSendEstimate` describe block, end of file):

```js
const {
  canRequestDeposit,
  invoiceScreenMode,
  jobChangesAfterInvoiceSave,
  invoiceScreenCopy,
} = require('../utils/jobStatus');

// Pre-work deposits: a deposit can be requested as soon as the estimate is
// approved, not just after the job is marked complete. These helpers decide
// which of CreateInvoiceFromJobScreen's three modes applies, and — critically
// — that requesting a deposit early never advances job.status.
describe('canRequestDeposit', () => {
  it('is true for approved, scheduled, and in_progress', () => {
    expect(canRequestDeposit('approved')).toBe(true);
    expect(canRequestDeposit('scheduled')).toBe(true);
    expect(canRequestDeposit('in_progress')).toBe(true);
  });

  it('is false before approval and once the job is done', () => {
    for (const s of ['lead', 'estimate_sent', 'complete', 'invoiced', 'paid', 'declined']) {
      expect(canRequestDeposit(s)).toBe(false);
    }
  });
});

describe('invoiceScreenMode', () => {
  it('is "requestDeposit" for deposit-eligible statuses with no invoice yet', () => {
    expect(invoiceScreenMode('approved', false)).toBe('requestDeposit');
    expect(invoiceScreenMode('scheduled', false)).toBe('requestDeposit');
    expect(invoiceScreenMode('in_progress', false)).toBe('requestDeposit');
  });

  it('is "create" at complete with no invoice yet', () => {
    expect(invoiceScreenMode('complete', false)).toBe('create');
  });

  it('is "finalize" at complete once a deposit invoice already exists', () => {
    expect(invoiceScreenMode('complete', true)).toBe('finalize');
  });

  it('is null for a deposit-eligible status that already has an invoice (JobDetailScreen routes to Outreach instead)', () => {
    expect(invoiceScreenMode('approved', true)).toBeNull();
    expect(invoiceScreenMode('scheduled', true)).toBeNull();
    expect(invoiceScreenMode('in_progress', true)).toBeNull();
  });

  it('is null before approval and after invoicing, regardless of invoiceId', () => {
    for (const s of ['lead', 'estimate_sent', 'invoiced', 'paid', 'declined']) {
      expect(invoiceScreenMode(s, false)).toBeNull();
      expect(invoiceScreenMode(s, true)).toBeNull();
    }
  });
});

describe('jobChangesAfterInvoiceSave', () => {
  it('requesting a deposit early never advances status — the core invariant', () => {
    expect(jobChangesAfterInvoiceSave('requestDeposit', 'inv123')).toEqual({ invoiceId: 'inv123' });
  });

  it('creating at complete advances to invoiced', () => {
    expect(jobChangesAfterInvoiceSave('create', 'inv123')).toEqual({ status: 'invoiced', invoiceId: 'inv123' });
  });

  it('finalizing advances to invoiced', () => {
    expect(jobChangesAfterInvoiceSave('finalize', 'inv123')).toEqual({ status: 'invoiced', invoiceId: 'inv123' });
  });
});

describe('invoiceScreenCopy', () => {
  it('returns distinct title/cta per mode', () => {
    expect(invoiceScreenCopy('requestDeposit')).toEqual({ title: 'Request Deposit', cta: 'Request deposit →' });
    expect(invoiceScreenCopy('finalize')).toEqual({ title: 'Finalize Invoice', cta: 'Finalize invoice →' });
    expect(invoiceScreenCopy('create')).toEqual({ title: 'Create Invoice', cta: 'Create invoice →' });
  });
});
```

- [ ] **Step 2: Run the new tests to verify they fail**

Run: `npx jest jobStatus -v`
Expected: FAIL — `canRequestDeposit`, `invoiceScreenMode`, `jobChangesAfterInvoiceSave`, `invoiceScreenCopy` are not exported from `../utils/jobStatus`.

- [ ] **Step 3: Implement the helpers**

Edit `utils/jobStatus.ts`. First, widen the type import (currently `import type { JobStatus } from "../types/models";`):

```ts
import type { Job, JobStatus } from "../types/models";
```

Then append at the end of the file:

```ts

const DEPOSIT_ELIGIBLE_STATUSES: JobStatus[] = ["approved", "scheduled", "in_progress"];

/**
 * Whether a deposit can be requested for a job at this status — any point
 * after the customer has approved the estimate but before the job is done.
 * Once "complete", invoicing takes over (see invoiceScreenMode).
 */
export function canRequestDeposit(status: JobStatus): boolean {
  return DEPOSIT_ELIGIBLE_STATUSES.includes(status);
}

export type InvoiceScreenMode = "create" | "requestDeposit" | "finalize";

/**
 * Which of CreateInvoiceFromJobScreen's three modes applies for a given job.
 * Returns null for any status/invoiceId combination that should never reach
 * that screen — e.g. a deposit-eligible status that already has an invoice,
 * which JobDetailScreen routes straight to Outreach for instead.
 */
export function invoiceScreenMode(status: JobStatus, hasInvoice: boolean): InvoiceScreenMode | null {
  if (status === "complete") return hasInvoice ? "finalize" : "create";
  if (canRequestDeposit(status) && !hasInvoice) return "requestDeposit";
  return null;
}

/**
 * The Job patch to apply once CreateInvoiceFromJobScreen saves. The core
 * invariant lives here: requesting a deposit early must never advance the job
 * to "invoiced" — only finishing the job (create at complete, or finalize an
 * existing deposit invoice at complete) does that.
 */
export function jobChangesAfterInvoiceSave(mode: InvoiceScreenMode, invoiceId: string): Partial<Job> {
  if (mode === "requestDeposit") return { invoiceId };
  return { status: "invoiced", invoiceId };
}

/** Screen title + primary-button copy for each CreateInvoiceFromJobScreen mode. */
export function invoiceScreenCopy(mode: InvoiceScreenMode): { title: string; cta: string } {
  switch (mode) {
    case "requestDeposit":
      return { title: "Request Deposit", cta: "Request deposit →" };
    case "finalize":
      return { title: "Finalize Invoice", cta: "Finalize invoice →" };
    case "create":
    default:
      return { title: "Create Invoice", cta: "Create invoice →" };
  }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `npx jest jobStatus -v`
Expected: PASS — all `describe` blocks in `jobStatus.test.js` green (existing + the four new ones).

- [ ] **Step 5: Typecheck**

Run: `npm run typecheck`
Expected: no errors (the new `Job` import must resolve; `Partial<Job>` must typecheck).

- [ ] **Step 6: Commit**

```bash
git add utils/jobStatus.ts __tests__/jobStatus.test.js
git commit -m "feat: add pure decision helpers for pre-work deposits (jobStatus.ts)"
```

---

### Task 2: `JobDetailScreen.tsx` — secondary deposit action + complete-action label

**Files:**
- Modify: `screens/JobDetailScreen.tsx:31` (import), `screens/JobDetailScreen.tsx:514-519` (complete action), `screens/JobDetailScreen.tsx:547` (after `PrimaryAction`, new component), `screens/JobDetailScreen.tsx:805-809` (render)

**Interfaces:**
- Consumes: `canRequestDeposit(status: JobStatus): boolean` from Task 1.
- Produces: nothing new consumed by later tasks — this is UI wiring only.

- [ ] **Step 1: Import the new helper**

In `screens/JobDetailScreen.tsx`, change:

```ts
import { canSendEstimate } from "../utils/jobStatus";
```

to:

```ts
import { canSendEstimate, canRequestDeposit } from "../utils/jobStatus";
```

- [ ] **Step 2: Make the "complete" primary action label depend on whether an invoice already exists**

In the `PrimaryAction` function's `actions` object, change:

```tsx
    complete: {
      label: "Create invoice",
      onPress: () =>
        navigation.navigate("CreateInvoiceFromJob", { jobId: job.id }),
      variant: "primary",
    },
```

to:

```tsx
    complete: {
      label: job.invoiceId ? "Finalize invoice" : "Create invoice",
      onPress: () =>
        navigation.navigate("CreateInvoiceFromJob", { jobId: job.id }),
      variant: "primary",
    },
```

(The navigation target is unchanged — `CreateInvoiceFromJobScreen` itself picks the right mode via `invoiceScreenMode`, built in Task 3.)

- [ ] **Step 3: Add the `DepositAction` component**

Immediately after the closing `}` of the `PrimaryAction` function (i.e. right before the `// ── Main Screen ──` comment), add:

```tsx
function DepositAction({ job, navigation }: { job: Job; navigation: JobStackScreenProps<'JobDetail'>['navigation'] }) {
  if (!canRequestDeposit(job.status)) return null;

  if (job.invoiceId) {
    const invoiceId = job.invoiceId;
    return (
      <Button
        label="View deposit →"
        variant="secondary"
        onPress={() => navigation.navigate("Outreach", { invoiceId })}
        style={{ marginBottom: spacing.sm }}
      />
    );
  }

  return (
    <Button
      label="Request deposit →"
      variant="secondary"
      onPress={() => navigation.navigate("CreateInvoiceFromJob", { jobId: job.id })}
      style={{ marginBottom: spacing.sm }}
    />
  );
}
```

- [ ] **Step 4: Render it below the primary action**

In the main screen's render, change:

```tsx
        <PrimaryAction
          job={job}
          navigation={navigation}
          onAdvance={advanceStatus}
        />

        {job.status === "declined" && (
```

to:

```tsx
        <PrimaryAction
          job={job}
          navigation={navigation}
          onAdvance={advanceStatus}
        />

        <DepositAction job={job} navigation={navigation} />

        {job.status === "declined" && (
```

- [ ] **Step 5: Typecheck**

Run: `npm run typecheck`
Expected: no errors.

- [ ] **Step 6: Manual smoke check (no automated screen tests in this repo)**

Run: `npx jest -v` (full suite — confirms this change didn't break any utils test that happens to import from this screen; none currently do, so this should be a no-op pass)
Expected: `Test Suites: 81 passed, 81 total` / `Tests: 1286 passed, 1286 total` (unchanged from baseline — this task adds no new test files).

- [ ] **Step 7: Commit**

```bash
git add screens/JobDetailScreen.tsx
git commit -m "feat: add Request/View deposit action to JobDetailScreen"
```

---

### Task 3: `CreateInvoiceFromJobScreen.tsx` — three-mode branching

**Files:**
- Modify: `screens/CreateInvoiceFromJobScreen.tsx` (full-file rewrite — the mode branching touches the imports, state, prefill effect, save handler, and JSX)

**Interfaces:**
- Consumes: `invoiceScreenMode`, `jobChangesAfterInvoiceSave`, `invoiceScreenCopy`, `type InvoiceScreenMode` from `utils/jobStatus.ts` (Task 1); `amountPaid` from `utils/invoicePayments.ts` (already exists, unmodified).
- Produces: nothing new consumed by later tasks.

- [ ] **Step 1: Replace the entire file**

Replace the full contents of `screens/CreateInvoiceFromJobScreen.tsx` with:

```tsx
// screens/CreateInvoiceFromJobScreen.tsx
// Bridges a job into an invoice — either the final bill (job complete) or an
// up-front deposit request (job approved/scheduled/in_progress, before work is
// done). Pre-fills everything it can so the user just reviews and taps the
// button — no retyping.
//
// Three modes (utils/jobStatus.ts invoiceScreenMode), keyed off
// (job.status, job.invoiceId):
//   "create"         — job complete, no invoice yet. Creates one, job -> invoiced.
//   "requestDeposit" — job approved/scheduled/in_progress, no invoice yet.
//                       Creates one WITHOUT advancing job.status.
//   "finalize"       — job complete, invoice already exists (deposit was
//                       requested earlier). Updates that invoice in place,
//                       job -> invoiced.
//
// Flow: JobDetailScreen → here → Outreach
// Side effects:
//   1. Saves the invoice to AsyncStorage (invoices key) — new row for
//      "create"/"requestDeposit", in-place update for "finalize".
//   2. Applies jobChangesAfterInvoiceSave(mode, invoiceId) to the job.

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
  ActivityIndicator,
} from "react-native";
import { SafeAreaView } from "react-native-safe-area-context";
import { loadJobs, saveJobs, loadInvoices, saveInvoices, loadCustomers, getOrCreateCustomer } from "../utils/storage";
import { computeEstimateBreakdown } from "../utils/pricingEngine";
import { invoiceScreenMode, jobChangesAfterInvoiceSave, invoiceScreenCopy, type InvoiceScreenMode } from "../utils/jobStatus";
import { amountPaid } from "../utils/invoicePayments";
import { formatQuote } from "../utils/format";
import Field from "../components/Field";
import { spacing, radius, fontSize } from "../utils/theme";
import type { ColorScheme, ShadowScheme } from "../utils/theme";
import { useTheme } from '../hooks/useTheme';
import { track, reportError } from '../utils/analytics';
import type { Job, Invoice, Customer, InvoiceLineItem } from "../types/models";
import type { JobStackScreenProps } from "../types/navigation";

function trackedDisplay(sessions: any[] = []): string | null {
  const ms = sessions
    .filter((s) => s.end)
    .reduce((sum: number, s: any) => sum + (new Date(s.end) as any) - (new Date(s.start) as any), 0);
  if (ms <= 0) return null;
  const h = Math.floor(ms / 3600000);
  const m = Math.floor((ms % 3600000) / 60000);
  return h > 0 ? `${h}h ${m}m` : `${m}m`;
}

// Default payment terms: 30 days from today
function defaultDueDate(): string {
  const d = new Date();
  d.setDate(d.getDate() + 30);
  return d.toISOString().split("T")[0];
}

// Auto-generate the next invoice number from existing invoices
function nextInvoiceNumber(invoices: Invoice[]): string {
  const nums = invoices
    .map((inv) => parseInt((inv.number || "").replace(/\D/g, ""), 10))
    .filter(Boolean);
  const next = nums.length ? Math.max(...nums) + 1 : 1;
  return `INV-${String(next).padStart(4, "0")}`;
}

export default function CreateInvoiceFromJobScreen({ route, navigation }: JobStackScreenProps<'CreateInvoiceFromJob'>) {
  const { colors, shadow } = useTheme();
  const styles = useMemo(() => createStyles(colors, shadow), [colors, shadow]);
  const { jobId } = route.params;

  const [loading, setLoading]   = useState<boolean>(true);
  const [saving, setSaving]     = useState<boolean>(false);
  const [job, setJob]           = useState<Job | null>(null);
  const [mode, setMode]         = useState<InvoiceScreenMode>("create");
  const [existingInvoice, setExistingInvoice] = useState<Invoice | null>(null);

  // Editable invoice fields — pre-filled from the job (or, in "finalize" mode,
  // from the existing deposit invoice, so a manually-adjusted amount survives).
  const [customer, setCustomer] = useState<string>("");
  const [number, setNumber]     = useState<string>("");
  const [amount, setAmount]     = useState<string>("");
  const [due, setDue]           = useState<string>(defaultDueDate());
  const [email, setEmail]       = useState<string>("");
  const [phone, setPhone]       = useState<string>("");
  const [desc, setDesc]         = useState<string>("");

  useEffect(() => {
    async function prefillFromJob() {
      try {
        const [jobs, invoices, customers] = await Promise.all([loadJobs(), loadInvoices(), loadCustomers()]);
        const j: Job | undefined = jobs.find((x: Job) => x.id === jobId);

        if (!j) {
          Alert.alert("Error", "Job not found.");
          navigation.goBack();
          return;
        }

        const screenMode = invoiceScreenMode(j.status, !!j.invoiceId);
        if (!screenMode) {
          Alert.alert("Error", "This job isn't ready for an invoice yet.");
          navigation.goBack();
          return;
        }
        setMode(screenMode);
        navigation.setOptions({ title: invoiceScreenCopy(screenMode).title });

        const matchingCustomer: Customer | undefined = customers.find((c: Customer) => c.id === j.customerId);

        setJob(j);

        if (screenMode === "finalize") {
          const existing = invoices.find((inv) => inv.id === j.invoiceId);
          if (!existing) {
            Alert.alert("Error", "The deposit invoice for this job could not be found.");
            navigation.goBack();
            return;
          }
          setExistingInvoice(existing);
          setCustomer(existing.customer);
          setNumber(existing.number);
          setAmount(String(existing.amount));
          setDue(existing.due);
          setEmail(existing.email);
          setPhone(existing.phone);
          setDesc(existing.desc);
        } else {
          setCustomer(j.customerName || "");
          setAmount(j.estimateTotal > 0 ? String(j.estimateTotal) : "");
          setEmail(matchingCustomer?.email || "");
          setPhone(matchingCustomer?.phone || "");
          setDesc(j.title || "");
          setNumber(nextInvoiceNumber(invoices));
        }
      } catch (err: unknown) {
        console.error("CreateInvoiceFromJobScreen: prefill failed", err);
        reportError(err, { context: 'invoicePrefill' });
      } finally {
        setLoading(false);
      }
    }
    prefillFromJob();
  }, [jobId, navigation]);

  async function handleCreate() {
    if (!customer.trim()) {
      Alert.alert("Missing info", "Customer name is required.");
      return;
    }
    const parsedAmount = parseFloat(amount);
    if (!amount || isNaN(parsedAmount) || parsedAmount <= 0) {
      Alert.alert("Missing info", "Please enter a valid invoice amount.");
      return;
    }

    setSaving(true);
    try {
      const [jobs, invoices] = await Promise.all([loadJobs(), loadInvoices()]);

      // Link to a real customer record (matches the job's customer by name, or
      // creates one); `customer` stays as the denormalized display name (#5).
      const record = await getOrCreateCustomer({
        name: customer.trim(),
        email: email.trim(),
        phone: phone.trim(),
      });

      // Derive line items from the job's current estimate breakdown — recomputed
      // fresh even in "finalize" mode, so estimate edits made after the deposit
      // was requested (extra materials, a change order) are picked up.
      const lineItems: InvoiceLineItem[] = [];
      if (job) {
        const { laborCost, materialCost, overheadLine, hasMaterials } = computeEstimateBreakdown(job);
        if (laborCost > 0) {
          lineItems.push({
            description: `Labor — ${job.laborHours || 0} hrs @ ${formatQuote(job.laborRate || 0)}/hr`,
            amount: laborCost,
            category: "labor",
          });
        }
        if (hasMaterials) {
          const materials = job.materials || [];
          const label = materials.length === 1
            ? materials[0].name || "Materials"
            : `Materials (${materials.length} items)`;
          lineItems.push({ description: label, amount: materialCost, category: "materials" });
        }
        if (overheadLine > 1) {
          lineItems.push({ description: "Overhead & operating costs", amount: overheadLine, category: "overhead" });
        }
      }

      let savedInvoiceId: string;

      if (mode === "finalize" && existingInvoice) {
        const updatedInvoice: Invoice = {
          ...existingInvoice,
          customer:   customer.trim(),
          customerId: record?.id ?? existingInvoice.customerId ?? "",
          number:     number.trim() || existingInvoice.number,
          amount:     parsedAmount,
          due,
          email:      email.trim(),
          phone:      phone.trim(),
          desc:       desc.trim(),
          lineItems:  lineItems.length > 0 ? lineItems : existingInvoice.lineItems,
        };
        const updatedInvoices = invoices.map((inv) => (inv.id === existingInvoice.id ? updatedInvoice : inv));
        await saveInvoices(updatedInvoices);
        track('invoice_finalized', { source: 'from_job' });
        savedInvoiceId = existingInvoice.id;
      } else {
        const newInvoice = {
          id:         `inv${Date.now()}`,
          customer:   customer.trim(),
          customerId: record?.id ?? "",
          number:   number.trim() || nextInvoiceNumber(invoices),
          amount:   parsedAmount,
          due,
          email:    email.trim(),
          phone:    phone.trim(),
          desc:     desc.trim(),
          paid:     false,
          jobId,
          ...(lineItems.length > 0 ? { lineItems } : {}),
        };
        await saveInvoices([...invoices, newInvoice]);
        track('invoice_created', { source: 'from_job', mode });
        savedInvoiceId = newInvoice.id;
      }

      const jobChanges = jobChangesAfterInvoiceSave(mode, savedInvoiceId);
      const updatedJobs = jobs.map((j): Job =>
        j.id === jobId ? { ...j, ...jobChanges } : j
      );
      await saveJobs(updatedJobs);

      // Go straight to the outreach screen so they can send it immediately.
      // Replace this screen in the stack so Back doesn't return here.
      navigation.replace("Outreach", { invoiceId: savedInvoiceId });
    } catch (err: unknown) {
      console.error("CreateInvoiceFromJobScreen: save failed", err);
      reportError(err, { context: 'invoiceCreate' });
      Alert.alert("Error", "Could not save invoice. Please try again.");
    } finally {
      setSaving(false);
    }
  }

  const copy = invoiceScreenCopy(mode);

  if (loading) {
    return (
      <View style={styles.loadingContainer}>
        <ActivityIndicator color={colors.accent} size={36} />
      </View>
    );
  }

  return (
    <SafeAreaView style={styles.container} edges={["bottom"]}>
      <KeyboardAvoidingView
        behavior={Platform.OS === "ios" ? "padding" : undefined}
        style={{ flex: 1 }}
      >
        <ScrollView
          contentContainerStyle={styles.scroll}
          keyboardShouldPersistTaps="handled"
        >
          {/* Deposit-already-requested notice (finalize mode only) */}
          {mode === "finalize" && existingInvoice?.depositRequest && (
            <View style={styles.prefillBanner}>
              <Text style={styles.prefillBannerText}>
                Deposit already requested: {formatQuote(existingInvoice.depositRequest.amount)}
                {existingInvoice.depositRequest.percent ? ` (${existingInvoice.depositRequest.percent}%)` : ""}
                {amountPaid(existingInvoice) > 0
                  ? ` — ${formatQuote(amountPaid(existingInvoice))} received.`
                  : " — not yet received."}
                {" "}Review the total below before finalizing.
              </Text>
            </View>
          )}

          {/* Pre-fill notice (create / requestDeposit modes only — finalize
              prefills from the existing invoice, not the raw estimate) */}
          {mode !== "finalize" && job && job.estimateTotal > 0 && (
            <View style={styles.prefillBanner}>
              <Text style={styles.prefillBannerText}>
                Pre-filled from job estimate ({formatQuote(job.estimateTotal)}). Review and adjust if needed.
              </Text>
            </View>
          )}

          {/* Tracked time hint */}
          {job && (() => {
            const tracked = trackedDisplay(job.timeSessions);
            if (!tracked) return null;
            const estH = job.laborHours || 0;
            return (
              <View style={styles.trackBanner}>
                <Text style={styles.trackBannerText}>
                  ⏱ Time tracked: {tracked}
                  {estH > 0 ? ` (estimated ${estH}h)` : ""}. Adjust the amount above if needed.
                </Text>
              </View>
            );
          })()}

          <Field label="Customer name *" value={customer} onChangeText={setCustomer} placeholder="Jane Smith" />
          <Field label="Invoice #" value={number} onChangeText={setNumber} placeholder="INV-0001" />

          <View style={styles.row}>
            <View style={{ flex: 1 }}>
              <Field
                label="Amount ($) *"
                value={amount}
                onChangeText={setAmount}
                placeholder="0.00"
                keyboardType="decimal-pad"
              />
            </View>
            <View style={{ width: spacing.md }} />
            <View style={{ flex: 1 }}>
              <Field
                label="Due date"
                value={due}
                onChangeText={setDue}
                placeholder="YYYY-MM-DD"
                keyboardType="numbers-and-punctuation"
              />
            </View>
          </View>

          <Field
            label="Customer email"
            value={email}
            onChangeText={setEmail}
            placeholder="jane@example.com"
            keyboardType="email-address"
            autoCapitalize="none"
          />
          <Field
            label="Customer phone"
            value={phone}
            onChangeText={setPhone}
            placeholder="(555) 123-4567"
            keyboardType="phone-pad"
          />
          <Field
            label="Description of work"
            value={desc}
            onChangeText={setDesc}
            placeholder="What was completed?"
            multiline
          />

          <View style={styles.actions}>
            <TouchableOpacity
              style={styles.cancelBtn}
              onPress={() => navigation.goBack()}
              accessibilityRole="button"
              accessibilityLabel="Cancel"
            >
              <Text style={styles.cancelBtnText}>Cancel</Text>
            </TouchableOpacity>
            <TouchableOpacity
              style={[styles.createBtn, saving && styles.createBtnDisabled]}
              onPress={handleCreate}
              disabled={saving}
              accessibilityRole="button"
              accessibilityLabel={copy.title}
              accessibilityState={{ disabled: saving, busy: saving }}
            >
              <Text style={styles.createBtnText}>
                {saving ? "Saving..." : copy.cta}
              </Text>
            </TouchableOpacity>
          </View>
        </ScrollView>
      </KeyboardAvoidingView>
    </SafeAreaView>
  );
}

function createStyles(colors: ColorScheme, shadow: ShadowScheme) {
  return StyleSheet.create({
  container:        { flex: 1, backgroundColor: colors.background },
  loadingContainer: { flex: 1, alignItems: "center", justifyContent: "center", backgroundColor: colors.background },
  scroll:           { padding: spacing.md, paddingBottom: 40 },

  prefillBanner: {
    backgroundColor: colors.accentBg,
    borderRadius: radius.md,
    padding: spacing.sm,
    marginBottom: spacing.md,
    borderLeftWidth: 3,
    borderLeftColor: colors.accent,
  },
  prefillBannerText: {
    fontSize: fontSize.sm,
    color: colors.accent,
    lineHeight: 20,
  },
  trackBanner: {
    backgroundColor: colors.surfaceSecondary,
    borderRadius: radius.md,
    padding: spacing.sm,
    marginBottom: spacing.md,
    borderLeftWidth: 3,
    borderLeftColor: colors.textMuted,
  },
  trackBannerText: {
    fontSize: fontSize.sm,
    color: colors.textSecondary,
    lineHeight: 20,
  },

  row:        { flexDirection: "row" },

  actions: {
    flexDirection: "row",
    gap: spacing.sm,
    marginTop: spacing.lg,
  },
  cancelBtn: {
    flex: 1,
    height: 48,
    borderRadius: radius.md,
    borderWidth: 1,
    borderColor: colors.border,
    alignItems: "center",
    justifyContent: "center",
  },
  cancelBtnText: {
    fontSize: fontSize.md,
    color: colors.textSecondary,
    fontWeight: "500",
  },
  createBtn: {
    flex: 2,
    height: 48,
    borderRadius: radius.md,
    backgroundColor: colors.accent,
    alignItems: "center",
    justifyContent: "center",
  },
  createBtnDisabled: {
    opacity: 0.6,
  },
  createBtnText: {
    fontSize: fontSize.md,
    color: colors.textOnAccent,
    fontWeight: "700",
  },
  });
}
```

- [ ] **Step 2: Typecheck**

Run: `npm run typecheck`
Expected: no errors. Pay particular attention to: `invoiceScreenMode` returning `InvoiceScreenMode | null` narrowed correctly by the `if (!screenMode)` guard before `setMode(screenMode)`; `updatedInvoice: Invoice` object literal type-checking against the `Invoice` interface in `types/models.ts`.

- [ ] **Step 3: Full test suite**

Run: `npx jest -v`
Expected: `Test Suites: 81 passed, 81 total` / `Tests: 1286 passed, 1286 total` — unchanged from baseline (this screen has no dedicated test file, and no other test imports it).

- [ ] **Step 4: Lint**

Run: `npm run lint`
Expected: 0 warnings, 0 errors.

- [ ] **Step 5: Commit**

```bash
git add screens/CreateInvoiceFromJobScreen.tsx
git commit -m "feat: three-mode CreateInvoiceFromJobScreen (create/requestDeposit/finalize)"
```

---

### Task 4: Full gate + manual device verification

**Files:** none (verification only)

- [ ] **Step 1: Run the full gate**

```bash
npm run typecheck && npx jest -v && npm run lint
```

Expected: tsc 0 errors; `Test Suites: 81 passed, 81 total`, `Tests: 1286 passed, 1286 total`; lint 0 warnings — identical counts to the pre-task baseline, since every new assertion landed inside the existing `jobStatus.test.js` file (Task 1) and no new test files were added.

- [ ] **Step 2: Manual device smoke test (owner, via Expo Go — this dev machine has no iOS simulator or Android emulator)**

Walk one job through the new path end-to-end:
1. Create a job, build an estimate, send it, mark it approved.
2. On the job detail screen, confirm **"Request deposit →"** appears below **"Schedule this job"**.
3. Tap it → confirm the screen title reads "Request Deposit" and the button reads "Request deposit →" → save.
4. Confirm it lands on the Outreach screen for a real invoice, and that invoice appears in the Invoices tab.
5. Go back to the job → confirm the secondary action now reads **"View deposit →"** and opens the same invoice's Outreach screen.
6. In Outreach, request a 50% deposit and mark it paid (Stripe test mode or `RecordPaymentSheet`, whichever this environment supports).
7. Advance the job through scheduled → in_progress → complete.
8. On the job detail screen at `"complete"`, confirm the primary action now reads **"Finalize invoice →"** (not "Create invoice").
9. Tap it → confirm the deposit-already-requested banner shows the correct amount and paid status, adjust the total if desired, save.
10. Confirm `job.status` is now `"invoiced"`, the same invoice (not a duplicate) shows the deposit payment plus the finalized total in its ledger, and the Invoices tab shows exactly one invoice for this job.

- [ ] **Step 3: Report results**

If all steps in Step 2 pass, the feature is complete and ready for the owner's usual merge/PR decision (see `superpowers:finishing-a-development-branch`). If any step fails, return to the relevant task above with the specific symptom before proceeding.

# Deposits & Partial Payments — Phase 6: PDF and polish

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop the invoice PDF telling a customer "TOTAL DUE $1,000" after they've paid a $400 deposit, and make CustomerDetailScreen agree with the Invoices tab.

**Architecture:** `utils/pdfTemplates.ts` builds HTML strings — pure functions, currently with zero test coverage. This phase adds a gated three-line total block, a `Partly paid` badge, and a payment-history table with two exclusions, all gated so pre-existing invoices render byte-identically. Then one screen is brought into line. The last task closes out the whole branch.

**Tech Stack:** TypeScript, React Native (Expo 54), Jest, no new dependencies.

**Spec:** `docs/superpowers/specs/2026-07-18-deposits-phase-6-pdf-and-polish-design.md`

## Global Constraints

- **No new dependencies.** No `package.json` change. Adding a package or changing the Expo SDK needs the owner's explicit approval (`tradeready-change-control`).
- **The gate must be green before every commit:** `npm run typecheck` (0 errors), `npm test` (0 failures), `npm run lint` (0 warnings — `--max-warnings=0`).
- **Starting baseline: 1018 tests / 61 suites** on branch `feat/deposits-partial-payments` @ `88427d1`.
- **Pre-existing invoices must render byte-identically.** These PDFs get emailed and archived; a silent change to historical documents is its own problem. Every new element is gated so a legacy or untouched invoice produces exactly today's output. There are explicit tests for this.
- **The customer's copy excludes voided payments and the synthesized `legacy_<id>` entry.** A void is internal bookkeeping; the legacy entry's note is internal language about an app migration.
- **`__tests__/invoicePaymentsLegacyEquivalence.test.js` and `__tests__/paymentMathParity.test.js` must remain unedited and pass.** If any pre-existing test fails, STOP and report — do NOT edit the test and do NOT add a defensive branch to the source. Both moves were made earlier in this feature and both were wrong.
- **Do not touch `estimateHtml`** (`utils/pdfTemplates.ts:217`) or its "Pending Approval" badge — estimates have no payment ledger.
- **Do NOT touch `utils/sync.ts`, `utils/syncMerge.ts`, or anything under `backend/`.**
- Money is a plain `number` of dollars. Dates are `"YYYY-MM-DD"` strings.
- Shell is PowerShell on Windows; a Bash tool is also available.

## Existing interfaces you will use

From `utils/invoicePayments.ts` (all tested; all coerce malformed amounts to zero):

```ts
export function amountPaid(invoice: Invoice): number;    // skips voided entries
export function balanceDue(invoice: Invoice): number;
export function isFullyPaid(invoice: Invoice): boolean;
export function isPartlyPaid(invoice: Invoice): boolean;
export const effectivePayments: (invoice: Invoice) => Payment[];  // INCLUDES voided; INCLUDES the synthesized legacy_<id> entry
```

From `utils/format.ts`: `formatMoney(n: number): string` — e.g. `"$1,000.00"`.

In `utils/pdfTemplates.ts` already: `invoiceHtml(invoice, biz, logoDataUri)` at line 134, a private `safe()` escaper, and a private `fmtDate()`.

## File structure

| File | Change |
|---|---|
| `utils/pdfTemplates.ts` | Badge state, gated total block, history table |
| `__tests__/pdfTemplates.test.js` | **New** — this module has no coverage today |
| `screens/CustomerDetailScreen.tsx` | Partly-paid status + balance-forward amount and label |
| `ARCHITECTURE.md`, `docs/deposits-resume-here.md` | Docs and branch wrap-up |

---

### Task 1: The invoice PDF

**Files:**
- Modify: `utils/pdfTemplates.ts`
- Create: `__tests__/pdfTemplates.test.js`

**Interfaces:**
- Consumes: `isFullyPaid`, `isPartlyPaid`, `amountPaid`, `balanceDue`, `effectivePayments`, `formatMoney`.
- Produces: no new exports — `invoiceHtml`'s output changes only for partly-paid invoices and invoices carrying real recorded payments.

**Note:** `utils/pdfTemplates.ts` has NO existing test suite. `__tests__/estimateDocument.test.js` covers a different module (`utils/estimateDocument`). You are creating the first coverage for this file.

- [ ] **Step 1: Write the failing tests**

Create `__tests__/pdfTemplates.test.js`:

```js
// __tests__/pdfTemplates.test.js
// First coverage for the invoice PDF builder.
//
// The load-bearing property is BYTE-IDENTICAL OUTPUT FOR PRE-EXISTING
// INVOICES. These documents get emailed and archived, so a silent rendering
// change to historical invoices would be its own problem. Every new element is
// gated, and the first three tests are what prove it.
//
// The customer's copy also deliberately excludes voided payments (internal
// bookkeeping — a mistyped entry, a bounced cheque) and the synthesized
// legacy_<id> entry (internal language about an app migration).

import { invoiceHtml } from "../utils/pdfTemplates";

const inv = (over) => ({
  id: "i1", customer: "Acme", number: "INV-1", desc: "Work done",
  email: "", phone: "", amount: 1000, due: "2026-07-01", paid: false, ...over,
});

const pmt = (over) => ({ id: "p1", amount: 400, date: "2026-06-20", method: "cash", ...over });

describe("invoiceHtml — pre-existing invoices are unchanged", () => {
  test("an untouched unpaid invoice keeps the single TOTAL DUE line", () => {
    const html = invoiceHtml(inv());
    expect(html).toContain("TOTAL DUE");
    expect(html).not.toContain("BALANCE DUE");
    expect(html).not.toContain("Paid to date");
    expect(html).toContain("Outstanding");
  });

  test("a legacy paid invoice keeps the single TOTAL DUE line and shows no history", () => {
    const html = invoiceHtml(inv({ paid: true, paidAt: "2026-06-15", payments: undefined }));
    expect(html).toContain("TOTAL DUE");
    expect(html).not.toContain("BALANCE DUE");
    // The synthesized legacy_ entry must never reach the customer's copy.
    expect(html).not.toContain("Recorded before payment history");
    expect(html).not.toContain("Payment history");
    expect(html).toContain("Paid");
  });

  test("a fully-paid ledger invoice keeps the single total but DOES show history", () => {
    const html = invoiceHtml(inv({
      paid: true,
      payments: [pmt({ id: "p1", amount: 400, date: "2026-06-20" }),
                 pmt({ id: "p2", amount: 600, date: "2026-07-20" })],
    }));
    expect(html).toContain("TOTAL DUE");
    expect(html).not.toContain("BALANCE DUE");
    expect(html).toContain("Payment history");
    expect(html).toContain("$400.00");
    expect(html).toContain("$600.00");
  });
});

describe("invoiceHtml — partly paid", () => {
  const partly = () => inv({ payments: [pmt({ amount: 400 })] });

  test("renders all three total lines with the right numbers", () => {
    const html = invoiceHtml(partly());
    expect(html).toContain("Invoice total");
    expect(html).toContain("Paid to date");
    expect(html).toContain("BALANCE DUE");
    expect(html).toContain("$1,000.00");   // invoice total
    expect(html).toContain("$400.00");     // paid to date
    expect(html).toContain("$600.00");     // balance
    expect(html).not.toContain("TOTAL DUE");
  });

  test("shows the Partly paid badge, not Paid or Outstanding", () => {
    const html = invoiceHtml(partly());
    expect(html).toContain("Partly paid");
    expect(html).toContain("badge-partial");
  });

  test("shows the payment history table", () => {
    const html = invoiceHtml(partly());
    expect(html).toContain("Payment history");
    expect(html).toContain("Cash");
  });
});

describe("invoiceHtml — history exclusions", () => {
  test("a voided payment does not appear on the customer's copy", () => {
    const html = invoiceHtml(inv({
      payments: [pmt({ id: "p1", amount: 400, date: "2026-06-20" }),
                 pmt({ id: "p2", amount: 250, date: "2026-06-25", voidedAt: "2026-07-01" })],
    }));
    expect(html).toContain("$400.00");
    expect(html).not.toContain("$250.00");
    expect(html).not.toContain("void");
    expect(html).not.toContain("Void");
  });

  test("a voided payment is excluded from the paid-to-date figure", () => {
    const html = invoiceHtml(inv({
      payments: [pmt({ id: "p1", amount: 400, date: "2026-06-20" }),
                 pmt({ id: "p2", amount: 250, date: "2026-06-25", voidedAt: "2026-07-01" })],
    }));
    // Balance is 1000 - 400 = 600, not 350.
    expect(html).toContain("$600.00");
    expect(html).not.toContain("$350.00");
  });

  test("an invoice whose only payment is voided renders as untouched", () => {
    const html = invoiceHtml(inv({
      payments: [pmt({ id: "p1", amount: 400, voidedAt: "2026-07-01" })],
    }));
    expect(html).toContain("TOTAL DUE");
    expect(html).not.toContain("BALANCE DUE");
    expect(html).not.toContain("Payment history");
  });
});
```

- [ ] **Step 2: Run to verify they fail**

Run: `npx jest __tests__/pdfTemplates.test.js`
Expected: the three "pre-existing invoices are unchanged" tests PASS already (nothing has changed yet); every "partly paid" and "history exclusions" test FAILS. That split is itself informative — it confirms the gating tests are pinning current behaviour before you touch anything.

- [ ] **Step 3: Add the badge CSS class**

In `utils/pdfTemplates.ts`, beside the existing badge classes at lines 122-123:

```css
  .badge-paid   { background: #e8f9f0; color: #25a65b; }
  .badge-unpaid { background: #fff3e0; color: #c47a00; }
  .badge-partial { background: #eaf2ff; color: #2f6fd0; }
```

Add these rules for the history table in the same `<style>` block:

```css
  .history { margin-top: 18px; }
  .history-title { font-size: 12px; font-weight: 600; color: #6b6b70; text-transform: uppercase; letter-spacing: 0.4px; }
  .history table { width: 100%; margin-top: 6px; }
  .history td { font-size: 12px; color: #48484a; padding: 3px 0; }
  .history td.amt { text-align: right; color: #1c1c1e; font-weight: 600; }
  .sub-row { display: flex; justify-content: space-between; padding: 2px 0; font-size: 13px; color: #48484a; }
  .sub-row .sub-amount { font-weight: 600; color: #1c1c1e; }
```

- [ ] **Step 4: Compute the new values in `invoiceHtml`**

Inside `invoiceHtml`, beside the existing `const isPaid = isFullyPaid(invoice);` (line 147):

```ts
  const isPartly = isPartlyPaid(invoice);
  const paidToDate = amountPaid(invoice);
  const balance = balanceDue(invoice);

  // The customer's copy excludes voided entries (internal bookkeeping) and the
  // synthesized legacy_<id> entry (internal language about an app migration).
  // Between those two rules a pre-existing invoice has nothing left to show,
  // which is what keeps its PDF byte-identical.
  const historyPayments = effectivePayments(invoice)
    .filter((p) => !p.voidedAt && !p.id.startsWith("legacy_"));
```

Add to the imports at the top of the file:

```ts
import { isFullyPaid, isPartlyPaid, amountPaid, balanceDue, effectivePayments } from "./invoicePayments";
```

(`isFullyPaid` is already imported — extend the existing statement rather than adding a second one.)

- [ ] **Step 5: Replace the badge**

Line 193 currently:

```html
      <span class="badge ${isPaid ? "badge-paid" : "badge-unpaid"}">${isPaid ? "Paid" : "Outstanding"}</span>
```

becomes:

```html
      <span class="badge ${isPaid ? "badge-paid" : isPartly ? "badge-partial" : "badge-unpaid"}">${isPaid ? "Paid" : isPartly ? "Partly paid" : "Outstanding"}</span>
```

- [ ] **Step 6: Replace the total block**

Lines 207-210 currently:

```html
<div class="total-row">
  <span class="total-label">TOTAL DUE</span>
  <span class="total-amount">${formatMoney(invoice.amount)}</span>
</div>
```

becomes:

```html
${isPartly ? `
<div class="sub-row">
  <span>Invoice total</span>
  <span class="sub-amount">${formatMoney(invoice.amount)}</span>
</div>
<div class="sub-row">
  <span>Paid to date</span>
  <span class="sub-amount">−${formatMoney(paidToDate)}</span>
</div>
<div class="total-row">
  <span class="total-label">BALANCE DUE</span>
  <span class="total-amount">${formatMoney(balance)}</span>
</div>` : `
<div class="total-row">
  <span class="total-label">TOTAL DUE</span>
  <span class="total-amount">${formatMoney(invoice.amount)}</span>
</div>`}
```

Note the minus sign on the paid line is U+2212 (−), not a hyphen — it renders correctly at the small size used here.

- [ ] **Step 7: Add the history table**

Immediately after the total block and before the `<div class="footer">` line:

```html
${historyPayments.length ? `
<div class="history">
  <div class="history-title">Payment history</div>
  <table>
    <tbody>
      ${historyPayments.map((p) => `<tr><td>${fmtDate(p.date)}</td><td>${safe(METHOD_LABELS[p.method] ?? p.method)}</td><td class="amt">${formatMoney(p.amount)}</td></tr>`).join("")}
    </tbody>
  </table>
</div>` : ""}
```

Add near the top of the file, beside the other module-level constants:

```ts
const METHOD_LABELS: Record<string, string> = {
  cash: "Cash", check: "Cheque", card: "Card", stripe: "Card", other: "Payment",
};
```

Note `stripe` maps to "Card" and `other` to "Payment" — a customer does not need to know which processor you used or that you filed something as "other".

- [ ] **Step 8: Run to verify everything passes**

Run: `npx jest __tests__/pdfTemplates.test.js`
Expected: PASS — 9 tests.

- [ ] **Step 9: Prove the byte-identical property is actually pinned**

Temporarily change the total-block gate from `isPartly` to `true`, run `npx jest __tests__/pdfTemplates.test.js`, and confirm the three "pre-existing invoices are unchanged" tests FAIL. Revert and confirm they pass. Paste both outputs — this is the evidence that historical PDFs are protected by a real test rather than by assumption.

- [ ] **Step 10: Run the full gate**

Run: `npm run typecheck && npm test && npm run lint`
Expected: all three exit 0, +9 tests, +1 suite.

- [ ] **Step 11: Commit**

```bash
git add utils/pdfTemplates.ts __tests__/pdfTemplates.test.js
git commit -m "feat: invoice PDF shows the balance, not the full amount

A PDF sent after a deposit said TOTAL DUE $1,000 and invited the customer to
pay it again. Partly-paid invoices now show invoice total, paid to date and
BALANCE DUE, plus a payment history. Voided and synthesized legacy entries are
excluded from the customer's copy, so every pre-existing invoice still renders
byte-identically."
```

---

### Task 2: `CustomerDetailScreen`

**Files:**
- Modify: `screens/CustomerDetailScreen.tsx`

**Interfaces:**
- Consumes: `isFullyPaid`, `isPartlyPaid`, `amountPaid`, `balanceDue`, `formatMoney`.

This screen has no test suite, so read it fully before editing and keep the diff minimal. It adds no tests.

- [ ] **Step 1: Read the screen and locate the three sites**

Run: `grep -n "invoiceStatus\|parseFloat(String(invoice.amount))\|accessibilityLabel" screens/CustomerDetailScreen.tsx`

You are looking for: the `invoiceStatus` helper (~line 42), the row's `accessibilityLabel` (~line 104), and the rendered amount (~line 112).

- [ ] **Step 2: Add the partly-paid status**

`invoiceStatus` is currently:

```ts
const invoiceStatus = (inv: Invoice, colors: ColorScheme): InvoiceStatusResult => {
  if (isFullyPaid(inv)) return { label: 'Paid', color: colors.success };
  const due = new Date(inv.due);
  const now = new Date();
  if (due < now) return { label: 'Overdue', color: colors.danger };
  return { label: 'Pending', color: colors.warning };
};
```

Add the partly-paid branch AFTER the overdue check and BEFORE `Pending`:

```ts
const invoiceStatus = (inv: Invoice, colors: ColorScheme): InvoiceStatusResult => {
  if (isFullyPaid(inv)) return { label: 'Paid', color: colors.success };
  const due = new Date(inv.due);
  const now = new Date();
  if (due < now) return { label: 'Overdue', color: colors.danger };
  // Matches getStatus's precedence in utils/invoiceHelpers.ts: overdue wins
  // when both apply, because an invoice with a deposit on it that is past due
  // is still late.
  if (isPartlyPaid(inv)) return { label: 'Partly paid', color: colors.accent };
  return { label: 'Pending', color: colors.warning };
};
```

- [ ] **Step 3: Make the amount and its label balance-forward**

Both sites must change together — a screen reader announcing "$1,000.00" while the visible row reads "$600.00 due" is its own defect.

Compute once, above the return:

```ts
  const partly = isPartlyPaid(invoice);
  const amountText = partly
    ? `${formatMoney(balanceDue(invoice))} due · ${formatMoney(amountPaid(invoice))} paid`
    : formatMoney(Number(invoice.amount) || 0);
```

Then use `amountText` in BOTH the `accessibilityLabel` (~line 104) and the rendered `<Text>` (~line 112), replacing the two existing `formatMoney(parseFloat(String(invoice.amount)) || 0)` expressions.

Add `isPartlyPaid`, `amountPaid` and `balanceDue` to the existing `../utils/invoicePayments` import.

- [ ] **Step 4: Check dark mode**

Confirm the file uses the `createStyles(colors)` factory with `useMemo` and does not import the static `colors` alias from `utils/theme.ts` — that alias would freeze the screen in light mode.

Run: `grep -n "from \"../utils/theme\"\|useTheme" screens/CustomerDetailScreen.tsx`

If it already uses the factory, change nothing. If your new code introduced a hardcoded colour, replace it with a theme token.

- [ ] **Step 5: Run the full gate**

Run: `npm run typecheck && npm test && npm run lint`
Expected: all three exit 0, test count unchanged from Task 1.

- [ ] **Step 6: Commit**

```bash
git add screens/CustomerDetailScreen.tsx
git commit -m "feat: customer detail shows partly-paid status and balance

The same invoice read '\$1,000.00 · Pending' here and '\$600.00 due · \$400.00
paid · Partly paid' on the Invoices tab. The accessibility label changes with
the visible text."
```

---

### Task 3: Docs and branch wrap-up

**Files:**
- Modify: `ARCHITECTURE.md`, `docs/deposits-resume-here.md`

This is the last task of the last phase to be built, so it closes out the whole branch rather than just this phase.

- [ ] **Step 1: Update ARCHITECTURE.md**

In the `### Invoice` block's `payments` bullet, append:

```markdown
  The customer-facing PDF (`utils/pdfTemplates.ts`) shows invoice total, paid to
  date and BALANCE DUE when partly paid, plus a payment history — excluding
  voided entries and the synthesized `legacy_<id>` entry, so pre-existing
  invoices render byte-identically.
```

- [ ] **Step 2: Rewrite `docs/deposits-resume-here.md`'s framing**

That document currently reads as work-in-progress. Rewrite its opening status block to describe a finished feature awaiting deployment. Specifically:

- Status line: Phases 1, 2, 2b, 3, 4 and 6 are built and green; **Phase 5 (deposit requests and partial-amount Stripe links) is deliberately unbuilt** — it is the phase whose value is an end-to-end money path, so it needs the backend live to verify rather than merely to ship.
- Refresh the gate count and the commit count to what you actually observe.
- Keep §1 (the do-not-ship-a-build warning), §4 (the owner-gated apply/deploy sequence) and §5 (scope boundaries) **exactly as they are** — none of that has changed.
- In §3, mark both defects as fixed if they are not already.

- [ ] **Step 3: Confirm the gate is unmoved**

Run: `npm run typecheck && npm test && npm run lint`
Expected: all three exit 0 — a docs change moves nothing.

- [ ] **Step 4: Commit**

```bash
git add ARCHITECTURE.md docs/deposits-resume-here.md
git commit -m "docs: record the PDF balance block and close out the branch"
```

---

## Exit criteria

- [ ] `npm run typecheck` — 0 errors
- [ ] `npm test` — 0 failures, +9 tests / +1 suite from Task 1, no pre-existing test edited
- [ ] `npm run lint` — 0 warnings
- [ ] The Task 1 Step 9 mutation check was performed and recorded — it is the proof that historical PDFs are protected
- [ ] `grep -n "estimateHtml" utils/pdfTemplates.ts` shows that function unchanged by this phase (`git diff` it to confirm)
- [ ] `git diff` on `utils/sync.ts`, `utils/syncMerge.ts` and `backend/` for this phase is empty
- [ ] `__tests__/invoicePaymentsLegacyEquivalence.test.js` and `__tests__/paymentMathParity.test.js` unedited and passing

Then stop and report. The whole-branch review comes after, followed by `superpowers:finishing-a-development-branch`.

## Still not shippable

Unchanged: this may be merged but must NOT ship until the Supabase migration is
applied and the backend deployed. See `docs/deposits-resume-here.md` §4.

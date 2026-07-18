# Deposits & Partial Payments — Phase 3: Recording UI

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a tradesperson record cash/cheque/card payments against an invoice, see the payment history, and void a mistaken entry — with `markPaid` rewired so it stops writing a bare `paid: true`.

**Architecture:** All money math already exists in `utils/invoicePayments.ts` (Phases 1–2b) and is tested. This phase is UI over it, plus three small pure additions. Two new components are built and tested in isolation before anything is wired into `InvoicesScreen`, so a wiring failure can't be mistaken for a component failure.

**Tech Stack:** TypeScript, React Native (Expo 54), Jest + `@testing-library/react-native`, no new dependencies.

**Spec:** `docs/superpowers/specs/2026-07-18-deposits-phase-3-recording-ui-design.md` (a delta on `2026-07-18-deposits-partial-payments-design.md`)

## Global Constraints

- **No new dependencies.** No `package.json` change. Adding a package or changing the Expo SDK needs the owner's explicit approval (`tradeready-change-control`).
- **The gate must be green before every commit:** `npm run typecheck` (0 errors), `npm test` (0 failures), `npm run lint` (0 warnings — `--max-warnings=0`).
- **Starting baseline: 942 tests / 59 suites** on branch `feat/deposits-partial-payments` @ `7477b7f`.
- **Use the shared primitives. Do not write new copies.** `components/Field.tsx` (form text field), `components/DateTimePickerSheet.tsx` (date picker), `formatMoney` from `utils/format.ts`, `Badge`/`Button`/`Card` from `components/UI.tsx`. Re-introducing a local copy of any of these is a regression even if it works — the duplication itself was the bug class (`tradeready-architecture-contract` §9).
- **Every themed component uses the `createStyles` factory pattern:** `const { colors, shadow } = useTheme();` then `const styles = useMemo(() => createStyles(colors, shadow), [colors, shadow]);` with `function createStyles(colors: ColorScheme, shadow: ShadowScheme)` below. Never import the static `colors` alias into a themed component — it silently freezes that component in light mode.
- **Void is irreversible.** No code path may clear `voidedAt`. To correct a void the user records a new payment.
- **`method: 'stripe'` must never be selectable in the UI.** It is reserved for webhook-created entries so the two origins stay distinguishable. Manual card payments are `'card'`.
- **Do NOT modify `utils/invoiceStats.ts` or any analytics card.** Those are Phase 4. `isOverdue` already agrees with the ledger because `paid` is maintained.
- **Do NOT modify anything under `backend/`, `utils/sync.ts`, or `utils/syncMerge.ts`.**
- Money is a plain `number` of dollars. Dates are `"YYYY-MM-DD"` strings.
- Shell is PowerShell on Windows; a Bash tool is also available.

## Existing interfaces you will use

From `utils/invoicePayments.ts` (all committed and tested — do not change them):

```ts
export const PAID_EPSILON = 0.005;
export function amountPaid(invoice: Invoice): number;      // skips voided entries
export function balanceDue(invoice: Invoice): number;
export function isFullyPaid(invoice: Invoice): boolean;
export function isPartlyPaid(invoice: Invoice): boolean;
export function newPaymentId(): string;                    // `p<ts>_<n>`
export function materializeLegacyLedger(invoice: Invoice): Payment[];
export function applyPayment(invoice: Invoice, payment: Payment): Invoice;      // pure, idempotent by id
export function voidPayment(invoice: Invoice, paymentId: string, voidedAt: DateString): Invoice; // pure, idempotent
```

Shared component signatures:

```ts
// components/UI.tsx
export type BadgeColor = "danger" | "warning" | "success" | "accent" | "muted";
export function Badge({ label, color }: { label: string; color?: BadgeColor });
export function Button({ label, onPress, variant, style, loading }: ButtonProps); // NOTE: `label`, not `title`

// components/DateTimePickerSheet.tsx
export function DateTimePickerSheet({ visible, mode, value, title, onChange, onClose }: {
  visible: boolean; mode: "date" | "time"; value: Date; title: string;
  onChange: (date: Date) => void; onClose: () => void;
});

// components/Field.tsx — default export
// props include: label, value, onChangeText, keyboardType, multiline
```

## File structure

| File | Responsibility | Change |
|---|---|---|
| `types/models.ts` | Persisted shapes | Add `PaymentDraft` |
| `utils/invoicePayments.ts` | Payment math | Add `effectivePayments` alias + `settleRemaining` |
| `utils/invoiceHelpers.ts` | Invoice display derivations | `getStatus` partly-paid branch |
| `components/RecordPaymentSheet.tsx` | **New.** The record-payment form | Create |
| `components/PaymentHistoryList.tsx` | **New.** History rows incl. voided + legacy | Create |
| `screens/InvoicesScreen.tsx` | The Invoices tab | Wire both in; rewire `markPaid` |
| `__tests__/invoicePayments.test.js` | Existing suite | Append |
| `__tests__/invoiceHelpers.test.js` | Existing suite | Append |
| `__tests__/RecordPaymentSheet.test.js` | **New** | Create |
| `__tests__/PaymentHistoryList.test.js` | **New** | Create |

---

### Task 1: Pure derivations

**Files:**
- Modify: `types/models.ts`
- Modify: `utils/invoicePayments.ts`
- Modify: `utils/invoiceHelpers.ts`
- Test: `__tests__/invoicePayments.test.js`, `__tests__/invoiceHelpers.test.js`

**Interfaces:**
- Produces: `PaymentDraft`; `effectivePayments(invoice): Payment[]`; `settleRemaining(invoice, date): Invoice`; a "Partly paid" branch in `getStatus`.

- [ ] **Step 1: Add `PaymentDraft` to `types/models.ts`**

Immediately after the `Payment` interface:

```ts
/**
 * The fields the record-payment form collects, before `id` is stamped.
 * Mirrors the existing ExpenseDraft pattern. `voidedAt` and `stripeSessionId`
 * are excluded deliberately: a form can never create a voided payment, and
 * `stripeSessionId` belongs only to webhook-created entries.
 */
export type PaymentDraft = Omit<Payment, "id" | "voidedAt" | "stripeSessionId">;
```

- [ ] **Step 2: Write the failing tests for the two new helpers**

Append to `__tests__/invoicePayments.test.js`, extending the top-of-file import with `effectivePayments` and `settleRemaining`:

```js
describe("effectivePayments", () => {
  test("returns the ledger for an invoice that has one", () => {
    const i = inv({ amount: 1000, payments: [pmt({ id: "p1", amount: 400 })] });
    expect(effectivePayments(i).map((p) => p.id)).toEqual(["p1"]);
  });

  test("returns the synthesized entry for a legacy paid invoice", () => {
    const i = inv({ id: "i1", paid: true, amount: 1000, paidAt: "2026-06-15", payments: undefined });
    const list = effectivePayments(i);
    expect(list).toHaveLength(1);
    expect(list[0].id).toBe("legacy_i1");
    expect(list[0].amount).toBe(1000);
  });

  test("returns an empty list for a legacy unpaid invoice", () => {
    expect(effectivePayments(inv({ paid: false }))).toEqual([]);
  });
});

describe("settleRemaining", () => {
  test("records a payment for the outstanding balance and settles the invoice", () => {
    const i = inv({ amount: 1000 });
    const result = settleRemaining(i, "2026-07-22");
    expect(result.payments).toHaveLength(1);
    expect(result.payments[0].amount).toBe(1000);
    expect(result.payments[0].method).toBe("other");
    expect(result.paid).toBe(true);
    expect(result.paidAt).toBe("2026-07-22");
  });

  test("settles only the REMAINDER on a partly-paid invoice", () => {
    const partly = applyPayment(inv({ amount: 1000 }), pmt({ id: "p1", amount: 400, date: "2026-07-01" }));
    const result = settleRemaining(partly, "2026-07-22");
    expect(result.payments).toHaveLength(2);
    expect(result.payments[1].amount).toBe(600);
    expect(amountPaid(result)).toBe(1000);
    expect(result.paid).toBe(true);
  });

  test("preserves a legacy invoice's original amount", () => {
    const legacy = inv({ id: "i1", paid: true, amount: 1000, paidAt: "2026-06-15", payments: undefined });
    // Already settled — nothing to add.
    const result = settleRemaining(legacy, "2026-07-22");
    expect(amountPaid(result)).toBe(1000);
  });

  test("is a no-op on an already-settled invoice (no zero-amount entry)", () => {
    const settled = applyPayment(inv({ amount: 1000 }), pmt({ id: "p1", amount: 1000 }));
    const result = settleRemaining(settled, "2026-07-22");
    expect(result.payments).toHaveLength(1);
    expect(result).toBe(settled);
  });
});
```

- [ ] **Step 3: Run to verify they fail**

Run: `npx jest __tests__/invoicePayments.test.js`
Expected: FAIL — `effectivePayments is not a function`.

- [ ] **Step 4: Implement both helpers**

Append to `utils/invoicePayments.ts`:

```ts
/**
 * This invoice's payments as the UI should display them.
 *
 * An alias for materializeLegacyLedger, which is named for WHY it exists
 * rather than what callers want from it. A legacy paid invoice yields its one
 * synthesized `legacy_<id>` entry; an invoice with a real ledger yields a copy
 * of it. Voided entries ARE included — the history UI renders them struck
 * through, and hiding them would defeat the point of voiding rather than
 * deleting. Anything SUMMING this list must skip voided entries itself.
 */
export const effectivePayments = materializeLegacyLedger;

/**
 * Record a single payment for whatever is still owed, settling the invoice.
 *
 * This is what the "Mark paid" button does. It must go through applyPayment
 * rather than setting `paid: true` directly: a bare flag write is discarded by
 * the ledger merge on the next sync once an invoice has any recorded payment,
 * silently reverting the user's tap.
 *
 * A no-op on an already-settled invoice — returns it unchanged rather than
 * appending a zero-amount entry.
 */
export function settleRemaining(invoice: Invoice, date: DateString): Invoice {
  if (isFullyPaid(invoice)) return invoice;
  return applyPayment(invoice, {
    id: newPaymentId(),
    amount: balanceDue(invoice),
    date,
    method: "other",
  });
}
```

- [ ] **Step 5: Run to verify they pass**

Run: `npx jest __tests__/invoicePayments.test.js`
Expected: PASS — 7 new tests.

- [ ] **Step 6: Write the failing test for the `getStatus` branch**

Append to `__tests__/invoiceHelpers.test.js`. Read the top of that file first — it pins "today" with `jest.setSystemTime`, and your dates must be chosen relative to whatever it pins. Extend the import to include `getStatus` if it isn't already imported.

```js
describe("getStatus — partly paid", () => {
  const partly = (over) => ({
    id: "i1", customer: "Acme", number: "INV-1", desc: "", email: "", phone: "",
    amount: 1000, paid: false,
    payments: [{ id: "p1", amount: 400, date: "2026-07-01", method: "cash" }],
    ...over,
  });

  test("a partly-paid invoice not yet due reads 'Partly paid'", () => {
    const s = getStatus(partly({ due: "2026-08-01" }));
    expect(s.label).toBe("Partly paid");
    expect(s.color).toBe("accent");
  });

  test("a partly-paid invoice due today reads 'Partly paid'", () => {
    const s = getStatus(partly({ due: "2026-07-04" }));
    expect(s.label).toBe("Partly paid");
  });

  test("a partly-paid invoice PAST DUE still reads overdue, not 'Partly paid'", () => {
    // Overdue is the more urgent signal; the balance is shown next to the badge.
    const s = getStatus(partly({ due: "2026-06-01" }));
    expect(s.label).toMatch(/overdue/);
  });

  test("a fully-paid invoice still reads 'Paid'", () => {
    const s = getStatus(partly({
      due: "2026-06-01", paid: true,
      payments: [{ id: "p1", amount: 1000, date: "2026-07-01", method: "cash" }],
    }));
    expect(s.label).toBe("Paid");
  });

  test("an untouched unpaid invoice is unaffected", () => {
    const s = getStatus({ ...partly({ due: "2026-08-01" }), payments: undefined });
    expect(s.label).toBe("Due soon");
  });
});
```

- [ ] **Step 7: Run to verify they fail**

Run: `npx jest __tests__/invoiceHelpers.test.js`
Expected: FAIL — the partly-paid cases report "Due soon"/"Due today" instead of "Partly paid".

- [ ] **Step 8: Add the branch to `getStatus`**

In `utils/invoiceHelpers.ts`, add to the imports:

```ts
import { isPartlyPaid } from "./invoicePayments";
```

Then modify `getStatus` so the not-yet-due branch checks for a partial payment first. The full function becomes:

```ts
export function getStatus(invoice: Invoice): InvoiceStatus {
  if (invoice.paid) {
    return { label: "Paid", color: "success", days: 0 };
  }
  const days = daysPastDue(invoice.due);
  if (days <= 0) {
    // Partly paid only wins while the invoice is NOT past due — overdue is the
    // more urgent signal, and the row shows the balance next to the badge
    // either way.
    if (isPartlyPaid(invoice)) {
      return { label: "Partly paid", color: "accent", days };
    }
    return { label: days === 0 ? "Due today" : "Due soon", color: "accent", days };
  }
  if (days <= 14) {
    return { label: `${days}d overdue`, color: "warning", days };
  }
  return { label: `${days}d overdue`, color: "danger", days };
}
```

- [ ] **Step 9: Run to verify they pass, and check for an import cycle**

Run: `npx jest __tests__/invoiceHelpers.test.js`
Expected: PASS.

`utils/invoicePayments.ts` imports only from `./moneyUtils` and `../types/models`, so importing it from `invoiceHelpers` creates no cycle. Confirm with:
`grep -n "^import" utils/invoicePayments.ts`
Expected: no import of `invoiceHelpers`.

- [ ] **Step 10: Run the full gate**

Run: `npm run typecheck && npm test && npm run lint`
Expected: all three exit 0, +12 tests.

- [ ] **Step 11: Commit**

```bash
git add types/models.ts utils/invoicePayments.ts utils/invoiceHelpers.ts __tests__/invoicePayments.test.js __tests__/invoiceHelpers.test.js
git commit -m "feat: add effectivePayments, settleRemaining and a partly-paid status

settleRemaining is what Mark paid will call — routing through applyPayment
instead of setting paid directly, because a bare flag write is discarded by
the ledger merge on the next sync. Partly paid yields to overdue when both
apply."
```

---

### Task 2: `RecordPaymentSheet`

**Files:**
- Create: `components/RecordPaymentSheet.tsx`
- Test: `__tests__/RecordPaymentSheet.test.js`

**Interfaces:**
- Consumes: `balanceDue`, `PaymentDraft` (Task 1); `Field`, `DateTimePickerSheet`, `Button` (existing).
- Produces:
```ts
export function RecordPaymentSheet({ visible, invoice, onSave, onClose }: {
  visible: boolean;
  invoice: Invoice;
  onSave: (draft: PaymentDraft) => void;
  onClose: () => void;
}): JSX.Element | null;
```

The sheet does NOT stamp an id or call `applyPayment` — it hands a draft up and the screen does the rest. That keeps id generation out of a component and makes this testable without mocking storage.

- [ ] **Step 1: Write the failing tests**

Create `__tests__/RecordPaymentSheet.test.js`:

```js
// __tests__/RecordPaymentSheet.test.js
// The record-payment form. The money math it sits on is already covered by
// invoicePayments.test.js — these pin the UI contract: what it pre-fills, what
// it rejects, and the exact shape it hands up.

import React from "react";
import { render, fireEvent } from "@testing-library/react-native";
import { RecordPaymentSheet } from "../components/RecordPaymentSheet";

const invoice = (over) => ({
  id: "i1", customer: "Acme", number: "INV-1", desc: "", email: "", phone: "",
  amount: 1000, due: "2026-07-01", paid: false, ...over,
});

const noop = () => {};

describe("RecordPaymentSheet", () => {
  test("renders nothing when not visible", () => {
    const { queryByLabelText } = render(
      <RecordPaymentSheet visible={false} invoice={invoice()} onSave={noop} onClose={noop} />
    );
    expect(queryByLabelText("Amount")).toBeNull();
  });

  test("pre-fills the amount with the outstanding balance", () => {
    const partly = invoice({ payments: [{ id: "p1", amount: 400, date: "2026-07-01", method: "cash" }] });
    const { getByLabelText } = render(
      <RecordPaymentSheet visible invoice={partly} onSave={noop} onClose={noop} />
    );
    expect(getByLabelText("Amount").props.value).toBe("600");
  });

  test("does not call onSave for a zero amount", () => {
    const onSave = jest.fn();
    const { getByLabelText, getByText } = render(
      <RecordPaymentSheet visible invoice={invoice()} onSave={onSave} onClose={noop} />
    );
    fireEvent.changeText(getByLabelText("Amount"), "0");
    fireEvent.press(getByText("Record payment"));
    expect(onSave).not.toHaveBeenCalled();
  });

  test("does not call onSave for a negative amount", () => {
    const onSave = jest.fn();
    const { getByLabelText, getByText } = render(
      <RecordPaymentSheet visible invoice={invoice()} onSave={onSave} onClose={noop} />
    );
    fireEvent.changeText(getByLabelText("Amount"), "-5");
    fireEvent.press(getByText("Record payment"));
    expect(onSave).not.toHaveBeenCalled();
  });

  test("shows a hint when the amount exceeds the balance but still allows saving", () => {
    const onSave = jest.fn();
    const { getByLabelText, getByText, queryByText } = render(
      <RecordPaymentSheet visible invoice={invoice()} onSave={onSave} onClose={noop} />
    );
    fireEvent.changeText(getByLabelText("Amount"), "1500");
    expect(queryByText(/More than the/)).not.toBeNull();
    fireEvent.press(getByText("Record payment"));
    expect(onSave).toHaveBeenCalled();
  });

  test("hands up the exact draft shape", () => {
    const onSave = jest.fn();
    const { getByLabelText, getByText } = render(
      <RecordPaymentSheet visible invoice={invoice()} onSave={onSave} onClose={noop} />
    );
    fireEvent.changeText(getByLabelText("Amount"), "250.50");
    fireEvent.press(getByText("Cheque"));
    fireEvent.changeText(getByLabelText("Note (optional)"), "deposit");
    fireEvent.press(getByText("Record payment"));

    const draft = onSave.mock.calls[0][0];
    expect(draft.amount).toBe(250.5);
    expect(draft.method).toBe("check");
    expect(draft.note).toBe("deposit");
    expect(draft.date).toMatch(/^\d{4}-\d{2}-\d{2}$/);
    // The form must never be able to produce these.
    expect(draft.id).toBeUndefined();
    expect(draft.voidedAt).toBeUndefined();
  });

  test("offers no Stripe method — that origin is webhook-only", () => {
    const { queryByText } = render(
      <RecordPaymentSheet visible invoice={invoice()} onSave={noop} onClose={noop} />
    );
    expect(queryByText(/stripe/i)).toBeNull();
  });
});
```

- [ ] **Step 2: Run to verify they fail**

Run: `npx jest __tests__/RecordPaymentSheet.test.js`
Expected: FAIL — `Cannot find module '../components/RecordPaymentSheet'`.

- [ ] **Step 3: Implement the component**

Create `components/RecordPaymentSheet.tsx`:

```tsx
// components/RecordPaymentSheet.tsx
// The record-payment form. Hands a PaymentDraft up rather than mutating the
// invoice itself — id stamping and applyPayment belong to the screen, which
// keeps id generation out of a component and this file testable without
// mocking storage.
//
// NOTE: 'stripe' is deliberately absent from the method chips. It is reserved
// for webhook-created entries so the two origins stay distinguishable; a
// manually recorded card payment is 'card'.

import React, { useEffect, useMemo, useState } from "react";
import { Modal, View, Text, TouchableOpacity, StyleSheet } from "react-native";
import Field from "./Field";
import { DateTimePickerSheet } from "./DateTimePickerSheet";
import { Button } from "./UI";
import { balanceDue } from "../utils/invoicePayments";
import { formatMoney } from "../utils/format";
import { spacing, radius, fontSize } from "../utils/theme";
import type { ColorScheme, ShadowScheme } from "../utils/theme";
import { useTheme } from "../hooks/useTheme";
import type { Invoice, PaymentDraft, PaymentMethod } from "../types/models";

const METHODS: { key: PaymentMethod; label: string }[] = [
  { key: "cash", label: "Cash" },
  { key: "check", label: "Cheque" },
  { key: "card", label: "Card" },
  { key: "other", label: "Other" },
];

function toDateString(d: Date): string {
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}-${String(d.getDate()).padStart(2, "0")}`;
}

export function RecordPaymentSheet({
  visible,
  invoice,
  onSave,
  onClose,
}: {
  visible: boolean;
  invoice: Invoice;
  onSave: (draft: PaymentDraft) => void;
  onClose: () => void;
}) {
  const { colors, shadow } = useTheme();
  const styles = useMemo(() => createStyles(colors, shadow), [colors, shadow]);

  const balance = balanceDue(invoice);
  const [amount, setAmount] = useState(String(balance));
  const [date, setDate] = useState(new Date());
  const [method, setMethod] = useState<PaymentMethod>("cash");
  const [note, setNote] = useState("");
  const [pickerOpen, setPickerOpen] = useState(false);

  // Re-seed whenever the sheet reopens or the balance changes underneath it.
  useEffect(() => {
    if (visible) {
      setAmount(String(balanceDue(invoice)));
      setDate(new Date());
      setMethod("cash");
      setNote("");
    }
  }, [visible, invoice]);

  if (!visible) return null;

  const parsed = parseFloat(amount);
  const valid = Number.isFinite(parsed) && parsed > 0;
  const overBalance = valid && parsed > balance;

  function handleSave() {
    if (!valid) return;
    const draft: PaymentDraft = {
      amount: parsed,
      date: toDateString(date),
      method,
    };
    if (note.trim()) draft.note = note.trim();
    onSave(draft);
  }

  return (
    <Modal visible transparent animationType="slide" onRequestClose={onClose}>
      <View style={styles.backdrop}>
        <View style={styles.sheet}>
          <Text style={styles.title}>Record payment</Text>
          <Text style={styles.sub}>
            {invoice.number} · {formatMoney(balance)} due
          </Text>

          <Field
            label="Amount"
            value={amount}
            onChangeText={setAmount}
            keyboardType="decimal-pad"
          />
          {overBalance && (
            <Text style={styles.hint}>
              More than the {formatMoney(balance)} balance — that&apos;s fine, it will
              show as fully paid.
            </Text>
          )}

          <Text style={styles.label}>Date</Text>
          <TouchableOpacity
            style={styles.dateBtn}
            onPress={() => setPickerOpen(true)}
            accessibilityRole="button"
            accessibilityLabel="Payment date"
          >
            <Text style={styles.dateText}>{toDateString(date)}</Text>
          </TouchableOpacity>

          <Text style={styles.label}>Method</Text>
          <View style={styles.chipRow}>
            {METHODS.map((m) => (
              <TouchableOpacity
                key={m.key}
                style={[styles.chip, method === m.key && styles.chipActive]}
                onPress={() => setMethod(m.key)}
                accessibilityRole="radio"
                accessibilityState={{ selected: method === m.key }}
                accessibilityLabel={m.label}
              >
                <Text style={[styles.chipText, method === m.key && styles.chipTextActive]}>
                  {m.label}
                </Text>
              </TouchableOpacity>
            ))}
          </View>

          <Field label="Note (optional)" value={note} onChangeText={setNote} />

          <View style={styles.actions}>
            <Button label="Cancel" variant="secondary" onPress={onClose} style={{ flex: 1 }} />
            <Button label="Record payment" onPress={handleSave} style={{ flex: 1 }} />
          </View>
        </View>
      </View>

      <DateTimePickerSheet
        visible={pickerOpen}
        mode="date"
        value={date}
        title="Payment date"
        onChange={setDate}
        onClose={() => setPickerOpen(false)}
      />
    </Modal>
  );
}

function createStyles(colors: ColorScheme, shadow: ShadowScheme) {
  return StyleSheet.create({
    backdrop: { flex: 1, justifyContent: "flex-end", backgroundColor: "rgba(0,0,0,0.4)" },
    sheet: {
      backgroundColor: colors.card,
      borderTopLeftRadius: radius.lg,
      borderTopRightRadius: radius.lg,
      padding: spacing.lg,
      ...shadow.card,
    },
    title: { fontSize: fontSize.lg, fontWeight: "700", color: colors.text },
    sub: { fontSize: fontSize.sm, color: colors.textMuted, marginBottom: spacing.md },
    label: { fontSize: fontSize.sm, color: colors.textMuted, marginTop: spacing.sm },
    hint: { fontSize: fontSize.sm, color: colors.warning, marginTop: spacing.xs },
    dateBtn: {
      borderWidth: 1, borderColor: colors.border, borderRadius: radius.md,
      padding: spacing.md, marginTop: spacing.xs,
    },
    dateText: { fontSize: fontSize.md, color: colors.text },
    chipRow: { flexDirection: "row", flexWrap: "wrap", gap: spacing.xs, marginTop: spacing.xs },
    chip: {
      paddingVertical: spacing.sm, paddingHorizontal: spacing.md,
      borderRadius: radius.pill, borderWidth: 1, borderColor: colors.border,
      minHeight: 44, justifyContent: "center",
    },
    chipActive: { backgroundColor: colors.accentBg, borderColor: colors.accent },
    chipText: { color: colors.text, fontSize: fontSize.sm },
    chipTextActive: { color: colors.accent, fontWeight: "600" },
    actions: { flexDirection: "row", gap: spacing.sm, marginTop: spacing.lg },
  });
}
```

If any token used above (`radius.pill`, `colors.accentBg`, `shadow.card`, `spacing.xs`) does not exist in `utils/theme.ts`, substitute the nearest existing one rather than adding new tokens, and note the substitution in your report.

- [ ] **Step 4: Run to verify they pass**

Run: `npx jest __tests__/RecordPaymentSheet.test.js`
Expected: PASS — 7 tests.

- [ ] **Step 5: Run the full gate**

Run: `npm run typecheck && npm test && npm run lint`
Expected: all three exit 0.

- [ ] **Step 6: Commit**

```bash
git add components/RecordPaymentSheet.tsx __tests__/RecordPaymentSheet.test.js
git commit -m "feat: add RecordPaymentSheet

Pre-fills the outstanding balance, rejects non-positive amounts, warns without
blocking on overpayment, and hands a PaymentDraft up rather than mutating the
invoice. Offers no Stripe method — that origin is webhook-only."
```

---

### Task 3: `PaymentHistoryList`

**Files:**
- Create: `components/PaymentHistoryList.tsx`
- Test: `__tests__/PaymentHistoryList.test.js`

**Interfaces:**
- Consumes: `effectivePayments` (Task 1); `formatMoney` (existing).
- Produces:
```ts
export function PaymentHistoryList({ invoice, onVoid }: {
  invoice: Invoice;
  onVoid: (paymentId: string) => void;
}): JSX.Element;
```

The confirm dialog is NOT in this component — it lives in the screen, so this stays pure and testable. Long-press calls `onVoid` directly.

- [ ] **Step 1: Write the failing tests**

Create `__tests__/PaymentHistoryList.test.js`:

```js
// __tests__/PaymentHistoryList.test.js
// Voided payments STAY in the list, struck through — that is the whole point
// of voiding rather than deleting, and the legacy synthesized entry is shown
// plainly labelled so an old invoice's total visibly adds up.

import React from "react";
import { render, fireEvent } from "@testing-library/react-native";
import { PaymentHistoryList } from "../components/PaymentHistoryList";

const invoice = (over) => ({
  id: "i1", customer: "Acme", number: "INV-1", desc: "", email: "", phone: "",
  amount: 1000, due: "2026-07-01", paid: false, ...over,
});

const noop = () => {};

describe("PaymentHistoryList", () => {
  test("shows an empty state when nothing has been recorded", () => {
    const { getByText } = render(<PaymentHistoryList invoice={invoice()} onVoid={noop} />);
    expect(getByText(/No payments recorded/)).toBeTruthy();
  });

  test("renders one row per payment with amount and method", () => {
    const i = invoice({
      payments: [
        { id: "p1", amount: 400, date: "2026-07-01", method: "cash" },
        { id: "p2", amount: 600, date: "2026-07-20", method: "card" },
      ],
    });
    const { getByText } = render(<PaymentHistoryList invoice={i} onVoid={noop} />);
    expect(getByText("$400.00")).toBeTruthy();
    expect(getByText("$600.00")).toBeTruthy();
  });

  test("a voided payment stays visible and is labelled with its void date", () => {
    const i = invoice({
      payments: [{ id: "p1", amount: 400, date: "2026-07-01", method: "cash", voidedAt: "2026-07-22" }],
    });
    const { getByText } = render(<PaymentHistoryList invoice={i} onVoid={noop} />);
    expect(getByText("$400.00")).toBeTruthy();
    expect(getByText(/voided/i)).toBeTruthy();
  });

  test("the legacy synthesized entry renders with its explanatory label", () => {
    const i = invoice({ id: "i1", paid: true, amount: 1000, paidAt: "2026-06-15", payments: undefined });
    const { getByText } = render(<PaymentHistoryList invoice={i} onVoid={noop} />);
    expect(getByText("$1,000.00")).toBeTruthy();
    expect(getByText(/before itemised history/i)).toBeTruthy();
  });

  test("long-press calls onVoid with the payment id", () => {
    const onVoid = jest.fn();
    const i = invoice({ payments: [{ id: "p1", amount: 400, date: "2026-07-01", method: "cash" }] });
    const { getByLabelText } = render(<PaymentHistoryList invoice={i} onVoid={onVoid} />);
    fireEvent(getByLabelText(/Payment of \$400\.00/), "longPress");
    expect(onVoid).toHaveBeenCalledWith("p1");
  });

  test("long-press on an ALREADY voided payment does nothing", () => {
    const onVoid = jest.fn();
    const i = invoice({
      payments: [{ id: "p1", amount: 400, date: "2026-07-01", method: "cash", voidedAt: "2026-07-22" }],
    });
    const { getByLabelText } = render(<PaymentHistoryList invoice={i} onVoid={onVoid} />);
    fireEvent(getByLabelText(/Payment of \$400\.00/), "longPress");
    expect(onVoid).not.toHaveBeenCalled();
  });
});
```

- [ ] **Step 2: Run to verify they fail**

Run: `npx jest __tests__/PaymentHistoryList.test.js`
Expected: FAIL — `Cannot find module '../components/PaymentHistoryList'`.

- [ ] **Step 3: Implement the component**

Create `components/PaymentHistoryList.tsx`:

```tsx
// components/PaymentHistoryList.tsx
// The payment history for one invoice.
//
// Voided entries STAY in the list, struck through with their void date. That
// is the point of voiding rather than deleting: deletion has to be recorded as
// data, because the sync union cannot distinguish "a payment I don't know
// about" from "one I deleted".
//
// The synthesized `legacy_<id>` entry — which every invoice marked paid before
// itemised history carries — is shown plainly labelled rather than hidden, so
// an old invoice's total visibly adds up and a wrongly-marked-paid invoice
// still has a correction path.
//
// The void CONFIRM lives in the screen, not here. This component just reports
// the intent.

import React, { useMemo } from "react";
import { View, Text, TouchableOpacity, StyleSheet } from "react-native";
import { effectivePayments } from "../utils/invoicePayments";
import { formatMoney } from "../utils/format";
import { spacing, radius, fontSize } from "../utils/theme";
import type { ColorScheme, ShadowScheme } from "../utils/theme";
import { useTheme } from "../hooks/useTheme";
import type { Invoice, Payment } from "../types/models";

const METHOD_LABELS: Record<string, string> = {
  cash: "Cash",
  check: "Cheque",
  card: "Card",
  stripe: "Stripe",
  other: "Other",
};

function isLegacyEntry(p: Payment): boolean {
  return p.id.startsWith("legacy_");
}

export function PaymentHistoryList({
  invoice,
  onVoid,
}: {
  invoice: Invoice;
  onVoid: (paymentId: string) => void;
}) {
  const { colors, shadow } = useTheme();
  const styles = useMemo(() => createStyles(colors, shadow), [colors, shadow]);
  const payments = effectivePayments(invoice);

  if (payments.length === 0) {
    return <Text style={styles.empty}>No payments recorded yet.</Text>;
  }

  return (
    <View>
      {payments.map((p) => {
        const voided = Boolean(p.voidedAt);
        return (
          <TouchableOpacity
            key={p.id}
            style={styles.row}
            onLongPress={voided ? undefined : () => onVoid(p.id)}
            delayLongPress={500}
            accessibilityRole="button"
            accessibilityLabel={`Payment of ${formatMoney(p.amount)} on ${p.date}${voided ? ", voided" : ""}`}
            accessibilityHint={voided ? undefined : "Long press to void this payment"}
          >
            <View style={styles.rowMain}>
              <Text style={[styles.amount, voided && styles.struck]}>
                {formatMoney(p.amount)}
              </Text>
              <Text style={styles.meta}>
                {p.date} · {METHOD_LABELS[p.method] ?? p.method}
              </Text>
            </View>
            {isLegacyEntry(p) && (
              <Text style={styles.note}>recorded before itemised history</Text>
            )}
            {p.note && !isLegacyEntry(p) && <Text style={styles.note}>{p.note}</Text>}
            {voided && <Text style={styles.voided}>voided {p.voidedAt}</Text>}
          </TouchableOpacity>
        );
      })}
    </View>
  );
}

function createStyles(colors: ColorScheme, shadow: ShadowScheme) {
  return StyleSheet.create({
    empty: { color: colors.textMuted, fontSize: fontSize.sm, paddingVertical: spacing.sm },
    row: {
      paddingVertical: spacing.sm,
      borderBottomWidth: StyleSheet.hairlineWidth,
      borderBottomColor: colors.border,
      minHeight: 44,
      justifyContent: "center",
    },
    rowMain: { flexDirection: "row", justifyContent: "space-between", alignItems: "center" },
    amount: { fontSize: fontSize.md, fontWeight: "600", color: colors.text },
    struck: { textDecorationLine: "line-through", color: colors.textMuted },
    meta: { fontSize: fontSize.sm, color: colors.textMuted },
    note: { fontSize: fontSize.sm, color: colors.textMuted, fontStyle: "italic" },
    voided: { fontSize: fontSize.sm, color: colors.warning },
  });
}
```

If `shadow` ends up unused by `createStyles` here, drop it from the signature and the `useTheme` destructure rather than leaving an unused binding — lint runs with `--max-warnings=0`.

- [ ] **Step 4: Run to verify they pass**

Run: `npx jest __tests__/PaymentHistoryList.test.js`
Expected: PASS — 6 tests.

- [ ] **Step 5: Run the full gate**

Run: `npm run typecheck && npm test && npm run lint`
Expected: all three exit 0.

- [ ] **Step 6: Commit**

```bash
git add components/PaymentHistoryList.tsx __tests__/PaymentHistoryList.test.js
git commit -m "feat: add PaymentHistoryList

Voided entries stay visible struck through with their void date, and the
synthesized legacy entry renders plainly labelled so an old invoice's total
adds up. The void confirm lives in the screen; this only reports intent."
```

---

### Task 4: Wire into `InvoicesScreen`

**Files:**
- Modify: `screens/InvoicesScreen.tsx`

**Interfaces:**
- Consumes: everything from Tasks 1–3.
- Produces: no new exports.

This is the only task that touches a screen. Read the whole file first — it is long and has both a row-level action area and a detail modal, and the same actions must appear in both.

- [ ] **Step 1: Read the screen and locate the four insertion points**

Run: `grep -n "markPaid\|invoiceActions\|modalActionRow\|viewingInvoice" screens/InvoicesScreen.tsx`

You are looking for: (a) the `markPaid` function, (b) the row's action button area, (c) the detail modal's action row, (d) the detail modal body where history will go.

- [ ] **Step 2: Add imports and sheet state**

Add to the imports:

```ts
import { RecordPaymentSheet } from "../components/RecordPaymentSheet";
import { PaymentHistoryList } from "../components/PaymentHistoryList";
import {
  applyPayment,
  voidPayment,
  settleRemaining,
  newPaymentId,
  balanceDue,
  amountPaid,
  isPartlyPaid,
  isFullyPaid,
} from "../utils/invoicePayments";
import type { PaymentDraft } from "../types/models";
```

Add state alongside the existing `viewingInvoice` state:

```ts
const [recordingFor, setRecordingFor] = useState<Invoice | null>(null);
```

- [ ] **Step 3: Rewire `markPaid`**

Replace the body of the `onPress` inside `markPaid`'s Alert with:

```ts
        onPress: async () => {
          const today = new Date().toISOString().split('T')[0];
          const inv = invoices.find((i) => i.id === id);
          if (!inv) return;
          const settled = settleRemaining(inv, today);
          const updated = invoices.map((i) => (i.id === id ? settled : i));
          setInvoices(updated);
          await saveInvoices(updated);
          syncNotifications();
          onSuccess?.();
        },
```

Analytics are deliberately omitted here — Task 5 adds them in one place.

Also make the Alert's button label balance-aware. Where the Alert is constructed, the confirm button's text becomes:

```ts
text: inv && isPartlyPaid(inv) ? "Mark rest paid" : "Mark paid",
```

(resolve `inv` before building the Alert if it isn't already in scope there).

- [ ] **Step 4: Add the save and void handlers**

Add near `markPaid`:

```ts
  async function handleRecordPayment(invoice: Invoice, draft: PaymentDraft) {
    const next = applyPayment(invoice, { id: newPaymentId(), ...draft });
    const updated = invoices.map((i) => (i.id === invoice.id ? next : i));
    setInvoices(updated);
    await saveInvoices(updated);
    syncNotifications();
    setRecordingFor(null);
  }

  function confirmVoid(invoice: Invoice, paymentId: string) {
    const payment = effectivePayments(invoice).find((p) => p.id === paymentId);
    if (!payment) return;
    const after = voidPayment(invoice, paymentId, new Date().toISOString().split('T')[0]);
    Alert.alert(
      "Void this payment?",
      `This can't be undone. ${invoice.number} will go back to ${formatMoney(balanceDue(after))} due.\n\nTo correct a mistake, record a new payment.`,
      [
        { text: "Cancel", style: "cancel" },
        {
          text: "Void payment",
          style: "destructive",
          onPress: async () => {
            const updated = invoices.map((i) => (i.id === invoice.id ? after : i));
            setInvoices(updated);
            await saveInvoices(updated);
            syncNotifications();
          },
        },
      ]
    );
  }
```

`formatMoney` (line 24), `track` (line 34) and `Alert` are already imported by this screen. Add `effectivePayments` to the `utils/invoicePayments` import you created in Step 2.

Note the confirm computes the post-void balance by calling `voidPayment` first and reading the result — do not hand-calculate it, or the dialog can disagree with what actually happens.

- [ ] **Step 5: Add the row action and balance-forward display**

In the row's action area, alongside the existing Edit / PDF / Mark paid buttons, add a "Record payment" button shown only when the invoice is not fully paid:

```tsx
          {!isFullyPaid(inv) && (
            <TouchableOpacity style={styles.editBtn} onPress={() => setRecordingFor(inv)}>
              <Text style={styles.editBtnText}>Record payment</Text>
            </TouchableOpacity>
          )}
```

The row renders its amount at line 128 as `<Text style={styles.amount}>{formatMoney(inv.amount)}</Text>`. Make it balance-forward when partly paid:

```tsx
          {isPartlyPaid(inv) ? (
            <Text style={styles.amount}>
              {formatMoney(balanceDue(inv))} due · {formatMoney(amountPaid(inv))} paid
            </Text>
          ) : (
            <Text style={styles.amount}>{formatMoney(inv.amount)}</Text>
          )}
```

Do the same for the modal's amount at line ~246, which uses `styles.modalAmount` with an inline `{ color: accentColor }`.

- [ ] **Step 6: Add history and the record action to the detail modal**

In the detail modal, above the existing action row, add:

```tsx
                <View style={styles.modalDivider} />
                <Text style={styles.modalDetailLabel}>Payment history</Text>
                <PaymentHistoryList invoice={inv} onVoid={(pid) => confirmVoid(inv, pid)} />
```

`styles.modalDetailLabel` and `styles.modalDivider` both already exist in this file — there is no `modalSectionTitle`, so do not reference one.

Then add a "Record payment" entry to the modal's action row, gated the same way as the row button:

```tsx
                  {!isFullyPaid(inv) && (
                    <TouchableOpacity
                      style={styles.modalActionBtn}
                      onPress={() => { setViewingInvoice(null); setRecordingFor(inv); }}
                    >
                      <Text style={styles.modalActionBtnText}>Record payment</Text>
                    </TouchableOpacity>
                  )}
```

All of `modalActionBtn`, `modalActionBtnText`, `modalDivider`, `modalDetailLabel`, `editBtn` and `editBtnText` already exist in this file. Reuse them; do not add new style entries for these.

- [ ] **Step 7: Mount the sheet**

Near the bottom of the screen's returned tree, alongside the existing modal:

```tsx
      {recordingFor && (
        <RecordPaymentSheet
          visible
          invoice={recordingFor}
          onSave={(draft) => handleRecordPayment(recordingFor, draft)}
          onClose={() => setRecordingFor(null)}
        />
      )}
```

- [ ] **Step 8: Run the full gate**

Run: `npm run typecheck && npm test && npm run lint`
Expected: all three exit 0, test count unchanged from Task 3 (this task adds no tests — the components and math are covered, and the screen has no existing test harness).

- [ ] **Step 9: Verify the defect is actually closed**

Run: `grep -n "paid: true" screens/InvoicesScreen.tsx`
Expected: **no match.** If one remains, `markPaid` was not fully rewired and the phase's main defect fix did not land.

- [ ] **Step 10: Commit**

```bash
git add screens/InvoicesScreen.tsx
git commit -m "feat: wire payment recording, history and voiding into Invoices

markPaid now routes through settleRemaining instead of writing a bare
paid: true — the last instance of the defect class that the ledger merge
silently reverts. Rows go balance-forward when partly paid."
```

---

### Task 5: Analytics

**Files:**
- Modify: `screens/InvoicesScreen.tsx`

**Interfaces:**
- Consumes: `track` from `utils/analytics.ts` (already imported by this screen).

`track(event: string, properties?: Record<string, unknown>)` takes a plain string — there is no event union to extend.

- [ ] **Step 1: Add the events**

In `handleRecordPayment`, after the save:

```ts
    track('payment_recorded', {
      amount: draft.amount,
      method: draft.method,
      balanceRemaining: balanceDue(next),
    });
    if (isFullyPaid(next) && !isFullyPaid(invoice)) {
      track('invoice_paid', { amount: next.amount });
    }
```

In `markPaid`'s `onPress`, after the save:

```ts
          track('payment_recorded', {
            amount: balanceDue(inv),
            method: 'other',
            balanceRemaining: 0,
          });
          track('invoice_paid', { amount: inv.amount });
```

In `confirmVoid`'s `onPress`, after the save:

```ts
            track('payment_voided', { amount: payment.amount, method: payment.method });
```

- [ ] **Step 2: Confirm `invoice_paid` keeps its meaning**

Run: `grep -n "invoice_paid" screens/InvoicesScreen.tsx`

Both call sites must fire only when the balance reaches zero — in `handleRecordPayment` it is guarded by the `isFullyPaid` transition, and in `markPaid` settlement is unconditional. This preserves continuity with the existing PostHog series; do not widen it to fire on partial payments.

- [ ] **Step 3: Run the full gate**

Run: `npm run typecheck && npm test && npm run lint`
Expected: all three exit 0.

- [ ] **Step 4: Commit**

```bash
git add screens/InvoicesScreen.tsx
git commit -m "feat: add payment_recorded and payment_voided analytics

invoice_paid keeps its existing meaning — balance reached zero — so the
historical PostHog series stays comparable."
```

---

### Task 6: Accessibility, dark mode and docs

**Files:**
- Modify: `components/RecordPaymentSheet.tsx`, `components/PaymentHistoryList.tsx`, `screens/InvoicesScreen.tsx` (as needed)
- Modify: `ARCHITECTURE.md`

- [ ] **Step 1: Audit touch targets and labels**

Every interactive element added in Tasks 2–4 must have a minimum 44pt touch target and an `accessibilityLabel`. The method chips and history rows already set `minHeight: 44` and labels in the plan's code — verify the new buttons added in Task 4 do too, and fix any that don't.

Run: `grep -n "accessibilityLabel\|minHeight: 44" components/RecordPaymentSheet.tsx components/PaymentHistoryList.tsx`

- [ ] **Step 2: Verify no static colour import crept in**

Run: `grep -n "from \"../utils/theme\"" components/RecordPaymentSheet.tsx components/PaymentHistoryList.tsx`

Each must import only `spacing`, `radius`, `fontSize` and the `ColorScheme`/`ShadowScheme` types — never `colors`. Importing the static `colors` alias freezes the component in light mode.

- [ ] **Step 3: Update ARCHITECTURE.md**

In the `### Invoice` block, extend the `payments` bullet:

```markdown
  Recorded through the Record payment sheet (`components/RecordPaymentSheet.tsx`)
  and shown by `components/PaymentHistoryList.tsx`. "Mark paid" records a
  payment for the outstanding balance rather than setting the flag directly.
```

- [ ] **Step 4: Run the full gate**

Run: `npm run typecheck && npm test && npm run lint`
Expected: all three exit 0.

- [ ] **Step 5: Commit**

```bash
git add components/ screens/InvoicesScreen.tsx ARCHITECTURE.md
git commit -m "chore: a11y labels, theme check and docs for payment recording"
```

---

## Exit criteria

- [ ] `npm run typecheck` — 0 errors
- [ ] `npm test` — 0 failures, roughly +25 tests, no pre-existing test removed
- [ ] `npm run lint` — 0 warnings
- [ ] `grep -n "paid: true" screens/InvoicesScreen.tsx` returns **nothing** — the bare-flag defect is gone
- [ ] `grep -rn "stripe" components/RecordPaymentSheet.tsx` returns **nothing** — that method is webhook-only
- [ ] No file under `backend/`, `utils/sync.ts`, `utils/syncMerge.ts`, or `utils/invoiceStats.ts` was modified
- [ ] `git diff --stat master..HEAD -- utils/invoiceStats.ts` is empty — the analytics sweep is still Phase 4

Then stop and report for the phase gate.

## Reminder: built, but not shippable yet

This phase may be merged. It must NOT ship to users until the Supabase
migration is applied and the backend deployed — the currently-deployed webhook
still writes a bare `paid: true`, which the ledger merge discards, erasing a
real Stripe payment on any invoice carrying a recorded payment. See
`docs/deposits-resume-here.md` §4.

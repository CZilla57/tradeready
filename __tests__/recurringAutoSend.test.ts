// Phase 6 — which generated recurring invoice (if any) gets stamped for
// auto-delivery. Newest occurrence only; gated on the per-plan flag, the master
// setting, and a plausible customer email.

import { selectRecurringInvoiceToAutoSend } from "../utils/recurringAutoSend";
import type { Invoice } from "../types/models";

function inv(occurrenceNumber: number, over: Partial<Invoice> = {}): Invoice {
  return {
    id: `inv${occurrenceNumber}`,
    customer: "Acme",
    customerId: "c1",
    number: `INV-000${occurrenceNumber}`,
    amount: 200,
    due: "2026-09-01",
    email: "billing@acme.com",
    phone: "",
    desc: "Monthly service",
    paid: false,
    recurringInvoiceId: "ri1",
    occurrenceNumber,
    ...over,
  };
}

const ON = { ruleAutoSendEnabled: true, masterEnabled: true, customerEmail: "billing@acme.com" };

describe("selectRecurringInvoiceToAutoSend", () => {
  test("returns the newest occurrence when fully opted in (no catch-up burst)", () => {
    const picked = selectRecurringInvoiceToAutoSend([inv(4), inv(6), inv(5)], ON);
    expect(picked?.id).toBe("inv6");
  });

  test("null when the plan hasn't opted in", () => {
    expect(selectRecurringInvoiceToAutoSend([inv(6)], { ...ON, ruleAutoSendEnabled: false })).toBeNull();
    expect(selectRecurringInvoiceToAutoSend([inv(6)], { ...ON, ruleAutoSendEnabled: undefined })).toBeNull();
  });

  test("null when the master setting is off", () => {
    expect(selectRecurringInvoiceToAutoSend([inv(6)], { ...ON, masterEnabled: false })).toBeNull();
  });

  test("null when the customer email is missing or implausible", () => {
    expect(selectRecurringInvoiceToAutoSend([inv(6)], { ...ON, customerEmail: "" })).toBeNull();
    expect(selectRecurringInvoiceToAutoSend([inv(6)], { ...ON, customerEmail: "no-at-sign" })).toBeNull();
    expect(selectRecurringInvoiceToAutoSend([inv(6)], { ...ON, customerEmail: "a@b.c, c@d.e" })).toBeNull();
  });

  test("null when nothing was generated", () => {
    expect(selectRecurringInvoiceToAutoSend([], ON)).toBeNull();
  });
});

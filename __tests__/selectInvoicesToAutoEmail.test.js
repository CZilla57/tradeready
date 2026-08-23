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

// Phase 6 — recurring-invoice auto-send is gated INDEPENDENTLY of the
// job-completion toggle, on settings.autoSendRecurringInvoicesEnabled.
describe("selectInvoicesToAutoEmail — recurring gate", () => {
  const rinv = (over = {}) => inv({ id: "invR", recurringInvoiceId: "ri1", occurrenceNumber: 3, ...over });

  test("a recurring invoice does NOT send under only the job-completion toggle", () => {
    expect(
      run([rinv()], { settings: { autoEmailInvoiceOnComplete: true } }),
    ).toHaveLength(0);
  });

  test("a recurring invoice sends when the recurring toggle is on", () => {
    expect(
      run([rinv()], { settings: { autoSendRecurringInvoicesEnabled: true } }),
    ).toHaveLength(1);
  });

  test("a job invoice does NOT send under only the recurring toggle", () => {
    expect(
      run([inv()], { settings: { autoSendRecurringInvoicesEnabled: true } }),
    ).toHaveLength(0);
  });

  test("both gates off → nothing sends even when stamped", () => {
    expect(run([rinv(), inv()], { settings: {} })).toHaveLength(0);
  });

  test("mixed batch honors each invoice's own gate", () => {
    const out = run([rinv(), inv()], {
      settings: { autoSendRecurringInvoicesEnabled: true, autoEmailInvoiceOnComplete: false },
    });
    expect(out.map((i) => i.id)).toEqual(["invR"]);
  });

  test("recurring invoices still obey freshness, paid, and email gates", () => {
    const s = { settings: { autoSendRecurringInvoicesEnabled: true } };
    expect(run([rinv({ autoEmailRequestedAt: STALE })], s)).toHaveLength(0);
    expect(run([rinv({ paid: true })], s)).toHaveLength(0);
    expect(run([rinv({ email: "no-at-sign" })], s)).toHaveLength(0);
  });
});

// The autopay sweep's pure selector (Phase 24 spec §4.6): every eligibility
// row, the 14:00 UTC window edges, the amount ceiling, plan reassignment,
// account switch, the daily cap, and housekeeping selection.

const assert = require('node:assert/strict');
const { describe, test } = require('node:test');
const { selectInvoicesToCharge, selectHousekeeping, chargeWindow, planKey, MAX_CLAIMS_PER_USER_PER_DAY } = require('../lib/autopay/selectInvoicesToCharge.js');
const W = require('./helpers/autopayWorld.cjs');

const { USER, ACCOUNT } = W;
const DUE = '2026-11-01';
const OPEN = new Date(Date.UTC(2026, 10, 1, 14, 0, 0)); // due date 14:00 UTC

function run({ enrollment = W.enrollmentRow(), plan = W.planRow(), invoices = [W.invoiceRow({ due: DUE })], charges = [], accounts = new Map([[USER, ACCOUNT]]), now = OPEN } = {}) {
  const plansByKey = new Map(plan ? [[planKey(plan.user_id, plan.id), plan]] : []);
  return selectInvoicesToCharge({ enrollments: enrollment ? [enrollment] : [], accountsByUser: accounts, plansByKey, invoiceRows: invoices, charges, now });
}
const charged = (r) => r.charge.map((i) => i.invoice.id);

describe('autopay selector — eligibility rows', () => {
  test('the happy path charges the live balance in cents', () => {
    const r = run({ invoices: [W.invoiceRow({ due: DUE, payments: [{ id: 'p', amount: 20.5, date: '2026-10-20', method: 'cash' }] })] });
    assert.deepEqual(charged(r), ['inv1']);
    assert.equal(r.charge[0].cents, 9950);
    assert.ok(r.windowOpen.has('inv1'));
    assert.ok(r.willCharge.has('inv1'));
  });

  test('enrollment must be active', () => {
    for (const status of ['pending', 'revoked', 'replaced']) assert.deepEqual(charged(run({ enrollment: W.enrollmentRow({ status }) })), [], status);
  });

  test("account switch: the enrollment's account must be the owner's current one", () => {
    assert.deepEqual(charged(run({ accounts: new Map([[USER, 'acct_new']]) })), []);
    assert.deepEqual(charged(run({ accounts: new Map() })), []);
  });

  test('plan must exist, not be deleted, still offer autopay, and still be this customer’s', () => {
    assert.deepEqual(charged(run({ plan: null })), []);
    assert.deepEqual(charged(run({ plan: W.planRow({}, { deleted: true }) })), []);
    assert.deepEqual(charged(run({ plan: W.planRow({ autopayEnabled: false }) })), []);
    assert.deepEqual(charged(run({ plan: W.planRow({ autopayEnabled: undefined }) })), []);
    assert.deepEqual(charged(run({ plan: W.planRow({ customerId: 'c2' }) })), []);
    // A paused plan (isActive false) still charges its existing invoices: the
    // owner's switch is autopayEnabled (spec §4.6 table).
    assert.deepEqual(charged(run({ plan: W.planRow({ isActive: false }) })), ['inv1']);
  });

  test('plan invoices only; imported or reassigned invoices never', () => {
    assert.deepEqual(charged(run({ invoices: [W.invoiceRow({ due: DUE, recurringInvoiceId: 'ri_other' })] })), []);
    assert.deepEqual(charged(run({ invoices: [W.invoiceRow({ due: DUE, importBatchId: 'imp_1' })] })), []);
    assert.deepEqual(charged(run({ invoices: [W.invoiceRow({ due: DUE, customerId: 'c2' })] })), []);
    assert.deepEqual(charged(run({ invoices: [W.invoiceRow({ due: DUE, customerId: undefined })] })), ['inv1']);
    assert.deepEqual(charged(run({ invoices: [W.invoiceRow({ due: DUE }, { user_id: W.OTHER_USER })] })), []);
  });

  test('consent covers invoices that come due AFTER the activation date (UTC)', () => {
    const at = (iso) => W.enrollmentRow({ activated_at: iso });
    assert.deepEqual(charged(run({ enrollment: at('2026-10-31T23:59:59.000Z') })), ['inv1']);
    assert.deepEqual(charged(run({ enrollment: at('2026-11-01T00:00:00.000Z') })), [], 'due the same day');
    assert.deepEqual(charged(run({ enrollment: at('2026-11-02T00:00:00.000Z') })), []);
    assert.deepEqual(charged(run({ enrollment: at(null) })), []);
  });

  test('paid, zero and malformed balances are skipped', () => {
    assert.deepEqual(charged(run({ invoices: [W.invoiceRow({ due: DUE, paid: true })] })), []);
    assert.deepEqual(charged(run({ invoices: [W.invoiceRow({ due: DUE, payments: [{ id: 'p', amount: 119.996, date: 'x', method: 'cash' }] })] })), []);
    assert.deepEqual(charged(run({ invoices: [W.invoiceRow({ due: DUE, amount: 'abc' })] })), []);
    assert.deepEqual(charged(run({ invoices: [W.invoiceRow({ due: '2026-02-30' })] })), []);
    assert.deepEqual(charged(run({ invoices: [W.invoiceRow({ due: 'Nov 1' })] })), []);
  });

  test('one attempt ever: any charge row blocks the invoice', () => {
    for (const status of ['claimed', 'succeeded', 'failed', 'skipped']) {
      const r = run({ charges: [{ user_id: USER, invoice_id: 'inv1', status, created_at: '2026-10-01T00:00:00.000Z' }] });
      assert.deepEqual(charged(r), [], status);
      assert.equal(r.windowOpen.has('inv1'), false);
      assert.equal(r.willCharge.has('inv1'), false);
    }
  });
});

describe('autopay selector — the [due 14:00 UTC, due + 7 d] window', () => {
  test('edges', () => {
    const at = (ms) => run({ now: new Date(ms) });
    const start = Date.UTC(2026, 10, 1, 14);
    assert.deepEqual(charged(at(start - 1)), [], 'one ms before 14:00 UTC on the due date');
    assert.deepEqual(charged(at(start)), ['inv1']);
    assert.deepEqual(charged(at(start + 7 * 86400000)), ['inv1'], 'last instant');
    assert.deepEqual(charged(at(start + 7 * 86400000 + 1)), [], 'too late: normal email/link path');
  });

  test('before the window: not charged, but "will be charged" for the invoice email', () => {
    const r = run({ now: new Date(Date.UTC(2026, 9, 20)) });
    assert.deepEqual(charged(r), []);
    assert.ok(r.willCharge.has('inv1'));
    assert.equal(r.windowOpen.has('inv1'), false);
  });

  test('after the window: neither', () => {
    const r = run({ now: new Date(Date.UTC(2026, 10, 9)) });
    assert.equal(r.willCharge.size, 0);
  });

  test('chargeWindow is 14:00 UTC — 6–10 am across US zones, never before the due date anywhere', () => {
    const w = chargeWindow('2026-11-01');
    assert.equal(new Date(w.start).toISOString(), '2026-11-01T14:00:00.000Z');
    assert.equal(new Date(w.end).toISOString(), '2026-11-08T14:00:00.000Z');
    assert.equal(chargeWindow('2026-13-01'), null);
  });
});

describe('autopay selector — the authorized ceiling', () => {
  test('a balance above max_amount_cents is skipped once, never charged', () => {
    const r = run({ invoices: [W.invoiceRow({ due: DUE, amount: 120.01 })] });
    assert.deepEqual(charged(r), []);
    assert.deepEqual(r.skip.map((i) => [i.invoice.id, i.cents]), [['inv1', 12001]]);
    assert.equal(r.willCharge.has('inv1'), false);
    assert.equal(r.windowOpen.has('inv1'), false);
  });
  test('exactly the ceiling is charged', () => {
    assert.deepEqual(charged(run({ invoices: [W.invoiceRow({ due: DUE, amount: 120 })] })), ['inv1']);
  });
});

describe('autopay selector — daily cap', () => {
  test(`at most ${MAX_CLAIMS_PER_USER_PER_DAY} claims per user per UTC day, counting earlier claims`, () => {
    const invoices = Array.from({ length: 30 }, (_, i) => W.invoiceRow({ due: DUE }, { id: `inv${String(i).padStart(2, '0')}` }));
    const earlier = Array.from({ length: 3 }, (_, i) => ({ user_id: USER, invoice_id: `old${i}`, status: 'succeeded', created_at: '2026-11-01T00:30:00.000Z' }));
    const yesterday = [{ user_id: USER, invoice_id: 'y', status: 'succeeded', created_at: '2026-10-31T23:59:00.000Z' }];
    const r = run({ invoices, charges: [...earlier, ...yesterday] });
    assert.equal(r.charge.length, 22);
    assert.equal(r.deferred, 8);
    assert.deepEqual(r.charge.slice(0, 2).map((i) => i.invoice.id), ['inv00', 'inv01']);
  });
});

describe('autopay housekeeping selection', () => {
  const now = new Date(Date.UTC(2026, 10, 1, 14));
  const plans = (rows) => new Map(rows.map((p) => [planKey(p.user_id, p.id), p]));

  test('plan gone, deleted or reassigned → revoke; healthy → keep', () => {
    const keep = W.enrollmentRow();
    const gone = W.enrollmentRow({ recurring_invoice_id: 'ri_gone' });
    const deleted = W.enrollmentRow({ recurring_invoice_id: 'ri_del' });
    const moved = W.enrollmentRow({ recurring_invoice_id: 'ri_moved' });
    const r = selectHousekeeping({
      enrollments: [keep, gone, deleted, moved],
      plansByKey: plans([W.planRow(), W.planRow({ id: 'ri_del' }, { id: 'ri_del', deleted: true }), W.planRow({ id: 'ri_moved', customerId: 'c9' }, { id: 'ri_moved' })]),
      now,
    });
    assert.deepEqual(r.revokePlanGone.map((e) => e.recurring_invoice_id).sort(), ['ri_del', 'ri_gone', 'ri_moved']);
  });

  test('autopayEnabled off does NOT revoke (the card stays until removed)', () => {
    const r = selectHousekeeping({ enrollments: [W.enrollmentRow()], plansByKey: plans([W.planRow({ autopayEnabled: false })]), now });
    assert.equal(r.revokePlanGone.length, 0);
  });

  test('pending rows expire after 48 h', () => {
    const fresh = W.enrollmentRow({ status: 'pending', consented_at: new Date(now.getTime() - 47 * 3600e3).toISOString() });
    const stale = W.enrollmentRow({ status: 'pending', consented_at: new Date(now.getTime() - 49 * 3600e3).toISOString() });
    const r = selectHousekeeping({ enrollments: [fresh, stale], plansByKey: plans([W.planRow()]), now });
    assert.deepEqual(r.expirePending.map((e) => e.id), [stale.id]);
  });

  test('an id that could not be fetched is never treated as missing', () => {
    const odd = W.enrollmentRow({ recurring_invoice_id: 'ri with space' });
    const r = selectHousekeeping({ enrollments: [odd], plansByKey: new Map(), now, planIdOk: (id) => /^[A-Za-z0-9_-]+$/.test(id) });
    assert.equal(r.revokePlanGone.length, 0);
  });
});

// Open API resource mappers (Roadmap Phase 23, spec §3 and §10). The mapper
// is the field-exposure security boundary: fixtures carry EVERY canonical
// blob field (N/Domain/CanonicalModels.swift) plus later-phase secrets and
// junk, every secret value carries the SENTINEL marker or a distinctive
// number, and the tests assert exact public key sets and that no secret
// survives anywhere in the output. Money, ledger, payment-link and estimate
// totals are pinned to the shipped math (paymentMath.js, the portal).

const { describe, test } = require('node:test');
const assert = require('node:assert/strict');

const R = require('../lib/api/resources.js');
const { assemblePortalView } = require('../lib/estimate/portalAssemble.js');
const { amountPaid, balanceDue } = require('../lib/paymentMath.js');

const { FIELDS, toPublic, expandRow } = R;
const UPDATED = '2026-10-03T12:00:00.123456+00:00';
const SECRET_NUMBERS = [987.65, 4321.09, 55.55, 7777.77, 31.4159];

function assertNoSecrets(value) {
  const json = JSON.stringify(value);
  assert.ok(!json.includes('SENTINEL'), `a secret string leaked: ${json}`);
  for (const n of SECRET_NUMBERS) assert.ok(!json.includes(String(n)), `secret number ${n} leaked: ${json}`);
}

const JUNK = {
  referralCode: 'SENTINEL-referral',
  anthropicKey: 'SENTINEL-sk-ant',
  groqKey: 'SENTINEL-groq',
  portal: { token: 'SENTINEL-portal-token', enabled: true },
  futureSecretField: 'SENTINEL-future',
  __proto_junk: { nested: 'SENTINEL-nested' },
};

// ── fixtures: every canonical field ──────────────────────────────────────

const customerData = {
  id: 'cust-1',
  name: 'Dana Ruiz',
  email: 'dana@example.test',
  phone: '555-0100',
  address: '1 Main St',
  notes: 'SENTINEL-customer-note',
  createdAt: '2026-01-02',
  portal: { token: 'SENTINEL-portal', enabled: true },
  archivedAt: null,
  importBatchId: 'SENTINEL-batch',
  leadSource: 'google',
  ...JUNK,
};

const snapshot = {
  businessName: 'Ruiz Electric',
  customerName: 'Dana Ruiz',
  jobTitle: 'Panel upgrade',
  lineItems: [{ label: 'Labor', amount: 1200 }, { label: 'Materials', amount: 300.5 }],
  total: 1500.5,
  currency: 'USD',
  options: {
    tiers: [
      { id: 'good', name: 'Good', description: 'Basic', lineItems: [{ label: 'Labor', amount: 900 }], total: 900 },
      { id: 'best', name: 'Best', description: 'Full', lineItems: [{ label: 'Labor', amount: 1500.5 }], total: 1500.5 },
    ],
    addOns: [{ id: 'surge', label: 'Surge guard', description: 'Whole-home', amount: 250 }],
    recommendedTierId: 'best',
  },
  validUntil: '2026-11-01',
  validUntilTimeZone: 'America/Phoenix',
  secretSnapshotJunk: 'SENTINEL-snapshot',
};

const approval = {
  token: 'SENTINEL-approval-token',
  sentAt: '2026-10-01T15:00:00.000Z',
  snapshot,
  decision: 'approved',
  consentAt: '2026-10-02T16:30:00.000Z',
  signerName: 'Dana Ruiz',
  declineReason: 'SENTINEL-decline-reason',
  ip: 'SENTINEL-198.51.100.77',
  userAgent: 'SENTINEL-UA',
  selection: {
    tierId: 'best',
    tierName: 'Best',
    addOnIds: ['surge'],
    addOns: [{ id: 'surge', label: 'Surge guard', amount: 250 }],
    lineItems: [{ label: 'Labor', amount: 1500.5 }, { label: 'Surge guard', amount: 250 }],
    total: 1750.5,
  },
};

const jobData = {
  id: 'job-1',
  customerId: 'cust-1',
  customerName: 'Dana Ruiz',
  title: 'Panel upgrade',
  description: '200A service',
  status: 'approved',
  scheduledDate: '2026-10-10',
  scheduledStartTime: '08:00',
  scheduledEndTime: '12:00',
  address: '1 Main St',
  estimateTotal: 1750.5,
  laborHours: 31.4159,
  laborBreakdown: { onSite: 31.4159, note: 'SENTINEL-labor-note' },
  laborRate: 987.65,
  materials: [{ name: 'SENTINEL-material', cost: 55.55, qty: 1 }],
  materialMarkup: 7777.77,
  jobCosts: [{ label: 'SENTINEL-permit', amount: 55.55 }],
  overhead: 55.55,
  margin: 7777.77,
  notes: 'SENTINEL-job-note',
  invoiceId: 'inv1700000000000',
  createdAt: '2026-09-30',
  photos: ['file:///SENTINEL/photo.jpg'],
  timeSessions: [{ start: 'SENTINEL-session' }],
  recurringJobId: null,
  occurrenceNumber: 3,
  estimateSentAt: '2026-10-01',
  estimateValidUntil: '2026-11-01',
  approval,
  approvalHistory: [{ ...approval, token: 'SENTINEL-old-token' }],
  changeOrders: [{ id: 'co1', approval: { token: 'SENTINEL-co-token' } }],
  archivedAt: null,
  importBatchId: 'SENTINEL-batch',
  quoteOptions: { tiers: [{ id: 'best', cost: 4321.09 }], addOns: [{ id: 'surge', cost: 4321.09 }] },
  ...JUNK,
};

const invoiceData = {
  id: 'inv1700000000000',
  customer: 'Dana Ruiz',
  customerId: 'cust-1',
  number: 'INV-0042',
  amount: 1750.5,
  due: '2026-11-01',
  email: 'SENTINEL-dana@example.test',
  phone: 'SENTINEL-555',
  desc: 'Panel upgrade',
  paid: false,
  paidAt: null,
  payments: [
    { id: 'pay-1', amount: 500, date: '2026-10-05', method: 'Cheque', note: 'SENTINEL-payment-note', voidedAt: null },
    { id: 'stripe_cs_test_123', amount: 250.25, date: '2026-10-06', method: 'stripe', stripeSessionId: 'cs_test_123' },
    { id: 'pay-void', amount: 100, date: '2026-10-07', method: 'cash', voidedAt: '2026-10-08' },
  ],
  depositRequest: { amount: 500, percent: 28.56, requestedAt: '2026-10-01' },
  paymentLinkUrl: 'https://buy.stripe.com/test_abc',
  paymentLinkAmount: 1000.25,
  autoEmailRequestedAt: 'SENTINEL-auto-email',
  lineItems: [{ description: 'Labor', amount: 1500.5, category: 'labor' }, { description: 'Surge guard', amount: 250, category: 'materials' }],
  jobId: 'job-1',
  recurringInvoiceId: null,
  occurrenceNumber: 1,
  importBatchId: 'SENTINEL-batch',
  ...JUNK,
};

const expenseData = {
  id: 'exp-1',
  createdAt: '2026-10-01',
  description: 'Wire',
  amount: 89.991,
  category: 'materials',
  date: '2026-10-01',
  notes: 'SENTINEL-expense-note',
  receiptUri: 'file:///SENTINEL/receipt.jpg',
  jobId: 'job-1',
  importBatchId: 'SENTINEL-batch',
  ...JUNK,
};

const tripData = {
  id: 'trip-1',
  date: '2026-10-01',
  odometerStart: 1000,
  odometerEnd: 1012.4,
  miles: 12.4,
  fromJobId: null,
  fromLabel: 'Shop',
  toJobId: 'job-1',
  toLabel: '1 Main St',
  purpose: 'Site visit',
  createdAt: '2026-10-01',
  ...JUNK,
};

const row = (id, data, extra = {}) => ({ id, user_id: 'owner-1', updated_at: UPDATED, deleted: false, data, ...extra });
const NOW = Date.parse('2026-10-03T18:00:00Z');

// ── exact key sets ───────────────────────────────────────────────────────

describe('FIELDS are frozen by tests (adding a field is a deliberate edit, spec §7)', () => {
  test('every resource has exactly the spec §3 field list, in order', () => {
    assert.deepEqual(FIELDS.customers, ['id', 'name', 'email', 'phone', 'address', 'leadSource', 'createdAt', 'archivedAt', 'updatedAt']);
    assert.deepEqual(FIELDS.jobs, ['id', 'customerId', 'customerName', 'title', 'description', 'status', 'scheduledDate',
      'scheduledStartTime', 'scheduledEndTime', 'address', 'price', 'invoiceId', 'recurringJobId', 'estimateSentAt',
      'createdAt', 'archivedAt', 'updatedAt']);
    assert.deepEqual(FIELDS.estimates, ['id', 'jobId', 'customerId', 'customerName', 'title', 'status', 'sentAt', 'validUntil',
      'total', 'lineItems', 'options', 'decision', 'decidedAt', 'signerName', 'selection', 'updatedAt']);
    assert.deepEqual(FIELDS.invoices, ['id', 'number', 'customerId', 'customerName', 'jobId', 'recurringInvoiceId', 'description',
      'amount', 'amountPaid', 'balanceDue', 'status', 'issueDate', 'due', 'paid', 'paidAt', 'depositRequest', 'lineItems',
      'payments', 'paymentLinkUrl', 'updatedAt']);
    assert.deepEqual(FIELDS.payments, ['id', 'invoiceId', 'invoiceNumber', 'customerId', 'amount', 'date', 'method', 'source',
      'voided', 'voidedAt', 'processorReference', 'updatedAt']);
    assert.deepEqual(FIELDS.expenses, ['id', 'date', 'description', 'amount', 'category', 'categoryLabel', 'jobId', 'hasReceipt',
      'createdAt', 'updatedAt']);
    assert.deepEqual(FIELDS.mileage, ['id', 'date', 'miles', 'odometerStart', 'odometerEnd', 'fromLabel', 'toLabel', 'fromJobId',
      'toJobId', 'purpose', 'createdAt', 'updatedAt']);
    assert.deepEqual(FIELDS.account, ['businessName', 'currency', 'dataAsOf', 'apiVersion', 'key']);
    assert.deepEqual(FIELDS.tombstone, ['id', 'deleted', 'updatedAt']);
  });
});

describe('mappers: exact keys, no secrets, every canonical field plus junk', () => {
  test('customers', () => {
    const out = toPublic.customers(row('cust-1', customerData));
    assert.deepEqual(Object.keys(out), FIELDS.customers);
    assertNoSecrets(out);
    assert.equal(out.leadSource, 'google');
    assert.equal(out.archivedAt, null);
    assert.equal(out.updatedAt, '2026-10-03T12:00:00.123Z');
  });

  test('jobs: price is the customer-facing total; no cost or margin input leaves', () => {
    const out = toPublic.jobs(row('job-1', jobData));
    assert.deepEqual(Object.keys(out), FIELDS.jobs);
    assertNoSecrets(out);
    assert.equal(out.price, 1750.5);
    assert.equal(out.recurringJobId, null);
  });

  test('estimates: only the frozen snapshot and selection; no token, ip, user agent, decline reason or quoteOptions cost', () => {
    const out = toPublic.estimates(row('job-1', jobData), { nowMs: NOW });
    assert.deepEqual(Object.keys(out), FIELDS.estimates);
    assertNoSecrets(out);
    assert.deepEqual(Object.keys(out.options), ['tiers', 'addOns', 'recommendedTierId']);
    assert.deepEqual(Object.keys(out.options.tiers[0]), ['id', 'name', 'total']);
    assert.deepEqual(Object.keys(out.options.addOns[0]), ['id', 'label', 'amount']);
    assert.deepEqual(Object.keys(out.selection), ['tierId', 'tierName', 'addOnIds', 'total']);
    assert.deepEqual(Object.keys(out.lineItems[0]), ['label', 'amount']);
    assert.deepEqual(out.selection, { tierId: 'best', tierName: 'Best', addOnIds: ['surge'], total: 1750.5 });
    assert.equal(out.status, 'approved');
    assert.equal(out.decidedAt, '2026-10-02T16:30:00.000Z');
    assert.equal(out.total, 1750.5);
    assert.equal(out.validUntil, '2026-11-01');
    assert.equal(out.sentAt, '2026-10-01T15:00:00.000Z');
  });

  test('invoices: no email/phone repeat, no paymentLinkAmount/autoEmail/import ids, no payment notes', () => {
    const out = toPublic.invoices(row('inv1700000000000', invoiceData));
    assert.deepEqual(Object.keys(out), FIELDS.invoices);
    assertNoSecrets(out);
    assert.deepEqual(Object.keys(out.depositRequest), ['amount', 'percent', 'requestedAt']);
    assert.deepEqual(Object.keys(out.lineItems[0]), ['description', 'category', 'amount']);
    for (const p of out.payments) assert.deepEqual(Object.keys(p), FIELDS.payments);
    assert.equal(out.customerName, 'Dana Ruiz');
    assert.equal(out.description, 'Panel upgrade');
    assert.equal(out.issueDate, '2023-11-14');
  });

  test('payments (flattened from the invoice ledger)', () => {
    const list = expandRow('payments', row('inv1700000000000', invoiceData), { nowMs: NOW });
    assert.equal(list.length, 3);
    for (const p of list) {
      assert.deepEqual(Object.keys(p), FIELDS.payments);
      assertNoSecrets(p);
    }
    assert.deepEqual(list.map((p) => [p.method, p.source, p.voided, p.processorReference]), [
      ['check', 'device', false, null],
      ['stripe', 'stripe', false, 'cs_test_123'],
      ['cash', 'device', true, null],
    ]);
    assert.equal(list[0].invoiceNumber, 'INV-0042');
    assert.equal(list[0].customerId, 'cust-1');
    assert.equal(list[0].updatedAt, '2026-10-03T12:00:00.123Z');
  });

  test('expenses: hasReceipt instead of the local path; category label from the shared table', () => {
    const out = toPublic.expenses(row('exp-1', expenseData));
    assert.deepEqual(Object.keys(out), FIELDS.expenses);
    assertNoSecrets(out);
    assert.equal(out.hasReceipt, true);
    assert.equal(out.categoryLabel, 'Materials');
    assert.equal(out.amount, 89.99);
    assert.equal(toPublic.expenses(row('e2', { ...expenseData, receiptUri: undefined, category: 'mystery' })).hasReceipt, false);
    assert.equal(toPublic.expenses(row('e2', { ...expenseData, category: 'mystery' })).categoryLabel, 'Other');
    assert.equal(toPublic.expenses(row('e3', { ...expenseData, category: 'labor' })).categoryLabel, 'Subcontractors');
  });

  test('mileage', () => {
    const out = toPublic.mileage(row('trip-1', tripData));
    assert.deepEqual(Object.keys(out), FIELDS.mileage);
    assertNoSecrets(out);
    assert.equal(out.miles, 12.4);
    assert.equal(out.fromJobId, null);
  });

  test('account: businessName only from settings; key from the RPC envelope', () => {
    const out = toPublic.account({
      businessName: 'Ruiz Electric',
      dataAsOf: UPDATED,
      key: { keyId: 'k1', name: 'Books', prefix: 'trk_Ab3dE9fQ', scopes: ['invoices:read'], expiresAt: null, key_hash: 'SENTINEL-hash', userId: 'SENTINEL-owner' },
    });
    assert.deepEqual(Object.keys(out), FIELDS.account);
    assert.deepEqual(Object.keys(out.key), ['id', 'name', 'prefix', 'scopes', 'expiresAt']);
    assertNoSecrets(out);
    assert.equal(out.currency, 'USD');
    assert.equal(out.apiVersion, '2026-10-03');
  });

  test('a bare row with an empty blob still has the fixed key set, with nulls', () => {
    for (const name of ['customers', 'jobs', 'invoices', 'expenses', 'mileage']) {
      const out = toPublic[name](row('x', {}));
      assert.deepEqual(Object.keys(out), FIELDS[name], name);
    }
    const inv = toPublic.invoices(row('x', null));
    assert.equal(inv.depositRequest, null);
    assert.deepEqual(inv.payments, []);
    assert.deepEqual(inv.lineItems, []);
  });
});

describe('money and ledger math', () => {
  test('money is rounded to cents, half away from zero, tolerant of strings and garbage', () => {
    assert.equal(R.money(0.1 + 0.2), 0.3);
    assert.equal(R.money(12.345), 12.35);
    assert.equal(R.money('19.999'), 20);
    assert.equal(R.money(-12.345), -12.35);
    assert.equal(R.money('abc'), 0);
    assert.equal(R.money(undefined), 0);
    assert.ok(!Object.is(R.money(-0.001), -0));
  });

  const vectors = [
    ['legacy paid flag, no ledger', { amount: 100, paid: true }],
    ['legacy unpaid', { amount: 100, paid: false }],
    ['partly paid with a void', { amount: 300, payments: [{ id: 'a', amount: 100 }, { id: 'b', amount: 50, voidedAt: '2026-10-01' }] }],
    ['overpaid', { amount: 100, payments: [{ id: 'a', amount: 150 }] }],
    ['string amounts', { amount: '200.10', payments: [{ id: 'a', amount: '200.1' }] }],
    ['zero amount', { amount: 0 }],
  ];
  for (const [label, inv] of vectors) {
    test(`ledger parity with paymentMath.js: ${label}`, () => {
      const out = toPublic.invoices(row('inv-x', inv));
      assert.equal(out.amountPaid, R.money(amountPaid(inv)));
      assert.equal(out.balanceDue, R.money(balanceDue(inv)));
      const ledgerSum = out.payments.filter((p) => !p.voided).reduce((s, p) => s + p.amount, 0);
      assert.equal(R.money(ledgerSum), out.amountPaid, 'payments sum to amountPaid');
    });
  }

  test('status: paid | partly_paid | unpaid', () => {
    assert.equal(toPublic.invoices(row('i', { amount: 100, paid: true })).status, 'paid');
    assert.equal(toPublic.invoices(row('i', { amount: 100, payments: [{ id: 'a', amount: 40 }] })).status, 'partly_paid');
    assert.equal(toPublic.invoices(row('i', { amount: 100, payments: [{ id: 'a', amount: 40, voidedAt: 'x' }] })).status, 'unpaid');
    assert.equal(toPublic.invoices(row('i', { amount: 100, payments: [{ id: 'a', amount: 150 }] })).status, 'paid');
  });

  test('a legacy paid invoice exposes its synthesized legacy_ payment', () => {
    const out = toPublic.invoices(row('inv9', { amount: 80, paid: true, paidAt: '2026-09-01', number: 'INV-9' }));
    assert.equal(out.payments.length, 1);
    assert.equal(out.payments[0].id, 'legacy_inv9');
    assert.equal(out.payments[0].source, 'legacy');
    assert.equal(out.payments[0].date, '2026-09-01');
    assert.equal(out.payments[0].method, 'other');
  });

  test('issueDate uses the accountant-package id rule', () => {
    assert.equal(R.recoverIssueDate('inv1696118400000'), '2023-10-01');
    assert.equal(R.recoverIssueDate('1696118400000'), '2023-10-01');
    assert.equal(R.recoverIssueDate('abc'), null);
    assert.equal(R.recoverIssueDate('inv'), null);
    assert.equal(R.recoverIssueDate('inv12x'), null);
    assert.equal(R.recoverIssueDate('99999999999999999'), null);
    assert.equal(R.recoverIssueDate('inv0'), null);
  });
});

describe('payment link gate is the portal gate', () => {
  const base = { amount: 300, number: 'INV-1', paymentLinkUrl: 'https://buy.stripe.com/x', paymentLinkAmount: 300 };
  const cases = [
    ['current link on an allowed host', base, true],
    ['stale amount after a partial payment', { ...base, payments: [{ id: 'a', amount: 100 }] }, false],
    ['re-minted for the current balance', { ...base, payments: [{ id: 'a', amount: 100 }], paymentLinkAmount: 200 }, true],
    ['disallowed host', { ...base, paymentLinkUrl: 'https://evil.example/pay' }, false],
    ['legacy squareup.com link', { ...base, paymentLinkUrl: 'https://squareup.com/pay/x' }, false],
    ['http scheme', { ...base, paymentLinkUrl: 'http://buy.stripe.com/x' }, false],
    ['paid invoice', { ...base, paid: true }, false],
    ['no recorded link amount', { ...base, paymentLinkAmount: undefined }, false],
  ];
  for (const [label, inv, shown] of cases) {
    test(label, () => {
      const api = toPublic.invoices(row('inv-1', inv)).paymentLinkUrl;
      const portal = assemblePortalView({
        businessName: 'B', customerRow: { data: { name: 'C' } }, jobRows: [], invoiceRows: [{ data: inv }],
        requestRows: [], photoRows: [], token: 't', apiOrigin: 'https://w.test', nowMs: NOW, userId: 'u', photoSecret: null,
      }).invoices[0].paymentLinkUrl;
      assert.equal(api, portal, 'API and portal agree');
      assert.equal(api !== null, shown);
    });
  }
});

describe('payment method normalization and source', () => {
  test('native display strings and RN union values', () => {
    const table = [
      ['Cash', 'cash'], ['cash', 'cash'], ['Cheque', 'check'], ['check', 'check'], ['Card', 'card'],
      ['Stripe', 'stripe'], ['stripe', 'stripe'], ['Bank transfer', 'bank_transfer'], ['bank_transfer', 'bank_transfer'],
      ['ACH', 'bank_transfer'], ['Other', 'other'], ['Venmo', 'other'], [undefined, 'other'], [42, 'other'],
    ];
    for (const [input, want] of table) assert.equal(R.normalizeMethod(input), want, String(input));
    assert.deepEqual(R.PAYMENT_METHODS, ['stripe', 'cash', 'check', 'card', 'bank_transfer', 'other']);
  });

  test('source from the id prefix; processor reference falls back to the stripe_ id', () => {
    assert.equal(R.paymentSource('stripe_pi_123'), 'stripe');
    assert.equal(R.paymentSource('legacy_inv1'), 'legacy');
    assert.equal(R.paymentSource('p1'), 'device');
    const [p] = expandRow('payments', row('inv', { amount: 50, payments: [{ id: 'stripe_pi_777', amount: 50, method: 'card' }] }), { nowMs: NOW });
    assert.equal(p.processorReference, 'pi_777');
    assert.equal(p.source, 'stripe');
  });
});

describe('estimate status table (spec §3; owner-zone expiry)', () => {
  const EARLY = Date.parse('2026-10-03T05:00:00Z'); // Phoenix: Oct 2 22:00; Auckland: Oct 3 18:00; AoE: Oct 2 17:00
  const undecided = (snap, status = 'estimate_sent') => ({
    ...jobData,
    status,
    approval: { token: 't', sentAt: '2026-10-01T00:00:00Z', snapshot: snap },
  });
  const status = (data, nowMs = EARLY) => R.estimateStatus(data, nowMs);

  test('a customer decision on the link wins', () => {
    assert.equal(status({ ...jobData, status: 'lead' }), 'approved');
    assert.equal(status({ ...jobData, approval: { ...approval, decision: 'declined', selection: undefined } }), 'declined');
  });

  test('a manual owner decision via job status', () => {
    assert.equal(status(undecided(snapshot, 'scheduled')), 'approved');
    assert.equal(status(undecided(snapshot, 'declined')), 'declined');
    const out = toPublic.estimates(row('job-1', undecided(snapshot, 'complete')), { nowMs: EARLY });
    assert.equal(out.decision, 'approved');
    assert.equal(out.decidedAt, null, 'a manual decision has no decidedAt');
    assert.equal(out.signerName, null);
    assert.equal(out.selection, null);
  });

  test('expiry is judged in the snapshot zone, inclusive of the valid-until day', () => {
    const snap = (validUntil, tz) => ({ ...snapshot, validUntil, validUntilTimeZone: tz });
    assert.equal(status(undecided(snap('2026-10-02', 'America/Phoenix'))), 'sent', 'still Oct 2 in Phoenix');
    assert.equal(status(undecided(snap('2026-10-02', 'Pacific/Auckland'))), 'expired', 'already Oct 3 in Auckland');
    assert.equal(status(undecided(snap('2026-10-01', 'America/Phoenix'))), 'expired');
    assert.equal(status(undecided({ ...snapshot, validUntil: undefined, validUntilTimeZone: undefined })), 'sent', 'undated never expires');
  });

  test('a sent-without-link estimate uses the job date and anywhere-on-Earth', () => {
    const noLink = (validUntil, st = 'estimate_sent') => ({ ...jobData, status: st, approval: undefined, estimateValidUntil: validUntil });
    assert.equal(status(noLink('2026-10-02')), 'sent', 'AoE is still Oct 2');
    assert.equal(status(noLink('2026-10-01')), 'expired');
    assert.equal(status(noLink('2026-10-01', 'lead')), 'draft');
    const out = toPublic.estimates(row('job-2', noLink('2026-10-20')), { nowMs: EARLY });
    assert.equal(out.options, null);
    assert.deepEqual(out.lineItems, []);
    assert.equal(out.total, 1750.5);
    assert.equal(out.sentAt, '2026-10-01');
    assert.equal(out.validUntil, '2026-10-20');
  });

  test('a job that is not an estimate maps to nothing', () => {
    const plain = { ...jobData, approval: undefined, estimateSentAt: undefined };
    assert.equal(toPublic.estimates(row('job-3', plain), { nowMs: NOW }), null);
    assert.deepEqual(expandRow('estimates', row('job-3', plain), { nowMs: NOW }), []);
    assert.equal(toPublic.estimates(row('job-4', { ...plain, approval: null }), { nowMs: NOW }), null);
  });

  test('estimate total is the portal total (accepted, lowest option, or snapshot)', () => {
    const jobs = [
      row('j1', jobData),
      row('j2', undecided(snapshot)),
      row('j3', undecided({ ...snapshot, options: undefined })),
    ];
    const portal = assemblePortalView({
      businessName: 'B', customerRow: { data: { name: 'C' } }, jobRows: jobs, invoiceRows: [], requestRows: [],
      photoRows: [], token: 't', apiOrigin: 'https://w.test', nowMs: NOW, userId: 'u', photoSecret: null,
    }).estimates.map((e) => e.total);
    const api = jobs.map((r) => toPublic.estimates(r, { nowMs: NOW }).total);
    assert.deepEqual(api, portal);
    assert.deepEqual(api, [1750.5, 900, 1500.5]);
  });
});

describe('tombstones', () => {
  const dead = (id, data) => ({ ...row(id, data), deleted: true });

  test('a deleted row becomes {id, deleted:true, updatedAt}', () => {
    const [t] = expandRow('customers', dead('cust-1', customerData), { nowMs: NOW });
    assert.deepEqual(t, { id: 'cust-1', deleted: true, updatedAt: '2026-10-03T12:00:00.123Z' });
    assert.deepEqual(Object.keys(t), FIELDS.tombstone);
  });

  test('a deleted invoice retracts each of its payments', () => {
    const list = expandRow('payments', dead('inv1700000000000', invoiceData), { nowMs: NOW });
    assert.deepEqual(list.map((t) => t.id), ['pay-1', 'stripe_cs_test_123', 'pay-void']);
    for (const t of list) assert.equal(t.deleted, true);
  });

  test('a deleted job that was not an estimate is not an estimate tombstone', () => {
    assert.deepEqual(expandRow('estimates', dead('j', { title: 'x' }), { nowMs: NOW }), []);
    assert.equal(expandRow('estimates', dead('j', jobData), { nowMs: NOW }).length, 1);
  });
});

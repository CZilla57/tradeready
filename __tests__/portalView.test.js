// __tests__/portalView.test.js
// The portal read is the feature's security boundary: the response is a
// WHITELIST (exact-keys assertions), estimates are only approval-carrying
// jobs, and payment links pass the same host allowlist as dunning email.
// balanceDue/isAllowedPaymentLink are REAL — behavior, not mocks.

jest.mock('../backend/lib/estimate/portalStore', () => ({
  lookupCustomerByPortalToken: jest.fn(),
  fetchBusinessName: jest.fn(),
  fetchCustomerJobs: jest.fn(),
  fetchCustomerInvoices: jest.fn(),
}));

const store = require('../backend/lib/estimate/portalStore');
const portalView = require('../backend/lib/estimate/portalView');

function mockRes() {
  const res = { headers: {}, statusCode: 0, body: null };
  res.setHeader = (k, v) => { res.headers[k] = v; };
  res.status = (c) => { res.statusCode = c; return res; };
  res.json = (b) => { res.body = b; return res; };
  res.end = () => res;
  return res;
}

function req(query, extra = {}) {
  return { method: 'GET', headers: { origin: 'https://gettradereadyapp.com' }, query, ...extra };
}

beforeEach(() => {
  jest.clearAllMocks();
  store.lookupCustomerByPortalToken.mockResolvedValue({
    user_id: 'u1', id: 'c1',
    data: { name: 'Dana Rivers', email: 'private@example.com', portal: { token: 'T', enabled: true } },
  });
  store.fetchBusinessName.mockResolvedValue('Rivera Plumbing');
  store.fetchCustomerJobs.mockResolvedValue([
    { id: 'j1', data: { title: 'Internal job', status: 'scheduled' } }, // no approval — invisible
    { id: 'j2', data: { title: 'Water heater', status: 'estimate_sent',
      approval: { token: 'apptok', snapshot: { jobTitle: 'Water heater replacement', total: 1200 } } } },
    { id: 'j3', data: { title: 'Fence', status: 'declined',
      approval: { token: 'apptok3', decision: 'declined', snapshot: { jobTitle: 'Fence repair', total: 800 } } } },
  ]);
  store.fetchCustomerInvoices.mockResolvedValue([
    { id: 'i1', data: { number: 'INV-0001', amount: 500, due: '2026-08-20', paid: false,
      paymentLinkUrl: 'https://buy.stripe.com/pay123' } },
    { id: 'i2', data: { number: 'INV-0002', amount: 300, due: '2026-07-01', paid: true, paidAt: '2026-07-03',
      paymentLinkUrl: 'https://buy.stripe.com/old' } },
    { id: 'i3', data: { number: 'INV-0003', amount: 250, due: '2026-08-25', paid: false,
      paymentLinkUrl: 'https://squareup.com/pay/SECRET-TOKEN' } }, // disallowed host
  ]);
});

describe('portal-view', () => {
  it('returns the exact whitelist shape — nothing else leaks', async () => {
    const res = mockRes();
    await portalView(req({ p: 'T' }), res);
    expect(res.statusCode).toBe(200);
    expect(Object.keys(res.body).sort()).toEqual(['businessName', 'customerName', 'estimates', 'invoices']);
    expect(res.body.businessName).toBe('Rivera Plumbing');
    expect(res.body.customerName).toBe('Dana Rivers');
    for (const e of res.body.estimates) {
      expect(Object.keys(e).sort()).toEqual(['approvalUrl', 'decision', 'title', 'total']);
    }
    for (const i of res.body.invoices) {
      expect(Object.keys(i).sort()).toEqual(['amount', 'balanceDue', 'due', 'number', 'paid', 'paidAt', 'paymentLinkUrl']);
    }
    expect(JSON.stringify(res.body)).not.toContain('private@example.com');
  });

  it('lists only approval-carrying jobs as estimates, with decision + approval URL', async () => {
    const res = mockRes();
    await portalView(req({ p: 'T' }), res);
    expect(res.body.estimates).toHaveLength(2);
    const [pending, declined] = res.body.estimates;
    expect(pending.title).toBe('Water heater replacement');
    expect(pending.total).toBe(1200);
    expect(pending.decision).toBeNull();
    expect(pending.approvalUrl).toBe('https://gettradereadyapp.com/estimate.html?j=j2&t=apptok');
    expect(declined.decision).toBe('declined');
  });

  it('computes balanceDue with the real payment math and filters payment links', async () => {
    const res = mockRes();
    await portalView(req({ p: 'T' }), res);
    const [open, paid, badHost] = res.body.invoices;
    expect(open.balanceDue).toBe(500);            // no ledger → full amount
    expect(open.paymentLinkUrl).toBe('https://buy.stripe.com/pay123');
    expect(paid.paid).toBe(true);
    expect(paid.paymentLinkUrl).toBeNull();       // paid → never a link
    expect(badHost.paymentLinkUrl).toBeNull();    // squareup.com is not allowlisted
    expect(JSON.stringify(res.body)).not.toContain('SECRET-TOKEN');
  });

  it('404s unknown/disabled tokens oracle-free and 400s a missing token', async () => {
    store.lookupCustomerByPortalToken.mockResolvedValue(null);
    const res = mockRes();
    await portalView(req({ p: 'nope' }), res);
    expect(res.statusCode).toBe(404);
    expect(res.body).toEqual({ error: 'This link is invalid.' });
    const missing = mockRes();
    await portalView(req({}), missing);
    expect(missing.statusCode).toBe(400);
    expect(missing.body).toEqual({ error: 'Missing link parameters.' });
  });

  it('handles OPTIONS/405/CORS and 500s on store failure', async () => {
    const pre = mockRes();
    await portalView({ method: 'OPTIONS', headers: {}, query: {} }, pre);
    expect(pre.statusCode).toBe(200);
    const post = mockRes();
    await portalView({ method: 'POST', headers: {}, query: {} }, post);
    expect(post.statusCode).toBe(405);
    const res = mockRes();
    await portalView(req({ p: 'T' }), res);
    expect(res.headers['Access-Control-Allow-Origin']).toBe('https://gettradereadyapp.com');
    store.fetchCustomerJobs.mockRejectedValue(new Error('db down'));
    const err = mockRes();
    await portalView(req({ p: 'T' }), err);
    expect(err.statusCode).toBe(500);
  });
});

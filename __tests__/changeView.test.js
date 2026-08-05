jest.mock('../backend/lib/estimateStore', () => ({
  fetchJob: jest.fn(),
  constantTimeEqual: (a, b) => a === b,
}));

const store = require('../backend/lib/estimateStore');
const changeView = require('../backend/lib/estimate/changeView');

function mockRes() {
  const res = { headers: {}, statusCode: 0, body: null };
  res.setHeader = (k, v) => { res.headers[k] = v; };
  res.status = (c) => { res.statusCode = c; return res; };
  res.json = (b) => { res.body = b; return res; };
  res.end = () => res;
  return res;
}
const req = (query) => ({ method: 'GET', headers: { origin: 'https://gettradereadyapp.com' }, query });

const jobData = {
  title: 'Bath remodel', estimateTotal: 2400,
  changeOrders: [
    { id: 'coA', title: 'Prior work', amount: 850, createdAt: 'd',
      manualDecision: { decision: 'approved', decidedAt: 'd' } },
    { id: 'coB', title: 'Subfloor', amount: 200, description: 'Replace rotted section', createdAt: 'd',
      approval: { token: 'TOK', sentAt: 's',
        snapshot: { businessName: 'Rivera Plumbing', customerName: 'Dana', jobTitle: 'Bath remodel',
          lineItems: [{ label: 'Subfloor', amount: 200 }], total: 200, currency: 'USD' } } },
  ],
};

beforeEach(() => {
  jest.clearAllMocks();
  store.fetchJob.mockResolvedValue({ user_id: 'u1', data: jobData });
});

describe('change-view', () => {
  it('returns snapshot + live context totals for a valid token', async () => {
    const res = mockRes();
    await changeView(req({ j: 'j1', co: 'coB', t: 'TOK' }), res);
    expect(res.statusCode).toBe(200);
    expect(res.body.businessName).toBe('Rivera Plumbing');
    expect(res.body.total).toBe(200);
    expect(res.body.description).toBe('Replace rotted section');
    expect(res.body.decision).toBeNull();
    expect(res.body.signatureRequired).toBe(true);
    expect(res.body.context).toEqual({ originalTotal: 3250, changeAmount: 200, newTotal: 3450 });
  });

  it('surfaces a manual decision as decided state', async () => {
    const decided = JSON.parse(JSON.stringify(jobData));
    decided.changeOrders[1].manualDecision = { decision: 'approved', decidedAt: 'd' };
    store.fetchJob.mockResolvedValue({ user_id: 'u1', data: decided });
    const res = mockRes();
    await changeView(req({ j: 'j1', co: 'coB', t: 'TOK' }), res);
    expect(res.body.decision).toBe('approved');
  });

  it('404s on a bad token, missing CO, or CO without approval', async () => {
    for (const q of [
      { j: 'j1', co: 'coB', t: 'WRONG' },
      { j: 'j1', co: 'nope', t: 'TOK' },
      { j: 'j1', co: 'coA', t: 'TOK' },   // coA has no approval object
    ]) {
      const res = mockRes();
      await changeView(req(q), res);
      expect(res.statusCode).toBe(404);
      expect(res.body.error).toBe('This link is invalid or has expired.');
    }
  });

  it('400s on missing params', async () => {
    const res = mockRes();
    await changeView(req({ j: 'j1', t: 'TOK' }), res);
    expect(res.statusCode).toBe(400);
  });
});

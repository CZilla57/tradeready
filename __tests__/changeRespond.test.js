jest.mock('../backend/lib/estimateStore', () => ({
  fetchJob: jest.fn(),
  upsertJob: jest.fn().mockResolvedValue(undefined),
  constantTimeEqual: (a, b) => a === b,
}));

const store = require('../backend/lib/estimateStore');
const changeRespond = require('../backend/lib/estimate/changeRespond');

function mockRes() {
  const res = { headers: {}, statusCode: 0, body: null };
  res.setHeader = (k, v) => { res.headers[k] = v; };
  res.status = (c) => { res.statusCode = c; return res; };
  res.json = (b) => { res.body = b; return res; };
  res.end = () => res;
  return res;
}
const req = (body) => ({
  method: 'POST', headers: { origin: 'https://gettradereadyapp.com', 'user-agent': 'ua' },
  socket: { remoteAddress: '9.9.9.9' }, body,
});

const freshJob = () => ({
  user_id: 'u1',
  data: {
    estimateTotal: 2400,
    changeOrders: [
      { id: 'coB', title: 'Subfloor', amount: 200, createdAt: 'd',
        approval: { token: 'TOK', sentAt: 's', snapshot: { total: 200 } } },
    ],
  },
});

beforeEach(() => {
  jest.clearAllMocks();
  store.fetchJob.mockResolvedValue(freshJob());
});

describe('change-respond', () => {
  it('records an approval into the RIGHT array element with server consent', async () => {
    const res = mockRes();
    await changeRespond(req({ jobId: 'j1', changeOrderId: 'coB', token: 'TOK', decision: 'approved', signerName: 'Dana R' }), res);
    expect(res.statusCode).toBe(200);
    expect(res.body.ok).toBe(true);
    expect(res.body.decision).toBe('approved');
    const [, , written] = store.upsertJob.mock.calls[0];
    const co = written.changeOrders[0];
    expect(co.approval.decision).toBe('approved');
    expect(co.approval.signerName).toBe('Dana R');
    expect(typeof co.approval.consentAt).toBe('string');
    expect(written.estimateTotal).toBe(2400); // rest of blob preserved
  });

  it('refuses 409 when the CO was manually decided on site', async () => {
    const decided = freshJob();
    decided.data.changeOrders[0].manualDecision = { decision: 'approved', decidedAt: 'd' };
    store.fetchJob.mockResolvedValue(decided);
    const res = mockRes();
    await changeRespond(req({ jobId: 'j1', changeOrderId: 'coB', token: 'TOK', decision: 'declined' }), res);
    expect(res.statusCode).toBe(409);
    expect(res.body.error).toBe('This change was already decided.');
    expect(store.upsertJob).not.toHaveBeenCalled();
  });

  it('does not rewrite once link-approved (terminal lock, no needless upsert)', async () => {
    const approved = freshJob();
    approved.data.changeOrders[0].approval.decision = 'approved';
    approved.data.changeOrders[0].approval.consentAt = 'c1';
    store.fetchJob.mockResolvedValue(approved);
    const res = mockRes();
    await changeRespond(req({ jobId: 'j1', changeOrderId: 'coB', token: 'TOK', decision: 'declined' }), res);
    expect(res.statusCode).toBe(200);
    expect(res.body.decision).toBe('approved');   // lock held
    expect(store.upsertJob).not.toHaveBeenCalled();
  });

  it('404s on bad token / unknown CO; 400s on bad decision or missing signer name', async () => {
    let res = mockRes();
    await changeRespond(req({ jobId: 'j1', changeOrderId: 'coB', token: 'WRONG', decision: 'approved', signerName: 'D' }), res);
    expect(res.statusCode).toBe(404);
    res = mockRes();
    await changeRespond(req({ jobId: 'j1', changeOrderId: 'nope', token: 'TOK', decision: 'approved', signerName: 'D' }), res);
    expect(res.statusCode).toBe(404);
    res = mockRes();
    await changeRespond(req({ jobId: 'j1', changeOrderId: 'coB', token: 'TOK', decision: 'maybe' }), res);
    expect(res.statusCode).toBe(400);
    res = mockRes();
    await changeRespond(req({ jobId: 'j1', changeOrderId: 'coB', token: 'TOK', decision: 'approved', signerName: '  ' }), res);
    expect(res.statusCode).toBe(400);
  });
});

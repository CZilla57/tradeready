// __tests__/bookingDispatcher.test.js
// One serverless function for all booking routes (12-function-cap
// discipline). hasOwnProperty guard pins against prototype-name actions —
// the same hardening as api/estimate/[action].js.

jest.mock('../backend/lib/booking/mint', () => jest.fn((req, res) => res.status(200).json({ route: 'mint' })));
jest.mock('../backend/lib/booking/config', () => jest.fn((req, res) => res.status(200).json({ route: 'config' })));
jest.mock('../backend/lib/booking/submit', () => jest.fn((req, res) => res.status(200).json({ route: 'submit' })));

const handler = require('../backend/api/booking/[action]');

function mockRes() {
  const res = { statusCode: 0, body: null };
  res.status = (c) => { res.statusCode = c; return res; };
  res.json = (b) => { res.body = b; return res; };
  return res;
}

describe('booking dispatcher', () => {
  it.each(['mint', 'config', 'submit'])('routes %s to its handler', async (action) => {
    const res = mockRes();
    await handler({ query: { action } }, res);
    expect(res.body).toEqual({ route: action });
  });

  it('404s unknown actions', async () => {
    const res = mockRes();
    await handler({ query: { action: 'nope' } }, res);
    expect(res.statusCode).toBe(404);
  });

  it('404s prototype-inherited action names', async () => {
    const res = mockRes();
    await handler({ query: { action: 'constructor' } }, res);
    expect(res.statusCode).toBe(404);
  });
});

// __tests__/bookingConfig.test.js
// The form-bootstrap read leaks NOTHING but the business display name —
// the response-keys assertion is the point of this suite.

jest.mock('../backend/lib/booking/store', () => ({
  lookupUserByBookingToken: jest.fn(),
}));

const store = require('../backend/lib/booking/store');
const config = require('../backend/lib/booking/config');

function mockRes() {
  const res = { headers: {}, statusCode: 0, body: null };
  res.setHeader = (k, v) => { res.headers[k] = v; };
  res.status = (c) => { res.statusCode = c; return res; };
  res.json = (b) => { res.body = b; return res; };
  res.end = () => res;
  return res;
}

beforeEach(() => {
  jest.clearAllMocks();
  store.lookupUserByBookingToken.mockResolvedValue({
    user_id: 'u1',
    data: { businessName: 'Rivera Plumbing', email: 'private@example.com', laborRate: 95, pushToken: { token: 'SECRETISH' } },
  });
});

describe('booking config', () => {
  it('returns ONLY businessName — no other settings fields leak', async () => {
    const res = mockRes();
    await config({ method: 'GET', headers: {}, query: { b: 'tok123' } }, res);
    expect(res.statusCode).toBe(200);
    expect(res.body).toEqual({ businessName: 'Rivera Plumbing' });
    expect(Object.keys(res.body)).toEqual(['businessName']);
  });

  it('404s unknown/disabled tokens with the oracle-free message', async () => {
    store.lookupUserByBookingToken.mockResolvedValue(null);
    const res = mockRes();
    await config({ method: 'GET', headers: {}, query: { b: 'nope' } }, res);
    expect(res.statusCode).toBe(404);
    expect(res.body).toEqual({ error: 'This link is invalid.' });
  });

  it('400s a missing token, 405s non-GET, 200s OPTIONS', async () => {
    const res = mockRes();
    await config({ method: 'GET', headers: {}, query: {} }, res);
    expect(res.statusCode).toBe(400);
    const post = mockRes();
    await config({ method: 'POST', headers: {}, query: {} }, post);
    expect(post.statusCode).toBe(405);
    const pre = mockRes();
    await config({ method: 'OPTIONS', headers: {}, query: {} }, pre);
    expect(pre.statusCode).toBe(200);
  });

  it('applies the CORS allowlist headers', async () => {
    const res = mockRes();
    await config({ method: 'GET', headers: { origin: 'https://gettradereadyapp.com' }, query: { b: 'tok123' } }, res);
    expect(res.headers['Access-Control-Allow-Origin']).toBe('https://gettradereadyapp.com');
    expect(res.headers['Vary']).toBe('Origin');
  });
});

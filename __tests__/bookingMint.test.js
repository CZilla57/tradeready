// __tests__/bookingMint.test.js
// Mint is JWT-authed and STATELESS — it returns a secure token and writes
// nothing; the device saves it into settings and normal sync publishes it.
// (The device has no secure RNG — the create-link precedent.)

process.env.SUPABASE_URL = 'https://unit.test';
process.env.SUPABASE_ANON_KEY = 'anon-test';

const mint = require('../backend/lib/booking/mint');

function mockRes() {
  const res = { headers: {}, statusCode: 0, body: null };
  res.setHeader = (k, v) => { res.headers[k] = v; };
  res.status = (c) => { res.statusCode = c; return res; };
  res.json = (b) => { res.body = b; return res; };
  res.end = () => res;
  return res;
}

afterEach(() => { delete global.fetch; });

describe('booking mint', () => {
  it('401s without a bearer token', async () => {
    const res = mockRes();
    await mint({ method: 'POST', headers: {} }, res);
    expect(res.statusCode).toBe(401);
  });

  it('401s an invalid session', async () => {
    global.fetch = jest.fn().mockResolvedValue({ ok: false });
    const res = mockRes();
    await mint({ method: 'POST', headers: { authorization: 'Bearer bad' } }, res);
    expect(res.statusCode).toBe(401);
  });

  it('returns a fresh 48-hex token for a valid session and performs no writes', async () => {
    global.fetch = jest.fn().mockResolvedValue({ ok: true, json: async () => ({ id: 'u1' }) });
    const res = mockRes();
    await mint({ method: 'POST', headers: { authorization: 'Bearer good' } }, res);
    expect(res.statusCode).toBe(200);
    expect(res.body.token).toMatch(/^[0-9a-f]{48}$/);
    // Only the auth verification call — stateless by contract.
    expect(global.fetch).toHaveBeenCalledTimes(1);
    expect(global.fetch.mock.calls[0][0]).toBe('https://unit.test/auth/v1/user');
  });

  it('405s non-POST', async () => {
    const res = mockRes();
    await mint({ method: 'GET', headers: {} }, res);
    expect(res.statusCode).toBe(405);
  });
});

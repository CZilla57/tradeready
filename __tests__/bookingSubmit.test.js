// __tests__/bookingSubmit.test.js
// The public submit handler: honeypot drops silently (don't teach the bot),
// alerts are fire-and-forget, and the inserted row carries a server-minted
// id + status "new" + server-clock createdAt.

jest.mock('../backend/lib/booking/store', () => ({
  lookupUserByBookingToken: jest.fn(),
  insertBookingRequest: jest.fn(),
  newRequestId: jest.fn(() => 'bk1700000000000_a1b2c3'),
}));
jest.mock('../backend/lib/booking/notifyOwner', () => ({ notifyOwner: jest.fn().mockResolvedValue(undefined) }));

const store = require('../backend/lib/booking/store');
const { notifyOwner } = require('../backend/lib/booking/notifyOwner');
const submit = require('../backend/lib/booking/submit');

function mockRes() {
  const res = { headers: {}, statusCode: 0, body: null };
  res.setHeader = (k, v) => { res.headers[k] = v; };
  res.status = (c) => { res.statusCode = c; return res; };
  res.json = (b) => { res.body = b; return res; };
  res.end = () => res;
  return res;
}

function makeReq(body, ip = '1.2.3.4') {
  return { method: 'POST', headers: { 'x-forwarded-for': ip, origin: 'https://gettradereadyapp.com' }, body };
}

const payload = {
  b: 'tok123', name: 'Dana Rivers', phone: '555-0142', email: 'dana@example.com',
  address: '12 Elm St', details: 'Water heater is leaking', preferredTiming: 'Mornings', website: '',
};

beforeEach(() => {
  jest.clearAllMocks();
  store.lookupUserByBookingToken.mockResolvedValue({ user_id: 'u1', data: { businessName: 'Rivera Plumbing' } });
  store.insertBookingRequest.mockResolvedValue(undefined);
});

describe('booking submit', () => {
  it('inserts a "new" request and fires alerts on the happy path', async () => {
    const res = mockRes();
    await submit(makeReq(payload), res);
    expect(res.statusCode).toBe(200);
    expect(res.body).toEqual({ ok: true });
    const [userId, request] = store.insertBookingRequest.mock.calls[0];
    expect(userId).toBe('u1');
    expect(request.id).toBe('bk1700000000000_a1b2c3');
    expect(request.status).toBe('new');
    expect(request.name).toBe('Dana Rivers');
    expect(typeof request.createdAt).toBe('string');
    expect(notifyOwner).toHaveBeenCalledWith(expect.objectContaining({ userId: 'u1', request: expect.any(Object) }));
  });

  it('honeypot: non-empty website returns ok WITHOUT inserting or alerting', async () => {
    const res = mockRes();
    await submit(makeReq({ ...payload, website: 'http://spam' }), res);
    expect(res.statusCode).toBe(200);
    expect(res.body).toEqual({ ok: true });
    expect(store.insertBookingRequest).not.toHaveBeenCalled();
    expect(notifyOwner).not.toHaveBeenCalled();
  });

  it('404s an unknown/disabled token with the oracle-free message', async () => {
    store.lookupUserByBookingToken.mockResolvedValue(null);
    const res = mockRes();
    await submit(makeReq(payload), res);
    expect(res.statusCode).toBe(404);
    expect(res.body).toEqual({ error: 'This link is invalid.' });
    expect(store.insertBookingRequest).not.toHaveBeenCalled();
  });

  it('400s validation failures with the field message and does not insert', async () => {
    const res = mockRes();
    await submit(makeReq({ ...payload, details: '' }), res);
    expect(res.statusCode).toBe(400);
    expect(res.body.error).toMatch(/describe what you need/);
    expect(store.insertBookingRequest).not.toHaveBeenCalled();
  });

  it('500s when the insert fails (nothing partial persists)', async () => {
    store.insertBookingRequest.mockRejectedValue(new Error('db down'));
    const res = mockRes();
    await submit(makeReq(payload), res);
    expect(res.statusCode).toBe(500);
    expect(notifyOwner).not.toHaveBeenCalled();
  });

  it('still returns 200 when alerts fail after a successful insert', async () => {
    notifyOwner.mockRejectedValue(new Error('mail down'));
    const res = mockRes();
    await submit(makeReq(payload), res);
    expect(res.statusCode).toBe(200);
    expect(res.body).toEqual({ ok: true });
  });

  it('405s non-POST and handles OPTIONS preflight', async () => {
    const res = mockRes();
    await submit({ method: 'GET', headers: {} }, res);
    expect(res.statusCode).toBe(405);
    const pre = mockRes();
    await submit({ method: 'OPTIONS', headers: {} }, pre);
    expect(pre.statusCode).toBe(200);
  });

  it('rate limits by IP with 429', async () => {
    for (let i = 0; i < 10; i++) await submit(makeReq(payload, '9.9.9.9'), mockRes());
    const res = mockRes();
    await submit(makeReq(payload, '9.9.9.9'), res);
    expect(res.statusCode).toBe(429);
  });
});

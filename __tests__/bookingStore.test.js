// __tests__/bookingStore.test.js
// Booking backend store: token → user resolution reads the settings blob
// (the device WRITES the token via normal settings sync; the server only
// reads), and submissions INSERT rows shaped exactly like the sync engine's
// own pushes so pullRemote absorbs them unchanged.

process.env.SUPABASE_URL = 'https://unit.test';
process.env.SUPABASE_SERVICE_ROLE_KEY = 'service-role-test';

const { lookupUserByBookingToken, insertBookingRequest, newRequestId } = require('../backend/lib/booking/store');

describe('newRequestId', () => {
  it('builds bk<epoch>_<hex> from its inputs (pure, injectable)', () => {
    expect(newRequestId(1700000000000, 'a1b2c3')).toBe('bk1700000000000_a1b2c3');
  });
});

describe('lookupUserByBookingToken', () => {
  afterEach(() => { delete global.fetch; });

  it('queries settings by JSON-path token + enabled and returns the row', async () => {
    global.fetch = jest.fn().mockResolvedValue({
      ok: true,
      json: async () => [{ user_id: 'u1', data: { businessName: 'Rivera Plumbing' } }],
    });
    const row = await lookupUserByBookingToken('abc123');
    expect(row.user_id).toBe('u1');
    const url = global.fetch.mock.calls[0][0];
    expect(url).toContain('/rest/v1/settings');
    expect(url).toContain('data->bookingLink->>token=eq.abc123');
    expect(url).toContain('data->bookingLink->>enabled=eq.true');
    expect(url).toContain('select=user_id,data');
  });

  it('returns null when no row matches', async () => {
    global.fetch = jest.fn().mockResolvedValue({ ok: true, json: async () => [] });
    expect(await lookupUserByBookingToken('nope')).toBeNull();
  });

  it('throws on a non-ok response (caller maps to 500)', async () => {
    global.fetch = jest.fn().mockResolvedValue({ ok: false, status: 500, text: async () => 'boom' });
    await expect(lookupUserByBookingToken('abc')).rejects.toThrow('Supabase');
  });
});

describe('insertBookingRequest', () => {
  afterEach(() => { delete global.fetch; });

  it('POSTs the standard blob row shape to bookingRequests', async () => {
    global.fetch = jest.fn().mockResolvedValue({ ok: true });
    const request = { id: 'bk1_x', status: 'new', name: 'Dana' };
    await insertBookingRequest('u1', request);
    const [url, opts] = global.fetch.mock.calls[0];
    expect(url).toBe('https://unit.test/rest/v1/bookingRequests');
    const body = JSON.parse(opts.body);
    expect(body.id).toBe('bk1_x');
    expect(body.user_id).toBe('u1');
    expect(body.data).toEqual(request);
    expect(body.deleted).toBe(false);
    expect(typeof body.updated_at).toBe('string');
    expect(opts.headers.Authorization).toBe('Bearer service-role-test');
  });

  it('throws on a non-ok response', async () => {
    global.fetch = jest.fn().mockResolvedValue({ ok: false, status: 401, text: async () => 'denied' });
    await expect(insertBookingRequest('u1', { id: 'x' })).rejects.toThrow('Supabase');
  });
});

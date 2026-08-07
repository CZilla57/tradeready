// __tests__/portalLink.test.ts
// Phase 12D: managePortal is the owner-side wrapper for the server-owned
// token table (mint / set_enabled / rotate) — discriminated result, no
// Alerts, bearer-authed. The legacy stateless mint identity assertion stays
// while the export exists (removed in the Phase E sweep).

import { buildPortalUrl, mintPortalToken, managePortal, PORTAL_PUBLIC_BASE } from '../utils/portalLink';
import { mintBookingToken } from '../utils/bookingLink';
import { supabase } from '../utils/supabase';

jest.mock('../utils/supabase', () => ({
  supabase: { auth: { getSession: jest.fn() } },
}));

const TOKEN = 'e'.repeat(48);

describe('portalLink', () => {
  it('builds the portal URL with an encoded token', () => {
    expect(PORTAL_PUBLIC_BASE).toBe('https://gettradereadyapp.com/portal.html');
    expect(buildPortalUrl('abc123')).toBe('https://gettradereadyapp.com/portal.html?p=abc123');
    expect(buildPortalUrl('a&b')).toBe('https://gettradereadyapp.com/portal.html?p=a%26b');
  });

  it('mintPortalToken IS mintBookingToken (single mint wrapper, no fork)', () => {
    expect(mintPortalToken).toBe(mintBookingToken);
  });
});

describe('managePortal', () => {
  beforeEach(() => {
    (supabase.auth.getSession as jest.Mock).mockResolvedValue({
      data: { session: { access_token: 'jwt' } },
    });
  });
  afterEach(() => {
    delete (global as { fetch?: unknown }).fetch;
  });

  function mockFetch(body: object, status = 200) {
    const f = jest.fn(async () => ({ ok: status >= 200 && status < 300, status, json: async () => body }));
    (global as { fetch?: unknown }).fetch = f;
    return f;
  }

  it('POSTs the action with the bearer and returns the raw token', async () => {
    const f = mockFetch({ ok: true, token: TOKEN });
    const out = await managePortal('mint', 'c1');
    expect(out).toEqual({ ok: true, token: TOKEN, enabled: undefined });
    const [url, init] = f.mock.calls[0] as unknown as [string, { headers: Record<string, string>; body: string }];
    expect(String(url)).toContain('/api/estimate/portal-manage');
    expect(init.headers.Authorization).toBe('Bearer jwt');
    expect(JSON.parse(init.body)).toEqual({ action: 'mint', customerId: 'c1' });
  });

  it('set_enabled carries the boolean and echoes it back', async () => {
    const f = mockFetch({ ok: true, enabled: false });
    const out = await managePortal('set_enabled', 'c1', false);
    expect(out).toEqual({ ok: true, token: undefined, enabled: false });
    expect(JSON.parse((f.mock.calls[0] as unknown as [string, { body: string }])[1].body)).toEqual({
      action: 'set_enabled',
      customerId: 'c1',
      enabled: false,
    });
  });

  it('maps the 409 stale-paint guard to already-exists', async () => {
    mockFetch({ error: 'already_exists' }, 409);
    const out = await managePortal('mint', 'c1');
    expect(out).toMatchObject({ ok: false, reason: 'already-exists' });
  });

  it('no session → signed-out without a network call', async () => {
    (supabase.auth.getSession as jest.Mock).mockResolvedValue({ data: { session: null } });
    const f = mockFetch({});
    const out = await managePortal('rotate', 'c1');
    expect(out).toMatchObject({ ok: false, reason: 'signed-out' });
    expect(f).not.toHaveBeenCalled();
  });

  it('server error and thrown fetch map to server / network', async () => {
    mockFetch({ error: 'Database error' }, 500);
    expect(await managePortal('mint', 'c1')).toMatchObject({ ok: false, reason: 'server', message: 'Database error' });
    (global as { fetch?: unknown }).fetch = jest.fn(async () => { throw new Error('offline'); });
    expect(await managePortal('mint', 'c1')).toMatchObject({ ok: false, reason: 'network' });
  });
});

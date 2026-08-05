// __tests__/bookingLink.test.ts
// The app-side mint wrapper mirrors createApprovalLink's discriminated-result
// shape so the Settings screen decides how to surface each failure.

import { buildBookingUrl, mintBookingToken } from '../utils/bookingLink';
import { supabase } from '../utils/supabase';

jest.mock('../utils/supabase', () => ({
  supabase: { auth: { getSession: jest.fn() } },
}));
jest.mock('expo-constants', () => ({
  expoConfig: { extra: { backendUrl: 'https://backend.unit.test', eas: { projectId: 'proj' } } },
}));

const getSession = supabase.auth.getSession as jest.Mock;

afterEach(() => {
  jest.clearAllMocks();
  (global as { fetch?: unknown }).fetch = undefined;
});

describe('buildBookingUrl', () => {
  it('appends the token as ?b=', () => {
    expect(buildBookingUrl('abc123')).toBe('https://gettradereadyapp.com/book.html?b=abc123');
  });
});

describe('mintBookingToken', () => {
  it('returns signed-out without a session', async () => {
    getSession.mockResolvedValue({ data: { session: null } });
    const out = await mintBookingToken();
    expect(out).toMatchObject({ ok: false, reason: 'signed-out' });
  });

  it('POSTs to /api/booking/mint with the JWT and returns the token', async () => {
    getSession.mockResolvedValue({ data: { session: { access_token: 'jwt1', user: { id: 'u1' } } } });
    global.fetch = jest.fn().mockResolvedValue({ ok: true, json: async () => ({ token: 'a'.repeat(48) }) }) as never;
    const out = await mintBookingToken();
    expect(out).toEqual({ ok: true, token: 'a'.repeat(48) });
    const [url, opts] = (global.fetch as jest.Mock).mock.calls[0];
    expect(url).toBe('https://backend.unit.test/api/booking/mint');
    expect((opts.headers as Record<string, string>).Authorization).toBe('Bearer jwt1');
  });

  it('maps a server error body to reason "server"', async () => {
    getSession.mockResolvedValue({ data: { session: { access_token: 'jwt1', user: { id: 'u1' } } } });
    global.fetch = jest.fn().mockResolvedValue({ ok: false, json: async () => ({ error: 'nope' }) }) as never;
    const out = await mintBookingToken();
    expect(out).toMatchObject({ ok: false, reason: 'server', message: 'nope' });
  });

  it('maps a thrown fetch to reason "network"', async () => {
    getSession.mockResolvedValue({ data: { session: { access_token: 'jwt1', user: { id: 'u1' } } } });
    global.fetch = jest.fn().mockRejectedValue(new Error('offline')) as never;
    const out = await mintBookingToken();
    expect(out).toMatchObject({ ok: false, reason: 'network' });
  });
});

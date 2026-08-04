// __tests__/bookingNotify.test.js
// Booking alerts are fire-and-forget: an alert failure must never fail the
// submission (spec §5). Subject header is attacker-influenceable submission
// data — CR/LF stripped, length capped.

process.env.SUPABASE_URL = 'https://unit.test';
process.env.SUPABASE_SERVICE_ROLE_KEY = 'service-role-test';
process.env.RESEND_API_KEY = 'resend-test';

const { buildBookingEmail, notifyOwner } = require('../backend/lib/booking/notifyOwner');

const request = {
  id: 'bk1_x', status: 'new', name: 'Dana Rivers', phone: '555-0142',
  email: 'dana@example.com', address: '12 Elm St',
  details: 'Water heater is leaking', preferredTiming: 'Mornings',
  createdAt: '2026-08-04T15:00:00.000Z',
};

describe('buildBookingEmail', () => {
  it('builds a complete plain-text email from the verified domain', () => {
    const email = buildBookingEmail({ to: 'owner@example.com', request });
    expect(email.from).toBe('TradeReady <leads@gettradereadyapp.com>');
    expect(email.to).toBe('owner@example.com');
    expect(email.subject).toBe('New quote request from Dana Rivers');
    expect(email.text).toContain('Water heater is leaking');
    expect(email.text).toContain('555-0142');
    expect(email.text).toContain('dana@example.com');
    expect(email.text).toContain('12 Elm St');
    expect(email.text).toContain('Mornings');
    expect(email.text).toContain('Open TradeReady');
  });

  it('strips header-smuggling characters from the subject and caps length', () => {
    const evil = { ...request, name: 'A\r\nBcc: spam@x.com' + 'x'.repeat(200) };
    const email = buildBookingEmail({ to: 'o@x.com', request: evil });
    expect(email.subject).not.toMatch(/[\r\n]/);
    expect(email.subject.length).toBeLessThanOrEqual(120);
  });
});

describe('notifyOwner', () => {
  afterEach(() => { delete global.fetch; });

  it('sends email (admin lookup + Resend) and push when a pushToken exists', async () => {
    global.fetch = jest.fn()
      .mockResolvedValueOnce({ ok: true, json: async () => ({ email: 'owner@example.com' }) }) // admin user lookup
      .mockResolvedValueOnce({ ok: true, text: async () => '' })                                // resend
      .mockResolvedValueOnce({ ok: true, text: async () => '' });                               // expo push
    await notifyOwner({
      userId: 'u1',
      settingsData: { pushToken: { token: 'ExponentPushToken[abc]' } },
      request,
    });
    const urls = global.fetch.mock.calls.map((c) => c[0]);
    expect(urls[0]).toBe('https://unit.test/auth/v1/admin/users/u1');
    expect(urls[1]).toBe('https://api.resend.com/emails');
    expect(urls[2]).toBe('https://exp.host/--/api/v2/push/send');
    const push = JSON.parse(global.fetch.mock.calls[2][1].body);
    expect(push.to).toBe('ExponentPushToken[abc]');
    expect(push.title).toBe('New quote request');
    expect(push.data).toEqual({ type: 'booking_request' });
  });

  it('skips push when settings has no pushToken', async () => {
    global.fetch = jest.fn()
      .mockResolvedValueOnce({ ok: true, json: async () => ({ email: 'owner@example.com' }) })
      .mockResolvedValueOnce({ ok: true, text: async () => '' });
    await notifyOwner({ userId: 'u1', settingsData: {}, request });
    expect(global.fetch).toHaveBeenCalledTimes(2);
  });

  it('never throws — even when every call fails', async () => {
    global.fetch = jest.fn().mockRejectedValue(new Error('network down'));
    await expect(
      notifyOwner({ userId: 'u1', settingsData: { pushToken: { token: 'T' } }, request })
    ).resolves.toBeUndefined();
  });
});

// Worker notifyOwnerUpdate (backend-workers/lib/booking/notifyOwner.js):
// the owner email for a Phase 32 quote-update request names the estimate,
// and other update events keep their existing body.

const { notifyOwnerUpdate } = require('../backend-workers/lib/booking/notifyOwner');

const env = { SUPABASE_URL: 'https://sb.test', SUPABASE_SERVICE_ROLE_KEY: 'srk', RESEND_API_KEY: 're_test' };

function stubFetch() {
  const emails = [];
  global.fetch = jest.fn(async (url, init) => {
    if (String(url).includes('/auth/v1/admin/users/')) {
      return { ok: true, json: async () => ({ email: 'owner@example.com' }) };
    }
    if (url === 'https://api.resend.com/emails') {
      emails.push(JSON.parse(init.body));
      return { ok: true, text: async () => '' };
    }
    throw new Error(`unexpected fetch ${url}`);
  });
  return emails;
}

afterEach(() => {
  delete global.fetch;
});

test('quote_update email names the estimate from the request details', async () => {
  const emails = stubFetch();
  await notifyOwnerUpdate(env, {
    userId: 'u1',
    settingsData: {},
    event: 'quote_update',
    note: 'Still interested',
    request: {
      name: 'Dana Fox',
      jobRef: 'job-1',
      details: 'Updated estimate requested for "Water heater swap" (expired November 2, 2026) — Still interested',
    },
  });
  expect(emails).toHaveLength(1);
  expect(emails[0].subject).toBe('Updated estimate requested: Dana Fox');
  expect(emails[0].text).toBe([
    'Updated estimate requested — Dana Fox.',
    '',
    'Updated estimate requested for "Water heater swap" (expired November 2, 2026) — Still interested',
    '',
    'Open TradeReady to respond.',
  ].join('\n'));
});

test('other update events keep the note block', async () => {
  const emails = stubFetch();
  await notifyOwnerUpdate(env, {
    userId: 'u1',
    settingsData: {},
    event: 'cancelled',
    note: 'Out of town',
    request: { name: 'Dana Fox', details: 'Not shown for this event' },
  });
  expect(emails).toHaveLength(1);
  expect(emails[0].text).toContain('Their note:\nOut of town');
  expect(emails[0].text).not.toContain('Not shown for this event');
});

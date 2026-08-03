// Ownership check for the Stripe Connect webhook: a checkout.session.completed
// event may only settle an invoice when it fired on the connected account
// belonging to that invoice's owner. metadata.invoiceId is client-supplied at
// link-creation time, so without this check a payment into an attacker's own
// connected account could mark a victim's invoice paid.
//
// Two layers:
//   1. Unit tests of verifyConnectedAccountOwnership (fetchImpl injected).
//   2. Handler-level wiring tests through backend/api/stripe/webhook.js with a
//      real signature over the raw body and global fetch mocked — proving the
//      helper is actually consulted before the upsert.
//
// All ids are deliberately low-entropy fakes ("acct_fake_owner") — realistic
// secret shapes would trip the gitleaks history scan.

const crypto = require('crypto');

// The real `stripe` package lives in backend/node_modules, which CI never
// installs (the gate installs root deps only) — resolving it here is
// local-green/CI-red. Virtual mock with a faithful constructEvent: it
// verifies the same t=...,v1=HMAC-SHA256("<t>.<payload>") shape signPayload
// produces, so the handler's signature path stays genuinely exercised.
jest.mock(
  'stripe',
  () => {
    const mockCrypto = require('crypto');
    return jest.fn().mockImplementation(() => ({
      webhooks: {
        constructEvent(rawBody, sigHeader, secret) {
          const parts = Object.fromEntries(
            String(sigHeader || '').split(',').map((p) => p.split('='))
          );
          const payload = Buffer.isBuffer(rawBody) ? rawBody.toString('utf8') : String(rawBody);
          const expected = mockCrypto
            .createHmac('sha256', secret)
            .update(`${parts.t}.${payload}`)
            .digest('hex');
          if (!parts.v1 || parts.v1 !== expected) {
            throw new Error('Webhook signature verification failed (mock)');
          }
          return JSON.parse(payload);
        },
      },
    }));
  },
  { virtual: true }
);

const WEBHOOK_SECRET = 'fake_webhook_secret_a';
const SUPABASE_URL = 'https://supabase.fake.local';

// The webhook module reads env at require time — set fakes BEFORE requiring it.
const ENV = {
  STRIPE_SECRET_KEY: 'key_fake_a',
  STRIPE_CONNECT_WEBHOOK_SECRET: WEBHOOK_SECRET,
  SUPABASE_URL,
  SUPABASE_SERVICE_ROLE_KEY: 'service_role_fake_a',
};
const savedEnv = {};
for (const [k, v] of Object.entries(ENV)) {
  savedEnv[k] = process.env[k];
  process.env[k] = v;
}

const { verifyConnectedAccountOwnership } = require('../backend/lib/stripe/webhookOwnership');
const handler = require('../backend/api/stripe/webhook');

afterAll(() => {
  for (const k of Object.keys(ENV)) {
    if (savedEnv[k] === undefined) delete process.env[k];
    else process.env[k] = savedEnv[k];
  }
});

// ── Shared fixtures ───────────────────────────────────────────────────────────

const serviceHeaders = {
  Authorization: 'Bearer service_role_fake_a',
  apikey: 'service_role_fake_a',
};

function jsonResponse(rows) {
  return { ok: true, status: 200, json: async () => rows, text: async () => JSON.stringify(rows) };
}

// ── Layer 1: the decision helper itself ───────────────────────────────────────

describe('verifyConnectedAccountOwnership', () => {
  function stubFetch(rows) {
    return jest.fn(async () => jsonResponse(rows));
  }

  const baseArgs = {
    supabaseUrl: SUPABASE_URL,
    headers: serviceHeaders,
    userId: 'user_fake_a',
  };

  it('passes when the event account matches the owner stripe_accounts row', async () => {
    const fetchImpl = stubFetch([{ stripe_account_id: 'acct_fake_owner' }]);
    const out = await verifyConnectedAccountOwnership({
      ...baseArgs,
      eventAccount: 'acct_fake_owner',
      fetchImpl,
    });
    expect(out.ok).toBe(true);
    // Looks up the OWNER's row with the service-role headers, not the caller's.
    expect(fetchImpl).toHaveBeenCalledWith(
      `${SUPABASE_URL}/rest/v1/stripe_accounts?user_id=eq.user_fake_a&select=stripe_account_id`,
      { headers: serviceHeaders }
    );
  });

  it('fails closed when the event account belongs to someone else', async () => {
    const out = await verifyConnectedAccountOwnership({
      ...baseArgs,
      eventAccount: 'acct_fake_attacker',
      fetchImpl: stubFetch([{ stripe_account_id: 'acct_fake_owner' }]),
    });
    expect(out).toEqual({ ok: false, reason: 'account-mismatch', expectedAccountId: 'acct_fake_owner' });
  });

  it('fails closed when the owner has no stripe_accounts row', async () => {
    const out = await verifyConnectedAccountOwnership({
      ...baseArgs,
      eventAccount: 'acct_fake_attacker',
      fetchImpl: stubFetch([]),
    });
    expect(out).toEqual({ ok: false, reason: 'no-stripe-account', expectedAccountId: null });
  });

  it('fails closed when the event carries no connected account at all', async () => {
    const out = await verifyConnectedAccountOwnership({
      ...baseArgs,
      eventAccount: undefined,
      fetchImpl: stubFetch([{ stripe_account_id: 'acct_fake_owner' }]),
    });
    expect(out.ok).toBe(false);
    expect(out.reason).toBe('account-mismatch');
  });

  it('throws on a Supabase error so the webhook 500s and Stripe retries', async () => {
    const fetchImpl = jest.fn(async () => ({ ok: false, status: 503, text: async () => 'unavailable' }));
    await expect(
      verifyConnectedAccountOwnership({ ...baseArgs, eventAccount: 'acct_fake_owner', fetchImpl })
    ).rejects.toThrow('Supabase stripe_accounts fetch 503');
  });
});

// ── Layer 2: the helper is wired into the webhook handler ─────────────────────

describe('stripe webhook handler enforces ownership', () => {
  const savedFetch = global.fetch;
  let fetchCalls;
  let warnSpy;
  let logSpy;

  beforeEach(() => {
    fetchCalls = [];
    warnSpy = jest.spyOn(console, 'warn').mockImplementation(() => {});
    logSpy = jest.spyOn(console, 'log').mockImplementation(() => {});
  });

  afterEach(() => {
    global.fetch = savedFetch;
    warnSpy.mockRestore();
    logSpy.mockRestore();
  });

  // Routes the webhook's three Supabase calls: invoice fetch, stripe_accounts
  // fetch, invoice upsert. accountRows controls what the ownership lookup sees.
  function installFetchMock(accountRows) {
    global.fetch = jest.fn(async (url, opts = {}) => {
      fetchCalls.push({ url, opts });
      if (url.includes('/rest/v1/invoices?')) {
        return jsonResponse([{ user_id: 'user_fake_a', data: { amount: 50 } }]);
      }
      if (url.includes('/rest/v1/stripe_accounts?')) {
        return jsonResponse(accountRows);
      }
      if (opts.method === 'POST' && url.endsWith('/rest/v1/invoices')) {
        return { ok: true, status: 201, json: async () => ({}), text: async () => '' };
      }
      throw new Error(`unexpected fetch: ${url}`);
    });
  }

  function makeEventPayload(account) {
    return JSON.stringify({
      id: 'evt_fake_a',
      type: 'checkout.session.completed',
      account,
      data: {
        object: {
          id: 'cs_fake_a',
          payment_status: 'paid',
          amount_total: 5000,
          metadata: { invoiceId: 'inv_fake_a' },
        },
      },
    });
  }

  // Real signature over the raw payload — the handler's constructEvent must accept it.
  function signPayload(payload) {
    const t = Math.floor(Date.now() / 1000);
    const v1 = crypto.createHmac('sha256', WEBHOOK_SECRET).update(`${t}.${payload}`).digest('hex');
    return `t=${t},v1=${v1}`;
  }

  function makeReq(payload) {
    return {
      method: 'POST',
      headers: { 'stripe-signature': signPayload(payload) },
      async *[Symbol.asyncIterator]() {
        yield Buffer.from(payload);
      },
    };
  }

  function makeRes() {
    const res = { statusCode: 0, body: null };
    res.status = (code) => {
      res.statusCode = code;
      return res;
    };
    res.json = (body) => {
      res.body = body;
      return res;
    };
    return res;
  }

  function upsertCalls() {
    return fetchCalls.filter((c) => c.opts.method === 'POST');
  }

  it('records the payment when the event account is the invoice owner\'s', async () => {
    installFetchMock([{ stripe_account_id: 'acct_fake_owner' }]);
    const res = makeRes();

    await handler(makeReq(makeEventPayload('acct_fake_owner')), res);

    expect(res.statusCode).toBe(200);
    expect(res.body).toEqual({ received: true });
    const upserts = upsertCalls();
    expect(upserts).toHaveLength(1);
    const written = JSON.parse(upserts[0].opts.body);
    expect(written.user_id).toBe('user_fake_a');
    expect(written.data.payments).toEqual([
      expect.objectContaining({ id: 'stripe_cs_fake_a', amount: 50, method: 'stripe' }),
    ]);
    expect(written.data.paid).toBe(true);
  });

  it('skips with 200 (no write) when the event account is someone else\'s', async () => {
    installFetchMock([{ stripe_account_id: 'acct_fake_owner' }]);
    const res = makeRes();

    await handler(makeReq(makeEventPayload('acct_fake_attacker')), res);

    // 200, not 500 — a mismatch is not transient and Stripe must not retry it.
    expect(res.statusCode).toBe(200);
    expect(res.body).toEqual({ received: true, skipped: true });
    expect(upsertCalls()).toHaveLength(0);
    // The warning names both ids so the mismatch is traceable in Vercel logs.
    expect(warnSpy).toHaveBeenCalledWith(
      expect.stringContaining('acct_fake_attacker')
    );
    expect(warnSpy).toHaveBeenCalledWith(
      expect.stringContaining('acct_fake_owner')
    );
  });

  it('skips with 200 (no write) when the owner has no stripe_accounts row', async () => {
    installFetchMock([]);
    const res = makeRes();

    await handler(makeReq(makeEventPayload('acct_fake_attacker')), res);

    expect(res.statusCode).toBe(200);
    expect(res.body).toEqual({ received: true, skipped: true });
    expect(upsertCalls()).toHaveLength(0);
    expect(warnSpy).toHaveBeenCalled();
  });
});

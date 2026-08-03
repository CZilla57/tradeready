// Hardening tests for the RevenueCat subscription webhook
// (backend/api/subscription/webhook.js):
//   - app_user_id must be a UUID that exists in Supabase auth before the
//     service-role upsert runs (poisoning-vector fix)
//   - bearer secret compared constant-time (shared backend/lib/constantTime.js)
//   - malformed expiration_at_ms / product_id must not crash the handler
//     outside its try block (RC would retry a permanently-bad event forever)
//
// The handler is a plain (req, res) function — tested directly with stub
// req/res objects and a mocked global.fetch. The module captures env vars at
// load time, so each test sets env first, then requires a fresh copy via
// jest.resetModules(). All ids/secrets are deliberately low-entropy fakes.

const VALID_UUID = '11111111-2222-3333-4444-555555555555';
const FAKE_SECRET = 'not-a-real-secret';

const ENV_KEYS = ['SUPABASE_URL', 'SUPABASE_SERVICE_ROLE_KEY', 'REVENUECAT_WEBHOOK_SECRET'];
const savedEnv = {};
let savedFetch;

beforeAll(() => {
  ENV_KEYS.forEach((k) => { savedEnv[k] = process.env[k]; });
  savedFetch = global.fetch;
});

afterAll(() => {
  ENV_KEYS.forEach((k) => {
    if (savedEnv[k] === undefined) delete process.env[k];
    else process.env[k] = savedEnv[k];
  });
  global.fetch = savedFetch;
});

beforeEach(() => {
  jest.resetModules();
  process.env.SUPABASE_URL = 'https://fake-supabase.example';
  process.env.SUPABASE_SERVICE_ROLE_KEY = 'not-a-real-service-key';
  process.env.REVENUECAT_WEBHOOK_SECRET = FAKE_SECRET;
  // Silence the handler's expected warn/error logging.
  jest.spyOn(console, 'warn').mockImplementation(() => {});
  jest.spyOn(console, 'error').mockImplementation(() => {});
});

afterEach(() => {
  jest.restoreAllMocks();
});

function loadHandler() {
  return require('../backend/api/subscription/webhook');
}

function fetchResponse(status) {
  return {
    ok: status >= 200 && status < 300,
    status,
    text: async () => '{}',
    json: async () => ({}),
  };
}

// Routes the two backend calls the handler can make: the auth admin existence
// GET and the subscriptions upsert POST.
function installFetch({ adminStatus = 200, upsertStatus = 201 } = {}) {
  const mock = jest.fn(async (url) => {
    const u = String(url);
    if (u.includes('/auth/v1/admin/users/')) return fetchResponse(adminStatus);
    if (u.includes('/rest/v1/subscriptions')) return fetchResponse(upsertStatus);
    throw new Error(`Unexpected fetch: ${u}`);
  });
  global.fetch = mock;
  return mock;
}

function upsertCalls(mock) {
  return mock.mock.calls.filter(([url]) => String(url).includes('/rest/v1/subscriptions'));
}

// Pass authorization: null to omit the header entirely.
function makeReq(eventOverrides = {}, { authorization = `Bearer ${FAKE_SECRET}` } = {}) {
  const headers = {};
  if (authorization !== null) headers.authorization = authorization;
  return {
    method: 'POST',
    headers,
    body: {
      event: {
        type: 'INITIAL_PURCHASE',
        app_user_id: VALID_UUID,
        ...eventOverrides,
      },
    },
  };
}

function makeRes() {
  return {
    statusCode: null,
    body: null,
    status(code) { this.statusCode = code; return this; },
    json(payload) { this.body = payload; return this; },
  };
}

describe('subscription webhook hardening', () => {
  test('valid event with existing auth user upserts under that user_id', async () => {
    const mock = installFetch();
    const res = makeRes();
    await loadHandler()(makeReq({ product_id: 'tradeready_annual_2026', expiration_at_ms: 1754000000000 }), res);

    expect(res.statusCode).toBe(200);
    expect(res.body).toEqual({ received: true });

    // Existence check hit the auth admin endpoint for that exact UUID.
    const adminCall = mock.mock.calls.find(([url]) => String(url).includes('/auth/v1/admin/users/'));
    expect(adminCall[0]).toBe(`https://fake-supabase.example/auth/v1/admin/users/${VALID_UUID}`);

    const upserts = upsertCalls(mock);
    expect(upserts).toHaveLength(1);
    const payload = JSON.parse(upserts[0][1].body);
    expect(payload.user_id).toBe(VALID_UUID);
    expect(payload.plan).toBe('annual');
    expect(payload.expires_at).toBe(new Date(1754000000000).toISOString());
  });

  test('non-UUID app_user_id → 200 skipped, no Supabase calls at all', async () => {
    const mock = installFetch();
    const res = makeRes();
    await loadHandler()(makeReq({ app_user_id: 'attacker-chosen-alias' }), res);

    expect(res.statusCode).toBe(200);
    expect(res.body).toEqual({ received: true, skipped: true });
    expect(mock).not.toHaveBeenCalled();
  });

  test('non-string app_user_id → 200 skipped, no throw', async () => {
    const mock = installFetch();
    const res = makeRes();
    await loadHandler()(makeReq({ app_user_id: 12345 }), res);

    expect(res.statusCode).toBe(200);
    expect(res.body).toEqual({ received: true, skipped: true });
    expect(mock).not.toHaveBeenCalled();
  });

  test('UUID not in auth.users (admin 404) → 200 skipped, no upsert', async () => {
    const mock = installFetch({ adminStatus: 404 });
    const res = makeRes();
    await loadHandler()(makeReq(), res);

    expect(res.statusCode).toBe(200);
    expect(res.body).toEqual({ received: true, skipped: true });
    expect(upsertCalls(mock)).toHaveLength(0);
  });

  test('admin lookup transient failure (500) → 500 so RC retries', async () => {
    const mock = installFetch({ adminStatus: 500 });
    const res = makeRes();
    await loadHandler()(makeReq(), res);

    expect(res.statusCode).toBe(500);
    expect(upsertCalls(mock)).toHaveLength(0);
  });

  test('admin lookup network error (fetch rejects) → 500 so RC retries', async () => {
    global.fetch = jest.fn(async () => { throw new Error('socket hang up'); });
    const res = makeRes();
    await loadHandler()(makeReq(), res);

    expect(res.statusCode).toBe(500);
  });

  test('garbage expiration_at_ms values → no throw, expires_at null', async () => {
    for (const garbage of ['banana', 1e20, {}, [1, 2], '12,000']) {
      const mock = installFetch();
      const res = makeRes();
      await loadHandler()(makeReq({ expiration_at_ms: garbage }), res);

      expect(res.statusCode).toBe(200);
      const payload = JSON.parse(upsertCalls(mock)[0][1].body);
      expect(payload.expires_at).toBeNull();
    }
  });

  test('numeric expiration_at_ms as a string still parses', async () => {
    const mock = installFetch();
    const res = makeRes();
    await loadHandler()(makeReq({ expiration_at_ms: '1754000000000' }), res);

    expect(res.statusCode).toBe(200);
    const payload = JSON.parse(upsertCalls(mock)[0][1].body);
    expect(payload.expires_at).toBe(new Date(1754000000000).toISOString());
  });

  test('numeric product_id → no throw, coerced to string, plan null', async () => {
    const mock = installFetch();
    const res = makeRes();
    await loadHandler()(makeReq({ product_id: 12345 }), res);

    expect(res.statusCode).toBe(200);
    const payload = JSON.parse(upsertCalls(mock)[0][1].body);
    expect(payload.product_identifier).toBe('12345');
    expect(payload.plan).toBeNull();
  });

  test('wrong bearer secret → 401, nothing fetched', async () => {
    const mock = installFetch();
    const res = makeRes();
    await loadHandler()(makeReq({}, { authorization: 'Bearer not-the-right-fake' }), res);

    expect(res.statusCode).toBe(401);
    expect(mock).not.toHaveBeenCalled();
  });

  test('missing authorization header → 401 (constantTimeEqual rejects non-strings)', async () => {
    const mock = installFetch();
    const res = makeRes();
    await loadHandler()(makeReq({}, { authorization: null }), res);

    expect(res.statusCode).toBe(401);
    expect(mock).not.toHaveBeenCalled();
  });

  test('unset REVENUECAT_WEBHOOK_SECRET → 500 Webhook not configured', async () => {
    delete process.env.REVENUECAT_WEBHOOK_SECRET;
    const mock = installFetch();
    const res = makeRes();
    await loadHandler()(makeReq(), res);

    expect(res.statusCode).toBe(500);
    expect(res.body).toEqual({ error: 'Webhook not configured' });
    expect(mock).not.toHaveBeenCalled();
  });
});

describe('shared constantTimeEqual module', () => {
  test('estimateStore re-exports the shared implementation unchanged', () => {
    const { constantTimeEqual } = require('../backend/lib/constantTime');
    const store = require('../backend/lib/estimateStore');
    expect(store.constantTimeEqual).toBe(constantTimeEqual);
  });

  test('compares correctly and rejects non-strings/empties', () => {
    const { constantTimeEqual } = require('../backend/lib/constantTime');
    expect(constantTimeEqual('abc', 'abc')).toBe(true);
    expect(constantTimeEqual('abc', 'abd')).toBe(false);
    expect(constantTimeEqual('abc', 'ab')).toBe(false);
    expect(constantTimeEqual(undefined, 'abc')).toBe(false);
    expect(constantTimeEqual('', '')).toBe(false);
  });
});

// Referral program (Roadmap Phase 34) — Worker side.
// Spec: docs/superpowers/specs/2026-10-03-referral-program-design.md §3, §6, §10.
// The code vectors are the shared parity fixture the Swift ReferralTests
// suite also loads; every vector (including jsOnly ones) runs here. The
// route tests drive the real POST /api/booking/submit handler with a fake
// Hono context and a URL-dispatching fetch mock.

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { before, afterEach, describe, test } = require('node:test');

const {
  validateBookingPayload,
  cleanReferralCode,
  REFERRAL_CODE_RE,
} = require('../lib/booking/validate.js');

const FIXTURE_PATH = path.join(__dirname, '../../native/ReferralTests/Fixtures/referral-code-vectors.json');
const fixture = JSON.parse(fs.readFileSync(FIXTURE_PATH, 'utf8'));

// Reference encoder for the device's NativeReferrals.encodeCode: exactly
// 10 bytes → 80 bits → 16 five-bit groups, most significant first.
function referenceEncode(bytes) {
  if (bytes.length !== fixture.codeByteCount) return null;
  let bits = 0n;
  for (const b of bytes) bits = (bits << 8n) | BigInt(b);
  let out = '';
  for (let i = fixture.codeLength - 1; i >= 0; i -= 1) {
    out += fixture.alphabet[Number((bits >> BigInt(i * 5)) & 31n)];
  }
  return out;
}

function hexBytes(hex) {
  const out = [];
  for (let i = 0; i < hex.length; i += 2) out.push(parseInt(hex.slice(i, i + 2), 16));
  return out;
}

const good = {
  name: 'Dana Rivers', phone: '555-0142', email: 'dana@example.com',
  address: '12 Elm St', details: 'Water heater is leaking', preferredTiming: 'Mornings',
};

describe('shared referral-code fixture', () => {
  test('the fixture pins the Worker pattern, alphabet and sizes', () => {
    assert.equal(fixture.pattern, REFERRAL_CODE_RE.source);
    assert.equal(fixture.alphabet.length, 32);
    assert.equal(new Set(fixture.alphabet).size, 32);
    assert.equal(fixture.codeLength, 16);
    assert.equal(fixture.codeByteCount, 10);
    assert.ok(fixture.normalize.some((v) => v.jsOnly));
  });

  test('the alphabet is exactly the characters the Worker accepts', () => {
    for (let cp = 0x20; cp <= 0x7e; cp += 1) {
      const ch = String.fromCharCode(cp);
      const lower = ch.toLowerCase();
      const accepted = cleanReferralCode(ch.repeat(16)) !== '';
      assert.equal(accepted, fixture.alphabet.includes(lower), `character ${JSON.stringify(ch)}`);
    }
  });

  for (const vector of fixture.encode) {
    test(`encode: ${vector.name}`, () => {
      const code = referenceEncode(hexBytes(vector.bytesHex));
      assert.equal(code, vector.expect);
      // A code the device generates always survives the Worker unchanged.
      if (code !== null) assert.equal(cleanReferralCode(code), code);
    });
  }

  for (const vector of fixture.normalize) {
    test(`${vector.jsOnly ? '[jsOnly] ' : ''}normalize: ${vector.name}`, () => {
      const expected = vector.expect === null ? '' : vector.expect;
      assert.equal(cleanReferralCode(vector.input), expected);

      const out = validateBookingPayload({ ...good, referralCode: vector.input });
      assert.equal(out.ok, true, 'a referral code never fails a booking');
      if (vector.expect === null) {
        assert.equal('referralCode' in out.value, false);
      } else {
        assert.equal(out.value.referralCode, vector.expect);
      }
    });
  }
});

describe('validateBookingPayload referralCode', () => {
  test('absent → no key, and the rest of the value is unchanged', () => {
    const without = validateBookingPayload(good);
    const withCode = validateBookingPayload({ ...good, referralCode: '0123456789ABCDEF' });
    assert.equal('referralCode' in without.value, false);
    const { referralCode, ...rest } = withCode.value;
    assert.equal(referralCode, '0123456789abcdef');
    assert.deepEqual(rest, without.value);
  });

  test('coexists with leadSource', () => {
    const out = validateBookingPayload({ ...good, leadSource: 'nextdoor', referralCode: 'vtpvxvr024h36h2n' });
    assert.equal(out.value.leadSource, 'nextdoor');
    assert.equal(out.value.referralCode, 'vtpvxvr024h36h2n');
  });

  test('never masks an existing-field error', () => {
    const out = validateBookingPayload({ ...good, name: '', referralCode: '0123456789abcdef' });
    assert.equal(out.ok, false);
    assert.match(out.error, /your name/i);
  });

  test('only the referralCode key is read (no r alias)', () => {
    const out = validateBookingPayload({ ...good, r: '0123456789abcdef', ref: '0123456789abcdef' });
    assert.equal('referralCode' in out.value, false);
    assert.equal('r' in out.value, false);
  });
});

// ── POST /api/booking/submit, end to end ──────────────────────────────────

let bookingSubmitHandler;
before(async () => {
  ({ bookingSubmitHandler } = await import('../src/routes/booking/submit.js'));
});

const realFetch = global.fetch;
const realConsole = { log: console.log, warn: console.warn, error: console.error };
afterEach(() => {
  global.fetch = realFetch;
  Object.assign(console, realConsole);
});

const BOOKING_TOKEN = 'b'.repeat(48);

function jsonRes(body, status = 200) {
  return {
    ok: status >= 200 && status < 300,
    status,
    json: async () => body,
    text: async () => JSON.stringify(body),
  };
}

function installBackend({ settingsRows = [{ user_id: 'u1', data: { businessName: 'Rivera Plumbing', pushToken: { token: 'ExponentPushToken[x]' } } }] } = {}) {
  const calls = { requestPosts: [], emails: [], pushes: [], logs: [] };
  global.fetch = async (url, init = {}) => {
    const u = String(url);
    const method = init.method || 'GET';
    if (u.includes('/rest/v1/booking_link_state')) return jsonRes({ message: 'relation does not exist' }, 404);
    if (u.includes('/rest/v1/settings')) return jsonRes(settingsRows);
    if (u.includes('/rest/v1/bookingRequests') && method === 'POST') {
      calls.requestPosts.push(JSON.parse(init.body));
      return jsonRes({}, 201);
    }
    if (u.includes('/auth/v1/admin/users')) return jsonRes({ email: 'owner@example.com' });
    if (u.includes('api.resend.com')) {
      calls.emails.push(JSON.parse(init.body));
      return jsonRes({ id: 'em_1' });
    }
    if (u.includes('exp.host')) {
      calls.pushes.push(JSON.parse(init.body));
      return jsonRes({});
    }
    return jsonRes([]);
  };
  for (const level of ['log', 'warn', 'error']) {
    console[level] = (...args) => calls.logs.push(args.map(String).join(' '));
  }
  return calls;
}

let ipCounter = 0;
function fakeC(body) {
  ipCounter += 1;
  const headers = { 'cf-connecting-ip': `203.0.113.${ipCounter}`, origin: 'https://gettradereadyapp.com' };
  const responseHeaders = {};
  return {
    env: { SUPABASE_URL: 'https://supa.test', SUPABASE_SERVICE_ROLE_KEY: 'srk', RESEND_API_KEY: 'resend-test' },
    responseHeaders,
    header: (k, v) => { responseHeaders[k] = v; },
    req: {
      method: 'POST',
      header: (k) => headers[String(k).toLowerCase()],
      json: async () => body,
    },
    json: (b, s) => ({ status: s, body: b }),
    body: (b, s) => ({ status: s, body: b }),
  };
}

const submitBody = (over = {}) => ({ b: BOOKING_TOKEN, ...good, ...over });
const REFERRAL_LINE = "Came in through a customer's referral link — open TradeReady to see who referred them.";

describe('POST /api/booking/submit with a referral code', () => {
  test('a valid code lands lowercased on the stored request', async () => {
    const calls = installBackend();
    const res = await bookingSubmitHandler(fakeC(submitBody({ referralCode: ' VTPVXVR024H36H2N ' })));
    assert.equal(res.status, 200);
    assert.deepEqual(res.body, { ok: true });
    assert.equal(calls.requestPosts.length, 1);
    assert.equal(calls.requestPosts[0].data.referralCode, 'vtpvxvr024h36h2n');
    assert.equal(calls.requestPosts[0].data.status, 'new');
    assert.equal(calls.requestPosts[0].data.name, 'Dana Rivers');
  });

  test('garbage leaves no key and never fails the booking', async () => {
    for (const bad of ['0123456789abcdeu', 'x'.repeat(5000), '<script>alert(1)</script>', 42, { $ne: '' }, ['0123456789abcdef'], null]) {
      const calls = installBackend();
      const res = await bookingSubmitHandler(fakeC(submitBody({ referralCode: bad })));
      assert.equal(res.status, 200);
      assert.deepEqual(res.body, { ok: true });
      assert.equal(calls.requestPosts.length, 1);
      assert.equal('referralCode' in calls.requestPosts[0].data, false);
    }
  });

  test('valid, unknown, malformed and absent codes get byte-identical responses (no oracle)', async () => {
    const bodies = [
      submitBody({ referralCode: '0123456789abcdef' }),
      submitBody({ referralCode: 'zzzzzzzzzzzzzzzz' }),
      submitBody({ referralCode: 'not-a-code' }),
      submitBody(),
    ];
    const seen = [];
    for (const body of bodies) {
      installBackend();
      const c = fakeC(body);
      const res = await bookingSubmitHandler(c);
      seen.push(JSON.stringify({ status: res.status, body: res.body, headers: c.responseHeaders }));
    }
    assert.equal(new Set(seen).size, 1);
  });

  test('an invalid token answers the same 404 with or without a code', async () => {
    const outs = [];
    for (const over of [{ referralCode: '0123456789abcdef' }, {}]) {
      installBackend({ settingsRows: [] });
      const res = await bookingSubmitHandler(fakeC(submitBody(over)));
      outs.push(JSON.stringify(res));
    }
    assert.equal(outs[0], outs[1]);
    assert.equal(JSON.parse(outs[0]).status, 404);
  });

  test('the owner email gains the referral line; the push and logs never carry the code', async () => {
    const code = 'vtpvxvr024h36h2n';
    const calls = installBackend();
    await bookingSubmitHandler(fakeC(submitBody({ referralCode: code })));
    assert.equal(calls.emails.length, 1);
    assert.ok(calls.emails[0].text.includes(REFERRAL_LINE));
    assert.ok(!JSON.stringify(calls.emails[0]).includes(code));
    assert.equal(calls.pushes.length, 1);
    assert.ok(!JSON.stringify(calls.pushes[0]).includes(code));
    assert.ok(!calls.logs.some((line) => line.includes(code)));

    const plain = installBackend();
    await bookingSubmitHandler(fakeC(submitBody()));
    assert.ok(!plain.emails[0].text.includes(REFERRAL_LINE));
    assert.deepEqual(plain.pushes[0], calls.pushes[0]);
  });

  test('the honeypot still wins: a fake success and nothing stored', async () => {
    const calls = installBackend();
    const res = await bookingSubmitHandler(fakeC(submitBody({ referralCode: '0123456789abcdef', website: 'spam.biz' })));
    assert.deepEqual(res, { status: 200, body: { ok: true } });
    assert.equal(calls.requestPosts.length, 0);
  });
});

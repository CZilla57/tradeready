// Past-customer campaigns (Roadmap Phase 33): the Worker side.
// Spec: docs/superpowers/specs/2026-10-03-campaigns-tags-design.md §9.1, §16.
// The device generates codes with NativeAttributionCode; this file checks that
// every code it can produce survives the Worker unchanged, and that the
// Worker's alphabet is the device's. The route tests drive the real
// POST /api/booking/submit handler with a fake Hono context and a
// URL-dispatching fetch mock. No network.

const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');
const { before, afterEach, describe, test } = require('node:test');

const {
  validateBookingPayload,
  cleanCampaignCode,
  CAMPAIGN_CODE_RE,
} = require('../lib/booking/validate.js');

const SWIFT_PATH = path.join(__dirname, '../../native/TradeReadyNative/Domain/NativeAttributionCode.swift');
const swiftSource = fs.readFileSync(SWIFT_PATH, 'utf8');
const ALPHABET = (swiftSource.match(/static let alphabet = Array\("([0-9a-z]+)"\)/) || [])[1];
const LENGTH = Number((swiftSource.match(/static let length = (\d+)/) || [])[1]);

// JS port of NativeAttributionCode.makeCode(randomBytes:): 10 bytes, most
// significant bit first, 5 bits per character, zero-padded to 16.
function referenceEncode(bytes) {
  let bits = 0;
  let bitCount = 0;
  let out = '';
  for (const byte of bytes) {
    bits = (bits << 8) | byte;
    bitCount += 8;
    while (bitCount >= 5 && out.length < LENGTH) {
      bitCount -= 5;
      out += ALPHABET[(bits >> bitCount) & 0x1f];
    }
    bits &= (1 << bitCount) - 1;
  }
  while (out.length < LENGTH) out += ALPHABET[0];
  return out;
}

const good = {
  name: 'Dana Rivers', phone: '555-0142', email: 'dana@example.com',
  address: '12 Elm St', details: 'Water heater is leaking', preferredTiming: 'Mornings',
};

describe('campaign code format matches the device', () => {
  test('the Swift encoder source is where this test expects it', () => {
    assert.equal(ALPHABET, '0123456789abcdefghjkmnpqrstvwxyz');
    assert.equal(LENGTH, 16);
  });

  test('the Worker pattern is the device alphabet at the device length', () => {
    assert.equal(CAMPAIGN_CODE_RE.source, `^[0-9a-hjkmnp-tv-z]{${LENGTH}}$`);
    assert.ok(CAMPAIGN_CODE_RE.test(ALPHABET.slice(0, 16)));
    assert.ok(CAMPAIGN_CODE_RE.test(ALPHABET.slice(16)));
  });

  test('the alphabet is exactly the printable ASCII characters the Worker accepts', () => {
    for (let cp = 0x20; cp <= 0x7e; cp += 1) {
      const ch = String.fromCharCode(cp);
      const accepted = cleanCampaignCode(ch.repeat(16)) !== '';
      assert.equal(accepted, ALPHABET.includes(ch.toLowerCase()), `character ${JSON.stringify(ch)}`);
    }
  });

  test('fixed byte vectors encode as the device would and pass unchanged', () => {
    const vectors = [
      [Array(10).fill(0x00), '0000000000000000'],
      [Array(10).fill(0xff), 'zzzzzzzzzzzzzzzz'],
      [[0x00, 0x44, 0x32, 0x14, 0xc7, 0x42, 0x54, 0xb6, 0x35, 0xcf], '0123456789abcdef'],
    ];
    for (const [bytes, expected] of vectors) {
      const code = referenceEncode(bytes);
      assert.equal(code, expected);
      assert.equal(cleanCampaignCode(code), code);
      assert.equal(cleanCampaignCode(code.toUpperCase()), code);
    }
  });

  test('every code from 2000 random draws survives the Worker unchanged', () => {
    for (let i = 0; i < 2000; i += 1) {
      const code = referenceEncode([...crypto.randomBytes(10)]);
      assert.equal(code.length, 16);
      assert.equal(cleanCampaignCode(code), code);
    }
  });

  test('a Kelvin sign is dropped, not mapped to k', () => {
    const kelvin = 'K123456789abcdef';
    assert.equal(kelvin.toLowerCase(), 'k123456789abcdef');
    assert.equal(cleanCampaignCode(kelvin), '');
    assert.equal(cleanCampaignCode('k123456789abcdef'), 'k123456789abcdef');
  });
});

describe('validateBookingPayload campaignCode', () => {
  test('absent → no key, and the rest of the value is unchanged', () => {
    const without = validateBookingPayload(good);
    const withCode = validateBookingPayload({ ...good, campaignCode: '0123456789ABCDEF' });
    assert.equal('campaignCode' in without.value, false);
    const { campaignCode, ...rest } = withCode.value;
    assert.equal(campaignCode, '0123456789abcdef');
    assert.deepEqual(rest, without.value);
  });

  test('coexists with leadSource', () => {
    const out = validateBookingPayload({ ...good, leadSource: 'nextdoor', campaignCode: 'vtpvxvr024h36h2n' });
    assert.equal(out.value.leadSource, 'nextdoor');
    assert.equal(out.value.campaignCode, 'vtpvxvr024h36h2n');
  });

  test('never masks an existing-field error', () => {
    const out = validateBookingPayload({ ...good, name: '', campaignCode: '0123456789abcdef' });
    assert.equal(out.ok, false);
    assert.match(out.error, /your name/i);
  });

  test('only the campaignCode key is read (no c alias)', () => {
    const out = validateBookingPayload({ ...good, c: '0123456789abcdef', campaign: '0123456789abcdef' });
    assert.equal('campaignCode' in out.value, false);
    assert.equal('c' in out.value, false);
    assert.equal('campaign' in out.value, false);
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
const CAMPAIGN_LINE = 'Came in through one of your campaign links. Open TradeReady to see which one.';

describe('POST /api/booking/submit with a campaign code', () => {
  test('a valid code lands lowercased on the stored request', async () => {
    const calls = installBackend();
    const res = await bookingSubmitHandler(fakeC(submitBody({ campaignCode: ' VTPVXVR024H36H2N ' })));
    assert.equal(res.status, 200);
    assert.deepEqual(res.body, { ok: true });
    assert.equal(calls.requestPosts.length, 1);
    assert.equal(calls.requestPosts[0].data.campaignCode, 'vtpvxvr024h36h2n');
    assert.equal(calls.requestPosts[0].data.status, 'new');
    assert.equal(calls.requestPosts[0].data.name, 'Dana Rivers');
  });

  test('garbage leaves no key and never fails the booking', async () => {
    for (const bad of ['0123456789abcdeu', 'K123456789abcdef', 'x'.repeat(5000), '<script>alert(1)</script>', 42, { $ne: '' }, ['0123456789abcdef'], null]) {
      const calls = installBackend();
      const res = await bookingSubmitHandler(fakeC(submitBody({ campaignCode: bad })));
      assert.equal(res.status, 200);
      assert.deepEqual(res.body, { ok: true });
      assert.equal(calls.requestPosts.length, 1);
      assert.equal('campaignCode' in calls.requestPosts[0].data, false);
    }
  });

  test('valid, unknown, malformed and absent codes get byte-identical responses (no oracle)', async () => {
    const bodies = [
      submitBody({ campaignCode: '0123456789abcdef' }),
      submitBody({ campaignCode: 'zzzzzzzzzzzzzzzz' }),
      submitBody({ campaignCode: 'not-a-code' }),
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
    for (const over of [{ campaignCode: '0123456789abcdef' }, {}]) {
      installBackend({ settingsRows: [] });
      const res = await bookingSubmitHandler(fakeC(submitBody(over)));
      outs.push(JSON.stringify(res));
    }
    assert.equal(outs[0], outs[1]);
    assert.equal(JSON.parse(outs[0]).status, 404);
  });

  test('a field error answers the same 400 with or without a code', async () => {
    const outs = [];
    for (const over of [{ campaignCode: '0123456789abcdef' }, { campaignCode: 'nope' }, {}]) {
      installBackend();
      const res = await bookingSubmitHandler(fakeC(submitBody({ ...over, details: '' })));
      outs.push(JSON.stringify(res));
    }
    assert.equal(new Set(outs).size, 1);
    assert.equal(JSON.parse(outs[0]).status, 400);
  });

  test('the owner email gains the campaign line; the push and logs never carry the code', async () => {
    const code = 'vtpvxvr024h36h2n';
    const calls = installBackend();
    await bookingSubmitHandler(fakeC(submitBody({ campaignCode: code })));
    assert.equal(calls.emails.length, 1);
    const lines = calls.emails[0].text.split('\n');
    assert.equal(lines[lines.length - 2], CAMPAIGN_LINE);
    assert.equal(lines[lines.length - 1], 'Open TradeReady to see the new lead in Jobs.');
    assert.ok(!JSON.stringify(calls.emails[0]).includes(code));
    assert.equal(calls.pushes.length, 1);
    assert.ok(!JSON.stringify(calls.pushes[0]).includes(code));
    assert.ok(!calls.logs.some((line) => line.includes(code)));

    const plain = installBackend();
    await bookingSubmitHandler(fakeC(submitBody()));
    assert.ok(!plain.emails[0].text.includes(CAMPAIGN_LINE));
    assert.deepEqual(plain.pushes[0], calls.pushes[0]);
  });

  test('the honeypot still wins: a fake success and nothing stored', async () => {
    const calls = installBackend();
    const res = await bookingSubmitHandler(fakeC(submitBody({ campaignCode: '0123456789abcdef', website: 'spam.biz' })));
    assert.deepEqual(res, { status: 200, body: { ok: true } });
    assert.equal(calls.requestPosts.length, 0);
    assert.equal(calls.emails.length, 0);
  });
});

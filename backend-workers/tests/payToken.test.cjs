// Signed pay-page tokens (Phase 24 spec §4.2): round trip, tamper, kind
// confusion, setup expiry, constant-time compare, public base derivation.

const assert = require('node:assert/strict');
const { describe, test } = require('node:test');
const crypto = require('node:crypto');
const t = require('../lib/pay/payToken.js');

const SECRET = 's'.repeat(40);
const USER = '11111111-2222-4333-8444-555555555555';
const ENROLLMENT = '6f1c2a4e-1d2b-4c3d-8e9f-0a1b2c3d4e5f';

describe('pay tokens', () => {
  test('p round trip, with and without a requested amount', () => {
    const tok = t.mintInvoicePayToken(SECRET, { userId: USER, invoiceId: 'inv1700000000000', cents: 12050 });
    assert.match(tok, /^p\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$/);
    assert.deepEqual(t.verifyPayToken(SECRET, tok, { expectKind: 'p' }), { ok: true, kind: 'p', payload: { v: 1, u: USER, i: 'inv1700000000000', a: 12050 } });
    const full = t.mintInvoicePayToken(SECRET, { userId: USER, invoiceId: 'inv1' });
    assert.deepEqual(t.verifyPayToken(SECRET, full).payload, { v: 1, u: USER, i: 'inv1' });
  });

  test('tokenCharge: min(requested, live), and a partial ask goes stale once the balance drops', () => {
    assert.deepEqual(t.tokenCharge({ v: 1 }, 12000), { cents: 12000, depositCents: null });
    assert.deepEqual(t.tokenCharge({ a: 15000 }, 12000), { cents: 12000, depositCents: null });
    assert.deepEqual(t.tokenCharge({ a: 6000, b: 12000 }, 12000), { cents: 6000, depositCents: 6000 });
    assert.deepEqual(t.tokenCharge({ a: 6000, b: 12000 }, 15000), { cents: 6000, depositCents: 6000 }, 'balance went UP: still a deposit');
    assert.deepEqual(t.tokenCharge({ a: 6000, b: 12000 }, 6000), { cents: 6000, depositCents: null });
    assert.deepEqual(t.tokenCharge({ a: 6000, b: 12000 }, 9000), { cents: 9000, depositCents: null });
    assert.deepEqual(t.tokenCharge({ a: 6000 }, 9000), { cents: 6000, depositCents: 6000 }, 'no b (unsynced at mint): plain min');
    const tok = t.mintInvoicePayToken(SECRET, { userId: USER, invoiceId: 'inv1', cents: 6000, balanceCents: 12000 });
    assert.deepEqual(t.verifyPayToken(SECRET, tok).payload, { v: 1, u: USER, i: 'inv1', a: 6000, b: 12000 });
    const full = t.mintInvoicePayToken(SECRET, { userId: USER, invoiceId: 'inv1', cents: 12000, balanceCents: 12000 });
    assert.deepEqual(t.verifyPayToken(SECRET, full).payload, { v: 1, u: USER, i: 'inv1', a: 12000 });
  });

  test('s round trip binds the plan customer and expires after 7 days', () => {
    const nowSec = 1_800_000_000;
    const tok = t.mintSetupToken(SECRET, { userId: USER, planId: 'ri1', customerId: 'c1', nowSec });
    const ok = t.verifyPayToken(SECRET, tok, { expectKind: 's', nowSec: nowSec + t.SETUP_TOKEN_TTL_SEC });
    assert.equal(ok.ok, true);
    assert.deepEqual(ok.payload, { v: 1, u: USER, r: 'ri1', c: 'c1', x: nowSec + 7 * 86400 });
    const late = t.verifyPayToken(SECRET, tok, { expectKind: 's', nowSec: nowSec + t.SETUP_TOKEN_TTL_SEC + 1 });
    assert.equal(late.ok, false);
    assert.equal(late.reason, 'expired');
    assert.equal(late.payload.r, 'ri1'); // the owner can still be named on the expired page
  });

  test('m round trip; manage tokens never expire', () => {
    const tok = t.mintManageToken(SECRET, { userId: USER, enrollmentId: ENROLLMENT });
    assert.equal(t.verifyPayToken(SECRET, tok, { expectKind: 'm', nowSec: 9_999_999_999 }).ok, true);
  });

  test('any tampering fails the signature', () => {
    const tok = t.mintInvoicePayToken(SECRET, { userId: USER, invoiceId: 'inv1', cents: 100 });
    const [kind, payload, sig] = tok.split('.');
    const forged = Buffer.from(JSON.stringify({ v: 1, u: USER, i: 'inv1', a: 1 })).toString('base64url');
    assert.equal(t.verifyPayToken(SECRET, `${kind}.${forged}.${sig}`).reason, 'signature');
    assert.equal(t.verifyPayToken(SECRET, `${kind}.${payload}.${sig.slice(0, -2)}AA`).reason, 'signature');
    assert.equal(t.verifyPayToken('other-secret-xxxxxxxxxxxxxxxxxxxxxx', tok).reason, 'signature');
  });

  test('kind confusion: a token never verifies as another kind', () => {
    const p = t.mintInvoicePayToken(SECRET, { userId: USER, invoiceId: 'inv1' });
    assert.equal(t.verifyPayToken(SECRET, p, { expectKind: 'm' }).reason, 'kind');
    // Relabeling the kind breaks the MAC (the kind is inside it).
    const [, payload, sig] = p.split('.');
    assert.equal(t.verifyPayToken(SECRET, `m.${payload}.${sig}`).reason, 'signature');
    assert.equal(t.verifyPayToken(SECRET, `s.${payload}.${sig}`).reason, 'signature');
  });

  test('malformed inputs fail closed without throwing', () => {
    for (const bad of [undefined, null, '', 'p', 'p.a', 'p.a.b.c', 'x.a.b', 'p..', 'p.!!.??', 'p.' + 'a'.repeat(2000) + '.b']) {
      const r = t.verifyPayToken(SECRET, bad);
      assert.equal(r.ok, false, String(bad));
    }
    assert.equal(t.verifyPayToken('', 'p.a.b').reason, 'missing');
  });

  test('a validly signed but out-of-shape payload is refused', () => {
    const sign = (kind, obj) => {
      const b = Buffer.from(JSON.stringify(obj)).toString('base64url');
      const mac = crypto.createHmac('sha256', SECRET).update(`tr-pay|${kind}|${b}`).digest('base64url');
      return `${kind}.${b}.${mac}`;
    };
    assert.equal(t.verifyPayToken(SECRET, sign('p', { v: 1, u: USER, i: 'inv1' })).ok, true); // control
    assert.equal(t.verifyPayToken(SECRET, sign('p', { v: 2, u: USER, i: 'inv1' })).reason, 'malformed');
    assert.equal(t.verifyPayToken(SECRET, sign('p', { v: 1, u: 'not-a-uuid', i: 'inv1' })).reason, 'malformed');
    assert.equal(t.verifyPayToken(SECRET, sign('p', { v: 1, u: USER, i: 'inv"1' })).reason, 'malformed');
    assert.equal(t.verifyPayToken(SECRET, sign('p', { v: 1, u: USER, i: 'inv1', a: -5 })).reason, 'malformed');
    assert.equal(t.verifyPayToken(SECRET, sign('p', { v: 1, u: USER, i: 'inv1', a: 1.5 })).reason, 'malformed');
    assert.equal(t.verifyPayToken(SECRET, sign('m', { v: 1, u: USER, e: 'x' })).reason, 'malformed');
    assert.equal(t.verifyPayToken(SECRET, sign('s', { v: 1, u: USER, r: 'ri1' })).reason, 'malformed');
  });

  test('the signature is compared in constant time (constantTimeEqual)', () => {
    const src = require('node:fs').readFileSync(require.resolve('../lib/pay/payToken.js'), 'utf8');
    assert.match(src, /constantTimeEqual\(mac\(secret, kind, payloadB64\), sig\)/);
    assert.doesNotMatch(src, /mac\([^)]*\)\s*===\s*sig/);
  });

  test('minting refuses bad inputs instead of signing them', () => {
    assert.throws(() => t.mintInvoicePayToken('', { userId: USER, invoiceId: 'inv1' }));
    assert.throws(() => t.mintInvoicePayToken(SECRET, { userId: 'nope', invoiceId: 'inv1' }));
    assert.throws(() => t.mintInvoicePayToken(SECRET, { userId: USER, invoiceId: 'inv/1' }));
  });

  test('public base: explicit var, derived from the estimate base, else the apex', () => {
    assert.equal(t.payPublicBase({}), 'https://gettradereadyapp.com/pay.html');
    assert.equal(t.payPublicBase({ ESTIMATE_PUBLIC_BASE: 'https://gettradereadyapp.com/estimate.html' }), 'https://gettradereadyapp.com/pay.html');
    assert.equal(t.payPublicBase({ ESTIMATE_PUBLIC_BASE: 'https://x.test/weird' }), 'https://gettradereadyapp.com/pay.html');
    assert.equal(t.payPublicBase({ PAY_PUBLIC_BASE: 'https://pay.test/p' }), 'https://pay.test/p');
    assert.equal(t.payPageUrl({}, 'm', 'm.a.b'), 'https://gettradereadyapp.com/pay.html?m=m.a.b');
  });
});

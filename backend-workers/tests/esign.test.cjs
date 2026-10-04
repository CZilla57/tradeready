// E-signatures (Roadmap Phase 19) — the pure lib/esign modules.
// Spec: docs/superpowers/specs/2026-10-03-esignature-upgrade-design.md §3, §6.
//
// Golden fixtures live in tests/fixtures/esign/. Regenerate them ONLY for an
// intended change (a new renderer or record version), never to make a
// failing test pass:  UPDATE_ESIGN_GOLDEN=1 node --test tests/esign.test.cjs
//
// Seal tests generate an Ed25519 key pair at runtime. No private key is
// committed anywhere.

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { createHash } = require('node:crypto');
const { describe, test, afterEach } = require('node:test');

const texts = require('../lib/esign/texts.js');
const validate = require('../lib/esign/validate.js');
const { edgeClientIp } = require('../lib/esign/ip.js');
const record = require('../lib/esign/record.js');
const seal = require('../lib/esign/seal.js');
const pdf = require('../lib/esign/pdf.js');
const { buildCopyEmail } = require('../lib/esign/copyEmail.js');
const store = require('../lib/esign/store.js');
const flags = require('../lib/esign/flags.js');
const { canonicalJson, snapshotDigest } = require('../lib/estimate/quoteOptions.js');
const F = require('./esignFixtures.cjs');

const GOLDEN_DIR = path.join(__dirname, 'fixtures/esign');
const UPDATE = process.env.UPDATE_ESIGN_GOLDEN === '1';
const sha = (bytes) => createHash('sha256').update(bytes).digest('hex');

// The §7 "must not say" list, applied to every customer-facing string.
const MUST_NOT_SAY = [
  /legally[ -]binding/i, /\benforceable\b/i, /court[- ]admissible/i, /court[- ]proof/i, /\bguaranteed?\b/i,
  /ESIGN\/UETA compliant/i, /\bcompliant\b/i, /identity verified/i, /\bnotari[sz]ed\b/i, /\bcertified\b/i,
  /qualified signature/i, /as valid as DocuSign/i, /more legal/i,
];
function assertCleanCopy(text, where) {
  for (const re of MUST_NOT_SAY) assert.doesNotMatch(String(text), re, `${where} must not say ${re}`);
}

function golden(name, actual) {
  const file = path.join(GOLDEN_DIR, name);
  if (UPDATE) fs.writeFileSync(file, actual);
  return fs.readFileSync(file);
}

// Text content of an uncompressed pdf-v1 file: every literal string shown.
function pdfStrings(bytes) {
  const s = Buffer.from(bytes).toString('latin1');
  return [...s.matchAll(/\(((?:\\.|[^\\)])*)\) Tj/g)]
    .map((m) => m[1].replace(/\\([0-7]{3})/g, (_, o) => String.fromCharCode(parseInt(o, 8))).replace(/\\(.)/g, '$1'))
    .join('\n');
}

describe('flags', () => {
  test('both default off; only explicit truthy strings turn them on', () => {
    assert.equal(flags.esignV2({}), false);
    assert.equal(flags.esignV2({ ESIGN_V2: 'false' }), false);
    assert.equal(flags.esignV2({ ESIGN_V2: '0' }), false);
    assert.equal(flags.esignV2({ ESIGN_V2: 'true' }), true);
    assert.equal(flags.esignV2({ ESIGN_V2: ' ON ' }), true);
    assert.equal(flags.esignRequireConsent({ ESIGN_REQUIRE_CONSENT: 'true' }), false, 'needs ESIGN_V2 too');
    assert.equal(flags.esignRequireConsent({ ESIGN_V2: '1', ESIGN_REQUIRE_CONSENT: 'true' }), true);
  });

  test('esignActive: snapshot marker, or everyone once consent is required', () => {
    const v2 = { ESIGN_V2: 'true' };
    assert.equal(flags.esignActive({}, { esign: { version: 1 } }), false);
    assert.equal(flags.esignActive(v2, { esign: { version: 1 } }), true);
    assert.equal(flags.esignActive(v2, { total: 1 }), false);
    assert.equal(flags.esignActive({ ...v2, ESIGN_REQUIRE_CONSENT: 'true' }, { total: 1 }), true);
  });
});

describe('edgeClientIp ignores x-forwarded-for', () => {
  const fakeC = (h) => ({ req: { header: (k) => h[k.toLowerCase()] } });
  test('cf-connecting-ip only', () => {
    assert.equal(edgeClientIp(fakeC({ 'cf-connecting-ip': '203.0.113.9', 'x-forwarded-for': '1.2.3.4' })), '203.0.113.9');
    assert.equal(edgeClientIp(fakeC({ 'cf-connecting-ip': ' 2001:db8::1 ' })), '2001:db8::1');
  });
  test('no edge header → null, never the spoofable XFF', () => {
    assert.equal(edgeClientIp(fakeC({ 'x-forwarded-for': '1.2.3.4' })), null);
    assert.equal(edgeClientIp(fakeC({ 'cf-connecting-ip': '   ' })), null);
    assert.equal(edgeClientIp(fakeC({ 'cf-connecting-ip': '1.2.3.4<script>' })), null);
    assert.equal(edgeClientIp(fakeC({ 'cf-connecting-ip': '1'.repeat(65) })), null);
  });
});

describe('texts (§3.1, §3.2 drafts)', () => {
  test('the version-1 disclosure renders the spec text with the business details', () => {
    const t = texts.signingTexts(F.estimateSnapshot(), 'estimate');
    assert.equal(t.version, 1);
    assert.equal(t.disclosureText, [
      "Using electronic records and signatures. Rector HVAC uses TradeReady to send you this estimate electronically. If you agree, you'll sign it electronically and receive your copy electronically.",
      '- Paper copy: you can ask Rector HVAC for a paper copy at no charge — (602) 555-0143 · office@rectorhvac.test.',
      "- Your choice: you don't have to sign electronically. To sign on paper instead, contact Rector HVAC. Withdrawing your agreement later doesn't affect anything you already signed.",
      '- Scope: this agreement covers this estimate and any change orders to this job.',
      '- Contact details: to change the email address for your copies, tell Rector HVAC.',
      '- What you need: a device with a current web browser that can open and save PDF files. You can open this page, so you can view these records; use "Download this estimate (PDF)" to check that you can open and save the PDF.',
    ].join('\n'));
    assert.equal(t.checkboxLabel, 'I agree to use electronic records and signatures for this estimate.');
    assert.equal(t.disclosureLinkLabel, 'Read the electronic records disclosure');
    assert.equal(t.intent, 'By selecting Approve and sign, you are signing this estimate electronically. Your typed name — and your drawing, if you add one — is your signature.');
    assert.equal(t.approveLabel, 'Approve and sign');
    assert.equal(t.drawPad, true);
  });

  test('change orders, missing contact details and the pad turned off', () => {
    const co = texts.signingTexts(F.changeOrderSnapshot(), 'change_order');
    assert.match(co.disclosureText, /send you this change order electronically/);
    assert.match(co.disclosureText, /- Scope: this agreement covers this change order and any other change orders to this job\./);
    assert.match(co.disclosureText, /a paper copy at no charge\.\n/, 'no dangling dash without contact details');
    assert.match(co.disclosureText, /"Download this change order \(PDF\)"/);
    assert.equal(co.checkboxLabel, 'I agree to use electronic records and signatures for this change order.');
    const off = texts.signingTexts(F.optionsSnapshot(), 'estimate');
    assert.equal(off.drawPad, false);
    assert.equal(off.intent, 'By selecting Approve and sign, you are signing this estimate electronically. Your typed name is your signature.');
    assert.match(off.disclosureText, /no charge — office@rectorhvac\.test\./);
  });

  test('no customer-facing string uses a must-not-say phrase (§7, Q5)', () => {
    for (const [snap, type] of [[F.estimateSnapshot(), 'estimate'], [F.changeOrderSnapshot(), 'change_order'], [F.optionsSnapshot(), 'estimate']]) {
      const t = texts.signingTexts(snap, type);
      assertCleanCopy(JSON.stringify(t), `signingTexts(${type})`);
    }
    for (const msg of Object.values(validate.ERRORS)) assertCleanCopy(msg, 'validation error');
  });

  test('an unknown consent version renders nothing', () => {
    assert.equal(texts.disclosure(2, F.estimateSnapshot(), 'estimate'), null);
  });
});

describe('validate (§3.3)', () => {
  test('typed name: trimmed, 1–200 characters, no control characters', () => {
    assert.deepEqual(validate.validateTypedName('  Pat Lee '), { value: 'Pat Lee' });
    assert.equal(validate.validateTypedName('   ').code, 'name_required');
    assert.equal(validate.validateTypedName(undefined).code, 'name_required');
    assert.equal(validate.validateTypedName(42).code, 'name_required');
    assert.deepEqual(validate.validateTypedName('x'.repeat(200)), { value: 'x'.repeat(200) });
    assert.equal(validate.validateTypedName('x'.repeat(201)).code, 'name_too_long');
    assert.equal(validate.validateTypedName('Pat\nLee').code, 'name_invalid');
    assert.equal(validate.validateTypedName('Pat\u0000').code, 'name_invalid');
    assert.equal(validate.validateTypedName('Pat \ud800').code, 'name_invalid');
    assert.deepEqual(validate.validateTypedName('Nguyễn 👍'), { value: 'Nguyễn 👍' });
  });

  test('drawing: shape, box, integer points', () => {
    assert.deepEqual(validate.normalizeDrawn(null), { value: null });
    assert.deepEqual(validate.normalizeDrawn(F.DRAWN), { value: F.DRAWN });
    for (const bad of [
      'x', [], { w: 300, h: 200, strokes: [] }, { w: 600, h: 200 }, { w: 600, h: 200, strokes: [[]] },
      { w: 600, h: 200, strokes: [[[1, 2]]] }, { w: 600, h: 200, strokes: [[[1.5, 2, 0], [3, 4, 5]]] },
      { w: 600, h: 200, strokes: [[[601, 2, 0], [3, 4, 5]]] }, { w: 600, h: 200, strokes: [[[1, -1, 0], [3, 4, 5]]] },
      { w: 600, h: 200, strokes: [[[1, 2, -5], [3, 4, 5]]] }, { w: 600, h: 200, strokes: [[['1', 2, 0], [3, 4, 5]]] },
    ]) {
      assert.equal(validate.normalizeDrawn(bad).code, 'drawing_invalid', JSON.stringify(bad));
    }
  });

  test('drawing caps: 40 strokes, 2,000 points, 24 KB', () => {
    // Small coordinates and times, so the point cap is reached before the byte cap.
    const stroke = (n) => Array.from({ length: n }, (_, i) => [i % 10, i % 10, i % 100]);
    assert.ok(validate.normalizeDrawn({ w: 600, h: 200, strokes: Array.from({ length: 40 }, () => stroke(2)) }).value);
    assert.equal(validate.normalizeDrawn({ w: 600, h: 200, strokes: Array.from({ length: 41 }, () => stroke(2)) }).code, 'drawing_too_large');
    assert.ok(validate.normalizeDrawn({ w: 600, h: 200, strokes: [stroke(1000), stroke(1000)] }).value);
    assert.equal(validate.normalizeDrawn({ w: 600, h: 200, strokes: [stroke(1000), stroke(1001)] }).code, 'drawing_too_large');
    // 2,000 points with long timestamps exceed 24 KB of JSON.
    const heavy = [Array.from({ length: 2000 }, (_, i) => [599, 199, 3_000_000 + i])];
    assert.equal(validate.normalizeDrawn({ w: 600, h: 200, strokes: heavy }).code, 'drawing_too_large');
  });

  test('an empty or single-dot drawing counts as not drawn', () => {
    assert.deepEqual(validate.normalizeDrawn({ w: 600, h: 200, strokes: [] }), { value: null });
    assert.deepEqual(validate.normalizeDrawn({ w: 600, h: 200, strokes: [[[5, 5, 0]]] }), { value: null });
    assert.ok(validate.normalizeDrawn({ w: 600, h: 200, strokes: [[[5, 5, 0]], [[9, 9, 30]]] }).value);
  });

  test('a normalized drawing carries only the documented keys', () => {
    const out = validate.normalizeDrawn({ ...F.clone(F.DRAWN), extra: 'x' }).value;
    assert.deepEqual(Object.keys(out), ['w', 'h', 'strokes']);
  });

  test('signer email: optional, format-checked, at most 254', () => {
    assert.deepEqual(validate.normalizeEmail(undefined), { value: null });
    assert.deepEqual(validate.normalizeEmail('  '), { value: null });
    assert.deepEqual(validate.normalizeEmail(' pat@example.test '), { value: 'pat@example.test' });
    for (const bad of ['pat', 'pat@', '@x.y', 'a b@x.y', 'pat@x', 'pat@x.y\r\nBcc: z@z.z', 7, `${'a'.repeat(250)}@x.yz`]) {
      assert.equal(validate.normalizeEmail(bad).code, 'email_invalid', String(bad));
    }
  });

  test('consent: absent is null (old page); present must be accepted + known version', () => {
    assert.deepEqual(validate.normalizeConsent(undefined), { value: null });
    assert.deepEqual(validate.normalizeConsent({ accepted: true, version: 1 }), { value: { version: 1 } });
    assert.equal(validate.normalizeConsent({ accepted: false, version: 1 }).code, 'consent_required');
    assert.equal(validate.normalizeConsent({ accepted: 'true', version: 1 }).code, 'consent_required');
    assert.equal(validate.normalizeConsent(true).code, 'consent_required');
    assert.equal(validate.normalizeConsent({ accepted: true, version: 2 }).code, 'consent_version_unknown');
    assert.equal(validate.normalizeConsent({ accepted: true, version: '1' }).code, 'consent_version_unknown');
  });

  test('parseSignatureFields returns the first error, with a code', () => {
    assert.deepEqual(validate.parseSignatureFields({}), { value: { drawn: null, email: null, consent: null } });
    const err = validate.parseSignatureFields({ drawn: 'x', signerEmail: 'bad' });
    assert.equal(err.code, 'drawing_invalid');
    assert.equal(typeof err.error, 'string');
  });

  test('snapshot additions (§3.4), checked by create-link', () => {
    const v = validate.validateSnapshotEsign;
    assert.equal(v(F.estimateSnapshot()), null);
    assert.equal(v({ total: 1 }), null);
    assert.equal(v({ scope: 'x'.repeat(4000) }), null);
    assert.equal(v({ scope: 'x'.repeat(4001) }), 'The scope must be text of at most 4,000 characters.');
    assert.equal(v({ scope: 5 }), 'The scope must be text of at most 4,000 characters.');
    assert.equal(v({ terms: 'x'.repeat(4001) }), 'The terms must be text of at most 4,000 characters.');
    assert.equal(v({ businessContact: 'x' }), 'Business contact details are malformed.');
    assert.equal(v({ businessContact: { phone: 5 } }), 'Business contact details are malformed.');
    assert.equal(v({ businessContact: { phone: '1'.repeat(41) } }), 'The business phone must be at most 40 characters.');
    assert.equal(v({ businessContact: { email: 'nope' } }), 'The business email address is invalid.');
    assert.equal(v({ businessContact: { email: '' } }), null);
    assert.equal(v({ signature: { drawPad: 'yes' } }), 'Signature settings are malformed.');
    assert.equal(v({ signature: [] }), 'Signature settings are malformed.');
    assert.equal(v({ esign: { version: 2 } }), "This e-signature version isn't supported. Please update the app.");
    assert.equal(v({ esign: true }), "This e-signature version isn't supported. Please update the app.");
    assert.equal(v({ esign: { version: 1, timeZone: '' } }), 'The e-signature time zone is invalid.');
    assert.equal(v({ esign: { version: 1, timeZone: 'x'.repeat(65) } }), 'The e-signature time zone is invalid.');
  });
});

describe('record (§3.5): canonical bytes and digests', () => {
  const built = Object.fromEntries(Object.entries(F.CASES).map(([name, make]) => {
    const c = make();
    const rec = record.recordFromApproval(c);
    return [name, { c, rec, canonical: canonicalJson(rec), digest: record.recordDigest(rec) }];
  }));
  if (UPDATE) {
    fs.writeFileSync(path.join(GOLDEN_DIR, 'records.golden.json'), `${JSON.stringify(
      Object.fromEntries(Object.entries(built).map(([k, v]) => [k, { canonical: v.canonical, digest: v.digest }])), null, 2)}\n`);
  }
  const goldenRecords = JSON.parse(fs.readFileSync(path.join(GOLDEN_DIR, 'records.golden.json'), 'utf8'));

  for (const name of Object.keys(F.CASES)) {
    test(`${name}: canonical JSON and digest match the golden fixture`, () => {
      assert.equal(built[name].canonical, goldenRecords[name].canonical);
      assert.equal(built[name].digest, goldenRecords[name].digest);
      assert.equal(built[name].digest, sha(Buffer.from(goldenRecords[name].canonical, 'utf8')));
    });
  }

  test('shape: version 1, the snapshot as stored, its digest, hashed texts', () => {
    const { c, rec } = built.estimate;
    assert.equal(rec.recordVersion, 1);
    assert.equal(rec.recordId, c.approval.signatureRecordId);
    assert.equal(rec.documentType, 'estimate');
    assert.equal(rec.changeOrderId, null);
    assert.equal(rec.approvalTokenSha256, sha(Buffer.from(c.approval.token)));
    assert.deepEqual(rec.document, c.approval.snapshot);
    assert.equal(rec.documentDigest, snapshotDigest(c.approval.snapshot));
    assert.equal(rec.consent.version, 1);
    assert.equal(rec.consent.textSha256, sha(Buffer.from(rec.consent.text, 'utf8')));
    assert.equal(rec.consent.text, texts.signingTexts(c.approval.snapshot, 'estimate').disclosureText);
    assert.equal(rec.consent.acceptedAt, F.SIGNED_AT);
    assert.equal(rec.intent.textSha256, sha(Buffer.from(rec.intent.text, 'utf8')));
    assert.deepEqual(rec.signer, { typedName: 'Zoë Ångström', drawn: F.DRAWN, email: 'zoe@example.test' });
    assert.equal(rec.signatureMethod, 'typed_drawn');
    assert.equal(rec.signedAt, F.SIGNED_AT);
    assert.equal(rec.context, 'remote_link');
    assert.equal(rec.renderer, 'pdf-v1');
    assert.deepEqual(rec.events, F.EVENTS);
    assert.ok(!JSON.stringify(rec).includes(c.approval.token), 'the raw token never enters the record');
  });

  test('an old page (no consent) records consent and intent as null', () => {
    const { rec } = built.changeOrder;
    assert.equal(rec.consent, null);
    assert.equal(rec.intent, null);
    assert.equal(rec.ip, null);
    assert.equal(rec.changeOrderId, 'co-1');
    assert.equal(rec.documentType, 'change_order');
  });

  test('any change to the record changes the digest', () => {
    const { rec, digest } = built.options;
    for (const mutate of [
      (r) => { r.signer.typedName = 'Pat Lea'; },
      (r) => { r.selection.total = 1586; },
      (r) => { r.document.options.tiers[0].total = 1; },
      (r) => { r.events.push({ type: 'viewed', at: F.SIGNED_AT, ip: null }); },
      (r) => { r.signedAt = '2026-10-03T14:05:10.000Z'; },
    ]) {
      const copy = F.clone(rec);
      mutate(copy);
      assert.notEqual(record.recordDigest(copy), digest);
    }
    assert.equal(record.recordDigest(F.clone(rec)), digest, 'a JSON round trip (jsonb) keeps the digest');
  });

  test('legacy approvals have no record', () => {
    const { c } = built.estimate;
    const legacy = { ...c.approval };
    delete legacy.signatureEvidence;
    assert.equal(record.recordFromApproval({ ...c, approval: legacy }), null);
    assert.equal(record.recordFromApproval({ ...c, approval: { ...c.approval, decision: 'declined' } }), null);
  });

  test('signApproval adds the four keys and commits to the record digest', () => {
    const c = F.CASES.estimate();
    const merged = { ...c.approval };
    for (const k of ['signatureRecordId', 'signatureMethod', 'signatureEvidence']) delete merged[k];
    merged.recordDigest = 'stale';
    const out = record.signApproval(merged, {
      recordId: c.approval.signatureRecordId, consent: { version: 1 }, drawn: F.DRAWN, email: 'zoe@example.test',
      events: F.EVENTS, jobId: c.jobId, documentType: 'estimate',
    });
    assert.equal(out.digest, built.estimate.digest, 'same inputs → the golden record');
    assert.equal(out.approval.recordDigest, out.digest);
    assert.equal(out.approval.signatureMethod, 'typed_drawn');
    assert.deepEqual(out.approval.signatureEvidence, c.approval.signatureEvidence);
    assert.equal(record.recordDigest(record.recordFromApproval({ ...c, approval: out.approval })), out.digest, 'a lazy re-seal reproduces it');
  });

  test('eventsForRecord: link/view/decline only, oldest first, ISO times, owner has no IP', () => {
    const rows = [
      { id: 3, event: 'viewed', ip: '198.51.100.2', created_at: '2026-10-03T13:00:00.5+00:00' },
      { id: 1, event: 'link_created', ip: '10.0.0.1', created_at: '2026-10-02T12:00:00.123456+00:00' },
      { id: 4, event: 'copy_downloaded', ip: '198.51.100.2', created_at: '2026-10-03T13:01:00+00:00' },
      { id: 2, event: 'viewed', ip: null, created_at: 'garbage' },
    ];
    assert.deepEqual(record.eventsForRecord(rows), [
      { type: 'link_created', at: '2026-10-02T12:00:00.123Z', actor: 'owner' },
      { type: 'viewed', at: '2026-10-03T13:00:00.500Z', ip: '198.51.100.2' },
    ]);
    const many = Array.from({ length: 80 }, (_, i) => ({ event: 'viewed', created_at: new Date(Date.UTC(2026, 9, 1) + i * 1000).toISOString() }));
    assert.equal(record.eventsForRecord(many).length, record.MAX_RECORD_EVENTS);
  });
});

describe('seal (§3.5, D6): Ed25519 with a runtime test key', () => {
  let env;
  let otherRaw;
  const digest = record.recordDigest(record.recordFromApproval(F.CASES.estimate()));

  async function testEnv(keyId = 'k-test') {
    const pair = await crypto.subtle.generateKey({ name: 'Ed25519' }, true, ['sign', 'verify']);
    const pkcs8 = Buffer.from(await crypto.subtle.exportKey('pkcs8', pair.privateKey)).toString('base64');
    const raw = Buffer.from(await crypto.subtle.exportKey('raw', pair.publicKey)).toString('base64');
    return { ESIGN_SEAL_PRIVATE_KEY: pkcs8, ESIGN_SEAL_KEY_ID: keyId, ESIGN_SEAL_PUBLIC_KEYS: JSON.stringify({ [keyId]: raw }) };
  }

  test('seal → verify round trip; deterministic', async () => {
    env = await testEnv();
    const s1 = await seal.sealDigest(env, digest);
    const s2 = await seal.sealDigest(env, digest);
    assert.equal(s1.alg, 'Ed25519');
    assert.equal(s1.keyId, 'k-test');
    assert.equal(Buffer.from(s1.signature, 'base64').length, 64);
    assert.equal(s1.signature, s2.signature, 'Ed25519 re-seals identically');
    assert.equal(await seal.verifySeal(env, digest, 'k-test', s1.signature), true);
  });

  test('a PEM-wrapped private key works too', async () => {
    const pem = `-----BEGIN PRIVATE KEY-----\n${env.ESIGN_SEAL_PRIVATE_KEY.match(/.{1,64}/g).join('\n')}\n-----END PRIVATE KEY-----\n`;
    const s = await seal.sealDigest({ ...env, ESIGN_SEAL_PRIVATE_KEY: pem }, digest);
    assert.equal(await seal.verifySeal(env, digest, 'k-test', s.signature), true);
  });

  test('a tampered digest, record, signature or key id is rejected', async () => {
    const s = await seal.sealDigest(env, digest);
    const tampered = F.CASES.estimate();
    tampered.approval.signerName = 'Someone Else';
    const otherDigest = record.recordDigest(record.recordFromApproval(tampered));
    assert.equal(await seal.verifySeal(env, otherDigest, 'k-test', s.signature), false);
    assert.equal(await seal.verifySeal(env, `${digest.slice(0, 63)}0`, 'k-test', s.signature), false);
    const sig = Buffer.from(s.signature, 'base64');
    sig[5] ^= 1;
    assert.equal(await seal.verifySeal(env, digest, 'k-test', sig.toString('base64')), false);
    assert.equal(await seal.verifySeal(env, digest, 'unknown', s.signature), false);
    assert.equal(await seal.verifySeal(env, digest, 'k-test', 'not base64!'), false);
  });

  test('misconfiguration never mints a seal nobody can check', async () => {
    const other = await testEnv('k-other');
    otherRaw = JSON.parse(other.ESIGN_SEAL_PUBLIC_KEYS)['k-other'];
    await assert.rejects(seal.sealDigest({}, digest), seal.SealUnavailableError);
    await assert.rejects(seal.sealDigest({ ...env, ESIGN_SEAL_KEY_ID: '' }, digest), seal.SealUnavailableError);
    await assert.rejects(seal.sealDigest({ ...env, ESIGN_SEAL_PUBLIC_KEYS: '{}' }, digest), /no published public key/);
    await assert.rejects(
      seal.sealDigest({ ...env, ESIGN_SEAL_PUBLIC_KEYS: JSON.stringify({ 'k-test': otherRaw }) }, digest),
      /does not match the published key/
    );
    await assert.rejects(seal.sealDigest({ ...env, ESIGN_SEAL_PRIVATE_KEY: 'AAAA' }, digest), seal.SealUnavailableError);
  });

  test('publicKeys lists every configured key with its SPKI form', async () => {
    const env2 = { ...env, ESIGN_SEAL_PUBLIC_KEYS: JSON.stringify({ ...JSON.parse(env.ESIGN_SEAL_PUBLIC_KEYS), 'k-old': otherRaw, 'bad id!': otherRaw, short: 'AAAA' }) };
    const keys = seal.publicKeys(env2);
    assert.deepEqual(keys.map((k) => k.keyId), ['k-old', 'k-test']);
    for (const k of keys) {
      assert.equal(k.alg, 'Ed25519');
      const spki = Buffer.from(k.spki, 'base64');
      assert.equal(spki.length, 44);
      const imported = await crypto.subtle.importKey('spki', spki, { name: 'Ed25519' }, true, ['verify']);
      assert.equal(Buffer.from(await crypto.subtle.exportKey('raw', imported)).toString('base64'), k.publicKey);
    }
    assert.deepEqual(seal.publicKeys({ ESIGN_SEAL_PUBLIC_KEYS: 'not json' }), []);
  });
});

describe('pdf (§3.6): deterministic pdf-v1 golden bytes', () => {
  const renders = {
    'estimate-signed.pdf': () => {
      const rec = record.recordFromApproval(F.CASES.estimate());
      return pdf.renderSignedPdf({ record: rec, recordDigest: record.recordDigest(rec), seal: F.FAKE_SEAL });
    },
    'options-signed.pdf': () => {
      const rec = record.recordFromApproval(F.CASES.options());
      return pdf.renderSignedPdf({ record: rec, recordDigest: record.recordDigest(rec), seal: F.FAKE_SEAL });
    },
    'options-preview.pdf': () => pdf.renderPreviewPdf({
      snapshot: F.optionsSnapshot(), documentType: 'estimate', snapshotDigest: snapshotDigest(F.optionsSnapshot()),
    }),
    'change-order-signed.pdf': () => {
      const rec = record.recordFromApproval(F.CASES.changeOrder());
      return pdf.renderSignedPdf({ record: rec, recordDigest: record.recordDigest(rec), seal: null });
    },
  };

  for (const [name, render] of Object.entries(renders)) {
    test(`${name} is byte-identical to its golden file and across runs`, () => {
      const a = render();
      const b = render();
      assert.ok(Buffer.from(a).equals(Buffer.from(b)), 'two renders differ');
      const expected = golden(name, Buffer.from(a));
      assert.ok(Buffer.from(a).equals(expected), `${name} differs from the golden bytes (sha ${sha(a)} vs ${sha(expected)})`);
    });
  }

  test('well-formed: header, xref offsets point at their objects, startxref, %%EOF', () => {
    for (const render of Object.values(renders)) {
      const s = Buffer.from(render()).toString('latin1');
      assert.ok(s.startsWith('%PDF-1.4\n%âãÏÓ\n'));
      assert.ok(s.endsWith('%%EOF\n'));
      const startxref = Number(s.match(/startxref\n(\d+)\n%%EOF\n$/)[1]);
      assert.equal(s.slice(startxref, startxref + 4), 'xref');
      const [, count] = s.slice(startxref).match(/^xref\n0 (\d+)\n/);
      const entries = s.slice(startxref).split('\n').slice(3, 2 + Number(count));
      entries.forEach((line, i) => {
        const off = Number(line.slice(0, 10));
        assert.equal(s.slice(off, off + `${i + 1} 0 obj`.length), `${i + 1} 0 obj`);
      });
      for (const m of s.matchAll(/<< \/Length (\d+) >>\nstream\n/g)) {
        const start = m.index + m[0].length;
        assert.equal(s.slice(start + Number(m[1]), start + Number(m[1]) + 10), '\nendstream');
      }
    }
  });

  test('signed copy: the certificate shows signer, times, IP, consent, trail, ids, seal', () => {
    const rec = record.recordFromApproval(F.CASES.estimate());
    const d = record.recordDigest(rec);
    const text = pdfStrings(pdf.renderSignedPdf({ record: rec, recordDigest: d, seal: F.FAKE_SEAL }));
    for (const want of [
      'Signature certificate', 'Zoë Ångström', '2026-10-03 14:05:09 UTC',
      '2026-10-03 07:05:09 (America/Phoenix, UTC-07:00)', '203.0.113.9', 'Agreed (disclosure version 1)',
      'Link sent by the business', 'Opened by the signer', rec.recordId, rec.documentDigest, d,
      'Ed25519, key test-not-a-real-key', 'Verify at gettradereadyapp.com/verify', 'Scope of work', 'Terms',
      'Total estimate', '$2,900.50', 'November 1, 2026', 'Typed name and drawn signature',
    ]) assert.ok(text.includes(want), `missing ${want}`);
    assertCleanCopy(text, 'signed PDF');
    const raw = Buffer.from(pdf.renderSignedPdf({ record: rec, recordDigest: d, seal: F.FAKE_SEAL })).toString('latin1');
    assert.match(raw, /\/CreationDate \(D:20261003140509Z\)/, 'CreationDate is signedAt, not the clock');
    assert.ok(raw.includes(`/ID [<${d.slice(0, 32)}> <${d.slice(0, 32)}>]`), '/ID derives from the record digest');
    assert.match(raw, / re S/, 'the signature box');
    assert.match(raw, /1\.2 w 1 J 1 j/, 'the drawn strokes');
  });

  test('options: the chosen option and its total; preview lists every tier and is unsigned', () => {
    const rec = record.recordFromApproval(F.CASES.options());
    const signed = pdfStrings(pdf.renderSignedPdf({ record: rec, recordDigest: record.recordDigest(rec), seal: F.FAKE_SEAL }));
    assert.ok(signed.includes('Chosen option: Better'));
    assert.ok(signed.includes('$1,585'));
    assert.ok(!signed.includes('Tankless unit'), 'unchosen tiers are not part of the signed document');
    const preview = pdfStrings(renders['options-preview.pdf']());
    for (const want of ['Estimate: unsigned copy for review', 'Good', 'Better (recommended)', 'Best', 'Tankless unit', '+$85']) {
      assert.ok(preview.includes(want), `preview missing ${want}`);
    }
    assert.ok(!preview.includes('Signature certificate'));
    assert.ok(!Buffer.from(renders['options-preview.pdf']()).toString('latin1').includes('/CreationDate'), 'no clock in the preview');
  });

  test('non-WinAnsi characters print as "?" and negative amounts keep their sign', () => {
    const rec = record.recordFromApproval(F.CASES.changeOrder());
    const text = pdfStrings(pdf.renderSignedPdf({ record: rec, recordDigest: record.recordDigest(rec), seal: null }));
    assert.ok(text.includes('Nguy?n Th? Minh Khai ?'), 'Vietnamese letters and the emoji degrade to ?');
    assert.ok(text.includes('Kowalczyk & Søn Électrique'), 'Latin-1 survives');
    assert.ok(text.includes('-$60'));
    assert.ok(text.includes('Total for this change'));
    assert.ok(text.includes('No agreement recorded (signed on an earlier version of the page)'));
    assert.ok(text.includes('Pending.'), 'an unsealed copy says so');
    assert.ok(text.includes('Characters this PDF cannot show appear as "?"'));
    assert.equal(rec.signer.typedName, 'Nguyễn Thị Minh Khai 👍', 'the record keeps the exact text');
  });

  test('encodeWinAnsi and money', () => {
    assert.equal(pdf.encodeWinAnsi('A€—“x”\t\u0007'), 'A\u0080\u0097\u0093x\u0094 ?');
    assert.equal(pdf.money(87.5), '$87.50');
    assert.equal(pdf.money(1234567), '$1,234,567');
    assert.equal(pdf.money(-0.004), '$0');
    assert.equal(pdf.money(-12.3), '-$12.30');
  });

  test('wrapping never exceeds the line width and keeps every word', () => {
    const text = 'word '.repeat(200) + 'x'.repeat(300);
    const lines = pdf.wrapText(text, 'regular', 10, 200);
    for (const l of lines) assert.ok(pdf.widthOf(l, 'regular', 10) <= 200, l);
    assert.equal(lines.join(' ').replace(/ +/g, ' ').replace(/x /g, 'x').trim().length >= 1300, true);
  });
});

describe('copy email (§3.5 step 5, Q7)', () => {
  const rec = record.recordFromApproval(F.CASES.estimate());
  const d = record.recordDigest(rec);

  test('from "{business} via TradeReady", to the signer, PDF attached, reply-to the business', () => {
    const e = buildCopyEmail({ record: rec, recordDigest: d, pdfBase64: 'UERG', filename: 'signed-estimate-3f0c1a2b.pdf' });
    assert.equal(e.from, 'Rector HVAC via TradeReady <estimates@gettradereadyapp.com>');
    assert.deepEqual(e.to, ['zoe@example.test']);
    assert.equal(e.subject, 'Your signed estimate from Rector HVAC');
    assert.equal(e.reply_to, 'office@rectorhvac.test');
    assert.deepEqual(e.attachments, [{ filename: 'signed-estimate-3f0c1a2b.pdf', content: 'UERG' }]);
    assert.ok(e.text.includes(`Record ID: ${rec.recordId}`));
    assert.ok(e.text.includes(`https://gettradereadyapp.com/verify?r=${rec.recordId}&d=${d}`));
    assertCleanCopy(e.text, 'copy email');
    assertCleanCopy(e.subject, 'copy email subject');
  });

  test('a hostile business name cannot inject headers', () => {
    const evil = F.clone(rec);
    evil.document.businessName = 'Evil"\r\nBcc: x@y.z <a@b.c>';
    evil.document.businessContact = { email: 'not an email' };
    const e = buildCopyEmail({ record: evil, recordDigest: d, pdfBase64: '', filename: 'x.pdf' });
    assert.doesNotMatch(e.from, /[\r\n"<>].*via/);
    assert.doesNotMatch(e.subject, /[\r\n]/);
    assert.equal(e.reply_to, undefined);
  });
});

describe('store wire format', () => {
  const ENV = { SUPABASE_URL: 'https://supa.test', SUPABASE_SERVICE_ROLE_KEY: 'srk' };
  const calls = [];
  afterEach(() => { delete global.fetch; calls.length = 0; });
  const respond = (body, status = 200) => ({ ok: status < 400, status, json: async () => body, text: async () => JSON.stringify(body) });

  test('insertRecord: insert-if-absent on the token hash; reports whether it created the row', async () => {
    global.fetch = async (url, init) => { calls.push({ url: String(url), init }); return respond([{ id: 'r' }], 201); };
    assert.equal(await store.insertRecord(ENV, { id: 'r' }), true);
    assert.equal(calls[0].url, 'https://supa.test/rest/v1/signature_records?on_conflict=approval_token_sha256');
    assert.equal(calls[0].init.method, 'POST');
    assert.equal(calls[0].init.headers.Prefer, 'resolution=ignore-duplicates,return=representation');
    global.fetch = async () => respond([], 201);
    assert.equal(await store.insertRecord(ENV, { id: 'r' }), false);
    global.fetch = async () => respond({ code: '23514', message: 'check', details: 'Failing row contains (Pat Lee, pat@example.test)' }, 400);
    await assert.rejects(store.insertRecord(ENV, { id: 'r' }), (err) => {
      assert.equal(err.message, 'Supabase insert 400 23514', 'no row data in the error (it gets logged)');
      return true;
    });
  });

  test('owner lookups are always scoped by user_id', async () => {
    global.fetch = async (url) => { calls.push(String(url)); return respond([]); };
    await store.fetchOwnerRecord(ENV, 'u1', { jobId: 'j 1' });
    await store.fetchOwnerRecord(ENV, 'u1', { jobId: 'j1', changeOrderId: 'co1', recordId: 'r1' });
    assert.match(calls[0], /user_id=eq\.u1&job_id=eq\.j%201&change_order_id=is\.null&order=signed_at\.desc/);
    assert.match(calls[1], /user_id=eq\.u1&job_id=eq\.j1&change_order_id=eq\.co1&id=eq\.r1/);
  });

  test('logEvent posts the row and never throws', async () => {
    global.fetch = async (url, init) => { calls.push({ url: String(url), body: JSON.parse(init.body) }); return respond(null, 201); };
    await store.logEvent(ENV, { userId: 'u1', tokenHash: 'h', event: 'viewed', ip: '1.2.3.4', userAgent: 'x'.repeat(400) });
    assert.equal(calls[0].url, 'https://supa.test/rest/v1/signature_events');
    assert.deepEqual(Object.keys(calls[0].body).sort(), ['approval_token_sha256', 'event', 'ip', 'user_agent', 'user_id']);
    assert.equal(calls[0].body.user_agent.length, 300);
    global.fetch = async () => { throw new Error('down'); };
    await assert.doesNotReject(store.logEvent(ENV, { userId: 'u1', tokenHash: 'h', event: 'viewed' }));
  });
});

describe('retention (§3.8, decision 19-Q6): account deletion keeps deleting signature evidence', () => {
  const root = path.join(__dirname, '../..');
  const migration = fs.readFileSync(path.join(root, 'supabase/migrations/20261003_esign_records.sql'), 'utf8');
  const audit = fs.readFileSync(path.join(root, 'supabase/verify/account_deletion_cascade.sql'), 'utf8');
  const code = migration.replace(/--.*$/gm, '');

  test('both tables cascade from auth.users, and nothing blocks the delete', () => {
    for (const table of ['signature_records', 'signature_events']) {
      const body = code.slice(code.indexOf(`create table if not exists public.${table}`));
      const ddl = body.slice(0, body.indexOf(');'));
      assert.match(ddl, /user_id\s+uuid not null references auth\.users\(id\) on delete cascade/, table);
    }
    assert.doesNotMatch(code, /before\s+delete/i, 'a delete trigger would block account deletion');
    assert.match(code, /before update on public\.signature_records/);
    assert.match(code, /before update on public\.signature_events/);
  });

  test('the account-deletion audit expects both tables', () => {
    assert.match(audit, /\('signature_events'\)/);
    assert.match(audit, /\('signature_records'\)/);
  });

  test('the account-deletion core is unchanged: one auth.users delete, the database cascades', () => {
    const core = fs.readFileSync(path.join(__dirname, '../lib/accountDeletion.js'), 'utf8');
    assert.equal(core, fs.readFileSync(path.join(root, 'backend/lib/accountDeletion.js'), 'utf8'));
    assert.doesNotMatch(core, /signature_/);
  });
});

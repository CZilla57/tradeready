// Shared e-signature fixtures (Phase 19) for tests/esign*.test.cjs. Not a
// test file itself (the runner globs *.test.cjs). Everything is fixed data:
// no clock, no randomness. The seal in PDF fixtures is an obviously fake
// all-"A" base64 string; real seals are only ever made with key pairs the
// tests generate at runtime — no private key is stored anywhere.

const { buildEvidence, buildRecord } = require('../lib/esign/record.js');

const clone = (v) => JSON.parse(JSON.stringify(v));

const FAKE_SEAL = Object.freeze({ alg: 'Ed25519', keyId: 'test-not-a-real-key', signature: `${'A'.repeat(86)}==` });

const SIGNED_AT = '2026-10-03T14:05:09.000Z';

const DRAWN = {
  w: 600,
  h: 200,
  strokes: [
    [[40, 150, 0], [70, 60, 40], [100, 150, 80], [130, 60, 120], [160, 150, 160]],
    [[220, 70, 400], [230, 150, 440], [300, 150, 480]],
    [[380, 100, 900]],
  ],
};

function estimateSnapshot() {
  return {
    businessName: 'Rector HVAC',
    customerName: 'Zoë Ångström',
    jobTitle: 'AC replacement',
    lineItems: [
      { label: 'Labor (8 hrs @ $95/hr)', amount: 760 },
      { label: 'Materials (3 items)', amount: 2140.5 },
    ],
    total: 2900.5,
    currency: 'USD',
    validUntil: '2026-11-01',
    validUntilTimeZone: 'America/Phoenix',
    scope: 'Remove the old condenser and air handler.\nInstall a 3-ton heat pump, new pad, line set and thermostat.',
    terms: '50% deposit due on acceptance. Balance due on completion. Permits included.',
    businessContact: { phone: '(602) 555-0143', email: 'office@rectorhvac.test' },
    signature: { drawPad: true },
    esign: { version: 1, timeZone: 'America/Phoenix' },
  };
}

function optionsSnapshot() {
  return {
    businessName: 'Rector HVAC',
    customerName: 'Pat Lee',
    jobTitle: 'Water heater',
    lineItems: [{ label: 'Labor', amount: 400 }, { label: '50 gal tank', amount: 1100 }],
    total: 1500,
    currency: 'USD',
    options: {
      tiers: [
        { id: 'good', name: 'Good', lineItems: [{ label: 'Labor', amount: 300 }, { label: '40 gal tank', amount: 800 }], total: 1100 },
        { id: 'better', name: 'Better', description: 'Bigger tank, 10-year warranty', lineItems: [{ label: 'Labor', amount: 400 }, { label: '50 gal tank', amount: 1100 }], total: 1500 },
        { id: 'best', name: 'Best', lineItems: [{ label: 'Labor', amount: 500 }, { label: 'Tankless unit', amount: 2600 }], total: 3100 },
      ],
      addOns: [{ id: 'pan', label: 'Drain pan', description: 'Protects the floor', amount: 85 }],
      recommendedTierId: 'better',
    },
    businessContact: { email: 'office@rectorhvac.test' },
    signature: { drawPad: false },
    esign: { version: 1 },
  };
}

function changeOrderSnapshot() {
  return {
    businessName: 'Kowalczyk & Søn Électrique',
    customerName: 'Nguyễn Thị Minh Khai 👍',
    jobTitle: 'Panel upgrade',
    lineItems: [{ label: 'Extra 20A circuit for the garage', amount: 450 }, { label: 'Credit: skip the dimmer', amount: -60 }],
    total: 390,
    currency: 'USD',
    scope: 'Add one 20A circuit to the garage; drop the hallway dimmer.',
    esign: { version: 1 },
  };
}

const OPTIONS_SELECTION = {
  tierId: 'better',
  tierName: 'Better',
  addOnIds: ['pan'],
  addOns: [{ id: 'pan', label: 'Drain pan', amount: 85 }],
  lineItems: [{ label: 'Labor', amount: 400 }, { label: '50 gal tank', amount: 1100 }, { label: 'Drain pan', amount: 85 }],
  total: 1585,
};

const EVENTS = [
  { type: 'link_created', at: '2026-10-02T12:00:00.000Z', actor: 'owner' },
  { type: 'viewed', at: '2026-10-03T13:58:41.512Z', ip: '203.0.113.9' },
];

// A stored, e-signed approval as respond writes it (minus recordDigest,
// which the tests compute and pin).
function signedApproval({ snapshot, token = 'tok_0123456789abcdef', recordId, consentVersion = 1, drawn = null, email = null, selection = null, signerName, ip = '203.0.113.9', events = EVENTS }) {
  const a = {
    token,
    sentAt: '2026-10-02T12:00:00.000Z',
    snapshot,
    decision: 'approved',
    consentAt: SIGNED_AT,
    signerName,
    ip,
    userAgent: 'Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15',
    signatureRecordId: recordId,
    signatureMethod: drawn ? 'typed_drawn' : 'typed',
    signatureEvidence: buildEvidence({ consentVersion, drawn, email, events }),
  };
  if (selection) a.selection = selection;
  return a;
}

const CASES = {
  estimate: () => ({
    jobId: 'job-esign-1',
    changeOrderId: null,
    documentType: 'estimate',
    approval: signedApproval({
      snapshot: estimateSnapshot(),
      recordId: '3f0c1a2b-1111-4222-8333-444455556666',
      drawn: clone(DRAWN),
      email: 'zoe@example.test',
      signerName: 'Zoë Ångström',
    }),
  }),
  options: () => ({
    jobId: 'job-esign-2',
    changeOrderId: null,
    documentType: 'estimate',
    approval: signedApproval({
      snapshot: optionsSnapshot(),
      recordId: '7d1e2f30-2222-4333-9444-555566667777',
      selection: clone(OPTIONS_SELECTION),
      signerName: 'Pat Lee',
    }),
  }),
  changeOrder: () => ({
    jobId: 'job-esign-3',
    changeOrderId: 'co-1',
    documentType: 'change_order',
    approval: signedApproval({
      snapshot: changeOrderSnapshot(),
      token: 'tok_change_0001',
      recordId: '9a8b7c6d-3333-4444-a555-666677778888',
      drawn: clone(DRAWN),
      signerName: 'Nguyễn Thị Minh Khai 👍',
      consentVersion: null,
      ip: null,
      events: [],
    }),
  }),
};

// The explicit, Worker-validated inputs respond / change-respond pass to
// buildRecord for a case (the record is never built from a stored approval).
function recordInputs({ approval, jobId, changeOrderId = null, documentType }) {
  const ev = approval.signatureEvidence;
  return {
    recordId: approval.signatureRecordId,
    documentType,
    jobId,
    changeOrderId,
    token: approval.token,
    snapshot: approval.snapshot,
    selection: approval.selection || null,
    consentVersion: ev.consentVersion,
    signedAt: approval.consentAt,
    typedName: approval.signerName,
    drawn: ev.drawn,
    email: ev.email,
    ip: approval.ip,
    userAgent: approval.userAgent,
    events: ev.events,
  };
}

function recordOf(c) {
  return buildRecord(recordInputs(c));
}

module.exports = {
  clone,
  FAKE_SEAL,
  SIGNED_AT,
  DRAWN,
  EVENTS,
  OPTIONS_SELECTION,
  estimateSnapshot,
  optionsSnapshot,
  changeOrderSnapshot,
  signedApproval,
  CASES,
  recordInputs,
  recordOf,
};

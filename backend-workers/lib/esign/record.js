// The canonical signature record (spec §3.5, record version 1). Pure.
//
// ONE builder, recordFromApproval, serves both the first seal in respond and
// the lazy re-seal in view / copy / the owner route: everything the record
// holds is read from the stored approval (decision keys, frozen snapshot and
// the server-owned `signatureEvidence`), so a re-seal reproduces the same
// record and the same digest byte for byte. recordDigest = SHA-256 of
// quoteOptions.canonicalJson(record), the encoding the snapshot digest uses.
//
// Additions to the §3.5 shape, decided at build time (spec §11.3):
//   - consent.text: the exact disclosure rendering that consent.textSha256
//     hashes, so the record is self-contained evidence of what was agreed to.
//   - consent and intent are null when the signer used a page from before
//     Phase 19 (no checkbox, no intent statement was shown).
//   - events[].actor: 'owner' on link_created (no owner IP is recorded).

const { createHash } = require('node:crypto');
const { canonicalJson, snapshotDigest } = require('../estimate/quoteOptions.js');
const { signingTexts } = require('./texts.js');

const RECORD_VERSION = 1;
const EVIDENCE_VERSION = 1;
const RENDERER = 'pdf-v1';
const CONTEXT_REMOTE_LINK = 'remote_link';
const MAX_RECORD_EVENTS = 50;
const RECORD_EVENT_TYPES = ['link_created', 'viewed', 'declined'];
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;
const DIGEST_RE = /^[0-9a-f]{64}$/;

function isPlainObject(v) {
  return v !== null && typeof v === 'object' && !Array.isArray(v);
}

function sha256Hex(text) {
  return createHash('sha256').update(String(text), 'utf8').digest('hex');
}

function tokenSha256(token) {
  return sha256Hex(String(token));
}

function isRecordId(v) {
  return typeof v === 'string' && UUID_RE.test(v);
}

function isDigest(v) {
  return typeof v === 'string' && DIGEST_RE.test(v);
}

// PostgREST timestamps ("2026-10-03T14:05:09.123456+00:00") → ISO with
// milliseconds, so the stored evidence has one stable spelling.
function isoAt(value) {
  const ms = Date.parse(String(value));
  return Number.isFinite(ms) ? new Date(ms).toISOString() : null;
}

// signature_events rows → the trail sealed into the record: the link being
// created (owner), customer views and declines, oldest first, capped.
function eventsForRecord(rows) {
  const list = (Array.isArray(rows) ? rows : [])
    .filter((r) => isPlainObject(r) && RECORD_EVENT_TYPES.includes(r.event) && isoAt(r.created_at))
    .map((r, i) => ({ r, i, at: isoAt(r.created_at) }))
    .sort((a, b) => (a.at < b.at ? -1 : a.at > b.at ? 1 : a.i - b.i))
    .slice(0, MAX_RECORD_EVENTS);
  return list.map(({ r, at }) => (r.event === 'link_created'
    ? { type: 'link_created', at, actor: 'owner' }
    : { type: r.event, at, ip: typeof r.ip === 'string' && r.ip ? r.ip : null }));
}

// The server-owned approval key that lets the record be rebuilt later.
function buildEvidence({ consentVersion = null, drawn = null, email = null, events = [] }) {
  return {
    v: EVIDENCE_VERSION,
    consentVersion: consentVersion || null,
    drawn: drawn || null,
    email: email || null,
    events: Array.isArray(events) ? events : [],
  };
}

function hasEvidence(approval) {
  return isPlainObject(approval)
    && approval.decision === 'approved'
    && isRecordId(approval.signatureRecordId)
    && isPlainObject(approval.signatureEvidence)
    && approval.signatureEvidence.v === EVIDENCE_VERSION;
}

function signatureMethodFor(drawn) {
  return drawn ? 'typed_drawn' : 'typed';
}

// Returns the canonical record object, or null when the approval carries no
// e-signature evidence (a legacy typed-name approval).
function recordFromApproval({ approval, jobId, changeOrderId = null, documentType }) {
  if (!hasEvidence(approval)) return null;
  const ev = approval.signatureEvidence;
  const snapshot = approval.snapshot;
  const t = ev.consentVersion ? signingTexts(snapshot, documentType, ev.consentVersion) : null;
  return {
    recordVersion: RECORD_VERSION,
    recordId: approval.signatureRecordId,
    documentType,
    jobId: String(jobId),
    changeOrderId: changeOrderId == null ? null : String(changeOrderId),
    approvalTokenSha256: tokenSha256(approval.token),
    document: snapshot,
    documentDigest: snapshotDigest(snapshot),
    selection: isPlainObject(approval.selection) ? approval.selection : null,
    consent: t
      ? { version: t.version, text: t.disclosureText, textSha256: sha256Hex(t.disclosureText), acceptedAt: approval.consentAt }
      : null,
    intent: t ? { text: t.intent, textSha256: sha256Hex(t.intent) } : null,
    signer: {
      typedName: approval.signerName,
      drawn: ev.drawn || null,
      email: ev.email || null,
    },
    signatureMethod: signatureMethodFor(ev.drawn),
    signedAt: approval.consentAt,
    ip: typeof approval.ip === 'string' && approval.ip ? approval.ip : null,
    userAgent: typeof approval.userAgent === 'string' ? approval.userAgent : '',
    context: CONTEXT_REMOTE_LINK,
    events: Array.isArray(ev.events) ? ev.events : [],
    renderer: RENDERER,
  };
}

// Adds the server-owned e-signature keys to an approval the decision merge
// just produced (respond / change-respond, approve only) and builds the
// record those keys describe. Pure: `recordId` is pre-minted by the caller.
// Returns { approval, record, digest }.
function signApproval(merged, { recordId, consent = null, drawn = null, email = null, events = [], jobId, changeOrderId = null, documentType }) {
  const approval = {
    ...merged,
    signatureRecordId: recordId,
    signatureMethod: signatureMethodFor(drawn),
    signatureEvidence: buildEvidence({ consentVersion: consent ? consent.version : null, drawn, email, events }),
  };
  delete approval.recordDigest;
  const record = recordFromApproval({ approval, jobId, changeOrderId, documentType });
  const digest = recordDigest(record);
  approval.recordDigest = digest;
  return { approval, record, digest };
}

function canonicalRecordJson(record) {
  return canonicalJson(record);
}

function recordDigest(record) {
  return sha256Hex(canonicalJson(record));
}

module.exports = {
  RECORD_VERSION,
  EVIDENCE_VERSION,
  RENDERER,
  MAX_RECORD_EVENTS,
  sha256Hex,
  tokenSha256,
  isRecordId,
  isDigest,
  isoAt,
  eventsForRecord,
  buildEvidence,
  hasEvidence,
  signatureMethodFor,
  recordFromApproval,
  signApproval,
  canonicalRecordJson,
  recordDigest,
};

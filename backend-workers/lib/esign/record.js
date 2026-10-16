// The canonical signature record (spec §3.5, record version 1). Pure.
//
// ONE builder, buildRecord, called by respond / change-respond (through
// signApproval) with EXPLICIT, Worker-validated inputs only: the typed name,
// consent, drawing and email the customer submitted, the server clock, the
// edge IP and user agent of the signing request, the trail read for this
// link, the frozen snapshot the customer was shown (digest-checked by the
// route) and the selection the server itself resolved from the customer's
// submitted choice against that snapshot. Nothing is read from the stored
// approval (`jobs.data.approval`): the owner's JWT can write that blob, so a
// field planted there (a `selection`, a signer, a trail) must never reach a
// sealed record (spec §11.10, §11.11). A lazy seal uses only the record the
// Worker stored in `signature_pending` before the decision was written
// (service.js).
// recordDigest = SHA-256 of quoteOptions.canonicalJson(record), the encoding
// the snapshot digest uses.
//
// Additions to the §3.5 shape, decided at build time (spec §11.3):
//   - consent.text: the exact disclosure rendering that consent.textSha256
//     hashes, so the record is self-contained evidence of what was agreed to.
//   - consent and intent are null when the signer used a page from before
//     Phase 19 (no checkbox, no intent statement was shown).
//   - events[].actor: 'owner' on link_created (no owner IP is recorded).

const { createHash } = require('node:crypto');
const { canonicalJson, snapshotDigest, hasSnapshotOptions, resolveSelection } = require('../estimate/quoteOptions.js');
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

// The server-owned approval key: an informational, unsealed copy of the
// signing inputs for the owner app. Never an input to a seal.
function buildEvidence({ consentVersion = null, drawn = null, email = null, events = [] }) {
  return {
    v: EVIDENCE_VERSION,
    consentVersion: consentVersion || null,
    drawn: drawn || null,
    email: email || null,
    events: Array.isArray(events) ? events : [],
  };
}

function signatureMethodFor(drawn) {
  return drawn ? 'typed_drawn' : 'typed';
}

const DOCUMENT_TYPES = ['estimate', 'change_order'];

// The only selection a record may carry: the customer's choice re-resolved
// against the frozen snapshot. A change order, or an estimate without
// options, has none, whatever the caller passes. An options estimate must be
// signed with a choice that resolves to exactly `selection`.
function sealedSelection(snapshot, documentType, selection) {
  if (documentType !== 'estimate' || !hasSnapshotOptions(snapshot)) return null;
  if (!isPlainObject(selection)) throw new Error('an options estimate is signed only with a resolved choice');
  const again = resolveSelection(snapshot, { tierId: selection.tierId, addOnIds: selection.addOnIds });
  if (again.error || canonicalJson(again.selection) !== canonicalJson(selection)) {
    throw new Error('the selection does not resolve against the signed snapshot');
  }
  return again.selection;
}

// Returns the canonical record. Throws on inputs the routes never produce
// (a programming error, never a customer error).
function buildRecord({
  recordId, documentType, jobId, changeOrderId = null, token, snapshot, selection = null,
  consentVersion = null, signedAt, typedName, drawn = null, email = null, ip = null, userAgent = '', events = [],
}) {
  if (!isRecordId(recordId)) throw new Error('record id must be a v4 uuid');
  if (!DOCUMENT_TYPES.includes(documentType)) throw new Error('unknown document type');
  if ((documentType === 'change_order') !== (changeOrderId != null)) throw new Error('change order id iff change order');
  if (typeof token !== 'string' || !token) throw new Error('record without a token');
  if (!isPlainObject(snapshot)) throw new Error('record without a snapshot');
  if (typeof typedName !== 'string' || !typedName) throw new Error('record without a typed name');
  if (!isoAt(signedAt) || isoAt(signedAt) !== signedAt) throw new Error('signedAt must be an ISO timestamp');
  const t = consentVersion ? signingTexts(snapshot, documentType, consentVersion) : null;
  return {
    recordVersion: RECORD_VERSION,
    recordId,
    documentType,
    jobId: String(jobId),
    changeOrderId: changeOrderId == null ? null : String(changeOrderId),
    approvalTokenSha256: tokenSha256(token),
    document: snapshot,
    documentDigest: snapshotDigest(snapshot),
    selection: sealedSelection(snapshot, documentType, selection),
    consent: t
      ? { version: t.version, text: t.disclosureText, textSha256: sha256Hex(t.disclosureText), acceptedAt: signedAt }
      : null,
    intent: t ? { text: t.intent, textSha256: sha256Hex(t.intent) } : null,
    signer: {
      typedName,
      drawn: drawn || null,
      email: email || null,
    },
    signatureMethod: signatureMethodFor(drawn),
    signedAt,
    ip: typeof ip === 'string' && ip ? ip : null,
    userAgent: typeof userAgent === 'string' ? userAgent : '',
    context: CONTEXT_REMOTE_LINK,
    events: Array.isArray(events) ? events : [],
    renderer: RENDERER,
  };
}

// The e-signed approval the routes write: the decision merge's result with
// every signature-bearing key taken FROM THE RECORD (so the stored approval
// and the sealed record agree by construction), plus the server-owned keys.
// Pure: `recordId` is pre-minted by the caller. Returns { approval, record,
// digest }.
function signApproval(merged, inputs) {
  const record = buildRecord(inputs);
  const digest = recordDigest(record);
  const approval = {
    ...merged,
    consentAt: record.signedAt,
    signerName: record.signer.typedName,
    ip: record.ip,
    userAgent: record.userAgent,
    signatureRecordId: record.recordId,
    signatureMethod: record.signatureMethod,
    signatureEvidence: buildEvidence({
      consentVersion: record.consent ? record.consent.version : null,
      drawn: record.signer.drawn,
      email: record.signer.email,
      events: record.events,
    }),
    recordDigest: digest,
  };
  if (record.selection) approval.selection = record.selection;
  else delete approval.selection;
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
  signatureMethodFor,
  sealedSelection,
  buildRecord,
  signApproval,
  canonicalRecordJson,
  recordDigest,
};

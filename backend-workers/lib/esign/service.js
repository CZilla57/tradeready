// E-signature orchestration over the pure modules (record, seal, pdf,
// copyEmail) and the stores. Used by the estimate / change-order routes and
// the /api/esign/* routes.
//
// Write order (D13): the customer's decision is written to the job first and
// is authoritative. Sealing and the record insert come after; when they fail
// the response still succeeds with `recordPending`, and the next view / copy
// / owner fetch re-seals lazily from the stored approval (ensureRecord). The
// insert is idempotent on the token hash and Ed25519 is deterministic, so a
// re-seal yields the same row.

const { Buffer } = require('node:buffer');
const store = require('./store.js');
const { constantTimeEqual } = require('../constantTime.js');
const {
  recordFromApproval,
  recordDigest,
  tokenSha256,
  hasEvidence,
  eventsForRecord,
} = require('./record.js');
const { sealDigest } = require('./seal.js');
const { renderSignedPdf, signedPdfFilename } = require('./pdf.js');
const { buildCopyEmail } = require('./copyEmail.js');

const VIEW_EVENT_CAP = 20;

function isPlainObject(v) {
  return v !== null && typeof v === 'object' && !Array.isArray(v);
}

function sealOf(row) {
  return row && row.seal ? { alg: row.seal_alg || 'Ed25519', keyId: row.seal_key_id, signature: row.seal } : null;
}

function rowFor({ userId, record, digest, seal }) {
  return {
    id: record.recordId,
    user_id: userId,
    approval_token_sha256: record.approvalTokenSha256,
    job_id: record.jobId,
    change_order_id: record.changeOrderId,
    document_type: record.documentType,
    record,
    record_digest: digest,
    seal_alg: seal.alg,
    seal_key_id: seal.keyId,
    seal: seal.signature,
    signed_at: record.signedAt,
  };
}

// Never throws. { seal, row, stored }: `seal` is null when the key is not
// usable; `stored` is false when the insert failed (the seal may still be
// good — the emailed copy then carries it).
async function sealAndStore(env, { userId, record, digest }) {
  let seal;
  try {
    seal = await sealDigest(env, digest);
  } catch (err) {
    console.error('[esign] seal unavailable:', err.message);
    return { seal: null, row: null, stored: false };
  }
  const row = rowFor({ userId, record, digest, seal });
  try {
    if (await store.insertRecord(env, row)) return { seal, row, stored: true };
    // A record for this link already exists (a concurrent or earlier seal).
    const existing = await store.fetchRecordByTokenHash(env, record.approvalTokenSha256);
    if (!existing) throw new Error('insert ignored but no record found');
    if (existing.id !== record.recordId || existing.record_digest !== digest) {
      console.error('[esign] a different record already exists for this link; keeping the first');
    }
    return { seal: sealOf(existing), row: existing, stored: true };
  } catch (err) {
    console.error('[esign] record insert failed:', err.message);
    return { seal, row: null, stored: false };
  }
}

// Lazy seal from a stored approval. Returns:
//   null                    the approval has no e-signature evidence (legacy)
//   { row }                 the sealed record (found, or sealed now)
//   { pending: true }       it should exist but can't be sealed yet
async function ensureRecord(env, { userId, jobId, changeOrderId = null, documentType, approval }) {
  if (!hasEvidence(approval)) return null;
  const tokenHash = tokenSha256(approval.token);
  try {
    const existing = await store.fetchRecordByTokenHash(env, tokenHash);
    if (existing) return { row: existing };
  } catch (err) {
    console.error('[esign] record lookup failed:', err.message);
    return { pending: true };
  }
  const record = recordFromApproval({ approval, jobId, changeOrderId, documentType });
  const digest = recordDigest(record);
  if (approval.recordDigest !== digest) {
    // Never seal something other than what the approval committed to.
    console.error('[esign] stored approval no longer reproduces its record digest; not sealing');
    return { pending: true };
  }
  const out = await sealAndStore(env, { userId, record, digest });
  return out.stored ? { row: out.row } : { pending: true };
}

// Runs work after the response when the runtime offers waitUntil (Workers);
// without an execution context (tests, local) the promise simply runs.
function afterResponse(c, promise) {
  const p = Promise.resolve(promise).catch((err) => console.error('[esign] background task failed:', err.message));
  try {
    c.executionCtx.waitUntil(p);
  } catch {
    // no ExecutionContext — p still runs to completion on its own
  }
  return p;
}

// The trail sealed into a new record. A failed read degrades to an empty
// trail rather than blocking the signature.
async function eventsAtSigning(env, tokenHash) {
  try {
    return eventsForRecord(await store.listEvents(env, tokenHash, { limit: 100 }));
  } catch (err) {
    console.error('[esign] event trail read failed:', err.message);
    return [];
  }
}

// `viewed`, logged for the first VIEW_EVENT_CAP views of a link only.
async function logViewCapped(env, { userId, tokenHash, ip, userAgent }) {
  try {
    const seen = await store.listEvents(env, tokenHash, { event: 'viewed', limit: VIEW_EVENT_CAP });
    if (seen.length >= VIEW_EVENT_CAP) return;
  } catch (err) {
    console.error('[esign] view count failed:', err.message);
    return;
  }
  await store.logEvent(env, { userId, tokenHash, event: 'viewed', ip, userAgent });
}

function signedPdfOf(row) {
  return renderSignedPdf({ record: row.record, recordDigest: row.record_digest, seal: sealOf(row) });
}

// The downloadable JSON: the record plus what it takes to check it.
function envelopeOf(row) {
  return {
    format: 'tradeready-esign-record',
    version: 1,
    recordId: row.id,
    recordDigest: row.record_digest,
    seal: sealOf(row),
    record: row.record,
  };
}

async function sendCopyEmail(env, { userId, record, digest, seal }) {
  const tokenHash = record.approvalTokenSha256;
  try {
    if (!env.RESEND_API_KEY) throw new Error('RESEND_API_KEY not configured');
    const bytes = renderSignedPdf({ record, recordDigest: digest, seal });
    const email = buildCopyEmail({
      record,
      recordDigest: digest,
      pdfBase64: Buffer.from(bytes).toString('base64'),
      filename: signedPdfFilename(record),
    });
    const res = await fetch('https://api.resend.com/emails', {
      method: 'POST',
      headers: { Authorization: `Bearer ${env.RESEND_API_KEY}`, 'Content-Type': 'application/json' },
      body: JSON.stringify(email),
    });
    // The status only: Resend's error body can echo the recipient address.
    if (!res.ok) throw new Error(`Resend ${res.status}`);
    await store.logEvent(env, { userId, tokenHash, event: 'copy_emailed' });
  } catch (err) {
    console.error('[esign] copy email failed:', err.message);
    await store.logEvent(env, { userId, tokenHash, event: 'copy_email_failed' });
  }
}

// After the decision write of an e-signed approval: seal + insert, log
// `signed`, and queue the emailed copy. Returns { recordPending }.
async function finishSigning(c, { userId, record, digest, email, ip, userAgent }) {
  const env = c.env;
  const out = await sealAndStore(env, { userId, record, digest });
  await store.logEvent(env, { userId, tokenHash: record.approvalTokenSha256, event: 'signed', ip, userAgent });
  if (email) afterResponse(c, sendCopyEmail(env, { userId, record, digest, seal: out.seal }));
  return { recordPending: !out.stored };
}

// Finds the approval a public link points at: the estimate approval, or one
// change order's when `changeOrderId` is given. Token compared in constant
// time. Returns { approval, documentType, changeOrderId } or null.
function approvalForLink(row, { changeOrderId = null, token }) {
  const data = row && isPlainObject(row.data) ? row.data : null;
  if (!data || typeof token !== 'string' || !token) return null;
  if (changeOrderId == null) {
    const a = data.approval;
    if (!isPlainObject(a) || !constantTimeEqual(a.token, token)) return null;
    return { approval: a, documentType: 'estimate', changeOrderId: null };
  }
  const cos = Array.isArray(data.changeOrders) ? data.changeOrders : [];
  const co = cos.find((x) => isPlainObject(x) && x.id === String(changeOrderId));
  const a = co && co.approval;
  if (!isPlainObject(a) || !constantTimeEqual(a.token, token)) return null;
  return { approval: a, documentType: 'change_order', changeOrderId: String(changeOrderId) };
}

// The signed-view block for view / change-view. No email or IP: the page
// only needs what it draws. Returns null for legacy approvals.
function signedViewOf(approval, ensured) {
  if (!hasEvidence(approval)) return null;
  const ev = approval.signatureEvidence;
  return {
    recordId: approval.signatureRecordId,
    recordDigest: approval.recordDigest,
    signatureMethod: approval.signatureMethod,
    signedAt: approval.consentAt,
    typedName: approval.signerName,
    drawn: ev.drawn || null,
    recordPending: !(ensured && ensured.row),
  };
}

module.exports = {
  VIEW_EVENT_CAP,
  sealOf,
  sealAndStore,
  ensureRecord,
  afterResponse,
  eventsAtSigning,
  logViewCapped,
  signedPdfOf,
  envelopeOf,
  sendCopyEmail,
  finishSigning,
  approvalForLink,
  signedViewOf,
};

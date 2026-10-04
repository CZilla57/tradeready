// E-signature orchestration over the pure modules (record, seal, pdf,
// copyEmail) and the stores. Used by the estimate / change-order routes and
// the /api/esign/* routes.
//
// Write order (D13): the customer's decision is written to the job first and
// is authoritative. The record is built in that same request from the
// Worker-validated inputs, then sealed and inserted. When sealing or the
// insert fails, the built record is stored in the service-role-only
// `signature_pending` table and the response still succeeds with
// `recordPending`; the next view / copy / owner fetch seals THAT row lazily
// (ensureRecord). The job blob is never an input to a seal: the owner's JWT
// can write it, so a self-consistent forged approval there must never be
// sealed as a customer signature (spec §11.10). The insert is idempotent per
// link and Ed25519 is deterministic, so a re-seal yields the same row.

const { Buffer } = require('node:buffer');
const store = require('./store.js');
const { constantTimeEqual } = require('../constantTime.js');
const { recordDigest, isRecordId, eventsForRecord } = require('./record.js');
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

// The link a record belongs to, as the store filters it.
function linkOfRecord(userId, record) {
  return {
    userId,
    jobId: record.jobId,
    changeOrderId: record.changeOrderId == null ? null : record.changeOrderId,
    tokenHash: record.approvalTokenSha256,
  };
}

function pendingRowFor({ userId, record, digest }) {
  return {
    id: record.recordId,
    user_id: userId,
    approval_token_sha256: record.approvalTokenSha256,
    job_id: record.jobId,
    change_order_id: record.changeOrderId,
    document_type: record.documentType,
    record,
    record_digest: digest,
    signed_at: record.signedAt,
  };
}

function rowFor({ userId, record, digest, seal }) {
  return {
    ...pendingRowFor({ userId, record, digest }),
    seal_alg: seal.alg,
    seal_key_id: seal.keyId,
    seal: seal.signature,
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
    const existing = await store.fetchRecordForLink(env, linkOfRecord(userId, record));
    if (!existing) throw new Error('insert ignored but no record found for this link');
    if (existing.id !== record.recordId || existing.record_digest !== digest) {
      console.error('[esign] a different record already exists for this link; keeping the first');
    }
    return { seal: sealOf(existing), row: existing, stored: true };
  } catch (err) {
    console.error('[esign] record insert failed:', err.message);
    return { seal, row: null, stored: false };
  }
}

// A pending row is sealed only when it is exactly what the Worker stored for
// THIS link: its record commits to its own columns and digest. (The table is
// service-role only; this is a second guard, not the first.)
function pendingMatchesLink(p, link) {
  if (!isPlainObject(p) || !isPlainObject(p.record) || !isRecordId(p.id)) return false;
  const r = p.record;
  const co = p.change_order_id == null ? null : String(p.change_order_id);
  return r.recordId === p.id
    && r.jobId === String(p.job_id) && p.job_id === String(link.jobId)
    && (r.changeOrderId == null ? null : r.changeOrderId) === co
    && co === (link.changeOrderId == null ? null : String(link.changeOrderId))
    && r.approvalTokenSha256 === p.approval_token_sha256
    && (link.tokenHash == null || p.approval_token_sha256 === link.tokenHash)
    && (link.userId == null || p.user_id === link.userId)
    && r.documentType === p.document_type
    && recordDigest(r) === p.record_digest;
}

// The sealed record of a link, sealing its Worker-held pending signature if
// that is all there is. `link` is { userId?, jobId, changeOrderId, tokenHash?,
// recordId? } (see store.linkQuery). NEVER reads the job. Returns:
//   null                    the Worker holds no signature for this link
//   { row }                 the sealed record (found, or sealed now)
//   { pending }             the Worker-held pending row; it can't be sealed yet
// Throws when the lookups fail (callers answer with a database error).
async function ensureRecord(env, link) {
  const existing = await store.fetchRecordForLink(env, link);
  if (existing) return { row: existing };
  const pending = await store.fetchPendingForLink(env, link);
  if (!pending) return null;
  if (!pendingMatchesLink(pending, link)) {
    console.error('[esign] pending signature does not match its link; not sealing');
    return null;
  }
  const out = await sealAndStore(env, { userId: pending.user_id, record: pending.record, digest: pending.record_digest });
  return out.stored ? { row: out.row } : { pending };
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

// The trail sealed into a new record: this link's events only (owner + job +
// change order + token hash). A failed read degrades to an empty trail
// rather than blocking the signature.
async function eventsAtSigning(env, link) {
  try {
    return eventsForRecord(await store.listEvents(env, link, { limit: 100 }));
  } catch (err) {
    console.error('[esign] event trail read failed:', err.message);
    return [];
  }
}

// `viewed`, logged for the first VIEW_EVENT_CAP views of a link only.
async function logViewCapped(env, { userId, jobId, changeOrderId = null, tokenHash, ip, userAgent }) {
  const link = { userId, jobId, changeOrderId, tokenHash };
  try {
    const seen = await store.listEvents(env, link, { event: 'viewed', limit: VIEW_EVENT_CAP });
    if (seen.length >= VIEW_EVENT_CAP) return;
  } catch (err) {
    console.error('[esign] view count failed:', err.message);
    return;
  }
  await store.logEvent(env, { ...link, event: 'viewed', ip, userAgent });
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
  const link = linkOfRecord(userId, record);
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
    await store.logEvent(env, { ...link, event: 'copy_emailed' });
  } catch (err) {
    console.error('[esign] copy email failed:', err.message);
    await store.logEvent(env, { ...link, event: 'copy_email_failed' });
  }
}

// After the decision write of an e-signed approval: seal + insert; when that
// fails, keep the Worker-built record in `signature_pending` (the only thing
// a later lazy seal may use); log `signed`; queue the emailed copy. Returns
// { recordPending }.
async function finishSigning(c, { userId, record, digest, email, ip, userAgent }) {
  const env = c.env;
  const out = await sealAndStore(env, { userId, record, digest });
  if (!out.stored) {
    try {
      await store.insertPending(env, pendingRowFor({ userId, record, digest }));
    } catch (err) {
      // The decision stands, but with no Worker-held evidence nothing will
      // ever be sealed for it: the signed view, copy and owner route say
      // "not signed" (spec §11.10 residual).
      console.error('[esign] pending signature could not be stored; this approval will not be sealed:', err.message);
    }
  }
  await store.logEvent(env, { ...linkOfRecord(userId, record), event: 'signed', ip, userAgent });
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

// Whether a stored approval says it was e-signed. Only a reason to LOOK for
// Worker-held evidence (a legacy typed-name approval causes no lookup); never
// evidence itself.
function claimsSignature(approval) {
  return isPlainObject(approval) && approval.decision === 'approved' && isRecordId(approval.signatureRecordId);
}

// The signed-view block for view / change-view, from the sealed record or
// the Worker-held pending row — never from the job blob. No email or IP: the
// page only needs what it draws. Null when the Worker holds no signature.
function signedViewOf(ensured) {
  if (!ensured) return null;
  const src = ensured.row || ensured.pending;
  const r = src && src.record;
  if (!isPlainObject(r)) return null;
  const signer = isPlainObject(r.signer) ? r.signer : {};
  return {
    recordId: src.id,
    recordDigest: src.record_digest,
    signatureMethod: r.signatureMethod,
    signedAt: r.signedAt,
    typedName: signer.typedName,
    drawn: signer.drawn || null,
    recordPending: !ensured.row,
  };
}

// view / change-view: the signed block for a link whose stored approval
// claims a signature, lazily sealing its pending row. Never throws; a failed
// lookup shows no signed block rather than the blob's claims.
async function signedViewForLink(env, approval, link) {
  if (!claimsSignature(approval)) return null;
  try {
    return signedViewOf(await ensureRecord(env, link));
  } catch (err) {
    console.error('[esign] signed view lookup failed:', err.message);
    return null;
  }
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
  claimsSignature,
  signedViewOf,
  signedViewForLink,
};

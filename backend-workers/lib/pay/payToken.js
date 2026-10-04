// Signed pay-page tokens (Phase 24 spec §4.2, D2). Pure.
//
// Format: <kind>.<base64url(JSON payload)>.<base64url(HMAC-SHA256(secret,
// "tr-pay|" + kind + "|" + payloadB64))>. The kind is inside the MAC, so a
// token can never be replayed as another kind. Compared with
// constantTimeEqual, following the lib/photoSign.js precedent.
//
//   p (pay)    {v:1, u: userId, i: invoiceId, a?: requestedCents,
//              b?: balanceCentsAtMint}                            no expiry
//              (`b` is added only to a partial ask such as a deposit, so a
//              deposit link stops asking for its deposit once any payment
//              has landed — an addition to the spec's payload)
//   s (setup)  {v:1, u, r: planId, c: customerId, x: expiresAtSec} 7-day expiry
//              (`c` binds the plan's customer at mint time, so a plan
//              reassigned inside the 7 days can't be set up by its old
//              customer — an addition to the spec's payload)
//   m (manage) {v:1, u, e: enrollmentId}                           no expiry
//
// The secret is the Worker secret PAY_LINK_SIGNING_SECRET (owner op, §9).
// It is deliberately NOT the portal photo secret, so rotations stay
// independent. Liveness (paid, deleted, disconnected, revoked) is always
// re-checked against the database at use time — a token only proves that
// TradeReady minted it for that owner and object.

const { createHmac } = require('node:crypto');
const { constantTimeEqual } = require('../constantTime.js');

const KINDS = new Set(['p', 's', 'm']);
const SETUP_TOKEN_TTL_SEC = 7 * 24 * 60 * 60;
// Ids are app/server-generated shapes; anything exotic is refused before a
// database lookup ever sees it.
const ID_RE = /^[A-Za-z0-9_-]{1,128}$/;
const UUID_RE = /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/;
const MAX_TOKEN_CHARS = 1024;
// Ten million dollars in cents — far above any honest invoice, far below
// anything that could overflow Stripe's integer amount.
const MAX_CENTS = 1_000_000_000;

function b64url(buf) {
  return Buffer.from(buf).toString('base64').replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

function fromB64url(s) {
  if (typeof s !== 'string' || !/^[A-Za-z0-9_-]+$/.test(s)) return null;
  try {
    return Buffer.from(s.replace(/-/g, '+').replace(/_/g, '/'), 'base64').toString('utf8');
  } catch {
    return null;
  }
}

function mac(secret, kind, payloadB64) {
  return b64url(createHmac('sha256', String(secret)).update(`tr-pay|${kind}|${payloadB64}`).digest());
}

function validPayload(kind, p) {
  if (!p || typeof p !== 'object' || Array.isArray(p) || p.v !== 1) return false;
  if (typeof p.u !== 'string' || !UUID_RE.test(p.u)) return false;
  if (kind === 'p') {
    if (typeof p.i !== 'string' || !ID_RE.test(p.i)) return false;
    if (p.a !== undefined && !(Number.isInteger(p.a) && p.a > 0 && p.a <= MAX_CENTS)) return false;
    if (p.b !== undefined && !(Number.isInteger(p.b) && p.b > 0 && p.b <= MAX_CENTS)) return false;
    return true;
  }
  if (kind === 's') {
    if (typeof p.r !== 'string' || !ID_RE.test(p.r)) return false;
    if (p.c !== undefined && (typeof p.c !== 'string' || !ID_RE.test(p.c))) return false;
    if (!Number.isInteger(p.x)) return false;
    return true;
  }
  if (kind === 'm') return typeof p.e === 'string' && UUID_RE.test(p.e);
  return false;
}

function signPayToken(secret, kind, payload) {
  if (!secret) throw new Error('PAY_LINK_SIGNING_SECRET is not configured');
  if (!KINDS.has(kind)) throw new Error(`unknown pay token kind ${kind}`);
  const body = { v: 1, ...payload };
  if (!validPayload(kind, body)) throw new Error(`invalid ${kind} token payload`);
  const payloadB64 = b64url(JSON.stringify(body));
  return `${kind}.${payloadB64}.${mac(secret, kind, payloadB64)}`;
}

// → { ok: true, kind, payload } | { ok: false, reason }
// reason: 'missing' | 'malformed' | 'kind' (wrong kind for this use) |
//         'signature' | 'expired' (setup tokens only; checked AFTER the MAC,
//         so an expired answer is never an oracle for a forged token).
function verifyPayToken(secret, token, { expectKind, nowSec = Math.floor(Date.now() / 1000) } = {}) {
  if (!secret) return { ok: false, reason: 'missing' };
  if (typeof token !== 'string' || token.length === 0) return { ok: false, reason: 'missing' };
  if (token.length > MAX_TOKEN_CHARS) return { ok: false, reason: 'malformed' };
  const parts = token.split('.');
  if (parts.length !== 3) return { ok: false, reason: 'malformed' };
  const [kind, payloadB64, sig] = parts;
  if (!KINDS.has(kind)) return { ok: false, reason: 'malformed' };
  if (!constantTimeEqual(mac(secret, kind, payloadB64), sig)) return { ok: false, reason: 'signature' };
  if (expectKind && kind !== expectKind) return { ok: false, reason: 'kind' };
  const json = fromB64url(payloadB64);
  let payload;
  try {
    payload = JSON.parse(json);
  } catch {
    return { ok: false, reason: 'malformed' };
  }
  if (!validPayload(kind, payload)) return { ok: false, reason: 'malformed' };
  if (kind === 's' && nowSec > payload.x) return { ok: false, reason: 'expired', kind, payload };
  return { ok: true, kind, payload };
}

const mintInvoicePayToken = (secret, { userId, invoiceId, cents, balanceCents }) =>
  signPayToken(secret, 'p', {
    u: userId,
    i: invoiceId,
    ...(cents ? { a: cents } : {}),
    ...(cents && balanceCents && cents < balanceCents ? { b: balanceCents } : {}),
  });

// The amount a `p` token charges now (spec §4.4: min(requested, live
// balance)). A partial ask (`a` below the mint-time balance `b`) is stale once
// the balance has dropped since minting — the deposit was paid, or another
// payment landed — and then the link asks for the live balance instead of a
// second deposit. → { cents, depositCents }.
function tokenCharge(payload, liveBalanceCents) {
  const a = payload.a;
  if (!a) return { cents: liveBalanceCents, depositCents: null };
  if (payload.b && liveBalanceCents < payload.b) return { cents: liveBalanceCents, depositCents: null };
  const cents = Math.min(a, liveBalanceCents);
  return { cents, depositCents: a < liveBalanceCents ? a : null };
}
const mintSetupToken = (secret, { userId, planId, customerId, nowSec = Math.floor(Date.now() / 1000) }) =>
  signPayToken(secret, 's', { u: userId, r: planId, ...(customerId ? { c: customerId } : {}), x: nowSec + SETUP_TOKEN_TTL_SEC });
const mintManageToken = (secret, { userId, enrollmentId }) =>
  signPayToken(secret, 'm', { u: userId, e: enrollmentId });

// Public pay page (spec §4.3): PAY_PUBLIC_BASE when set, else derived from
// ESTIMATE_PUBLIC_BASE the way createLink derives CHANGE_PUBLIC_BASE (swap
// the filename), else the apex. Only gettradereadyapp.com/pay(.html) passes
// the email/portal link allowlist (reminderEmail.js isAllowedPaymentLink).
const DEFAULT_PAY_PUBLIC_BASE = 'https://gettradereadyapp.com/pay.html';
function payPublicBase(env = {}) {
  if (env.PAY_PUBLIC_BASE) return String(env.PAY_PUBLIC_BASE);
  const estimateBase = env.ESTIMATE_PUBLIC_BASE ? String(env.ESTIMATE_PUBLIC_BASE) : '';
  if (/estimate\.html$/.test(estimateBase)) return estimateBase.replace(/estimate\.html$/, 'pay.html');
  return DEFAULT_PAY_PUBLIC_BASE;
}

function payPageUrl(env, param, token) {
  return `${payPublicBase(env)}?${param}=${encodeURIComponent(token)}`;
}

module.exports = {
  tokenCharge,
  signPayToken,
  verifyPayToken,
  mintInvoicePayToken,
  mintSetupToken,
  mintManageToken,
  payPublicBase,
  payPageUrl,
  SETUP_TOKEN_TTL_SEC,
  MAX_CENTS,
  ID_RE,
  UUID_RE,
  DEFAULT_PAY_PUBLIC_BASE,
};

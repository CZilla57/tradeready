// The client address recorded as signature evidence (spec §3.5, D9).
//
// cf-connecting-ip is set by Cloudflare's edge and cannot be supplied by the
// caller. Unlike appCors.clientIp (rate limiting), this NEVER falls back to
// x-forwarded-for: Cloudflare appends to a caller-sent x-forwarded-for, so
// its first entry is attacker-chosen. No edge header (local runs) → null.

const MAX_IP_CHARS = 64;
const IP_RE = /^[0-9A-Fa-f:.]+$/;

function edgeClientIp(c) {
  const raw = (c && c.req && typeof c.req.header === 'function' && c.req.header('cf-connecting-ip')) || '';
  const ip = String(raw).trim();
  if (!ip || ip.length > MAX_IP_CHARS || !IP_RE.test(ip)) return null;
  return ip;
}

module.exports = { edgeClientIp };

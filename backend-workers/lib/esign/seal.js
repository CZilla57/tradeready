// Ed25519 seal over a record digest (spec §3.5, D6). WebCrypto only — the
// same code runs in Workers and in Node's test runner.
//
// The signed message is the 32 raw bytes of the SHA-256 record digest (the
// hex `recordDigest`, hex-decoded). No domain prefix: verify.html and any
// independent verifier use exactly that message.
//
// Configuration (owner, stage B — decision 19-Q10; never in the repo):
//   ESIGN_SEAL_PRIVATE_KEY  secret: PKCS#8 Ed25519 private key, PEM or bare
//                           base64 DER (`wrangler secret put`).
//   ESIGN_SEAL_KEY_ID       var: id of that key, e.g. "k2026-10".
//   ESIGN_SEAL_PUBLIC_KEYS  var: JSON {"<keyId>": "<base64 raw 32-byte public
//                           key>", ...} — every key ever used, so old seals
//                           keep verifying after a rotation.
// A seal is only produced when the current key id's published public key
// verifies it, so a mis-paired configuration can never mint seals nobody can
// check; the record then stays pending and is sealed lazily once fixed.

const { Buffer } = require('node:buffer');
const ALG = 'Ed25519';
const SPKI_PREFIX_HEX = '302a300506032b6570032100';
const KEY_ID_RE = /^[A-Za-z0-9._-]{1,64}$/;

class SealUnavailableError extends Error {
  constructor(message) {
    super(message);
    this.name = 'SealUnavailableError';
  }
}

function subtle() {
  const s = globalThis.crypto && globalThis.crypto.subtle;
  if (!s) throw new SealUnavailableError('WebCrypto unavailable');
  return s;
}

function hexToBytes(hex) {
  if (typeof hex !== 'string' || !/^[0-9a-f]*$/.test(hex) || hex.length % 2) throw new Error('bad hex');
  const out = new Uint8Array(hex.length / 2);
  for (let i = 0; i < out.length; i += 1) out[i] = parseInt(hex.slice(i * 2, i * 2 + 2), 16);
  return out;
}

function bytesToBase64(bytes) {
  return Buffer.from(bytes).toString('base64');
}

function base64ToBytes(b64) {
  if (typeof b64 !== 'string' || !/^[A-Za-z0-9+/=_-]+$/.test(b64.replace(/\s+/g, ''))) throw new Error('bad base64');
  const norm = b64.replace(/\s+/g, '').replace(/-/g, '+').replace(/_/g, '/');
  return new Uint8Array(Buffer.from(norm, 'base64'));
}

function pemOrBase64ToDer(text) {
  const body = String(text || '')
    .replace(/-----BEGIN [A-Z ]+-----/g, '')
    .replace(/-----END [A-Z ]+-----/g, '')
    .replace(/\s+/g, '');
  return base64ToBytes(body);
}

function spkiFromRaw(raw) {
  const prefix = hexToBytes(SPKI_PREFIX_HEX);
  const out = new Uint8Array(prefix.length + raw.length);
  out.set(prefix, 0);
  out.set(raw, prefix.length);
  return out;
}

// { keyId: Uint8Array(32) } from ESIGN_SEAL_PUBLIC_KEYS; malformed → {}.
function publicKeyMap(env) {
  let parsed;
  try {
    parsed = JSON.parse(String((env && env.ESIGN_SEAL_PUBLIC_KEYS) || '{}'));
  } catch {
    return {};
  }
  const out = {};
  if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) return out;
  for (const [keyId, value] of Object.entries(parsed)) {
    if (!KEY_ID_RE.test(keyId)) continue;
    try {
      const raw = base64ToBytes(String(value));
      if (raw.length === 32) out[keyId] = raw;
    } catch {
      // skip a malformed entry
    }
  }
  return out;
}

// For GET /api/esign/public-keys. Sorted by key id for a stable response.
function publicKeys(env) {
  const map = publicKeyMap(env);
  return Object.keys(map).sort().map((keyId) => ({
    keyId,
    alg: ALG,
    publicKey: bytesToBase64(map[keyId]),
    spki: bytesToBase64(spkiFromRaw(map[keyId])),
  }));
}

async function signWithPkcs8(der, digestHex) {
  const key = await subtle().importKey('pkcs8', der, { name: ALG }, false, ['sign']);
  const sig = await subtle().sign({ name: ALG }, key, hexToBytes(digestHex));
  return bytesToBase64(new Uint8Array(sig));
}

async function verifyWithRaw(raw, digestHex, signatureB64) {
  try {
    const key = await subtle().importKey('raw', raw, { name: ALG }, false, ['verify']);
    const sig = base64ToBytes(signatureB64);
    if (sig.length !== 64) return false;
    return await subtle().verify({ name: ALG }, key, sig, hexToBytes(digestHex));
  } catch {
    return false;
  }
}

// Seals a 64-hex digest with the configured key. Throws SealUnavailableError
// when the key is missing, unusable, or doesn't match its published public
// key. Ed25519 is deterministic: re-sealing the same digest with the same key
// gives the same signature.
async function sealDigest(env, digestHex) {
  const keyId = String((env && env.ESIGN_SEAL_KEY_ID) || '').trim();
  const pkcs8 = env && env.ESIGN_SEAL_PRIVATE_KEY;
  if (!pkcs8 || !KEY_ID_RE.test(keyId)) throw new SealUnavailableError('seal key not configured');
  const publicRaw = publicKeyMap(env)[keyId];
  if (!publicRaw) throw new SealUnavailableError(`no published public key for ${keyId}`);
  let signature;
  try {
    signature = await signWithPkcs8(pemOrBase64ToDer(pkcs8), digestHex);
  } catch (err) {
    throw new SealUnavailableError(`seal failed: ${err.message}`);
  }
  if (!(await verifyWithRaw(publicRaw, digestHex, signature))) {
    throw new SealUnavailableError(`private key does not match the published key ${keyId}`);
  }
  return { alg: ALG, keyId, signature };
}

async function verifySeal(env, digestHex, keyId, signatureB64) {
  const raw = publicKeyMap(env)[keyId];
  if (!raw) return false;
  return verifyWithRaw(raw, digestHex, signatureB64);
}

module.exports = {
  ALG,
  SealUnavailableError,
  hexToBytes,
  bytesToBase64,
  base64ToBytes,
  spkiFromRaw,
  publicKeyMap,
  publicKeys,
  signWithPkcs8,
  verifyWithRaw,
  sealDigest,
  verifySeal,
};

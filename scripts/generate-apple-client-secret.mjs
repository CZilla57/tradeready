#!/usr/bin/env node
// Generate an Apple "Sign in with Apple" client secret (a signed JWT) for use
// as the OAuth Secret Key in Supabase's Apple auth provider.
//
// Apple client secrets are ES256-signed JWTs that EXPIRE (Apple caps the
// lifetime at 6 months / ~15777000s), so this needs to be re-run to rotate.
//
// Zero dependencies — uses Node's built-in crypto (Node 16+).
//
// Usage:
//   node scripts/generate-apple-client-secret.mjs \
//     --team-id   1A2BC3D4EF \
//     --key-id    ABC123DEFG \
//     --services-id com.gettradereadyapp.tradeready.web \
//     --p8        ./AuthKey_ABC123DEFG.p8
//
// Or via env vars: APPLE_TEAM_ID, APPLE_KEY_ID, APPLE_SERVICES_ID, APPLE_P8_PATH
//
// Paste the printed JWT into:
//   Supabase → Authentication → Providers → Apple → "Secret Key (for OAuth)"

import { createSign } from 'node:crypto';
import { readFileSync } from 'node:fs';

function arg(name, envName) {
  const flag = `--${name}`;
  const i = process.argv.indexOf(flag);
  if (i !== -1 && process.argv[i + 1]) return process.argv[i + 1];
  if (envName && process.env[envName]) return process.env[envName];
  return null;
}

const teamId = arg('team-id', 'APPLE_TEAM_ID');
const keyId = arg('key-id', 'APPLE_KEY_ID');
const servicesId = arg('services-id', 'APPLE_SERVICES_ID');
const p8Path = arg('p8', 'APPLE_P8_PATH');

const missing = [
  ['--team-id', teamId],
  ['--key-id', keyId],
  ['--services-id', servicesId],
  ['--p8', p8Path],
].filter(([, v]) => !v).map(([k]) => k);

if (missing.length) {
  console.error(`Missing required: ${missing.join(', ')}`);
  console.error('Run with --help-style flags or the APPLE_* env vars (see header).');
  process.exit(1);
}

const privateKey = readFileSync(p8Path, 'utf8');

const base64url = (input) =>
  Buffer.from(input)
    .toString('base64')
    .replace(/=/g, '')
    .replace(/\+/g, '-')
    .replace(/\//g, '_');

const now = Math.floor(Date.now() / 1000);
const SIX_MONTHS = 15777000; // Apple's maximum allowed lifetime, in seconds.

const header = { alg: 'ES256', kid: keyId };
const payload = {
  iss: teamId,
  iat: now,
  exp: now + SIX_MONTHS,
  aud: 'https://appleid.apple.com',
  sub: servicesId, // <-- MUST be the Services ID, not the app Bundle ID.
};

const signingInput = `${base64url(JSON.stringify(header))}.${base64url(
  JSON.stringify(payload),
)}`;

// ES256 JWTs require the raw (IEEE P1363 / JOSE) signature format, not DER.
const signature = createSign('SHA256')
  .update(signingInput)
  .sign({ key: privateKey, dsaEncoding: 'ieee-p1363' });

const jwt = `${signingInput}.${base64url(signature)}`;

console.log('\nApple client secret JWT (sub = ' + servicesId + '):\n');
console.log(jwt);
console.log(
  `\nExpires: ${new Date((now + SIX_MONTHS) * 1000).toISOString()} — regenerate before then.\n`,
);

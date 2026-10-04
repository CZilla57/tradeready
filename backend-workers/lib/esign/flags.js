// E-signature rollout flags (Roadmap Phase 19, spec
// docs/superpowers/specs/2026-10-03-esignature-upgrade-design.md §8).
//
// Both default OFF: an absent or unrecognized value is off. They are plain
// Worker vars (not secrets), set by the owner at stage C.
//   ESIGN_V2               consent, sealed records and events for snapshots
//                          that carry `esign` (the native Phase 19 build).
//   ESIGN_REQUIRE_CONSENT  with ESIGN_V2 on, every approval must carry consent
//                          (legacy snapshots too); an old cached page gets
//                          400 "Please reload the page".

function flagOn(value) {
  if (value === true) return true;
  return typeof value === 'string' && ['1', 'true', 'on', 'yes'].includes(value.trim().toLowerCase());
}

function esignV2(env) {
  return flagOn(env && env.ESIGN_V2);
}

function esignRequireConsent(env) {
  return esignV2(env) && flagOn(env && env.ESIGN_REQUIRE_CONSENT);
}

function isPlainObject(v) {
  return v !== null && typeof v === 'object' && !Array.isArray(v);
}

// Whether this approval goes through the e-signature path: ESIGN_V2 is on
// and either the snapshot asks for it (`esign`) or consent is now required
// for everyone. Off → every route behaves exactly as before Phase 19.
function esignActive(env, snapshot) {
  if (!esignV2(env)) return false;
  if (isPlainObject(snapshot) && isPlainObject(snapshot.esign)) return true;
  return esignRequireConsent(env);
}

module.exports = { flagOn, esignV2, esignRequireConsent, esignActive };

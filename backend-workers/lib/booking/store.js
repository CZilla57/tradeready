// Supabase access for the booking endpoints. Service role (bypasses RLS),
// exactly like ../estimateStore.js.
//
// The booking token lives INSIDE the owner's settings blob and is written
// only by the device (normal settings sync). The server resolves it with a
// PostgREST JSON-path filter and never writes settings — that one-way flow is
// what makes token rotation race-free (spec §4).
//
// Workers port of backend/lib/booking/store.js: env vars arrive as the `env`
// parameter (Workers bindings) instead of module-level process.env reads.

const { createHash } = require('node:crypto');

function headers(env) {
  return {
    Authorization: `Bearer ${env.SUPABASE_SERVICE_ROLE_KEY}`,
    apikey: env.SUPABASE_SERVICE_ROLE_KEY,
  };
}

// sha256 hex for booking token-hash comparison (contract §1.4: the server
// stores hashes only — the raw token never crosses into a table predicate).
function sha256Hex(value) {
  return createHash('sha256').update(String(value), 'utf8').digest('hex');
}

// bk<epoch-ms>_<6 hex>. Inputs injected so it stays pure/deterministic;
// callers pass Date.now() and crypto.randomBytes(3).toString('hex').
function newRequestId(nowMs, randHex) {
  return `bk${nowMs}_${randHex}`;
}

// Returns { user_id, data } for an ENABLED booking link, else null. Disabled
// and unknown tokens are indistinguishable to callers on purpose (no oracle).
//
// Phase 8 task 8.05 (G3, contract §3/§5): adoption-gated dual read. The
// booking_link_state table (20260921_booking_admin_state.sql) is authoritative
// ONLY once its row carries adopted_at (first admin mutation); before that —
// including when the table does not exist yet (missing-table 404 → blob
// path) — resolution is today's behavior verbatim (blob token + enabled
// gate). Post-adoption the blob is auth-inert: a stale RN/Swift
// whole-settings push can never resurrect a disabled/rotated token (R4), and
// a rotated token resolves even though the blob still carries the old one.
// Shape and status codes are unchanged, so config/submit/slots/reserve all
// share this one authority with zero caller changes (RN-compatible).
async function lookupUserByBookingToken(env, token) {
  const [blob, byHash] = await Promise.all([
    lookupBookingBlob(env, token),
    bookingLinkStateByHash(env, sha256Hex(token)),
  ]);
  if (!byHash.available) return blob; // table not deployed: verbatim legacy

  const adoptedHit = byHash.rows.find((r) => r.adopted_at);
  if (adoptedHit) {
    // Post-adoption: state table ONLY. Hash match + enabled, else
    // indistinguishable 404 — including when the blob still shows the old
    // token as enabled (stale-settings replay is inert, not authoritative).
    if (!adoptedHit.enabled) return null;
    return fetchSettingsRow(env, adoptedHit.user_id);
  }

  // No adopted row carries this hash. The blob may still be authoritative
  // (pre-adoption) or inert (its owner adopted and this token is stale).
  if (!blob) return null;
  const owner = await bookingLinkStateByUserId(env, blob.user_id);
  if (owner.available && owner.row && owner.row.adopted_at) {
    // Adopted owner presenting a non-current token (rotated/disabled): the
    // blob write is auth-inert — a delayed whole-settings push cannot
    // resurrect it (R4), and an old-RN blob-only rotate changes nothing (R5).
    return null;
  }
  return blob;
}

// Today's verbatim blob resolution, factored so the adopted branch above can
// reuse it. The server, not the client, applies the enabled gate.
async function lookupBookingBlob(env, token) {
  const res = await fetch(
    `${env.SUPABASE_URL}/rest/v1/settings?data->bookingLink->>token=eq.${encodeURIComponent(token)}&data->bookingLink->>enabled=eq.true&select=user_id,data`,
    { headers: headers(env) }
  );
  if (!res.ok) throw new Error(`Supabase fetch ${res.status}: ${await res.text()}`);
  const rows = await res.json();
  return rows.length ? rows[0] : null;
}

// booking_link_state row(s) matching a token hash. {available:false} means
// the table is not deployed (PostgREST 404 on the relation) — callers fall
// back to the blob path. Any other non-ok is a real failure and throws (the
// callers map it to 500, exactly like a settings-fetch failure today).
async function bookingLinkStateByHash(env, tokenHash) {
  const res = await fetch(
    `${env.SUPABASE_URL}/rest/v1/booking_link_state?token_hash=eq.${encodeURIComponent(tokenHash)}&select=user_id,token_hash,enabled,revision,adopted_at`,
    { headers: headers(env) }
  );
  if (res.status === 404) return { available: false, rows: [] };
  if (!res.ok) throw new Error(`Supabase fetch ${res.status}: ${await res.text()}`);
  return { available: true, rows: await res.json() };
}

// booking_link_state row for one owner (admin status reads + tests).
async function bookingLinkStateByUserId(env, userId) {
  const res = await fetch(
    `${env.SUPABASE_URL}/rest/v1/booking_link_state?user_id=eq.${encodeURIComponent(userId)}&select=user_id,token_hash,enabled,revision,adopted_at`,
    { headers: headers(env) }
  );
  if (res.status === 404) return { available: false, row: null };
  if (!res.ok) throw new Error(`Supabase fetch ${res.status}: ${await res.text()}`);
  const rows = await res.json();
  return { available: true, row: rows.length ? rows[0] : null };
}

// Settings row in the {user_id, data} shape the public cores consume — the
// adopted branch needs businessName/schedule from the blob even though the
// blob token is no longer authoritative.
async function fetchSettingsRow(env, userId) {
  const res = await fetch(
    `${env.SUPABASE_URL}/rest/v1/settings?user_id=eq.${encodeURIComponent(userId)}&select=user_id,data`,
    { headers: headers(env) }
  );
  if (!res.ok) throw new Error(`Supabase fetch ${res.status}: ${await res.text()}`);
  const rows = await res.json();
  return rows.length ? rows[0] : null;
}

// Row shape matches what the sync engine itself pushes, so the device's
// pullRemote absorbs these rows with zero special-casing.
async function insertBookingRequest(env, userId, request) {
  const res = await fetch(`${env.SUPABASE_URL}/rest/v1/bookingRequests`, {
    method: 'POST',
    headers: { ...headers(env), 'Content-Type': 'application/json', Prefer: 'resolution=merge-duplicates' },
    body: JSON.stringify({
      id: request.id,
      user_id: userId,
      data: request,
      updated_at: new Date().toISOString(),
      deleted: false,
    }),
  });
  if (!res.ok) throw new Error(`Supabase insert ${res.status}: ${await res.text()}`);
}

// ── Phase 11 C (slots + reserve) ─────────────────────────────────────────────

// rv<epoch-ms>_<6 hex> — same injected-inputs discipline as newRequestId.
function newReservationId(nowMs, randHex) {
  return `rv${nowMs}_${randHex}`;
}

// The user's job blobs — availability recompute input. Soft-deleted rows
// excluded; the engine itself skips terminal statuses and unscheduled jobs.
async function fetchJobsData(env, userId) {
  const res = await fetch(
    `${env.SUPABASE_URL}/rest/v1/jobs?user_id=eq.${encodeURIComponent(userId)}&deleted=eq.false&select=data`,
    { headers: headers(env) }
  );
  if (!res.ok) throw new Error(`Supabase jobs fetch ${res.status}: ${await res.text()}`);
  return (await res.json()).map((r) => r.data);
}

// Active holds — subtracted from offers and from the reserve-time recompute.
async function fetchActiveReservations(env, userId) {
  const res = await fetch(
    `${env.SUPABASE_URL}/rest/v1/booking_reservations?user_id=eq.${encodeURIComponent(userId)}&status=eq.booked&select=slot_date,slot_start,slot_end`,
    { headers: headers(env) }
  );
  if (!res.ok) throw new Error(`Supabase reservations fetch ${res.status}: ${await res.text()}`);
  return res.json();
}

// THE atomic claim (spec §6 step 4). The partial unique index
// (user_id, slot_start_utc) WHERE status='booked' serializes racing
// customers; PostgREST answers the loser with 409 (Postgres 23505), which
// this maps to {conflict:true} — never an exception, so the handler can
// answer 409 slot_taken deliberately.
async function insertReservation(env, row) {
  const res = await fetch(`${env.SUPABASE_URL}/rest/v1/booking_reservations`, {
    method: 'POST',
    headers: { ...headers(env), 'Content-Type': 'application/json' },
    body: JSON.stringify(row),
  });
  if (res.status === 409) return { conflict: true };
  if (!res.ok) throw new Error(`Supabase reservation insert ${res.status}: ${await res.text()}`);
  return { conflict: false };
}

// Compensation for a failed request-row insert: a reservation must never
// keep holding a slot the customer has no record of.
async function deleteReservation(env, id) {
  const res = await fetch(
    `${env.SUPABASE_URL}/rest/v1/booking_reservations?id=eq.${encodeURIComponent(id)}`,
    { method: 'DELETE', headers: headers(env) }
  );
  if (!res.ok) throw new Error(`Supabase reservation delete ${res.status}: ${await res.text()}`);
}

// ── Phase 11 D (manage + respond) ────────────────────────────────────────────

// The manage token is a per-booking capability living inside the request
// blob — resolved by JSON-path exactly like the booking token.
async function fetchRequestByManageToken(env, manageToken) {
  const res = await fetch(
    `${env.SUPABASE_URL}/rest/v1/bookingRequests?data->>manageToken=eq.${encodeURIComponent(manageToken)}&deleted=eq.false&select=id,user_id,data`,
    { headers: headers(env) }
  );
  if (!res.ok) throw new Error(`Supabase manage lookup ${res.status}: ${await res.text()}`);
  const rows = await res.json();
  return rows.length ? rows[0] : null;
}

async function fetchRequestById(env, id) {
  const res = await fetch(
    `${env.SUPABASE_URL}/rest/v1/bookingRequests?id=eq.${encodeURIComponent(id)}&deleted=eq.false&select=id,user_id,data`,
    { headers: headers(env) }
  );
  if (!res.ok) throw new Error(`Supabase request fetch ${res.status}: ${await res.text()}`);
  const rows = await res.json();
  return rows.length ? rows[0] : null;
}

async function fetchSettingsData(env, userId) {
  const res = await fetch(
    `${env.SUPABASE_URL}/rest/v1/settings?user_id=eq.${encodeURIComponent(userId)}&select=data`,
    { headers: headers(env) }
  );
  if (!res.ok) throw new Error(`Supabase settings fetch ${res.status}: ${await res.text()}`);
  const rows = await res.json();
  return rows.length ? rows[0].data : null;
}

// Server-side status/history write. updated_at moves so the device's
// incremental pull picks the change up like any other remote edit.
async function patchBookingRequest(env, id, data, nowMs) {
  const res = await fetch(
    `${env.SUPABASE_URL}/rest/v1/bookingRequests?id=eq.${encodeURIComponent(id)}`,
    {
      method: 'PATCH',
      headers: { ...headers(env), 'Content-Type': 'application/json' },
      body: JSON.stringify({ data, updated_at: new Date(nowMs).toISOString() }),
    }
  );
  if (!res.ok) throw new Error(`Supabase request patch ${res.status}: ${await res.text()}`);
}

// Freeing a slot is a status flip: the row leaves the partial unique index
// (status='booked') and the slot is instantly re-offerable. The status=eq
// filter makes repeats harmless no-ops.
async function updateReservationStatus(env, requestId, status) {
  const res = await fetch(
    `${env.SUPABASE_URL}/rest/v1/booking_reservations?request_id=eq.${encodeURIComponent(requestId)}&status=eq.booked`,
    {
      method: 'PATCH',
      headers: { ...headers(env), 'Content-Type': 'application/json' },
      body: JSON.stringify({ status }),
    }
  );
  if (!res.ok) throw new Error(`Supabase reservation patch ${res.status}: ${await res.text()}`);
}

// ── Phase 8 task 8.04 (G1/G2): transactional RPCs ─────────────────────────
// Additive callers for the 20260920_booking_lifecycle_rpcs.sql functions.
// Contract (docs/native-phase-8-contract-decisions.md §2):
// - The RPCs RETURN a jsonb envelope {ok:true,...}/{ok:false,error,...status?}
//   with HTTP 200. A transport 404 on /rpc/<fn> therefore unambiguously means
//   "function not deployed" → {unavailable:true} and the caller uses the
//   legacy split path byte-identically (adoption-gated dual reads, §10 step 3).
//   A 200 body that is not an {ok:boolean} envelope is treated the same way
//   (pre-deploy PostgREST answers unknown RPC routes without the envelope).
// - Envelope errors map deliberately: slot_taken/slot_changed → 409,
//   invalid_state/schedule_changed → 409 with echoed status, not_found → 404.

async function callBookingRpc(env, fn, args) {
  let res;
  try {
    res = await fetch(`${env.SUPABASE_URL}/rest/v1/rpc/${fn}`, {
      method: 'POST',
      headers: { ...headers(env), 'Content-Type': 'application/json' },
      body: JSON.stringify(args),
    });
  } catch (err) {
    throw new Error(`Booking RPC ${fn} transport failed: ${err.message}`);
  }
  if (res.status === 404) return { unavailable: true };
  if (!res.ok) throw new Error(`Booking RPC ${fn} ${res.status}: ${await res.text()}`);
  let out;
  try {
    out = await res.json();
  } catch (err) {
    throw new Error(`Booking RPC ${fn} undecodable: ${err.message}`);
  }
  if (!out || typeof out.ok !== 'boolean') return { unavailable: true };
  return { unavailable: false, out };
}

// G1 atomic claim (§2.1). `claim` carries the offer-time schedule twin
// (duration/buffer) plus the fully built request/reservation docs; the
// function revalidates authority + config + busy intervals in-txn and inserts
// both rows atomically.
async function claimBookingSlot(env, claim) {
  return callBookingRpc(env, 'claim_booking_slot', {
    p_user_id: claim.user_id,
    p_token: claim.token,
    p_slot_date: claim.slot_date,
    p_slot_start: claim.slot_start,
    p_slot_end: claim.slot_end,
    p_slot_start_utc: claim.slot_start_utc,
    p_slot_end_utc: claim.slot_end_utc,
    p_duration_minutes: claim.duration_minutes,
    p_buffer_minutes: claim.buffer_minutes,
    p_request: claim.request,
    p_reservation: claim.reservation,
  });
}

// G2 atomic lifecycle step (§2.2). Exactly one credential is set: owner path
// passes p_owner_id, customer path passes p_manage_token; the other is null.
// The server merges status + exactly one history entry and preserves every
// other blob field — callers MUST NOT whole-blob replay on this path (§2.6).
async function transitionBooking(env, step) {
  return callBookingRpc(env, 'transition_booking', {
    p_request_id: step.request_id,
    p_owner_id: step.owner_id || null,
    p_manage_token: step.manage_token || null,
    p_expected: step.expected,
    p_target: step.target,
    p_history: step.history,
    p_release: step.release,
    p_proof: step.proof || null,
  });
}

// Legacy scheduleProof verification for the pre-RPC fallback path only
// (proof-less calls stay L2-accepted, §7). Returns the job row
// {data, updated_at} or null. The RPC path verifies server-side instead.
async function fetchJobRowForProof(env, userId, jobId) {
  const res = await fetch(
    `${env.SUPABASE_URL}/rest/v1/jobs?id=eq.${encodeURIComponent(jobId)}&user_id=eq.${encodeURIComponent(userId)}&deleted=eq.false&select=data,updated_at`,
    { headers: headers(env) }
  );
  if (!res.ok) throw new Error(`Supabase job fetch ${res.status}: ${await res.text()}`);
  const rows = await res.json();
  return rows.length ? rows[0] : null;
}

// Proof predicate shared by the legacy fallback: the job blob must still
// carry (date, start) with updated_at >= proof.updatedAt, else the resolve
// would release the hold against a superseded schedule (§7 step 3).
function proofMatchesJob(jobRow, proof) {
  if (!jobRow || !jobRow.data) return false;
  if ((jobRow.data.scheduledDate ?? null) !== proof.date) return false;
  if ((jobRow.data.scheduledStartTime ?? null) !== proof.start) return false;
  if (!proof.updatedAt || !jobRow.updated_at) return false;
  return Date.parse(jobRow.updated_at) >= Date.parse(proof.updatedAt);
}

module.exports = {
  lookupUserByBookingToken,
  lookupBookingBlob,
  bookingLinkStateByHash,
  bookingLinkStateByUserId,
  fetchSettingsRow,
  sha256Hex,
  insertBookingRequest,
  newRequestId,
  newReservationId,
  fetchJobsData,
  fetchActiveReservations,
  insertReservation,
  deleteReservation,
  fetchRequestByManageToken,
  fetchRequestById,
  fetchSettingsData,
  patchBookingRequest,
  updateReservationStatus,
  claimBookingSlot,
  transitionBooking,
  fetchJobRowForProof,
  proofMatchesJob,
  callBookingRpc,
};

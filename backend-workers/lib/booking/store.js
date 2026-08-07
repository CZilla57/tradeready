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

function headers(env) {
  return {
    Authorization: `Bearer ${env.SUPABASE_SERVICE_ROLE_KEY}`,
    apikey: env.SUPABASE_SERVICE_ROLE_KEY,
  };
}

// bk<epoch-ms>_<6 hex>. Inputs injected so it stays pure/deterministic;
// callers pass Date.now() and crypto.randomBytes(3).toString('hex').
function newRequestId(nowMs, randHex) {
  return `bk${nowMs}_${randHex}`;
}

// Returns { user_id, data } for an ENABLED booking link, else null. Disabled
// and unknown tokens are indistinguishable to callers on purpose (no oracle).
async function lookupUserByBookingToken(env, token) {
  const res = await fetch(
    `${env.SUPABASE_URL}/rest/v1/settings?data->bookingLink->>token=eq.${encodeURIComponent(token)}&data->bookingLink->>enabled=eq.true&select=user_id,data`,
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

module.exports = {
  lookupUserByBookingToken,
  insertBookingRequest,
  newRequestId,
  newReservationId,
  fetchJobsData,
  fetchActiveReservations,
  insertReservation,
  deleteReservation,
};

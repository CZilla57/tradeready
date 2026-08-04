// Supabase access for the booking endpoints. Service role (bypasses RLS),
// exactly like ../estimateStore.js. NOT routed by Vercel (lives under lib/).
//
// The booking token lives INSIDE the owner's settings blob and is written
// only by the device (normal settings sync). The server resolves it with a
// PostgREST JSON-path filter and never writes settings — that one-way flow is
// what makes token rotation race-free (spec §4).

const SUPABASE_URL = process.env.SUPABASE_URL;
const SUPABASE_SERVICE_ROLE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY;

function headers() {
  return {
    Authorization: `Bearer ${SUPABASE_SERVICE_ROLE_KEY}`,
    apikey: SUPABASE_SERVICE_ROLE_KEY,
  };
}

// bk<epoch-ms>_<6 hex>. Inputs injected so it stays pure/deterministic;
// callers pass Date.now() and crypto.randomBytes(3).toString('hex').
function newRequestId(nowMs, randHex) {
  return `bk${nowMs}_${randHex}`;
}

// Returns { user_id, data } for an ENABLED booking link, else null. Disabled
// and unknown tokens are indistinguishable to callers on purpose (no oracle).
async function lookupUserByBookingToken(token) {
  const res = await fetch(
    `${SUPABASE_URL}/rest/v1/settings?data->bookingLink->>token=eq.${encodeURIComponent(token)}&data->bookingLink->>enabled=eq.true&select=user_id,data`,
    { headers: headers() }
  );
  if (!res.ok) throw new Error(`Supabase fetch ${res.status}: ${await res.text()}`);
  const rows = await res.json();
  return rows.length ? rows[0] : null;
}

// Row shape matches what the sync engine itself pushes, so the device's
// pullRemote absorbs these rows with zero special-casing.
async function insertBookingRequest(userId, request) {
  const res = await fetch(`${SUPABASE_URL}/rest/v1/bookingRequests`, {
    method: 'POST',
    headers: { ...headers(), 'Content-Type': 'application/json', Prefer: 'resolution=merge-duplicates' },
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

module.exports = { lookupUserByBookingToken, insertBookingRequest, newRequestId };

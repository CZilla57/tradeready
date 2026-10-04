// backend-workers/lib/calendar/busyStore.js
// Service-role PostgREST access to public.calendar_busy (Roadmap Phase 26,
// spec §2.3, §3.2), the booking store.js pattern. One row per owner; only the
// Worker touches it (RLS on, no client policy, no client grants).
//
// A PostgREST 404 on the relation means the migration is not applied yet:
// reads report `available: false` (slots/reserve then treat busy times as
// `off`, today's behavior) and the endpoint answers 503. Any other non-ok
// answer throws, and callers map it to 500.

const SELECT = 'user_id,source_id,snapshot,computed_at,window_start,window_end,received_at';

function headers(env) {
  return {
    Authorization: `Bearer ${env.SUPABASE_SERVICE_ROLE_KEY}`,
    apikey: env.SUPABASE_SERVICE_ROLE_KEY,
  };
}

/** `{available, row}`: row is the owner's calendar_busy row or null. */
async function fetchCalendarBusyRow(env, userId) {
  const res = await fetch(
    `${env.SUPABASE_URL}/rest/v1/calendar_busy?user_id=eq.${encodeURIComponent(userId)}&select=${SELECT}`,
    { headers: headers(env) }
  );
  if (res.status === 404) return { available: false, row: null };
  if (!res.ok) throw new Error(`Supabase calendar_busy fetch ${res.status}: ${await res.text()}`);
  const rows = await res.json();
  return { available: true, row: Array.isArray(rows) && rows.length ? rows[0] : null };
}

/** The owner's row, or null when absent or not deployed (both mean `off`). */
async function fetchCalendarBusy(env, userId) {
  return (await fetchCalendarBusyRow(env, userId)).row;
}

/** Replaces the owner's row atomically (merge-duplicates on user_id). */
async function upsertCalendarBusy(env, row) {
  const res = await fetch(`${env.SUPABASE_URL}/rest/v1/calendar_busy?on_conflict=user_id`, {
    method: 'POST',
    headers: {
      ...headers(env),
      'Content-Type': 'application/json',
      Prefer: 'resolution=merge-duplicates,return=minimal',
    },
    body: JSON.stringify(row),
  });
  if (res.status === 404) return { available: false };
  if (!res.ok) throw new Error(`Supabase calendar_busy upsert ${res.status}: ${await res.text()}`);
  return { available: true };
}

async function deleteCalendarBusy(env, userId) {
  const res = await fetch(
    `${env.SUPABASE_URL}/rest/v1/calendar_busy?user_id=eq.${encodeURIComponent(userId)}`,
    { method: 'DELETE', headers: headers(env) }
  );
  if (res.status === 404) return { available: false };
  if (!res.ok) throw new Error(`Supabase calendar_busy delete ${res.status}: ${await res.text()}`);
  return { available: true };
}

module.exports = { fetchCalendarBusyRow, fetchCalendarBusy, upsertCalendarBusy, deleteCalendarBusy };

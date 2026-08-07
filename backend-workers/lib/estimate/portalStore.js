// Supabase access for the customer-portal read (2026-08-04 portal spec §4).
// Service role, READ-ONLY by contract — the portal adds zero server write
// paths; an insert/update here is a defect. Every jobs/invoices query is
// scoped by BOTH user_id and customerId so a portal token can never read
// across tenants.
//
// Workers port of backend/lib/estimate/portalStore.js: env vars arrive as the
// `env` parameter (Workers bindings) instead of module-level process.env reads.

function headers(env) {
  return {
    Authorization: `Bearer ${env.SUPABASE_SERVICE_ROLE_KEY}`,
    apikey: env.SUPABASE_SERVICE_ROLE_KEY,
  };
}

async function get(env, pathAndQuery) {
  const res = await fetch(`${env.SUPABASE_URL}/rest/v1/${pathAndQuery}`, { headers: headers(env) });
  if (!res.ok) throw new Error(`Supabase fetch ${res.status}: ${await res.text()}`);
  return res.json();
}

// { user_id, id, data } for an ENABLED portal link, else null. Disabled and
// unknown tokens are indistinguishable to callers on purpose (no oracle).
async function lookupCustomerByPortalToken(env, token) {
  const rows = await get(
    env,
    `customers?data->portal->>token=eq.${encodeURIComponent(token)}&data->portal->>enabled=eq.true&deleted=eq.false&select=user_id,id,data`
  );
  return rows.length ? rows[0] : null;
}

async function fetchBusinessName(env, userId) {
  const rows = await get(env, `settings?user_id=eq.${encodeURIComponent(userId)}&select=data`);
  return rows.length ? String(rows[0].data?.businessName || '') : '';
}

async function fetchCustomerJobs(env, userId, customerId) {
  return get(
    env,
    `jobs?user_id=eq.${encodeURIComponent(userId)}&data->>customerId=eq.${encodeURIComponent(customerId)}&deleted=eq.false&select=id,data`
  );
}

async function fetchCustomerInvoices(env, userId, customerId) {
  return get(
    env,
    `invoices?user_id=eq.${encodeURIComponent(userId)}&data->>customerId=eq.${encodeURIComponent(customerId)}&deleted=eq.false&select=id,data`
  );
}

// This customer's booking requests — used only to attach the shipped
// manage-page link to appointments that originated as bookings. Read-only
// like everything else here; scoped by BOTH user_id and the converted
// customer id so a portal token can never see another customer's bookings.
async function fetchCustomerBookingRequests(env, userId, customerId) {
  return get(
    env,
    `bookingRequests?user_id=eq.${encodeURIComponent(userId)}&data->>convertedCustomerId=eq.${encodeURIComponent(customerId)}&deleted=eq.false&select=id,data`
  );
}

module.exports = { lookupCustomerByPortalToken, fetchBusinessName, fetchCustomerJobs, fetchCustomerInvoices, fetchCustomerBookingRequests };

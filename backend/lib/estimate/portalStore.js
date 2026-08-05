// Supabase access for the customer-portal read (2026-08-04 portal spec §4).
// Service role, READ-ONLY by contract — the portal adds zero server write
// paths; an insert/update here is a defect. Every jobs/invoices query is
// scoped by BOTH user_id and customerId so a portal token can never read
// across tenants. NOT routed by Vercel (lives under lib/).

const SUPABASE_URL = process.env.SUPABASE_URL;
const SUPABASE_SERVICE_ROLE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY;

function headers() {
  return {
    Authorization: `Bearer ${SUPABASE_SERVICE_ROLE_KEY}`,
    apikey: SUPABASE_SERVICE_ROLE_KEY,
  };
}

async function get(pathAndQuery) {
  const res = await fetch(`${SUPABASE_URL}/rest/v1/${pathAndQuery}`, { headers: headers() });
  if (!res.ok) throw new Error(`Supabase fetch ${res.status}: ${await res.text()}`);
  return res.json();
}

// { user_id, id, data } for an ENABLED portal link, else null. Disabled and
// unknown tokens are indistinguishable to callers on purpose (no oracle).
async function lookupCustomerByPortalToken(token) {
  const rows = await get(
    `customers?data->portal->>token=eq.${encodeURIComponent(token)}&data->portal->>enabled=eq.true&deleted=eq.false&select=user_id,id,data`
  );
  return rows.length ? rows[0] : null;
}

async function fetchBusinessName(userId) {
  const rows = await get(`settings?user_id=eq.${encodeURIComponent(userId)}&select=data`);
  return rows.length ? String(rows[0].data?.businessName || '') : '';
}

async function fetchCustomerJobs(userId, customerId) {
  return get(
    `jobs?user_id=eq.${encodeURIComponent(userId)}&data->>customerId=eq.${encodeURIComponent(customerId)}&deleted=eq.false&select=id,data`
  );
}

async function fetchCustomerInvoices(userId, customerId) {
  return get(
    `invoices?user_id=eq.${encodeURIComponent(userId)}&data->>customerId=eq.${encodeURIComponent(customerId)}&deleted=eq.false&select=id,data`
  );
}

module.exports = { lookupCustomerByPortalToken, fetchBusinessName, fetchCustomerJobs, fetchCustomerInvoices };

// Supabase (PostgREST, service role) access for the pay page, the autopay
// sweep, the webhook activation and the owner routes (Phase 24). Every read
// of a synced blob is scoped by user_id so a token minted for one owner can
// never read another owner's rows. Enrollment and charge rows are
// server-owned (20261003_autopay.sql): only these helpers write them.
//
// Read helpers throw on a Supabase error (callers map that to a 500 or a
// retry); the few best-effort writes say so in their names.

const { ID_RE, UUID_RE } = require('../pay/payToken.js');
const { isPlausibleEmail } = require('../selectInvoicesToRemind.js');

function headers(env, extra = {}) {
  return {
    Authorization: `Bearer ${env.SUPABASE_SERVICE_ROLE_KEY}`,
    apikey: env.SUPABASE_SERVICE_ROLE_KEY,
    'Content-Type': 'application/json',
    ...extra,
  };
}

async function sbGet(env, pathAndQuery) {
  const res = await fetch(`${env.SUPABASE_URL}/rest/v1/${pathAndQuery}`, { headers: headers(env) });
  if (!res.ok) throw new Error(`Supabase GET ${pathAndQuery.split('?')[0]} ${res.status}: ${await res.text()}`);
  return res.json();
}

async function sbWrite(env, method, pathAndQuery, body, prefer = 'return=representation') {
  const res = await fetch(`${env.SUPABASE_URL}/rest/v1/${pathAndQuery}`, {
    method,
    headers: headers(env, { Prefer: prefer }),
    body: JSON.stringify(body),
  });
  if (!res.ok) {
    const err = new Error(`Supabase ${method} ${pathAndQuery.split('?')[0]} ${res.status}: ${await res.text()}`);
    err.status = res.status;
    throw err;
  }
  const text = await res.text();
  return text ? JSON.parse(text) : [];
}

const enc = encodeURIComponent;

// PostgREST in-list of quoted, shape-checked ids. Anything outside the id
// alphabet is dropped, so a hostile id can never break out of the filter.
function inList(ids, re = ID_RE) {
  const safe = [...new Set((ids || []).map(String))].filter((id) => re.test(id));
  return safe.length ? `(${safe.map((id) => `"${id}"`).join(',')})` : null;
}

// --- owner-level reads -------------------------------------------------------

async function fetchSettings(env, userId) {
  const rows = await sbGet(env, `settings?user_id=eq.${enc(userId)}&select=data`);
  return rows.length ? rows[0].data || {} : {};
}

async function fetchSettingsForUsers(env, userIds) {
  const list = inList(userIds, UUID_RE);
  if (!list) return new Map();
  const rows = await sbGet(env, `settings?user_id=in.${list}&select=user_id,data`);
  return new Map(rows.map((r) => [r.user_id, r.data || {}]));
}

async function fetchStripeAccountId(env, userId) {
  const rows = await sbGet(env, `stripe_accounts?user_id=eq.${enc(userId)}&select=stripe_account_id`);
  return rows.length ? rows[0].stripe_account_id || null : null;
}

async function fetchStripeAccountsForUsers(env, userIds) {
  const list = inList(userIds, UUID_RE);
  if (!list) return new Map();
  const rows = await sbGet(env, `stripe_accounts?user_id=in.${list}&select=user_id,stripe_account_id`);
  return new Map(rows.map((r) => [r.user_id, r.stripe_account_id]));
}

// Invoice row (deleted rows included, so callers can tell "deleted" from
// "not synced yet") or null.
async function fetchInvoiceForUser(env, userId, invoiceId) {
  const rows = await sbGet(env, `invoices?id=eq.${enc(invoiceId)}&user_id=eq.${enc(userId)}&select=id,user_id,data,deleted`);
  return rows.length ? rows[0] : null;
}

async function fetchPlanForUser(env, userId, planId) {
  const rows = await sbGet(env, `recurringInvoices?id=eq.${enc(planId)}&user_id=eq.${enc(userId)}&select=id,user_id,data,deleted`);
  return rows.length ? rows[0] : null;
}

// --- enrollments -------------------------------------------------------------

const ENROLLMENT_COLUMNS = '*';

async function fetchEnrollmentById(env, userId, enrollmentId) {
  if (!UUID_RE.test(String(enrollmentId))) return null;
  const rows = await sbGet(env, `autopay_enrollments?id=eq.${enc(enrollmentId)}&user_id=eq.${enc(userId)}&select=${ENROLLMENT_COLUMNS}`);
  return rows.length ? rows[0] : null;
}

async function fetchEnrollmentsForPlan(env, userId, planId) {
  return sbGet(env, `autopay_enrollments?user_id=eq.${enc(userId)}&recurring_invoice_id=eq.${enc(planId)}&select=${ENROLLMENT_COLUMNS}&order=created_at.desc`);
}

async function fetchActiveEnrollmentsForCustomer(env, userId, customerId) {
  return sbGet(env, `autopay_enrollments?user_id=eq.${enc(userId)}&customer_id=eq.${enc(customerId)}&status=eq.active&select=${ENROLLMENT_COLUMNS}`);
}

async function fetchEnrollmentsForUser(env, userId, { statuses } = {}) {
  const status = statuses ? `&status=in.(${statuses.join(',')})` : '';
  return sbGet(env, `autopay_enrollments?user_id=eq.${enc(userId)}${status}&select=${ENROLLMENT_COLUMNS}&order=consented_at.desc`);
}

async function fetchLiveEnrollments(env) {
  return sbGet(env, `autopay_enrollments?status=in.(active,pending)&select=${ENROLLMENT_COLUMNS}`);
}

// The newest Stripe Customer already used for (owner, TradeReady customer)
// on this connected account, so one person keeps one Customer (spec §4.4).
async function findReusableStripeCustomer(env, userId, customerId, stripeAccountId) {
  const rows = await sbGet(
    env,
    `autopay_enrollments?user_id=eq.${enc(userId)}&customer_id=eq.${enc(customerId)}` +
      `&stripe_account_id=eq.${enc(stripeAccountId)}&select=stripe_customer_id,created_at&order=created_at.desc&limit=1`
  );
  return rows.length ? rows[0].stripe_customer_id : null;
}

async function insertEnrollment(env, row) {
  const now = new Date().toISOString();
  const [created] = await sbWrite(env, 'POST', 'autopay_enrollments', { ...row, created_at: now, updated_at: now });
  return created;
}

// Conditional update: only rows still matching `where` (e.g. status=eq.pending)
// change. Returns the updated rows ([] when another writer got there first).
// A unique violation (a second active row for the plan) throws with
// err.status 409 so activation can replace and retry.
async function updateEnrollments(env, filter, patch) {
  return sbWrite(env, 'PATCH', `autopay_enrollments?${filter}`, { ...patch, updated_at: new Date().toISOString() });
}

// --- charges -----------------------------------------------------------------

async function fetchChargesForInvoice(env, userId, invoiceId) {
  return sbGet(env, `autopay_charges?user_id=eq.${enc(userId)}&invoice_id=eq.${enc(invoiceId)}&select=*`);
}

async function fetchChargesForUsers(env, userIds) {
  const list = inList(userIds, UUID_RE);
  if (!list) return [];
  return sbGet(env, `autopay_charges?user_id=in.${list}&select=*`);
}

async function fetchRecentChargesForUser(env, userId, sinceIso) {
  return sbGet(env, `autopay_charges?user_id=eq.${enc(userId)}&created_at=gte.${enc(sinceIso)}&select=*&order=created_at.desc&limit=500`);
}

// The claim (spec §4.6 step 1): insert-first with on_conflict +
// ignore-duplicates. Returns the new row, or null when another run already
// holds (user, invoice, attempt).
async function claimCharge(env, row, { now = new Date() } = {}) {
  const stamp = now.toISOString();
  const rows = await sbWrite(
    env,
    'POST',
    'autopay_charges?on_conflict=user_id,invoice_id,attempt',
    { attempt: 1, ...row, created_at: stamp, updated_at: stamp },
    'return=representation,resolution=ignore-duplicates'
  );
  return Array.isArray(rows) && rows.length ? rows[0] : null;
}

// Releases a claim no charge was attempted for (the customer paid on the pay
// page first). Conditional on status=claimed.
async function deleteClaim(env, chargeId) {
  return sbWrite(env, 'DELETE', `autopay_charges?id=eq.${enc(chargeId)}&status=eq.claimed`, undefined, 'return=minimal');
}

async function updateCharge(env, chargeId, patch, { where = '' } = {}) {
  return sbWrite(env, 'PATCH', `autopay_charges?id=eq.${enc(chargeId)}${where}`, { ...patch, updated_at: new Date().toISOString() });
}

// --- plan + invoice reads for the sweep ------------------------------------

async function fetchPlansByIds(env, userIds, planIds) {
  const users = inList(userIds, UUID_RE);
  const plans = inList(planIds);
  if (!users || !plans) return [];
  return sbGet(env, `recurringInvoices?user_id=in.${users}&id=in.${plans}&select=id,user_id,data,deleted`);
}

async function fetchPlanInvoices(env, userIds, planIds) {
  const users = inList(userIds, UUID_RE);
  const plans = inList(planIds);
  if (!users || !plans) return [];
  return sbGet(env, `invoices?user_id=in.${users}&data->>recurringInvoiceId=in.${plans}&deleted=is.false&select=id,user_id,data`);
}

// The TradeReady customer's email (fallback recipient for autopay mail when
// Checkout collected none), or null.
async function fetchCustomerEmail(env, userId, customerId) {
  const rows = await sbGet(env, `customers?id=eq.${enc(customerId)}&user_id=eq.${enc(userId)}&select=data`);
  const email = rows.length && rows[0].data ? rows[0].data.email : null;
  return typeof email === 'string' && email ? email : null;
}

// Autopay mail recipient (spec §4.7): the Checkout-entered billing email,
// else `fallback` (e.g. the invoice's email), else the TradeReady customer's
// email. Only a plausible single address is ever returned; null → no mail.
async function resolveAutopayRecipient(env, enrollment, fallback) {
  const plausible = isPlausibleEmail;
  if (plausible(enrollment && enrollment.billing_email)) return enrollment.billing_email;
  if (plausible(fallback)) return fallback;
  try {
    const email = await fetchCustomerEmail(env, enrollment.user_id, enrollment.customer_id);
    return plausible(email) ? email : null;
  } catch (err) {
    console.error('[autopay] customer email lookup failed:', err.message);
    return null;
  }
}

async function fetchCustomerPlans(env, userId, customerId) {
  return sbGet(env, `recurringInvoices?user_id=eq.${enc(userId)}&data->>customerId=eq.${enc(customerId)}&deleted=eq.false&select=id,data`);
}

module.exports = {
  sbGet,
  sbWrite,
  inList,
  fetchSettings,
  fetchSettingsForUsers,
  fetchStripeAccountId,
  fetchStripeAccountsForUsers,
  fetchInvoiceForUser,
  fetchPlanForUser,
  fetchEnrollmentById,
  fetchEnrollmentsForPlan,
  fetchActiveEnrollmentsForCustomer,
  fetchEnrollmentsForUser,
  fetchLiveEnrollments,
  findReusableStripeCustomer,
  insertEnrollment,
  updateEnrollments,
  fetchChargesForInvoice,
  fetchChargesForUsers,
  fetchRecentChargesForUser,
  claimCharge,
  deleteClaim,
  updateCharge,
  fetchPlansByIds,
  fetchPlanInvoices,
  fetchCustomerPlans,
  fetchCustomerEmail,
  resolveAutopayRecipient,
};

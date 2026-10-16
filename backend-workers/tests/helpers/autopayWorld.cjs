// A small in-memory "world" for the Phase 24 pay/autopay tests: a fake
// Supabase with the autopay constraints, plus capture of every Resend email,
// Expo push and Supabase admin lookup. No network.

const { installFetch, fakeSupabase, jsonRes, AUTOPAY_UNIQUE } = require('./fakes.cjs');

const USER = '11111111-2222-4333-8444-555555555555';
const OTHER_USER = '99999999-2222-4333-8444-555555555555';
const ACCOUNT = 'acct_owner1';
const SECRET = 'pay-secret-'.padEnd(40, 'x');
const OWNER_EMAIL = 'owner@example.com';

const ENV = {
  PAY_LINK_SIGNING_SECRET: SECRET,
  SUPABASE_URL: 'https://supa.test',
  SUPABASE_ANON_KEY: 'anon',
  SUPABASE_SERVICE_ROLE_KEY: 'srk',
  STRIPE_SECRET_KEY: 'sk_test_platform',
  RESEND_API_KEY: 're_test',
};

function settingsRow(data = {}, userId = USER) {
  return { user_id: userId, data: { businessName: 'Rector HVAC', email: 'office@rectorhvac.com', contactName: 'Chad', phone: '555-0100', pushToken: { token: 'ExponentPushToken[abc]' }, ...data } };
}

function planRow(data = {}, extra = {}) {
  return {
    id: 'ri1',
    user_id: USER,
    deleted: false,
    ...extra,
    data: {
      id: 'ri1',
      customerId: 'c1',
      customerName: 'Pat Lee',
      description: 'Quarterly HVAC maintenance',
      amount: 120,
      dueDays: 14,
      cadence: 'monthly',
      isActive: true,
      autopayEnabled: true,
      ...data,
    },
  };
}

function invoiceRow(data = {}, extra = {}) {
  return {
    id: 'inv1',
    user_id: USER,
    deleted: false,
    ...extra,
    data: {
      number: 'INV-0042',
      customer: 'Pat Lee',
      customerId: 'c1',
      email: 'pat@example.com',
      amount: 120,
      due: '2026-11-01',
      desc: 'November maintenance',
      recurringInvoiceId: 'ri1',
      ...data,
    },
  };
}

let seq = 0;
function enrollmentRow(over = {}) {
  seq += 1;
  const id = over.id || `00000000-0000-4000-8000-${String(seq).padStart(12, '0')}`;
  return {
    id,
    user_id: USER,
    stripe_account_id: ACCOUNT,
    customer_id: 'c1',
    recurring_invoice_id: 'ri1',
    stripe_customer_id: 'cus_1',
    payment_method_id: 'pm_1',
    card_brand: 'visa',
    card_last4: '4242',
    card_exp_month: 8,
    card_exp_year: 2027,
    card_wallet: null,
    billing_email: 'pat@example.com',
    max_amount_cents: 12000,
    status: 'active',
    consent_version: 'autopay-consent-v1',
    consent_text: 'consent text',
    consented_at: '2026-10-01T12:00:00.000Z',
    consent_ip: '203.0.113.9',
    consent_user_agent: 'agent',
    checkout_session_id: null,
    activated_at: '2026-10-01T12:01:00.000Z',
    revoked_at: null,
    revoked_by: null,
    revoke_reason: null,
    created_at: '2026-10-01T12:00:00.000Z',
    updated_at: '2026-10-01T12:00:00.000Z',
    ...over,
  };
}

function world({
  settings = [settingsRow()],
  accounts = [{ user_id: USER, stripe_account_id: ACCOUNT }],
  invoices = [invoiceRow()],
  plans = [planRow()],
  enrollments = [],
  charges = [],
  customers = [{ id: 'c1', user_id: USER, deleted: false, data: { name: 'Pat Lee', email: 'pat@example.com' } }],
  authUser = USER,
  failOn,
  resendStatus = 200,
} = {}) {
  const db = fakeSupabase(
        {
          settings,
          stripe_accounts: accounts,
          invoices,
          recurringInvoices: plans,
          autopay_enrollments: enrollments,
          autopay_charges: charges,
          customers,
          auto_invoice_email_log: [],
          auto_reminder_log: [],
          jobs: [],
        },
    { unique: { ...AUTOPAY_UNIQUE, auto_invoice_email_log: [['user_id', 'invoice_id']], auto_reminder_log: [['user_id', 'invoice_id']] }, failOn }
  );
  const emails = [];
  const pushes = [];
  const net = installFetch((call) => {
    if (call.u.origin === 'https://api.resend.com') {
      emails.push(call.json);
      return jsonRes({ id: `email_${emails.length}` }, resendStatus);
    }
    if (call.u.origin === 'https://exp.host') {
      pushes.push(call.json);
      return jsonRes({ data: { status: 'ok' } });
    }
    if (call.u.pathname === '/auth/v1/user') {
      return authUser && call.headers.authorization === 'Bearer user-jwt' ? jsonRes({ id: authUser }) : jsonRes({ msg: 'bad' }, 401);
    }
    if (call.u.pathname.startsWith('/auth/v1/admin/users/')) return jsonRes({ id: USER, email: OWNER_EMAIL });
    const r = db.handle(call);
    if (r) return r;
    throw new Error(`unrouted ${call.method} ${call.url}`);
  });
  return { db, net, emails, pushes, restore: () => net.restore() };
}

module.exports = { USER, OTHER_USER, ACCOUNT, SECRET, ENV, OWNER_EMAIL, settingsRow, planRow, invoiceRow, enrollmentRow, world };

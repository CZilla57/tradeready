// Owner alerts for payments (Phase 24 spec §4.7): an email to the owner's
// auth address (Supabase admin API) plus an Expo push to settings.pushToken,
// following lib/booking/notifyOwner.js without touching that file.
// Fire-and-forget by contract: every failure is logged and swallowed — a lost
// alert must never fail a charge, a webhook or a customer's request.
//
// `alert` is { subject, text, pushTitle, pushBody } from
// lib/autopay/emails.js; `data` rides on the push for in-app routing.

const { buildOwnerAlertEmail } = require('./autopay/emails.js');

async function fetchOwnerEmail(env, userId) {
  const res = await fetch(`${env.SUPABASE_URL}/auth/v1/admin/users/${encodeURIComponent(userId)}`, {
    headers: { Authorization: `Bearer ${env.SUPABASE_SERVICE_ROLE_KEY}`, apikey: env.SUPABASE_SERVICE_ROLE_KEY },
  });
  if (!res.ok) throw new Error(`Admin user lookup ${res.status}`);
  const user = await res.json();
  return user && user.email ? user.email : null;
}

// → { emailed: boolean, pushed: boolean }
async function alertOwner(env, { userId, settings, alert, data = {} }) {
  let emailed = false;
  let pushed = false;
  try {
    const to = await fetchOwnerEmail(env, userId);
    const email = to ? buildOwnerAlertEmail({ to, subject: alert.subject, text: alert.text }) : null;
    if (email && env.RESEND_API_KEY) {
      const r = await fetch('https://api.resend.com/emails', {
        method: 'POST',
        headers: { Authorization: `Bearer ${env.RESEND_API_KEY}`, 'Content-Type': 'application/json' },
        body: JSON.stringify(email),
      });
      if (!r.ok) throw new Error(`Resend ${r.status}: ${await r.text()}`);
      emailed = true;
    }
  } catch (err) {
    console.error('[owner-alert] email failed:', err.message);
  }

  try {
    const token = settings && settings.pushToken && settings.pushToken.token;
    if (token) {
      const r = await fetch('https://exp.host/--/api/v2/push/send', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ to: token, title: alert.pushTitle, body: String(alert.pushBody || '').slice(0, 178), data: { type: 'autopay', ...data } }),
      });
      if (!r.ok) throw new Error(`Expo push ${r.status}: ${await r.text()}`);
      pushed = true;
    }
  } catch (err) {
    console.error('[owner-alert] push failed:', err.message);
  }
  return { emailed, pushed };
}

// Customer mail through the existing Resend sender. Best-effort: returns
// true when Resend accepted it; a null payload (no plausible recipient) is
// logged and skipped.
async function sendCustomerEmail(env, email, label = 'email') {
  if (!email) {
    console.warn(`[autopay] ${label}: no plausible recipient — not sent`);
    return false;
  }
  if (!env.RESEND_API_KEY) {
    console.error(`[autopay] ${label}: RESEND_API_KEY missing — not sent`);
    return false;
  }
  try {
    const r = await fetch('https://api.resend.com/emails', {
      method: 'POST',
      headers: { Authorization: `Bearer ${env.RESEND_API_KEY}`, 'Content-Type': 'application/json' },
      body: JSON.stringify(email),
    });
    if (!r.ok) throw new Error(`Resend ${r.status}: ${await r.text()}`);
    return true;
  } catch (err) {
    console.error(`[autopay] ${label} failed:`, err.message);
    return false;
  }
}

module.exports = { alertOwner, sendCustomerEmail, fetchOwnerEmail };

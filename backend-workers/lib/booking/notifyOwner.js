// Owner alerts for a new booking request: email always (Resend, same
// transport as the reminder cron), push when the settings blob carries an
// Expo push token (registered by utils/pushToken.ts; absent until the binary
// has the push entitlement — spec §7). Fire-and-forget by contract: every
// failure is logged and swallowed; a lost alert must never fail the
// customer's submission.
//
// Workers port of backend/lib/booking/notifyOwner.js: env vars arrive as the
// `env` parameter (Workers bindings) instead of module-level process.env reads.

const SENDER = 'TradeReady <leads@gettradereadyapp.com>';

// Subject is attacker-influenceable submission data landing in a mail header:
// strip CR/LF (header smuggling), collapse whitespace, cap length. Same
// threat model as sanitizeFromPhrase in ../reminderEmail.js, scoped to a
// subject line.
function sanitizeSubjectPart(name) {
  return String(name || '').replace(/[\r\n]/g, ' ').replace(/\s+/g, ' ').trim().slice(0, 80);
}

function buildBookingEmail({ to, request }) {
  const lines = [
    `New quote request via your booking link:`,
    ``,
    `Name: ${request.name}`,
    `Phone: ${request.phone || '-'}`,
    `Email: ${request.email || '-'}`,
    `Address: ${request.address || '-'}`,
    `Preferred timing: ${request.preferredTiming || '-'}`,
    ``,
    `What they need:`,
    request.details,
    ``,
    `Open TradeReady to see the new lead in Jobs.`,
  ];
  return {
    from: SENDER,
    to,
    subject: `New quote request from ${sanitizeSubjectPart(request.name)}`.slice(0, 120),
    text: lines.join('\n'),
  };
}

async function fetchOwnerEmail(env, userId) {
  const res = await fetch(`${env.SUPABASE_URL}/auth/v1/admin/users/${encodeURIComponent(userId)}`, {
    headers: { Authorization: `Bearer ${env.SUPABASE_SERVICE_ROLE_KEY}`, apikey: env.SUPABASE_SERVICE_ROLE_KEY },
  });
  if (!res.ok) throw new Error(`Admin user lookup ${res.status}`);
  const user = await res.json();
  return user && user.email ? user.email : null;
}

async function notifyOwner(env, { userId, settingsData, request }) {
  try {
    const to = await fetchOwnerEmail(env, userId);
    if (to && env.RESEND_API_KEY) {
      const r = await fetch('https://api.resend.com/emails', {
        method: 'POST',
        headers: { Authorization: `Bearer ${env.RESEND_API_KEY}`, 'Content-Type': 'application/json' },
        body: JSON.stringify(buildBookingEmail({ to, request })),
      });
      if (!r.ok) throw new Error(`Resend ${r.status}: ${await r.text()}`);
    }
  } catch (err) {
    console.error('[booking/notify] email failed:', err.message);
  }

  try {
    const token = settingsData && settingsData.pushToken && settingsData.pushToken.token;
    if (token) {
      const r = await fetch('https://exp.host/--/api/v2/push/send', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          to: token,
          title: 'New quote request',
          body: `${request.name} — ${String(request.details || '').slice(0, 120)}`,
          data: { type: 'booking_request' },
        }),
      });
      if (!r.ok) throw new Error(`Expo push ${r.status}: ${await r.text()}`);
    }
  } catch (err) {
    console.error('[booking/notify] push failed:', err.message);
  }
}

module.exports = { buildBookingEmail, notifyOwner };

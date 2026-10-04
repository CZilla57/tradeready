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

// Phase 34: a booking that came in through a customer's referral link. The
// server never resolves the code, so the line names nobody, and the code
// itself is never echoed (the owner's app resolves it at intake).
const REFERRAL_LINE = "Came in through a customer's referral link — open TradeReady to see who referred them.";

function hasReferralCode(request) {
  return typeof request.referralCode === 'string' && request.referralCode !== '';
}

// Phase 33: a booking that came in through one of the owner's past-customer
// campaign links. The server never resolves the code, so the line names no
// campaign, and the code itself is never echoed (the owner's app resolves it
// at intake). The line is a fixed plain-text string: nothing from the request
// is interpolated into it, so there is nothing to escape.
const CAMPAIGN_LINE = 'Came in through one of your campaign links. Open TradeReady to see which one.';

function hasCampaignCode(request) {
  return typeof request.campaignCode === 'string' && request.campaignCode !== '';
}

function buildBookingEmail({ to, request }) {
  // Accurate status wording (Phase 11 spec §2 Phase C): a slot booking is a
  // confirmed appointment on the calendar, not a quote request.
  const booked = request.kind === 'booked' && request.slot;
  const closing = booked
    ? `The slot is held for them. Open TradeReady to see it on your calendar.`
    : `Open TradeReady to see the new lead in Jobs.`;
  const lines = booked
    ? [
        `New booked appointment via your booking link:`,
        ``,
        `When: ${request.slot.date} at ${request.slot.start} (${request.slot.timeZone})`,
        `Name: ${request.name}`,
        `Phone: ${request.phone || '-'}`,
        `Email: ${request.email || '-'}`,
        `Address: ${request.address || '-'}`,
        ``,
        `What they need:`,
        request.details,
        ``,
      ]
    : [
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
      ];
  if (hasReferralCode(request)) lines.push(REFERRAL_LINE);
  if (hasCampaignCode(request)) lines.push(CAMPAIGN_LINE);
  lines.push(closing);
  return {
    from: SENDER,
    to,
    subject: `${booked ? 'New booked appointment' : 'New quote request'} from ${sanitizeSubjectPart(request.name)}`.slice(0, 120),
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
          title: request.kind === 'booked' ? 'New booked appointment' : 'New quote request',
          body:
            request.kind === 'booked' && request.slot
              ? `${request.name} — ${request.slot.date} at ${request.slot.start}`
              : `${request.name} — ${String(request.details || '').slice(0, 120)}`,
          data: { type: 'booking_request' },
        }),
      });
      if (!r.ok) throw new Error(`Expo push ${r.status}: ${await r.text()}`);
    }
  } catch (err) {
    console.error('[booking/notify] push failed:', err.message);
  }
}

const UPDATE_TITLES = {
  request_reschedule: 'Reschedule requested',
  cancel: 'Booking cancelled',
  // Phase 32: a customer asked for an updated version of an expired estimate.
  quote_update: 'Updated estimate requested',
};

/**
 * Owner alert for a CUSTOMER action on an existing booking (Phase 11 D1).
 * Same fire-and-forget contract as notifyOwner. Push carries
 * type "booking_update" + the converted job id so a tap can land on the
 * exact job instead of the coarse Jobs list.
 */
async function notifyOwnerUpdate(env, { userId, settingsData, request, event, note }) {
  const title = UPDATE_TITLES[event] || 'Booking update';
  const when = request.slot ? `${request.slot.date} at ${request.slot.start}` : '';

  try {
    const to = await fetchOwnerEmail(env, userId);
    if (to && env.RESEND_API_KEY) {
      // A quote-update row's details name the estimate (and carry the note),
      // so an owner with several open estimates knows which one.
      const details = event === 'quote_update' && typeof request.details === 'string' ? request.details : '';
      const lines = [
        `${title} — ${request.name}${when ? ` (${when})` : ''}.`,
        ...(details ? [``, details] : note ? [``, `Their note:`, note] : []),
        ``,
        `Open TradeReady to respond.`,
      ];
      const r = await fetch('https://api.resend.com/emails', {
        method: 'POST',
        headers: { Authorization: `Bearer ${env.RESEND_API_KEY}`, 'Content-Type': 'application/json' },
        body: JSON.stringify({
          from: SENDER,
          to,
          subject: `${title}: ${sanitizeSubjectPart(request.name)}`.slice(0, 120),
          text: lines.join('\n'),
        }),
      });
      if (!r.ok) throw new Error(`Resend ${r.status}: ${await r.text()}`);
    }
  } catch (err) {
    console.error('[booking/notify-update] email failed:', err.message);
  }

  try {
    const token = settingsData && settingsData.pushToken && settingsData.pushToken.token;
    if (token) {
      const r = await fetch('https://exp.host/--/api/v2/push/send', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          to: token,
          title,
          body: `${request.name}${when ? ` — ${when}` : ''}`,
          // Booking rows carry convertedJobId; estimate/portal rows carry jobRef.
          data: { type: 'booking_update', jobId: request.convertedJobId || request.jobRef },
        }),
      });
      if (!r.ok) throw new Error(`Expo push ${r.status}: ${await r.text()}`);
    }
  } catch (err) {
    console.error('[booking/notify-update] push failed:', err.message);
  }
}

module.exports = { buildBookingEmail, notifyOwner, notifyOwnerUpdate };

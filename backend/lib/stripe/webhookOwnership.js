// Ownership check for the Stripe Connect webhook (backend/api/stripe/webhook.js).
// NOT routed by Vercel (lives under lib/, not api/).
//
// Why this exists: create-payment-link accepts `invoiceId` from the client body
// and stamps it into link metadata unchecked, so the invoiceId a
// checkout.session.completed event carries may name an invoice the payer's
// connected account does NOT own — a caller who learned a victim's invoice
// UUID could mint a link on their OWN connected account and a real payment
// into it would settle the victim's invoice. Connect events name the account
// they fired on in `event.account`; requiring that to equal the invoice
// owner's stripe_accounts row pins the payment to the right tradesperson.

/**
 * Decide whether a Connect event may settle the given user's invoice.
 *
 * Fetches the owner's stripe_accounts row via service-role REST (same pattern
 * as the webhook's invoices fetch) and compares its stripe_account_id to the
 * event's connected account.
 *
 * Returns { ok: true } on a match, or { ok: false, reason, expectedAccountId }
 * where reason is 'no-stripe-account' (owner never connected, or disconnected
 * since) or 'account-mismatch'. Neither is transient, so the caller should ACK
 * with a 200 skip rather than 500 — Stripe would retry forever. A Supabase
 * error throws instead: that IS transient and should 500 so Stripe retries.
 *
 * `fetchImpl` is injectable so tests can stub the REST call.
 */
async function verifyConnectedAccountOwnership({ supabaseUrl, headers, userId, eventAccount, fetchImpl = fetch }) {
  const res = await fetchImpl(
    `${supabaseUrl}/rest/v1/stripe_accounts?user_id=eq.${encodeURIComponent(userId)}&select=stripe_account_id`,
    { headers }
  );

  if (!res.ok) {
    throw new Error(`Supabase stripe_accounts fetch ${res.status}: ${await res.text()}`);
  }

  const rows = await res.json();
  if (!rows.length) {
    return { ok: false, reason: 'no-stripe-account', expectedAccountId: null };
  }

  const expectedAccountId = rows[0].stripe_account_id;
  // `event.account` is absent on platform-account events; fail closed on those
  // too — this endpoint only ever handles Connect traffic.
  if (!eventAccount || expectedAccountId !== eventAccount) {
    return { ok: false, reason: 'account-mismatch', expectedAccountId };
  }

  return { ok: true, expectedAccountId };
}

module.exports = { verifyConnectedAccountOwnership };

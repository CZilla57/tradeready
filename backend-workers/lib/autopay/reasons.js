// Charge-failure classification for autopay (Phase 24 spec §4.6 step 5,
// §4.8 failureReason). Pure.

// Hard failures revoke the enrollment so later invoices don't keep failing.
const HARD_DECLINE_CODES = new Set(['lost_card', 'stolen_card', 'pickup_card', 'invalid_account', 'restricted_card']);

function isExpired({ code, decline_code }) {
  return code === 'expired_card' || decline_code === 'expired_card';
}

function isHardFailure(err) {
  return isExpired(err) || HARD_DECLINE_CODES.has(err.decline_code);
}

function needsAuthentication({ code, decline_code }) {
  return code === 'authentication_required' || decline_code === 'authentication_required';
}

// The owner-route `failureReason` enum (spec §13.1) from a stored charge row.
function normalizeFailureReason(charge) {
  if (!charge || (charge.status !== 'failed' && charge.status !== 'skipped')) return null;
  const code = charge.failure_code || null;
  const decline = charge.decline_code || null;
  if (code === 'amount_above_authorized') return 'amount_above_authorized';
  if (code === 'payment_method_missing') return 'payment_method_missing';
  if (code === 'unknown') return 'unknown';
  if (code === 'processing_error') return 'processing_error';
  if (needsAuthentication({ code, decline_code: decline })) return 'authentication_required';
  if (isExpired({ code, decline_code: decline })) return 'expired_card';
  if (decline === 'insufficient_funds' || code === 'insufficient_funds') return 'insufficient_funds';
  return 'card_declined';
}

// Customer-facing clause for the failure email (spec §4.6 step 5).
function customerReasonClause(reason) {
  if (reason === 'authentication_required') return 'your bank asked you to confirm this payment';
  if (reason === 'expired_card') return 'the card on file has expired';
  if (reason === 'payment_method_missing') return 'the saved card is no longer available';
  if (reason === 'processing_error') return "we couldn't process the card";
  return 'your card was declined';
}

// Owner-facing clause for alerts.
function ownerReasonClause(reason) {
  switch (reason) {
    case 'authentication_required': return "the customer's bank asked them to confirm the payment";
    case 'expired_card': return 'the card on file has expired';
    case 'insufficient_funds': return 'insufficient funds';
    case 'payment_method_missing': return 'the saved card was removed on Stripe';
    case 'processing_error': return 'Stripe could not process the card';
    case 'amount_above_authorized': return 'the balance is above the amount the customer authorized';
    case 'unknown': return 'Stripe never confirmed the outcome';
    default: return 'the card was declined';
  }
}

module.exports = {
  HARD_DECLINE_CODES,
  isHardFailure,
  isExpired,
  needsAuthentication,
  normalizeFailureReason,
  customerReasonClause,
  ownerReasonClause,
};

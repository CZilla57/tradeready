// Turning autopay off (Phase 24 spec §2.5, §4.4 autopay-off, §4.6
// housekeeping, §4.8 manage, §4.11 disconnect/deletion). Every path ends in
// the same two steps: a CONDITIONAL status write (so concurrent revokes are
// idempotent) and a best-effort detach of the saved card on the owner's
// connected account. Stripe failures are logged, never surfaced: the
// enrollment row is what stops charges; the detach is hygiene.

const store = require('./store.js');

const enc = encodeURIComponent;

// Detach the enrollment's card unless another ACTIVE enrollment of the same
// owner still charges it (one customer can authorize several plans with the
// same card). Never throws.
async function detachIfUnused(env, stripe, enrollment) {
  const pm = enrollment && enrollment.payment_method_id;
  if (!pm || !stripe || !enrollment.stripe_account_id) return false;
  try {
    const others = await store.sbGet(
      env,
      `autopay_enrollments?user_id=eq.${enc(enrollment.user_id)}&payment_method_id=eq.${enc(pm)}` +
        `&status=eq.active&id=neq.${enc(enrollment.id)}&select=id`
    );
    if (others.length) return false;
  } catch (err) {
    // Can't prove the card is unused → keep it. A stray saved card is
    // harmless; detaching one another plan still charges is not.
    console.error('[autopay] detach check failed:', err.message);
    return false;
  }
  try {
    await stripe.paymentMethods.detach(pm, {}, { stripeAccount: enrollment.stripe_account_id });
    return true;
  } catch (err) {
    console.error(`[autopay] detach ${pm} failed:`, err.message);
    return false;
  }
}

// Conditional revoke of one enrollment. `from` lists the statuses it may
// leave (default active + pending). Returns { changed, row } where row is the
// updated row, or the enrollment as given when nothing changed.
async function revokeEnrollment(env, { enrollment, by, reason, stripe, from = ['active', 'pending'], to = 'revoked', detach = true }) {
  const rows = await store.updateEnrollments(env, `id=eq.${enc(enrollment.id)}&status=in.(${from.join(',')})`, {
    status: to,
    revoked_at: new Date().toISOString(),
    revoked_by: by || null,
    revoke_reason: reason,
  });
  const changed = rows.length > 0;
  const row = changed ? rows[0] : enrollment;
  if (changed && detach && enrollment.status === 'active') await detachIfUnused(env, stripe, row);
  return { changed, row };
}

// Disconnect (§4.11): revoke every active/pending enrollment and detach the
// cards on the OLD account, best-effort. TradeReady can no longer honor
// "turn off" there, so the cards must not stay usable through us.
async function revokeAllForUser(env, { userId, stripe, reason }) {
  let revoked = 0;
  const enrollments = await store.fetchEnrollmentsForUser(env, userId, { statuses: ['active', 'pending'] });
  for (const e of enrollments) {
    try {
      const { changed } = await revokeEnrollment(env, { enrollment: e, by: 'system', reason, stripe, detach: false });
      if (changed) revoked++;
    } catch (err) {
      console.error(`[autopay] revoke ${e.id} failed:`, err.message);
    }
  }
  await detachCards(stripe, enrollments);
  return { revoked, total: enrollments.length };
}

// Detach every distinct saved card in `enrollments` (all being torn down, so
// no in-use check). Never throws.
async function detachCards(stripe, enrollments) {
  if (!stripe) return 0;
  const seen = new Set();
  let detached = 0;
  for (const e of enrollments || []) {
    const pm = e && e.payment_method_id;
    if (!pm || !e.stripe_account_id || seen.has(`${e.stripe_account_id}|${pm}`)) continue;
    seen.add(`${e.stripe_account_id}|${pm}`);
    try {
      await stripe.paymentMethods.detach(pm, {}, { stripeAccount: e.stripe_account_id });
      detached++;
    } catch (err) {
      console.error(`[autopay] detach ${pm} failed:`, err.message);
    }
  }
  return detached;
}

module.exports = { detachIfUnused, revokeEnrollment, revokeAllForUser, detachCards };

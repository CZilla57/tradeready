// Maps a store product identifier to the subscriptions-table `plan` value.
// Case-insensitive on purpose: the live App Store Connect products are named
// "Monthly" / "Annual" (verified via the RC offerings API 2026-07-14), and
// ASC product ids are immutable — so the code adapts, not the dashboard.
// Annual wins if an id ever contains both words (e.g. "annual_billed_monthly").

function resolvePlan(productId) {
  const id = (productId || '').toLowerCase();
  if (id.includes('annual')) return 'annual';
  if (id.includes('monthly')) return 'monthly';
  return null;
}

module.exports = { resolvePlan };

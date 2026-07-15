// utils/format.ts
// Single home for currency formatting (roadmap #2 — replaces 7 divergent
// `formatCurrency` copies). Two formatters exist *by design*:
//
//   • formatMoney — actual amounts (invoices, expenses, receivables, totals).
//     Always shows cents. Never rounds (a $9.99 invoice is $9.99, not $10).
//
//   • formatQuote — estimate / pricing headline figures. Whole dollars, with
//     cents revealed only when the amount isn't round ($2,400 but $2,499.50).
//
// Both use Intl currency style, so negatives render as "-$500" (not the old
// "$-500" from the hand-rolled "$" + n.toLocaleString() copies).

/**
 * Format an actual monetary amount — invoices, expenses, totals owed/collected.
 *   formatMoney(2400)  -> "$2,400.00"
 *   formatMoney(9.99)  -> "$9.99"
 *   formatMoney(-500)  -> "-$500.00"
 */
export function formatMoney(amount: number): string {
  return (Number(amount) || 0).toLocaleString("en-US", {
    style: "currency",
    currency: "USD",
    minimumFractionDigits: 2,
    maximumFractionDigits: 2,
  });
}

/**
 * Format an estimate / pricing headline — whole dollars, cents only when the
 * amount isn't round.
 *   formatQuote(2400)     -> "$2,400"
 *   formatQuote(9.99)     -> "$9.99"
 *   formatQuote(1234.56)  -> "$1,234.56"
 *   formatQuote(-500)     -> "-$500"
 */
export function formatQuote(amount: number): string {
  // Round to cents first so float dust doesn't count as "has cents", then
  // render whole dollars or a FULL cent pair. min:0/max:2 alone produced
  // "$87.5" (beta finding 2026-07-14) — the doc above always promised
  // "$2,499.50"-style output.
  const cents = Math.round((Number(amount) || 0) * 100) / 100;
  const hasCents = !Number.isInteger(cents);
  return cents.toLocaleString("en-US", {
    style: "currency",
    currency: "USD",
    minimumFractionDigits: hasCents ? 2 : 0,
    maximumFractionDigits: 2,
  });
}

// Tips on pay-page payments (Roadmap Phase 28, tips spec §2–§4). Pure.
//
// Money rules this module encodes:
//   - Tips are offered only when the owner's synced settings say
//     `tipsEnabled === true`, and only on a FINAL payment: an unpaid invoice,
//     paid for its full live balance, through a link that was not minted as a
//     deposit. Never on deposits, setup/manage pages, autopay charges or
//     legacy Payment Links (spec §3, T3).
//   - The tip is capped server-side at the invoice amount being paid (T4).
//   - The webhook splits a session into the invoice portion and the tip ONLY
//     from server-set metadata that reconciles exactly with Stripe's
//     amount_total. Anything else books the whole amount as the invoice
//     payment, as before Phase 28 (T5): money is never dropped.
//   - A tip is never an invoice payment: it never feeds paymentMath.js.

const { MAX_CENTS } = require('./payToken.js');

const TIP_PRESETS_PERCENT = Object.freeze([10, 15, 20]);

function tipsEnabled(settings) {
  return !!settings && typeof settings === 'object' && settings.tipsEnabled === true;
}

// The amount (cents) a tip may be added to, or null when no tip is offered.
// `payload` is the verified `p` token payload, `chargeCents` what this visit
// charges (tokenCharge), `balanceCents` the live balance.
//   - chargeCents === balanceCents: the payment settles the invoice (the
//     same full-balance test the autopay offer uses).
//   - no `b` in the token: `b` is stamped only on a link minted as a partial
//     ask, i.e. a deposit link. Phase 24 turns such a link into a
//     remaining-balance link once the deposit lands; it still never offers a
//     tip (Stripe: tips only for service already provided, spec §0.4).
function tipBaseCents({ settings, paid, payload, balanceCents, chargeCents }) {
  if (!tipsEnabled(settings) || paid) return null;
  if (!Number.isInteger(balanceCents) || balanceCents <= 0) return null;
  if (chargeCents !== balanceCents) return null;
  if (!payload || payload.b !== undefined) return null;
  if (payload.a !== undefined && payload.a < balanceCents) return null;
  return balanceCents;
}

// A preset tip: `percent` of the base, rounded half-up to the cent, in
// integer arithmetic (pay.html mirrors this exactly).
function presetTipCents(baseCents, percent) {
  return Math.floor((baseCents * percent + 50) / 100);
}

// The view's `tips` block (spec §4.1): null | { presetsPercent, baseAmount }.
function tipsBlock(baseCents) {
  if (!baseCents) return null;
  return { presetsPercent: [...TIP_PRESETS_PERCENT], baseAmount: baseCents / 100 };
}

// POST body `tipCents`: absent / null / 0 → no tip. Otherwise a
// non-negative integer number of cents (a JSON number, never a string).
// → { ok: true, cents } | { ok: false }
function parseTipCents(raw) {
  if (raw === undefined || raw === null) return { ok: true, cents: 0 };
  if (typeof raw !== 'number' || !Number.isSafeInteger(raw) || raw < 0 || raw > MAX_CENTS) return { ok: false };
  return { ok: true, cents: raw };
}

function metaInt(v) {
  if (typeof v === 'number') return Number.isSafeInteger(v) && v >= 0 ? v : null;
  if (typeof v !== 'string' || !/^\d{1,12}$/.test(v)) return null;
  return Number(v);
}

// Webhook split (spec §4.3) of a paid payment-mode Checkout Session.
// → { invoiceCents, tipCents, mismatch }
//   - split: tr_invoice_cents (> 0) + tr_tip_cents (default 0) === amount_total
//   - otherwise the whole amount_total is the invoice portion and tipCents is
//     0; `mismatch` is true only when tr_ amount keys were present (a legacy
//     Payment Link session has none and is not a mismatch).
function splitSessionAmount(session) {
  const md = (session && session.metadata) || {};
  const total = session ? session.amount_total : undefined;
  const hasKeys = md.tr_invoice_cents !== undefined || md.tr_tip_cents !== undefined;
  const invoiceCents = metaInt(md.tr_invoice_cents);
  const tipCents = md.tr_tip_cents === undefined ? 0 : metaInt(md.tr_tip_cents);
  if (invoiceCents !== null && invoiceCents > 0 && tipCents !== null && Number.isSafeInteger(total) && invoiceCents + tipCents === total) {
    return { invoiceCents, tipCents, mismatch: false };
  }
  return { invoiceCents: total || 0, tipCents: 0, mismatch: hasKeys };
}

module.exports = {
  TIP_PRESETS_PERCENT,
  tipsEnabled,
  tipBaseCents,
  presetTipCents,
  tipsBlock,
  parseTipCents,
  splitSessionAmount,
};

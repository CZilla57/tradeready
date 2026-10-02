// Good/better/best quote options (Roadmap Phase 25). Pure helpers shared by
// create-link (shape validation), view (digest), respond (digest + selection)
// and the portal assembler. Spec: docs/superpowers/specs/
// 2026-10-02-quote-options-design.md §2.2, §2.3, §3, §4.
//
// The selection arithmetic is a parity contract with the native app: both
// sides sum in integer cents and load the same vectors from
// native/QuoteOptionsTests/Fixtures/quote-selection-vectors.json.

const { createHash } = require('node:crypto');

const MIN_TIERS = 2;
const MAX_TIERS = 3;
const MAX_ADD_ONS = 10;
const MAX_ADD_ON_AMOUNT = 1_000_000;
const MAX_ID_CHARS = 100;
const MAX_TIER_NAME_CHARS = 60;
const MAX_TIER_DESCRIPTION_CHARS = 300;
const MAX_ADD_ON_LABEL_CHARS = 80;
const MAX_ADD_ON_DESCRIPTION_CHARS = 200;
// Line labels are derived on the device (labor, materials, owner-named direct
// costs); these bounds only stop garbage, they are not a UI rule.
const MAX_LINE_LABEL_CHARS = 300;
const MAX_LINE_ITEMS = 100;

function isPlainObject(v) {
  return v !== null && typeof v === 'object' && !Array.isArray(v);
}

function hasSnapshotOptions(snapshot) {
  return isPlainObject(snapshot) && snapshot.options != null;
}

// Lengths are UTF-16 code units — JS `length`, and exactly what the native
// editor measures (NativeQuoteOptions `length(_:)` uses `utf16.count`).
function badText(value, { min, max }) {
  if (typeof value !== 'string') return true;
  if (min > 0 && value.trim().length === 0) return true;
  return value.length > max;
}

function badOptionalText(value, max) {
  return value != null && badText(value, { min: 0, max });
}

function badId(value) {
  return typeof value !== 'string' || value.length === 0 || value.length > MAX_ID_CHARS;
}

function isNonNegativeAmount(v) {
  return typeof v === 'number' && Number.isFinite(v) && v >= 0;
}

// Returns null when snapshot.options matches §2.2 and the §2.1 limits, else
// a client-safe error string. Absent `addOns` is read as none.
function validateSnapshotOptions(snapshot) {
  const options = isPlainObject(snapshot) ? snapshot.options : undefined;
  if (!isPlainObject(options)) return 'Quote options are malformed.';

  const { tiers, recommendedTierId } = options;
  if (!Array.isArray(tiers) || tiers.length < MIN_TIERS || tiers.length > MAX_TIERS) {
    return `Quote options need ${MIN_TIERS} to ${MAX_TIERS} tiers.`;
  }
  const tierIds = new Set();
  for (const tier of tiers) {
    if (!isPlainObject(tier)) return 'Each option must be an object.';
    if (badId(tier.id)) return 'Each option needs an id.';
    if (tierIds.has(tier.id)) return 'Option ids must be unique.';
    tierIds.add(tier.id);
    if (badText(tier.name, { min: 1, max: MAX_TIER_NAME_CHARS })) {
      return `Option names must be 1 to ${MAX_TIER_NAME_CHARS} characters.`;
    }
    if (badOptionalText(tier.description, MAX_TIER_DESCRIPTION_CHARS)) {
      return `Option descriptions must be at most ${MAX_TIER_DESCRIPTION_CHARS} characters.`;
    }
    if (!isNonNegativeAmount(tier.total)) return 'Option totals must be zero or more.';
    if (!Array.isArray(tier.lineItems) || tier.lineItems.length > MAX_LINE_ITEMS) {
      return `Each option needs a list of at most ${MAX_LINE_ITEMS} line items.`;
    }
    for (const line of tier.lineItems) {
      if (!isPlainObject(line) || badText(line.label, { min: 0, max: MAX_LINE_LABEL_CHARS })) {
        return `Line item labels must be at most ${MAX_LINE_LABEL_CHARS} characters.`;
      }
      if (!isNonNegativeAmount(line.amount)) return 'Line item amounts must be zero or more.';
    }
  }
  if (typeof recommendedTierId !== 'string' || !tierIds.has(recommendedTierId)) {
    return 'The recommended option must be one of the options.';
  }

  const addOns = options.addOns === undefined ? [] : options.addOns;
  if (!Array.isArray(addOns) || addOns.length > MAX_ADD_ONS) {
    return `Quote options allow at most ${MAX_ADD_ONS} add-ons.`;
  }
  const addOnIds = new Set();
  for (const addOn of addOns) {
    if (!isPlainObject(addOn)) return 'Each add-on must be an object.';
    if (badId(addOn.id)) return 'Each add-on needs an id.';
    if (addOnIds.has(addOn.id)) return 'Add-on ids must be unique.';
    addOnIds.add(addOn.id);
    if (badText(addOn.label, { min: 1, max: MAX_ADD_ON_LABEL_CHARS })) {
      return `Add-on labels must be 1 to ${MAX_ADD_ON_LABEL_CHARS} characters.`;
    }
    if (badOptionalText(addOn.description, MAX_ADD_ON_DESCRIPTION_CHARS)) {
      return `Add-on descriptions must be at most ${MAX_ADD_ON_DESCRIPTION_CHARS} characters.`;
    }
    const { amount } = addOn;
    if (typeof amount !== 'number' || !Number.isFinite(amount) || amount <= 0 || amount > MAX_ADD_ON_AMOUNT) {
      return 'Add-on prices must be more than $0 and at most $1,000,000.';
    }
  }
  return null;
}

// Canonical JSON: object keys sorted recursively; otherwise JSON.stringify's
// rules (undefined members skipped, undefined/non-finite values → null).
function canonicalJson(value) {
  if (value === null || typeof value !== 'object') {
    const s = JSON.stringify(value);
    return s === undefined ? 'null' : s;
  }
  if (Array.isArray(value)) return `[${value.map(canonicalJson).join(',')}]`;
  const keys = Object.keys(value)
    .filter((k) => value[k] !== undefined && typeof value[k] !== 'function')
    .sort();
  return `{${keys.map((k) => `${JSON.stringify(k)}:${canonicalJson(value[k])}`).join(',')}}`;
}

// SHA-256 hex of the canonical encoding. The page echoes the digest it was
// shown so respond can refuse a decision made against a superseded snapshot.
function snapshotDigest(snapshot) {
  return createHash('sha256').update(canonicalJson(snapshot), 'utf8').digest('hex');
}

function cents(amount) {
  return Math.round(Number(amount) * 100);
}

// §3: resolves the customer's {tierId, addOnIds} against the frozen snapshot.
// Returns { selection } or { error: 'choose_option' | 'invalid_addons' }.
function resolveSelection(snapshot, input) {
  const options = hasSnapshotOptions(snapshot) ? snapshot.options : {};
  const tiers = Array.isArray(options.tiers) ? options.tiers : [];
  const snapshotAddOns = Array.isArray(options.addOns) ? options.addOns : [];
  const req = isPlainObject(input) ? input : {};

  const tier = typeof req.tierId === 'string'
    ? tiers.find((t) => isPlainObject(t) && t.id === req.tierId)
    : undefined;
  if (!tier) return { error: 'choose_option' };

  const raw = req.addOnIds === undefined ? [] : req.addOnIds;
  // The cap applies to the raw list, before de-duplication.
  if (!Array.isArray(raw) || raw.length > MAX_ADD_ONS) return { error: 'invalid_addons' };
  if (raw.some((id) => typeof id !== 'string')) return { error: 'invalid_addons' };
  const wanted = new Set(raw);
  const known = new Set(snapshotAddOns.filter(isPlainObject).map((a) => a.id));
  for (const id of wanted) {
    if (!known.has(id)) return { error: 'invalid_addons' };
  }

  const addOns = snapshotAddOns
    .filter((a) => isPlainObject(a) && wanted.has(a.id))
    .map((a) => ({ id: a.id, label: a.label, amount: Number(a.amount) }));
  const tierLines = (Array.isArray(tier.lineItems) ? tier.lineItems : [])
    .map((li) => ({ label: li.label, amount: Number(li.amount) }));
  const totalCents = addOns.reduce((sum, a) => sum + cents(a.amount), cents(tier.total));

  return {
    selection: {
      tierId: tier.id,
      tierName: tier.name,
      addOnIds: addOns.map((a) => a.id),
      addOns,
      lineItems: [...tierLines, ...addOns.map((a) => ({ label: a.label, amount: a.amount }))],
      total: totalCents / 100,
    },
  };
}

// True only for the shape resolveSelection produces — the guard nextApproval
// uses so a raw request body can never be persisted as a selection.
function isResolvedSelection(v) {
  return isPlainObject(v)
    && typeof v.tierId === 'string'
    && typeof v.tierName === 'string'
    && Array.isArray(v.addOnIds)
    && Array.isArray(v.addOns)
    && Array.isArray(v.lineItems)
    && typeof v.total === 'number'
    && Number.isFinite(v.total);
}

// Lowest tier total, for the portal's "From $X". null when no tier has one.
function lowestTierTotal(snapshot) {
  const tiers = hasSnapshotOptions(snapshot) && Array.isArray(snapshot.options.tiers)
    ? snapshot.options.tiers : [];
  const totals = tiers
    .map((t) => Number(t && t.total))
    .filter((n) => Number.isFinite(n));
  return totals.length ? Math.min(...totals) : null;
}

module.exports = {
  MAX_ADD_ONS,
  validateSnapshotOptions,
  snapshotDigest,
  canonicalJson,
  resolveSelection,
  isResolvedSelection,
  hasSnapshotOptions,
  lowestTierTotal,
};

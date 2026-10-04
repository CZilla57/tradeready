// Public schemas and allowlist mappers for the read-only open API (Roadmap
// Phase 23). Spec: docs/superpowers/specs/2026-10-03-open-api-design.md §3.
//
// THIS FILE IS THE SECURITY BOUNDARY for field exposure. The blob rows it
// reads also carry internal notes, labour rates, materials, margins, local
// file paths, approval tokens, consent IP/user agent, payment-link amounts
// and (on settings) vendor API keys. Every public object is built key by key
// from SCHEMA — never a spread, never a cleaned copy — so a field a later
// phase adds to a blob stays invisible until someone adds it here on purpose.
// Tests pin Object.keys(toPublic.x(row)) to FIELDS.x for fixtures that carry
// every known blob field plus junk.
//
// Money reuses the device ledger math (paymentMath.js) and is rounded to
// cents. Business dates are the stored strings, never shifted. Server
// timestamps are ISO-8601 UTC. Absent optional values are null.
//
// Pure: no I/O, no clock reads (callers pass nowMs).

const { amountPaid, balanceDue, isFullyPaid, materializeLegacyLedger, PAID_EPSILON } = require('../paymentMath.js');
const { isAllowedPaymentLink } = require('../reminderEmail.js');
const { hasSnapshotOptions, lowestTierTotal, isResolvedSelection } = require('../estimate/quoteOptions.js');
const { snapshotExpiry } = require('../estimate/estimateExpiry.js');

const API_VERSION = '2026-10-03';
const CURRENCY = 'USD';

// ── primitives ────────────────────────────────────────────────────────────

function isPlainObject(v) {
  return v !== null && typeof v === 'object' && !Array.isArray(v);
}

function obj(v) {
  return isPlainObject(v) ? v : {};
}

function str(v) {
  return typeof v === 'string' ? v : null;
}

// paymentMath's toAmount rule (a malformed amount contributes zero), then
// rounded half away from zero to cents. toPrecision(15) drops binary noise
// first, so 12.345 (stored as 12.3449999…) rounds to 12.35 like a person
// would expect.
function toAmount(value) {
  const n = typeof value === 'number' ? value : parseFloat(String(value));
  return Number.isFinite(n) ? n : 0;
}

function money(value) {
  const cents = Number((Math.abs(toAmount(value)) * 100).toPrecision(15));
  const rounded = (Math.sign(toAmount(value)) * Math.round(cents)) / 100;
  return rounded === 0 ? 0 : rounded;
}

function num(value) {
  if (value === null || value === undefined || value === '') return null;
  const n = typeof value === 'number' ? value : Number(value);
  return Number.isFinite(n) ? n : null;
}

function isoUtc(value) {
  if (typeof value !== 'string' || value.length === 0) return null;
  const ms = Date.parse(value);
  return Number.isFinite(ms) ? new Date(ms).toISOString() : null;
}

function rowId(row) {
  return row && row.id !== undefined && row.id !== null ? String(row.id) : null;
}

// ── public schemas (OpenAPI 3.1 JSON Schema) ─────────────────────────────
// SCHEMA[x] is the single source for FIELDS[x] (its key order) and for the
// generated /v1/openapi.json, so docs and mappers cannot drift.

const T = {
  id: { type: 'string' },
  text: { type: ['string', 'null'] },
  date: { type: ['string', 'null'], description: 'Stored business date, usually YYYY-MM-DD. Never shifted.' },
  time: { type: ['string', 'null'], description: 'Stored local time, HH:mm.' },
  updatedAt: { type: 'string', format: 'date-time', description: 'Server clock, UTC.' },
  timestamp: { type: ['string', 'null'], format: 'date-time' },
  money: { type: 'number', description: 'US dollars, rounded to cents.' },
  number: { type: ['number', 'null'] },
  boolean: { type: 'boolean' },
};

function object(properties, { nullable = false, description } = {}) {
  const out = {
    type: nullable ? ['object', 'null'] : 'object',
    properties,
    required: Object.keys(properties),
    additionalProperties: false,
  };
  if (description) out.description = description;
  return out;
}

function arrayOf(items) {
  return { type: 'array', items };
}

function enumOf(values, { nullable = false } = {}) {
  return nullable ? { type: ['string', 'null'], enum: [...values, null] } : { type: 'string', enum: values };
}

const PAYMENT_METHODS = ['stripe', 'cash', 'check', 'card', 'bank_transfer', 'other'];
const PAYMENT_SOURCES = ['device', 'stripe', 'legacy'];
const INVOICE_STATUSES = ['paid', 'partly_paid', 'unpaid'];
const ESTIMATE_STATUSES = ['draft', 'sent', 'approved', 'declined', 'expired'];
const DECISIONS = ['approved', 'declined'];

const SUB = {
  estimateLine: object({ label: T.text, amount: T.money }),
  tier: object({ id: T.text, name: T.text, total: T.money }),
  addOn: object({ id: T.text, label: T.text, amount: T.money }),
  invoiceLine: object({ description: T.text, category: T.text, amount: T.money }),
  key: object({
    id: T.id,
    name: T.text,
    prefix: T.text,
    scopes: arrayOf({ type: 'string' }),
    expiresAt: T.timestamp,
  }),
};
SUB.options = object(
  { tiers: arrayOf(SUB.tier), addOns: arrayOf(SUB.addOn), recommendedTierId: T.text },
  { nullable: true, description: 'Good/better/best options as the customer saw them, or null.' }
);
SUB.selection = object(
  { tierId: T.text, tierName: T.text, addOnIds: arrayOf({ type: 'string' }), total: T.money },
  { nullable: true, description: "The customer's accepted option, or null." }
);
SUB.depositRequest = object(
  { amount: T.money, percent: T.number, requestedAt: T.date },
  { nullable: true }
);

const PAYMENT_SCHEMA = {
  id: T.id,
  invoiceId: T.id,
  invoiceNumber: T.text,
  customerId: T.text,
  amount: T.money,
  date: T.date,
  method: enumOf(PAYMENT_METHODS),
  source: enumOf(PAYMENT_SOURCES),
  voided: T.boolean,
  voidedAt: T.date,
  processorReference: T.text,
  updatedAt: T.updatedAt,
};
SUB.payment = object(PAYMENT_SCHEMA);

const SCHEMA = {
  account: {
    businessName: T.text,
    currency: { type: 'string', enum: [CURRENCY] },
    dataAsOf: T.timestamp,
    apiVersion: { type: 'string' },
    key: SUB.key,
  },
  customers: {
    id: T.id,
    name: T.text,
    email: T.text,
    phone: T.text,
    address: T.text,
    leadSource: T.text,
    createdAt: T.date,
    archivedAt: T.date,
    updatedAt: T.updatedAt,
  },
  jobs: {
    id: T.id,
    customerId: T.text,
    customerName: T.text,
    title: T.text,
    description: T.text,
    status: T.text,
    scheduledDate: T.date,
    scheduledStartTime: T.time,
    scheduledEndTime: T.time,
    address: T.text,
    price: { ...T.money, description: 'The customer-facing estimate total.' },
    invoiceId: T.text,
    recurringJobId: T.text,
    estimateSentAt: T.date,
    createdAt: T.date,
    archivedAt: T.date,
    updatedAt: T.updatedAt,
  },
  estimates: {
    id: { ...T.id, description: 'The job id.' },
    jobId: T.id,
    customerId: T.text,
    customerName: T.text,
    title: T.text,
    status: enumOf(ESTIMATE_STATUSES),
    sentAt: T.date,
    validUntil: T.date,
    total: T.money,
    lineItems: arrayOf(SUB.estimateLine),
    options: SUB.options,
    decision: enumOf(DECISIONS, { nullable: true }),
    decidedAt: T.timestamp,
    signerName: T.text,
    selection: SUB.selection,
    updatedAt: T.updatedAt,
  },
  invoices: {
    id: T.id,
    number: T.text,
    customerId: T.text,
    customerName: T.text,
    jobId: T.text,
    recurringInvoiceId: T.text,
    description: T.text,
    amount: T.money,
    amountPaid: T.money,
    balanceDue: T.money,
    status: enumOf(INVOICE_STATUSES),
    issueDate: T.date,
    due: T.date,
    paid: T.boolean,
    paidAt: T.date,
    depositRequest: SUB.depositRequest,
    lineItems: arrayOf(SUB.invoiceLine),
    payments: arrayOf(SUB.payment),
    paymentLinkUrl: { type: ['string', 'null'], format: 'uri' },
    updatedAt: T.updatedAt,
  },
  payments: PAYMENT_SCHEMA,
  expenses: {
    id: T.id,
    date: T.date,
    description: T.text,
    amount: T.money,
    category: T.text,
    categoryLabel: { type: 'string' },
    jobId: T.text,
    hasReceipt: T.boolean,
    createdAt: T.date,
    updatedAt: T.updatedAt,
  },
  mileage: {
    id: T.id,
    date: T.date,
    miles: T.number,
    odometerStart: T.number,
    odometerEnd: T.number,
    fromLabel: T.text,
    toLabel: T.text,
    fromJobId: T.text,
    toJobId: T.text,
    purpose: T.text,
    createdAt: T.date,
    updatedAt: T.updatedAt,
  },
  tombstone: {
    id: T.id,
    deleted: { type: 'boolean', const: true },
    updatedAt: T.updatedAt,
  },
};

const FIELDS = Object.freeze(
  Object.fromEntries(Object.entries(SCHEMA).map(([name, props]) => [name, Object.freeze(Object.keys(props))]))
);

// ── derivations ───────────────────────────────────────────────────────────

// The shared expense category table (NativeExpenseCategories, utils/csvExport).
// An unknown id is shown as "Other".
const EXPENSE_CATEGORY_LABELS = Object.freeze({
  materials: 'Materials',
  tools: 'Tools & Equipment',
  fuel: 'Fuel & Transport',
  labor: 'Subcontractors',
  insurance: 'Insurance',
  software: 'Software & Apps',
  marketing: 'Marketing',
  other: 'Other',
});

function expenseCategoryLabel(id) {
  return Object.prototype.hasOwnProperty.call(EXPENSE_CATEGORY_LABELS, id) ? EXPENSE_CATEGORY_LABELS[id] : 'Other';
}

// Accountant-package rule (NativeAccountingPackage.recoverIssueDate): an
// `inv<epoch ms>` or bare `<epoch ms>` id yields its UTC date in 2000–2100;
// anything else has no recoverable issue date.
function recoverIssueDate(id) {
  const s = typeof id === 'string' ? id : '';
  const raw = s.startsWith('inv') ? s.slice(3) : s;
  if (raw.length === 0 || !/^[0-9]+$/.test(raw)) return null;
  const d = new Date(Number(raw));
  if (!Number.isFinite(d.getTime())) return null;
  const year = d.getUTCFullYear();
  if (year < 2000 || year > 2100) return null;
  return d.toISOString().slice(0, 10);
}

// The native display-string map (Models.swift LedgerPaymentMethod init) plus
// `stripe`, RN's union member.
function normalizeMethod(method) {
  switch (String(method ?? '').trim().toLowerCase()) {
    case 'cash': return 'cash';
    case 'check':
    case 'cheque': return 'check';
    case 'card': return 'card';
    case 'stripe': return 'stripe';
    case 'ach':
    case 'bank transfer':
    case 'bank_transfer': return 'bank_transfer';
    default: return 'other';
  }
}

// Accountant-package rule (NativeAccountingPackage.paymentSource).
function paymentSource(id) {
  const s = typeof id === 'string' ? id : '';
  if (s.startsWith('stripe_')) return 'stripe';
  if (s.startsWith('legacy_')) return 'legacy';
  return 'device';
}

// The Checkout Session id when recorded; otherwise a webhook/Tap to Pay
// entry's id carries the processor id after `stripe_` (Phase 18 writes
// `stripe_<payment_intent_id>`).
function processorReference(p) {
  if (typeof p.stripeSessionId === 'string' && p.stripeSessionId.length > 0) return p.stripeSessionId;
  if (typeof p.id === 'string' && p.id.startsWith('stripe_') && p.id.length > 7) return p.id.slice(7);
  return null;
}

// Mirrors the portal's linkCurrent gate (portalAssemble.js buildInvoices): a
// cached link is shown only while the invoice is unpaid, the link is on the
// allowed-host list, and it was minted for the CURRENT balance. Pinned to
// the portal by a parity test.
function currentPaymentLink(inv) {
  const link = inv.paymentLinkUrl;
  const linkAmount = Number(inv.paymentLinkAmount);
  const current =
    !inv.paid &&
    isAllowedPaymentLink(link) &&
    Number.isFinite(linkAmount) &&
    Math.abs(linkAmount - balanceDue(inv)) <= PAID_EPSILON;
  return current ? link : null;
}

function invoiceStatus(inv) {
  if (isFullyPaid(inv)) return 'paid';
  if (amountPaid(inv) > PAID_EPSILON) return 'partly_paid';
  return 'unpaid';
}

// Mirrors the portal's estimateTotal (portalAssemble.js): an accepted
// good/better/best choice is the agreed price; an undecided options estimate
// shows its lowest tier; otherwise the frozen snapshot total. Pinned to the
// portal by a parity test.
function approvalTotal(approval) {
  const accepted = approval.decision === 'approved' && approval.selection
    ? Number(approval.selection.total) : NaN;
  if (Number.isFinite(accepted)) return accepted;
  if (hasSnapshotOptions(approval.snapshot)) {
    const lowest = lowestTierTotal(approval.snapshot);
    if (lowest !== null) return lowest;
  }
  return Number((approval.snapshot && approval.snapshot.total) || 0);
}

// A job is an estimate when it carries an approval link or a sent stamp.
function isEstimateJob(data) {
  const d = obj(data);
  return isPlainObject(d.approval) || (typeof d.estimateSentAt === 'string' && d.estimateSentAt.length > 0);
}

// Job statuses that mean the owner recorded a decision by hand.
const MANUALLY_APPROVED = new Set(['approved', 'scheduled', 'in_progress', 'complete', 'invoiced', 'paid']);

function manualDecision(status) {
  if (status === 'declined') return 'declined';
  if (MANUALLY_APPROVED.has(status)) return 'approved';
  return null;
}

// Estimate status table (spec §3; build record 14.x):
//   1. A customer decision on the approval link wins: approved | declined.
//   2. Otherwise a job status the owner moved by hand: declined, or any
//      post-approval status → approved.
//   3. Otherwise a job with no approval link that is back at `lead` → draft.
//   4. Otherwise sent, or expired once the valid-until date has passed in
//      the owner's zone (the Worker's snapshotExpiry; a job-only date has no
//      zone and uses anywhere-on-Earth, which never expires early).
function estimateStatus(d, nowMs) {
  const approval = isPlainObject(d.approval) ? d.approval : null;
  if (approval && DECISIONS.includes(approval.decision)) return approval.decision;
  const manual = manualDecision(d.status);
  if (manual) return manual;
  if (!approval && d.status === 'lead') return 'draft';
  const { expired } = approval
    ? snapshotExpiry(approval.snapshot, nowMs)
    : snapshotExpiry({ validUntil: d.estimateValidUntil }, nowMs);
  return expired ? 'expired' : 'sent';
}

// ── mappers ───────────────────────────────────────────────────────────────

function tombstone(id, updatedAt) {
  return { id: String(id), deleted: true, updatedAt: isoUtc(updatedAt) };
}

function toCustomer(row) {
  const d = obj(row.data);
  return {
    id: rowId(row),
    name: str(d.name),
    email: str(d.email),
    phone: str(d.phone),
    address: str(d.address),
    leadSource: str(d.leadSource),
    createdAt: str(d.createdAt),
    archivedAt: str(d.archivedAt),
    updatedAt: isoUtc(row.updated_at),
  };
}

function toJob(row) {
  const d = obj(row.data);
  return {
    id: rowId(row),
    customerId: str(d.customerId),
    customerName: str(d.customerName),
    title: str(d.title),
    description: str(d.description),
    status: str(d.status),
    scheduledDate: str(d.scheduledDate),
    scheduledStartTime: str(d.scheduledStartTime),
    scheduledEndTime: str(d.scheduledEndTime),
    address: str(d.address),
    price: money(d.estimateTotal),
    invoiceId: str(d.invoiceId),
    recurringJobId: str(d.recurringJobId),
    estimateSentAt: str(d.estimateSentAt),
    createdAt: str(d.createdAt),
    archivedAt: str(d.archivedAt),
    updatedAt: isoUtc(row.updated_at),
  };
}

function toEstimateLines(lines) {
  return (Array.isArray(lines) ? lines : []).filter(isPlainObject).map((li) => ({
    label: str(li.label),
    amount: money(li.amount),
  }));
}

function toOptions(snapshot) {
  if (!hasSnapshotOptions(snapshot) || !isPlainObject(snapshot.options)) return null;
  const o = snapshot.options;
  return {
    tiers: (Array.isArray(o.tiers) ? o.tiers : []).filter(isPlainObject).map((t) => ({
      id: str(t.id),
      name: str(t.name),
      total: money(t.total),
    })),
    addOns: (Array.isArray(o.addOns) ? o.addOns : []).filter(isPlainObject).map((a) => ({
      id: str(a.id),
      label: str(a.label),
      amount: money(a.amount),
    })),
    recommendedTierId: str(o.recommendedTierId),
  };
}

function toSelection(selection) {
  if (!isResolvedSelection(selection)) return null;
  return {
    tierId: str(selection.tierId),
    tierName: str(selection.tierName),
    addOnIds: selection.addOnIds.filter((id) => typeof id === 'string'),
    total: money(selection.total),
  };
}

// Reads ONLY the frozen, customer-facing approval snapshot and selection —
// never quoteOptions (internal add-on costs), never token/ip/userAgent, and
// never the decline reason (the customer's free text to the owner, D7).
// Returns null for a job that is not an estimate.
function toEstimate(row, { nowMs }) {
  const d = obj(row.data);
  if (!isEstimateJob(d)) return null;
  const approval = isPlainObject(d.approval) ? d.approval : null;
  const snapshot = approval ? obj(approval.snapshot) : {};
  const linkDecision = approval && DECISIONS.includes(approval.decision) ? approval.decision : null;
  const validUntil = approval
    ? snapshotExpiry(approval.snapshot, nowMs).validUntil
    : snapshotExpiry({ validUntil: d.estimateValidUntil }, nowMs).validUntil;
  return {
    id: rowId(row),
    jobId: rowId(row),
    customerId: str(d.customerId),
    customerName: str(snapshot.customerName) ?? str(d.customerName),
    title: str(snapshot.jobTitle) ?? str(d.title),
    status: estimateStatus(d, nowMs),
    sentAt: (approval && str(approval.sentAt)) ?? str(d.estimateSentAt),
    validUntil,
    total: approval ? money(approvalTotal(approval)) : money(d.estimateTotal),
    lineItems: toEstimateLines(snapshot.lineItems),
    options: approval ? toOptions(snapshot) : null,
    decision: linkDecision ?? manualDecision(d.status),
    // A manual owner decision has no decidedAt (spec §3).
    decidedAt: linkDecision ? isoUtc(approval.consentAt) : null,
    signerName: linkDecision ? str(approval.signerName) : null,
    selection: linkDecision === 'approved' ? toSelection(approval.selection) : null,
    updatedAt: isoUtc(row.updated_at),
  };
}

// The invoice's ledger exactly as the device math sees it: a legacy paid
// invoice with no ledger gets its synthesized `legacy_<id>` entry, so the
// payments list always sums to amountPaid.
function invoiceLedger(row) {
  const inv = { ...obj(row.data), id: rowId(row) };
  return materializeLegacyLedger(inv).filter(isPlainObject);
}

function toPayment(p, row) {
  const inv = obj(row.data);
  return {
    id: str(p.id) ?? String(p.id ?? ''),
    invoiceId: rowId(row),
    invoiceNumber: str(inv.number),
    customerId: str(inv.customerId),
    amount: money(p.amount),
    date: str(p.date),
    method: normalizeMethod(p.method),
    source: paymentSource(p.id),
    voided: Boolean(p.voidedAt),
    voidedAt: str(p.voidedAt),
    processorReference: processorReference(p),
    updatedAt: isoUtc(row.updated_at),
  };
}

function toPayments(row) {
  return invoiceLedger(row).map((p) => toPayment(p, row));
}

function toInvoice(row) {
  const inv = obj(row.data);
  const dr = isPlainObject(inv.depositRequest) ? inv.depositRequest : null;
  return {
    id: rowId(row),
    number: str(inv.number),
    customerId: str(inv.customerId),
    customerName: str(inv.customer),
    jobId: str(inv.jobId),
    recurringInvoiceId: str(inv.recurringInvoiceId),
    description: str(inv.desc),
    amount: money(inv.amount),
    amountPaid: money(amountPaid(inv)),
    balanceDue: money(balanceDue(inv)),
    status: invoiceStatus(inv),
    issueDate: recoverIssueDate(rowId(row)),
    due: str(inv.due),
    paid: inv.paid === true,
    paidAt: str(inv.paidAt),
    depositRequest: dr
      ? { amount: money(dr.amount), percent: num(dr.percent), requestedAt: str(dr.requestedAt) }
      : null,
    lineItems: (Array.isArray(inv.lineItems) ? inv.lineItems : []).filter(isPlainObject).map((li) => ({
      description: str(li.description),
      category: str(li.category),
      amount: money(li.amount),
    })),
    payments: toPayments(row),
    paymentLinkUrl: currentPaymentLink(inv),
    updatedAt: isoUtc(row.updated_at),
  };
}

function toExpense(row) {
  const d = obj(row.data);
  return {
    id: rowId(row),
    date: str(d.date),
    description: str(d.description),
    amount: money(d.amount),
    category: str(d.category),
    categoryLabel: expenseCategoryLabel(d.category),
    jobId: str(d.jobId),
    // The local path itself never leaves.
    hasReceipt: typeof d.receiptUri === 'string' && d.receiptUri.length > 0,
    createdAt: str(d.createdAt),
    updatedAt: isoUtc(row.updated_at),
  };
}

function toMileage(row) {
  const d = obj(row.data);
  return {
    id: rowId(row),
    date: str(d.date),
    miles: num(d.miles),
    odometerStart: num(d.odometerStart),
    odometerEnd: num(d.odometerEnd),
    fromLabel: str(d.fromLabel),
    toLabel: str(d.toLabel),
    fromJobId: str(d.fromJobId),
    toJobId: str(d.toJobId),
    purpose: str(d.purpose),
    createdAt: str(d.createdAt),
    updatedAt: isoUtc(row.updated_at),
  };
}

// The key object is built from the authorize RPC's envelope, never from a
// table row, so key_hash cannot reach it.
function toAccount({ businessName, dataAsOf, key }) {
  const k = obj(key);
  return {
    businessName: str(businessName),
    currency: CURRENCY,
    dataAsOf: isoUtc(dataAsOf),
    apiVersion: API_VERSION,
    key: {
      id: String(k.keyId ?? ''),
      name: str(k.name),
      prefix: str(k.prefix),
      scopes: Array.isArray(k.scopes) ? k.scopes.filter((s) => typeof s === 'string') : [],
      expiresAt: isoUtc(k.expiresAt),
    },
  };
}

const toPublic = Object.freeze({
  account: toAccount,
  customers: toCustomer,
  jobs: toJob,
  estimates: toEstimate,
  invoices: toInvoice,
  payments: toPayment,
  expenses: toExpense,
  mileage: toMileage,
  tombstone,
});

// ── resource registry ────────────────────────────────────────────────────
// table: the blob table; scope: what the key needs; filter: extra PostgREST
// predicate (a logic-tree fragment ANDed into the query); expand(row, ctx):
// one raw row → zero or more public objects; tombstones(row): the ids a
// deleted row retracts.

const ESTIMATE_FILTER = 'or(data->approval.not.is.null,data->>estimateSentAt.not.is.null)';

const RESOURCES = Object.freeze({
  customers: { table: 'customers', expand: (row) => [toCustomer(row)], tombstoneIds: (row) => [rowId(row)] },
  jobs: { table: 'jobs', expand: (row) => [toJob(row)], tombstoneIds: (row) => [rowId(row)] },
  estimates: {
    table: 'jobs',
    filter: ESTIMATE_FILTER,
    expand: (row, ctx) => {
      const e = toEstimate(row, ctx);
      return e ? [e] : [];
    },
    tombstoneIds: (row) => (isEstimateJob(row.data) ? [rowId(row)] : []),
  },
  invoices: { table: 'invoices', expand: (row) => [toInvoice(row)], tombstoneIds: (row) => [rowId(row)] },
  payments: {
    table: 'invoices',
    expand: (row) => toPayments(row),
    tombstoneIds: (row) => invoiceLedger(row).map((p) => String(p.id ?? '')).filter(Boolean),
  },
  expenses: { table: 'expenses', expand: (row) => [toExpense(row)], tombstoneIds: (row) => [rowId(row)] },
  mileage: { table: 'trips', expand: (row) => [toMileage(row)], tombstoneIds: (row) => [rowId(row)] },
});

const RESOURCE_NAMES = Object.freeze(Object.keys(RESOURCES));

// One raw row → public objects. A deleted row becomes tombstones, but only
// when the caller is syncing (updated_since given); otherwise deleted rows
// are never fetched at all.
function expandRow(resource, row, ctx) {
  const def = RESOURCES[resource];
  if (row && row.deleted === true) {
    return def.tombstoneIds(row).map((id) => tombstone(id, row.updated_at));
  }
  return def.expand(row, ctx);
}

module.exports = {
  API_VERSION,
  CURRENCY,
  SCHEMA,
  FIELDS,
  PAYMENT_METHODS,
  PAYMENT_SOURCES,
  ESTIMATE_STATUSES,
  INVOICE_STATUSES,
  RESOURCES,
  RESOURCE_NAMES,
  ESTIMATE_FILTER,
  toPublic,
  expandRow,
  invoiceLedger,
  isEstimateJob,
  estimateStatus,
  recoverIssueDate,
  normalizeMethod,
  paymentSource,
  expenseCategoryLabel,
  currentPaymentLink,
  approvalTotal,
  money,
  isoUtc,
};

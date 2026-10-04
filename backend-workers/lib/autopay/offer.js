// When the pay page offers autopay (Phase 24 spec §2.2) and when a plan can
// be set up from the portal (§2.4). Pure.

const { dollarsToCents } = require('./format.js');

function nonEmpty(v) {
  return typeof v === 'string' && v.trim().length > 0;
}

function planCents(planRow) {
  return dollarsToCents(planRow && planRow.data ? planRow.data.amount : 0);
}

// A plan that may take a NEW authorization: synced, not deleted, active,
// "Offer autopay" on, assigned to a customer, with a positive amount.
function isPlanOfferable(planRow) {
  if (!planRow || planRow.deleted) return false;
  const d = planRow.data || {};
  return d.isActive === true && d.autopayEnabled === true && nonEmpty(d.customerId) && planCents(planRow) > 0;
}

// The plan's current active authorization for the plan's CURRENT customer.
// An authorization given by a previous customer of a reassigned plan never
// counts (the sweep revokes it).
function activeEnrollmentForPlan(enrollments, planRow) {
  if (!planRow) return null;
  const customerId = planRow.data && planRow.data.customerId;
  return (enrollments || []).find(
    (e) => e && e.status === 'active' && e.recurring_invoice_id === planRow.id && e.customer_id === customerId
  ) || null;
}

// → { offer: null | { amountCents, isUpdate }, active: enrollment | null }
// for one invoice payment. `isFullBalance` is false for a deposit link.
function evaluateInvoiceOffer({ invoice, planRow, enrollments, isFullBalance }) {
  if (!invoice || !nonEmpty(invoice.recurringInvoiceId) || !planRow || planRow.id !== invoice.recurringInvoiceId) {
    return { offer: null, active: null };
  }
  const active = activeEnrollmentForPlan(enrollments, planRow);
  if (!isPlanOfferable(planRow) || !isFullBalance) return { offer: null, active };
  // An invoice moved to another customer is not the plan customer's to
  // authorize (defensive: generated invoices copy the plan's customer).
  if (nonEmpty(invoice.customerId) && invoice.customerId !== planRow.data.customerId) return { offer: null, active };
  const amountCents = planCents(planRow);
  if (active && Number(active.max_amount_cents) >= amountCents) return { offer: null, active };
  return { offer: { amountCents, isUpdate: !!active }, active };
}

// Portal "Set up" / manage (§2.4, §4.9): offerable plans only.
function evaluatePlanSetup({ planRow, enrollments }) {
  if (!isPlanOfferable(planRow)) return null;
  const active = activeEnrollmentForPlan(enrollments, planRow);
  const amountCents = planCents(planRow);
  return { amountCents, active, isUpdate: !!active && Number(active.max_amount_cents) < amountCents };
}

module.exports = { planCents, isPlanOfferable, activeEnrollmentForPlan, evaluateInvoiceOffer, evaluatePlanSetup, nonEmpty };

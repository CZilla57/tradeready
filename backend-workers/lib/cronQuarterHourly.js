// The */15 cron tick (Phase 24 spec §4.6, §4.10): the autopay sweep runs
// FIRST, then the invoice auto-email sweep with its hand-off —
//   autopayHandled   → those invoices get a 'superseded' log row instead of
//                      a second email (the customer already got the autopay
//                      failure/skip notice with a pay link)
//   autopayByInvoice → the "will be charged automatically" line
// An autopay failure never blocks the invoice emails. Kept out of
// src/index.js so the Worker's main module exports only its default.

const { runAutopayCharges } = require('./autopay/runAutopayCharges');
const { runInvoiceEmails } = require('./sendInvoiceEmails');

async function runQuarterHourly(env, { autopay = runAutopayCharges, invoiceEmails = runInvoiceEmails } = {}) {
  let handoff = {};
  try {
    const r = await autopay(env);
    handoff = { autopayHandled: r.autopayHandled, autopayByInvoice: r.autopayByInvoice };
  } catch (err) {
    console.error('[run-autopay] scheduled run failed:', err.message);
  }
  try {
    await invoiceEmails(env, handoff);
  } catch (err) {
    console.error('[send-invoice-emails] scheduled run failed:', err.message);
  }
}

module.exports = { runQuarterHourly };

// utils/recurringInvoices.ts
// Recurring-invoice (maintenance plan) generation engine — a thin mirror of
// utils/recurringJobs.ts over the shared helpers in utils/recurrence.ts.
//
// LOCAL-FIRST INVARIANT: no network in here. Payment links are minted on
// demand by the existing send/outreach flow, exactly like every other
// invoice. Saving through saveInvoices enqueues sync and re-runs
// syncNotifications() automatically, so overdue-dunning applies to generated
// invoices with no extra wiring (isJobDunningEligible passes no-jobId
// invoices through — correct: a maintenance invoice is billable immediately).

import { DateString, Invoice } from '../types/models';
import {
  loadInvoices,
  saveInvoices,
  loadCustomers,
  loadRecurringInvoices,
  saveRecurringInvoices,
  resolveCustomer,
} from './storage';
import { calculateNextDate, isEndConditionMet } from './recurrence';
import { nextInvoiceNumber } from './invoiceNumber';

// Occurrence date + net terms. Same Date construction as calculateNextDate,
// and same local-frame formatting (not toISOString/UTC, which loses a
// calendar day east of Greenwich for the same parse-vs-format skew).
function addDays(from: DateString, days: number): DateString {
  const d = new Date(from + 'T00:00:00');
  d.setDate(d.getDate() + days);
  const y = d.getFullYear();
  const m = String(d.getMonth() + 1).padStart(2, '0');
  const day = String(d.getDate()).padStart(2, '0');
  return `${y}-${m}-${day}`;
}

// Invoice ids must stay ALL-DIGITS after the `inv` prefix so invoiceIssueDate
// (utils/pdfTemplates.ts) recovers the issue date from them. A catch-up batch
// can mint several invoices in one millisecond — the monotonic bump keeps ids
// unique without breaking the digits-only rule. Rule linkage lives ONLY in
// recurringInvoiceId, never in the id.
let lastIdMs = 0;
function nextGeneratedInvoiceId(): string {
  let ms = Date.now();
  if (ms <= lastIdMs) ms = lastIdMs + 1;
  lastIdMs = ms;
  return `inv${ms}`;
}

let generating = false;

export async function checkAndGenerateRecurringInvoices(): Promise<void> {
  if (generating) return;
  generating = true;
  try {
    const today = new Date().toISOString().split('T')[0];
    const [rules, invoices, customers] = await Promise.all([
      loadRecurringInvoices(),
      loadInvoices(),
      loadCustomers(),
    ]);
    const newInvoices: Invoice[] = [];
    let anyUpdated = false;

    for (const rule of rules) {
      if (!rule.isActive) continue;

      // Contact snapshot at generation time; blank if the customer is gone —
      // backfillInvoiceContacts heals later, as with any invoice.
      const customer = resolveCustomer(customers, {
        customerId: rule.customerId,
        customerName: rule.customerName,
      });

      while (rule.nextDueDate <= today) {
        if (isEndConditionMet(rule)) {
          rule.isActive = false;
          anyUpdated = true;
          break;
        }

        const newInvoice: Invoice = {
          id: nextGeneratedInvoiceId(),
          customer: rule.customerName,
          customerId: rule.customerId,
          number: nextInvoiceNumber([...invoices, ...newInvoices]),
          amount: rule.amount,
          // due = occurrence date + net terms (NOT generation date): catch-up
          // invoices for missed periods date from when the money was owed and
          // may appear already overdue — correct, mirrors catch-up jobs
          // appearing in the past.
          due: addDays(rule.nextDueDate, rule.dueDays),
          email: customer?.email ?? '',
          phone: customer?.phone ?? '',
          desc: rule.description,
          paid: false,
          recurringInvoiceId: rule.id,
          occurrenceNumber: rule.occurrenceCount + 1,
        };

        newInvoices.push(newInvoice);
        rule.occurrenceCount++;
        rule.lastGeneratedDate = rule.nextDueDate;
        rule.nextDueDate = calculateNextDate(rule.nextDueDate, rule.cadence);
        anyUpdated = true;

        if (isEndConditionMet(rule)) {
          rule.isActive = false;
          break;
        }
      }
    }

    if (newInvoices.length > 0 || anyUpdated) {
      await saveInvoices([...invoices, ...newInvoices]);
      await saveRecurringInvoices(rules);
    }
  } finally {
    generating = false;
  }
}

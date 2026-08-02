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

import { DateString, Invoice, RecurringInvoice } from '../types/models';
import {
  loadInvoices,
  saveInvoices,
  loadCustomers,
  loadRecurringInvoices,
  saveRecurringInvoices,
  loadSettings,
  resolveCustomer,
} from './storage';
import { calculateNextDate, isEndConditionMet } from './recurrence';
import { nextInvoiceNumber } from './invoiceNumber';
import { syncNotifications } from './notifications';

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

/**
 * A rule's nextDueDate advanced past `today`, for Resume. Occurrences that
 * elapsed while a plan was paused are deliberately never billed — pausing
 * suspends service, and back-billed invoices would arrive already overdue
 * and enter dunning (owner decision 2026-08-01). occurrenceCount is NOT
 * advanced: skipped periods don't count against an end-by-count limit.
 * NOTE: recurring JOBS deliberately keep back-fill on resume (a job card is
 * a to-do, not a receivable) — do not "unify" the two.
 *
 * An already-ended plan (endDate elapsed while paused, or endCount already
 * met) does NOT get fast-forwarded — nextDueDate is returned unchanged. The
 * generation engine (checkAndGenerateRecurringInvoices, above) deactivates
 * an ended plan on its next run regardless, so leaving nextDueDate alone
 * here just preserves that honest pre-existing feedback (a Resumed card
 * that shows Active with a Next date already past its own end, or schedules
 * a rinv_ reminder for an occurrence that will never bill, would otherwise
 * be self-correcting only after the next engine run).
 */
export function fastForwardedNextDueDate(rule: RecurringInvoice, today: DateString): DateString {
  if (isEndConditionMet(rule)) return rule.nextDueDate;
  let next = rule.nextDueDate;
  while (next <= today) next = calculateNextDate(next, rule.cadence);
  return next;
}

let generating = false;

export async function checkAndGenerateRecurringInvoices(): Promise<void> {
  if (generating) return;
  generating = true;
  try {
    const today = new Date().toISOString().split('T')[0];
    const [rules, invoices, customers, settings] = await Promise.all([
      loadRecurringInvoices(),
      loadInvoices(),
      loadCustomers(),
      loadSettings(),
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
          number: nextInvoiceNumber([...invoices, ...newInvoices], settings),
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
      // saveInvoices' own sweep raced the rules write above and may have read
      // pre-advance rules — re-run now that the advanced rules are persisted.
      syncNotifications();
    }
  } finally {
    generating = false;
  }
}

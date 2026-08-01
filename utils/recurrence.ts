// utils/recurrence.ts
// Shared recurrence math for the two thin scheduling engines
// (utils/recurringJobs.ts and utils/recurringInvoices.ts). Extracted from
// recurringJobs.ts on 2026-08-01 — behavior-preserving; the jobs engine's
// suite (recurringJobs.test.ts) pins the math unchanged.

import type { DateString, RecurrenceCadence, RecurrenceEndCondition } from '../types/models';

export function calculateNextDate(from: DateString, cadence: RecurrenceCadence): DateString {
  const d = new Date(from + 'T00:00:00');
  if (cadence === 'daily') d.setDate(d.getDate() + 1);
  else if (cadence === 'weekly') d.setDate(d.getDate() + 7);
  else if (cadence === 'monthly') d.setMonth(d.getMonth() + 1);
  else if (cadence === 'quarterly') d.setMonth(d.getMonth() + 3);
  else if (cadence === 'annually') d.setFullYear(d.getFullYear() + 1);
  return d.toISOString().split('T')[0];
}

/**
 * The recurrence fields RecurringJob and RecurringInvoice share. Both rule
 * types satisfy this structurally, so the engines pass their rules straight in.
 */
export interface RecurrenceState {
  endCondition: RecurrenceEndCondition;
  endCount?: number;
  endDate?: DateString;
  occurrenceCount: number;
  nextDueDate: DateString;
}

export function isEndConditionMet(rule: RecurrenceState): boolean {
  if (rule.endCondition === 'count') return rule.occurrenceCount >= rule.endCount!;
  if (rule.endCondition === 'date') return rule.nextDueDate > rule.endDate!;
  return false;
}

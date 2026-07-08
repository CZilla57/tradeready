import { DateString, Job, RecurrenceCadence, RecurringJob } from '../types/models';
import { loadJobs, saveJobs, loadRecurringJobs, saveRecurringJobs } from './storage';

export function calculateNextDate(from: DateString, cadence: RecurrenceCadence): DateString {
  const d = new Date(from + 'T00:00:00');
  if (cadence === 'daily') d.setDate(d.getDate() + 1);
  else if (cadence === 'weekly') d.setDate(d.getDate() + 7);
  else if (cadence === 'monthly') d.setMonth(d.getMonth() + 1);
  else if (cadence === 'quarterly') d.setMonth(d.getMonth() + 3);
  else if (cadence === 'annually') d.setFullYear(d.getFullYear() + 1);
  return d.toISOString().split('T')[0];
}

function isEndConditionMet(rule: RecurringJob): boolean {
  if (rule.endCondition === 'count') return rule.occurrenceCount >= rule.endCount!;
  if (rule.endCondition === 'date') return rule.nextDueDate > rule.endDate!;
  return false;
}

let generating = false;

export async function checkAndGenerateRecurringJobs(): Promise<void> {
  if (generating) return;
  generating = true;
  try {
    const today = new Date().toISOString().split('T')[0];
    const [recurringJobs, jobs] = await Promise.all([loadRecurringJobs(), loadJobs()]);
    const newJobs: Job[] = [];
    let anyUpdated = false;

    for (const rule of recurringJobs) {
      if (!rule.isActive) continue;

      while (rule.nextDueDate <= today) {
        if (isEndConditionMet(rule)) {
          rule.isActive = false;
          anyUpdated = true;
          break;
        }

        const newJob: Job = {
          id: `j${Date.now()}_${rule.id}_${rule.occurrenceCount + 1}`,
          customerId: rule.customerId,
          customerName: rule.customerName,
          title: rule.title,
          description: rule.description,
          address: rule.address,
          notes: rule.notes,
          estimateTotal: rule.estimateTotal,
          laborHours: rule.laborHours,
          laborRate: rule.laborRate,
          materials: rule.materials,
          materialMarkup: rule.materialMarkup,
          overhead: rule.overhead,
          margin: rule.margin,
          status: 'scheduled',
          scheduledDate: rule.nextDueDate,
          scheduledStartTime: null,
          scheduledEndTime: null,
          invoiceId: null,
          createdAt: today,
          recurringJobId: rule.id,
          occurrenceNumber: rule.occurrenceCount + 1,
        };

        newJobs.push(newJob);
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

    if (newJobs.length > 0 || anyUpdated) {
      await saveJobs([...jobs, ...newJobs]);
      await saveRecurringJobs(recurringJobs);
    }
  } finally {
    generating = false;
  }
}

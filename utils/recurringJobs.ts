import { Job } from '../types/models';
import { loadJobs, saveJobs, loadRecurringJobs, saveRecurringJobs } from './storage';
import { calculateNextDate, isEndConditionMet } from './recurrence';

// Re-exported so existing consumers (AddJobScreen.tsx:23,
// recurringJobs.test.ts:1) keep importing the cadence math from here.
export { calculateNextDate };

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

        // Rules sync across devices (2026-08-03): another device may have
        // generated this occurrence and pushed the job while our copy of the
        // rule was still stale. If the job is already here, creating it again
        // would duplicate it — skip creation but still advance the rule so
        // both devices' rule state converges to the same nextDueDate.
        const occurrence = rule.occurrenceCount + 1;
        const alreadyGenerated = jobs.some(
          j => j.recurringJobId === rule.id && j.occurrenceNumber === occurrence
        );

        if (!alreadyGenerated) {
          const newJob: Job = {
            id: `j${Date.now()}_${rule.id}_${occurrence}`,
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
            ...(rule.jobCosts ? { jobCosts: rule.jobCosts } : {}),
            overhead: rule.overhead,
            margin: rule.margin,
            status: 'scheduled',
            scheduledDate: rule.nextDueDate,
            scheduledStartTime: null,
            scheduledEndTime: null,
            invoiceId: null,
            createdAt: today,
            recurringJobId: rule.id,
            occurrenceNumber: occurrence,
          };

          newJobs.push(newJob);
        }
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

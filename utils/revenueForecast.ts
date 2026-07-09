import { computeConversionFunnel } from './conversionFunnel';
import type { Job, JobStatus } from '../types/models';

const CERTAIN_STATUSES: JobStatus[] = ['approved', 'scheduled', 'in_progress'];
const SPECULATIVE_STATUSES: JobStatus[] = ['lead', 'estimate_sent'];

export interface RevenueForecastResult {
  certainValue: number;
  certainCount: number;
  speculativeValue: number;
  speculativeCount: number;
  winRate: number | null;
  projectedValue: number;
  totalForecast: number;
}

export function computeRevenueForecast(jobs: Job[]): RevenueForecastResult {
  const funnel = computeConversionFunnel(jobs);
  const winRate = funnel.winRate;

  let certainValue = 0;
  let certainCount = 0;
  let speculativeValue = 0;
  let speculativeCount = 0;

  for (const job of jobs) {
    if (job.estimateTotal <= 0) continue;

    if (CERTAIN_STATUSES.includes(job.status)) {
      certainValue += job.estimateTotal;
      certainCount++;
    } else if (SPECULATIVE_STATUSES.includes(job.status)) {
      speculativeValue += job.estimateTotal;
      speculativeCount++;
    }
  }

  const projectedValue = winRate !== null ? speculativeValue * winRate : 0;
  const totalForecast = certainValue + projectedValue;

  return {
    certainValue,
    certainCount,
    speculativeValue,
    speculativeCount,
    winRate,
    projectedValue,
    totalForecast,
  };
}

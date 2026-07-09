import { computeRevenueForecast } from '../utils/revenueForecast';

function makeJob(status, estimateTotal) {
  return {
    id: '1', customerId: 'c1', customerName: 'Test', title: 'Job',
    description: '', status, scheduledDate: null, scheduledStartTime: null,
    scheduledEndTime: null, address: '', estimateTotal, laborHours: 0,
    laborRate: 0, materials: [], materialMarkup: 0, overhead: 0, margin: 0,
    notes: '', invoiceId: null, createdAt: '2026-01-01',
  };
}

describe('computeRevenueForecast', () => {
  it('returns zeroes for empty jobs', () => {
    const result = computeRevenueForecast([]);
    expect(result.certainValue).toBe(0);
    expect(result.certainCount).toBe(0);
    expect(result.speculativeValue).toBe(0);
    expect(result.speculativeCount).toBe(0);
    expect(result.winRate).toBeNull();
    expect(result.projectedValue).toBe(0);
    expect(result.totalForecast).toBe(0);
  });

  it('counts approved/scheduled/in_progress as certain at 100%', () => {
    const jobs = [
      makeJob('approved', 5000),
      makeJob('scheduled', 3000),
      makeJob('in_progress', 2000),
    ];
    const result = computeRevenueForecast(jobs);
    expect(result.certainValue).toBe(10000);
    expect(result.certainCount).toBe(3);
    expect(result.projectedValue).toBe(0);
    expect(result.totalForecast).toBe(10000);
  });

  it('weights speculative jobs by win rate', () => {
    const jobs = [
      makeJob('lead', 4000),
      makeJob('estimate_sent', 6000),
      // Need approved jobs to establish a win rate
      makeJob('approved', 2000),
      makeJob('complete', 1000),
    ];
    // Win rate = approved-or-beyond who reached approved / those who reached estimate_sent
    // estimate_sent reached: estimate_sent + approved + complete = 3
    // approved reached: approved + complete = 2
    // winRate = 2/3
    const result = computeRevenueForecast(jobs);
    expect(result.speculativeValue).toBe(10000);
    expect(result.speculativeCount).toBe(2);
    expect(result.winRate).toBeCloseTo(2 / 3);
    expect(result.projectedValue).toBeCloseTo(10000 * (2 / 3));
    expect(result.certainValue).toBe(2000); // only approved (complete is earned, not pipeline)
    expect(result.totalForecast).toBeCloseTo(2000 + 10000 * (2 / 3));
  });

  it('handles mixed certain and speculative jobs', () => {
    const jobs = [
      makeJob('lead', 1000),
      makeJob('estimate_sent', 2000),
      makeJob('approved', 3000),
      makeJob('in_progress', 4000),
    ];
    // estimate_sent reached: estimate_sent + approved + in_progress = 3
    // approved reached: approved + in_progress = 2
    // winRate = 2/3
    const result = computeRevenueForecast(jobs);
    expect(result.certainValue).toBe(7000);
    expect(result.certainCount).toBe(2);
    expect(result.speculativeValue).toBe(3000);
    expect(result.speculativeCount).toBe(2);
    expect(result.projectedValue).toBeCloseTo(3000 * (2 / 3));
    expect(result.totalForecast).toBeCloseTo(7000 + 3000 * (2 / 3));
  });

  it('excludes jobs with estimateTotal of 0', () => {
    const jobs = [
      makeJob('approved', 5000),
      makeJob('approved', 0),
      makeJob('lead', 3000),
      makeJob('lead', 0),
    ];
    const result = computeRevenueForecast(jobs);
    expect(result.certainCount).toBe(1);
    expect(result.certainValue).toBe(5000);
    expect(result.speculativeCount).toBe(1);
    expect(result.speculativeValue).toBe(3000);
  });

  it('returns null winRate and 0 projectedValue when no estimate_sent history', () => {
    const jobs = [
      makeJob('lead', 5000),
    ];
    const result = computeRevenueForecast(jobs);
    expect(result.winRate).toBeNull();
    expect(result.projectedValue).toBe(0);
    expect(result.speculativeValue).toBe(5000);
    expect(result.totalForecast).toBe(0);
  });
});

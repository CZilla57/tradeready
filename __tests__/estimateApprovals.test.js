const { applyDecisionsToJobs } = require('../utils/storage/estimateApprovals');

function job(over) {
  return { id: 'j1', status: 'estimate_sent', ...over };
}

describe('applyDecisionsToJobs', () => {
  it('advances an approved decision through the pipeline', () => {
    const { jobs, changed } = applyDecisionsToJobs([
      job({ approval: { token: 't', sentAt: '2026-07-17', snapshot: {}, decision: 'approved' } }),
    ]);
    expect(changed).toBe(true);
    expect(jobs[0].status).toBe('approved');
  });

  it('sets a declined decision', () => {
    const { jobs, changed } = applyDecisionsToJobs([
      job({ approval: { token: 't', sentAt: '2026-07-17', snapshot: {}, decision: 'declined' } }),
    ]);
    expect(changed).toBe(true);
    expect(jobs[0].status).toBe('declined');
  });

  it('is idempotent — a second pass reports no change', () => {
    const first = applyDecisionsToJobs([
      job({ approval: { token: 't', sentAt: '2026-07-17', snapshot: {}, decision: 'approved' } }),
    ]);
    const second = applyDecisionsToJobs(first.jobs);
    expect(second.changed).toBe(false);
    expect(second.jobs[0].status).toBe('approved');
  });

  it('ignores jobs without an approval decision', () => {
    const { changed } = applyDecisionsToJobs([
      job({}),
      job({ id: 'j2', approval: { token: 't', sentAt: 'x', snapshot: {} } }),
    ]);
    expect(changed).toBe(false);
  });

  it('never regresses a job already advanced', () => {
    const { changed } = applyDecisionsToJobs([
      job({ status: 'scheduled', approval: { token: 't', sentAt: 'x', snapshot: {}, decision: 'approved' } }),
    ]);
    expect(changed).toBe(false);
  });
});

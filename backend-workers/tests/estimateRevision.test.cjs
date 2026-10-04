const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { describe, test } = require('node:test');

const workerPath = path.join(__dirname, '../lib/estimateRevision.js');
const vercelPath = path.join(__dirname, '../../backend/lib/estimateRevision.js');
const implementations = [
  ['Cloudflare Worker', require(workerPath)],
  ['Vercel', require(vercelPath)],
];

const TOKEN = 'declined_token_1234567890';
const approval = {
  token: TOKEN,
  sentAt: '2026-09-15T12:00:00.000Z',
  snapshot: {
    businessName: 'Rector Plumbing',
    customerName: 'Pat Lee',
    jobTitle: 'Panel upgrade',
    lineItems: [{ label: 'Labor', amount: 200 }],
    total: 200,
    currency: 'USD',
  },
  decision: 'declined',
  consentAt: '2026-09-15T13:00:00.000Z',
  declineReason: 'Please revise the scope',
  ip: '203.0.113.7',
  userAgent: 'customer-browser',
  futureConsentField: { preserved: true },
};

// Phase 32 (quote expiration, spec §4.7 + §10): the Worker planner also
// strips estimateValidUntil; the dormant Vercel twin is deliberately NOT
// changed. This is the ONLY permitted difference — any other drift between
// the two files still fails the parity check below.
const PHASE32_WORKER_HUNK = [
  '  // Phase 32: the revised estimate is a new offer, so the old valid-until',
  '  // date goes too. (The dormant Vercel twin deliberately lacks this; see',
  '  // tests/estimateRevision.test.cjs.)',
  '  const { approval: _approval, estimateSentAt: _estimateSentAt, estimateValidUntil: _estimateValidUntil, ...rest } = job;',
].join('\n');
const VERCEL_HUNK = '  const { approval: _approval, estimateSentAt: _estimateSentAt, ...rest } = job;';

describe('declined estimate revision parity', () => {
  test('the Worker and Vercel planners differ only by the Phase 32 estimateValidUntil strip', () => {
    const worker = fs.readFileSync(workerPath, 'utf8');
    assert.ok(worker.includes(PHASE32_WORKER_HUNK), 'the Worker planner carries the Phase 32 hunk');
    assert.equal(worker.replace(PHASE32_WORKER_HUNK, VERCEL_HUNK), fs.readFileSync(vercelPath, 'utf8'));
  });

  test('Worker: revising a declined estimate also drops estimateValidUntil (§4.7)', () => {
    const { planDeclinedEstimateRevision } = require(workerPath);
    const job = {
      id: 'job-1',
      status: 'declined',
      estimateSentAt: '2026-09-15',
      estimateValidUntil: '2026-10-15',
      approval: { ...approval, snapshot: { ...approval.snapshot, validUntil: '2026-10-15', validUntilTimeZone: 'America/Phoenix' } },
      futureJobField: { preserved: true },
    };
    const plan = planDeclinedEstimateRevision(job, TOKEN);
    assert.equal(plan.changed, true);
    assert.equal(plan.job.status, 'lead');
    assert.equal('estimateValidUntil' in plan.job, false);
    assert.equal('estimateSentAt' in plan.job, false);
    assert.equal('approval' in plan.job, false);
    // The archived approval keeps its frozen snapshot, date included.
    assert.equal(plan.job.approvalHistory[0].snapshot.validUntil, '2026-10-15');
    assert.deepEqual(plan.job.futureJobField, { preserved: true });
    assert.equal(job.estimateValidUntil, '2026-10-15', 'the planner never mutates its input');

    const retried = planDeclinedEstimateRevision(plan.job, TOKEN);
    assert.equal(retried.changed, false);
  });

  for (const [name, { planDeclinedEstimateRevision }] of implementations) {
    describe(name, () => {
      test('archives the exact approval, invalidates the link, and returns to lead', () => {
        const job = {
          id: 'job-1',
          status: 'declined',
          estimateSentAt: '2026-09-15',
          approval,
          futureJobField: { preserved: true },
        };
        const plan = planDeclinedEstimateRevision(job, TOKEN);
        assert.equal(plan.changed, true);
        assert.equal(plan.job.status, 'lead');
        assert.equal('approval' in plan.job, false);
        assert.equal('estimateSentAt' in plan.job, false);
        assert.deepEqual(plan.job.approvalHistory, [approval]);
        assert.deepEqual(plan.job.futureJobField, { preserved: true });
        assert.deepEqual(job.approval, approval, 'the planner never mutates its input');
      });

      test('preserves earlier history and never appends the same token twice', () => {
        const prior = { ...approval, token: 'earlier_decline_123456', sentAt: 'earlier' };
        const first = planDeclinedEstimateRevision({
          id: 'job-1', status: 'estimate_sent', approval, approvalHistory: [prior],
        }, TOKEN);
        assert.deepEqual(first.job.approvalHistory, [prior, approval]);
        const retried = planDeclinedEstimateRevision(first.job, TOKEN);
        assert.equal(retried.changed, false);
        assert.deepEqual(retried.job.approvalHistory, [prior, approval]);
      });

      test('fails closed for a changed token, open approval, approval, or advanced job', () => {
        const cases = [
          [{ status: 'declined', approval }, 'another_token_12345678'],
          [{ status: 'estimate_sent', approval: { ...approval, decision: undefined } }, TOKEN],
          [{ status: 'approved', approval: { ...approval, decision: 'approved' } }, TOKEN],
          [{ status: 'scheduled', approval }, TOKEN],
        ];
        for (const [job, token] of cases) {
          assert.deepEqual(planDeclinedEstimateRevision(job, token), { error: 'conflict' });
        }
      });

      test('rejects conflicting history for the same capability', () => {
        const altered = { ...approval, declineReason: 'different' };
        assert.deepEqual(planDeclinedEstimateRevision({
          status: 'declined', approval, approvalHistory: [altered],
        }, TOKEN), { error: 'conflict' });
      });
    });
  }
});

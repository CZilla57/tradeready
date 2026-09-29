// Pure declined-estimate revision planner shared with the Vercel fallback.
// The route owns authentication and conditional persistence; this function
// only decides whether the exact active approval may be archived.

function sameArtifact(left, right) {
  return JSON.stringify(left) === JSON.stringify(right);
}

function planDeclinedEstimateRevision(job, expectedToken) {
  if (!job || typeof job !== 'object' || Array.isArray(job)) {
    return { error: 'conflict' };
  }
  const history = Array.isArray(job.approvalHistory) ? job.approvalHistory : [];
  const archived = history.find((item) => item && item.token === expectedToken);
  const active = job.approval;

  // A retried request after the conditional write is an idempotent success.
  if (!active && archived && job.status === 'lead' && job.estimateSentAt == null) {
    return { changed: false, job };
  }
  if (!active || active.token !== expectedToken || active.decision !== 'declined') {
    return { error: 'conflict' };
  }
  if (!['lead', 'estimate_sent', 'declined'].includes(job.status)) {
    return { error: 'conflict' };
  }
  if (archived && !sameArtifact(archived, active)) {
    return { error: 'conflict' };
  }

  const nextHistory = archived ? history.slice() : [...history, active];
  const { approval: _approval, estimateSentAt: _estimateSentAt, ...rest } = job;
  return {
    changed: true,
    job: { ...rest, status: 'lead', approvalHistory: nextHistory },
  };
}

module.exports = { planDeclinedEstimateRevision };

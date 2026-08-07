// Portal add-to-calendar read (Phase 12A): resolve the portal token, prove
// the job belongs to that customer AND is actually scheduled, and emit one
// floating-local-time VEVENT. Every failure is the same oracle-free 404 the
// portal view uses. READ-ONLY like the whole portal family.

const {
  lookupCustomerByPortalToken,
  fetchBusinessName,
  fetchCustomerJobs,
} = require('./portalStore.js');
const { buildJobIcs } = require('../booking/ics.js');

const DATE_RE = /^\d{4}-\d{2}-\d{2}$/;
const INVALID = { ok: false, status: 404, error: 'This link is invalid.' };

async function portalIcsCore(env, { token, jobId, stampUtc }) {
  const row = await lookupCustomerByPortalToken(env, String(token));
  if (!row) return INVALID;
  const jobs = await fetchCustomerJobs(env, row.user_id, row.id);
  const job = jobs.find((r) => r.id === String(jobId));
  const d = job && job.data;
  if (!d || d.archived || typeof d.scheduledDate !== 'string' || !DATE_RE.test(d.scheduledDate)) {
    return INVALID;
  }
  const businessName = await fetchBusinessName(env, row.user_id);
  const ics = buildJobIcs({
    businessName: String(businessName || '').slice(0, 120),
    title: String(d.title || '').slice(0, 200),
    date: d.scheduledDate,
    start: d.scheduledStartTime || null,
    end: d.scheduledEndTime || null,
    uid: `${String(jobId).slice(0, 24)}@tradeready-portal`,
    stampUtc,
  });
  return { ok: true, ics };
}

module.exports = { portalIcsCore };

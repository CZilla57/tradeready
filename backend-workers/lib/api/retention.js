// Open API retention (spec §4 "Retention"; decision D11): the daily cron
// deletes access-log rows older than 90 days and usage-counter rows older
// than 2 days. Service-role DELETEs on the two API bookkeeping tables only —
// never a business table. Best-effort per table: one failure is logged and
// never stops the other, or the reminder run it shares the trigger with.

const ACCESS_LOG_RETENTION_DAYS = 90;
const COUNTER_RETENTION_DAYS = 2;
const DAY_MS = 86_400_000;

async function pruneApiLogs(env, nowMs = Date.now()) {
  const jobs = [
    ['api_access_log', 'created_at', ACCESS_LOG_RETENTION_DAYS],
    ['api_usage_counters', 'window_start', COUNTER_RETENTION_DAYS],
  ];
  const result = {};
  for (const [table, column, days] of jobs) {
    const cutoff = new Date(nowMs - days * DAY_MS).toISOString();
    try {
      const res = await fetch(`${env.SUPABASE_URL}/rest/v1/${table}?${column}=lt.${encodeURIComponent(cutoff)}`, {
        method: 'DELETE',
        headers: {
          Authorization: `Bearer ${env.SUPABASE_SERVICE_ROLE_KEY}`,
          apikey: env.SUPABASE_SERVICE_ROLE_KEY,
          Prefer: 'return=minimal',
        },
      });
      result[table] = res.ok ? 'ok' : `http_${res.status}`;
      if (!res.ok) console.error(`[api-retention] ${table} prune failed:`, res.status);
    } catch (err) {
      result[table] = 'error';
      console.error(`[api-retention] ${table} prune threw:`, err.message);
    }
  }
  return result;
}

module.exports = { pruneApiLogs, ACCESS_LOG_RETENTION_DAYS, COUNTER_RETENTION_DAYS };

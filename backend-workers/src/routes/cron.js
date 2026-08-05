// GET /api/cron/send-reminders — manual-run HTTP fallback for the reminder
// batch, still behind CRON_SECRET (useful to force a run without waiting for
// 15:00 UTC). The PRODUCTION trigger is the Workers cron (scheduled() in
// src/index.js) — only Cloudflare's own scheduler can invoke that, so the
// bearer check here only guards this manual path. Response shapes are
// byte-identical to the Vercel handler (backend/api/cron/send-reminders.js).

import { runReminders } from '../../lib/sendReminders.js';

export async function cronSendRemindersHandler(c) {
  // Fail closed with a log if the secret is unset (misconfiguration); 401 on a
  // wrong/missing header — mirrors the subscription webhook.
  if (!c.env.CRON_SECRET) {
    console.error('[send-reminders] CRON_SECRET not configured');
    return c.json({ error: 'Cron not configured' }, 500);
  }
  if (c.req.header('authorization') !== `Bearer ${c.env.CRON_SECRET}`) {
    return c.json({ error: 'Unauthorized' }, 401);
  }
  if (!c.env.SUPABASE_URL || !c.env.SUPABASE_SERVICE_ROLE_KEY || !c.env.RESEND_API_KEY) {
    return c.json({ error: 'Server misconfiguration: SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, RESEND_API_KEY required.' }, 500);
  }

  try {
    const counts = await runReminders(c.env);
    return c.json(counts, 200);
  } catch (err) {
    console.error('[send-reminders] fatal', err.message);
    return c.json({ error: 'Reminder run failed' }, 500);
  }
}

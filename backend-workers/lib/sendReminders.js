// Daily payment-reminder batch — Workers port of
// backend/api/cron/send-reminders.js with the HTTP shell peeled off: this is
// the business logic both the Workers scheduled() trigger and the manual
// HTTP fallback route (src/routes/cron.js) call. Emails a one-and-done
// payment reminder for each overdue invoice whose owner opted in
// (settings.autoSendEmailEnabled) once it passes the owner's earliest
// reminder age. Idempotency + audit via auto_reminder_log.
//
// Required bindings:
//   SUPABASE_URL
//   SUPABASE_SERVICE_ROLE_KEY — service role (bypasses RLS to scan all users)
//   RESEND_API_KEY            — Resend REST API key (sender domain already verified)

const { selectInvoicesToRemind } = require("./selectInvoicesToRemind");
const { buildReminderEmail } = require("./reminderEmail");

// Owner-tunable per-user daily ceiling. Reminders are one-and-done per
// invoice, so honest volume is bounded by NEW overdue invoices in a day — 25
// covers any solo operator's worst backlog day while capping the blast radius
// of a hostile account (unbounded synced invoices → unbounded mail from the
// verified domain). Counted from auto_reminder_log rows stamped today (UTC):
// the claim insert defaults sent_at to now(), so pending/failed attempts
// count too — the conservative direction.
const MAX_REMINDERS_PER_USER_PER_DAY = 25;

function sbFetch(env, path, init = {}) {
  return fetch(`${env.SUPABASE_URL}/rest/v1/${path}`, {
    ...init,
    headers: {
      Authorization: `Bearer ${env.SUPABASE_SERVICE_ROLE_KEY}`,
      apikey: env.SUPABASE_SERVICE_ROLE_KEY,
      "Content-Type": "application/json",
      ...(init.headers || {}),
    },
  });
}

// Best-effort status write for an already-claimed log row. NEVER throws — a
// failure to record status must not flip a delivered email to 'failed', abort
// the batch, or double-count. A missed status write just leaves the row at its
// prior value (logged for investigation).
async function markLog(env, logId, patch) {
  try {
    const r = await sbFetch(env, `auto_reminder_log?id=eq.${logId}`, {
      method: "PATCH",
      body: JSON.stringify(patch),
    });
    if (!r.ok) console.error("[send-reminders] status write non-2xx", logId, r.status);
  } catch (e) {
    console.error("[send-reminders] status write threw", logId, e.message);
  }
}

// Runs the daily batch. Returns { scanned, sent, failed, capped }; throws on
// a fatal (whole-batch) error — callers map that to a 500 / scheduled-run log,
// mirroring the source handler's outer try/catch.
async function runReminders(env) {
  if (!env.SUPABASE_URL || !env.SUPABASE_SERVICE_ROLE_KEY || !env.RESEND_API_KEY) {
    throw new Error("Server misconfiguration: SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, RESEND_API_KEY required.");
  }

  const today = new Date();
  let scanned = 0;
  let sent = 0;
  let failed = 0;
  let capped = 0;

  const [invRows, setRows, logRows, jobRows] = await Promise.all([
    // All non-deleted invoices; selectInvoicesToRemind filters out paid ones.
    // (Avoids fragile JSONB-filter URL encoding; scale is small at launch.)
    sbFetch(env, "invoices?deleted=is.false&select=id,user_id,data").then((r) => r.json()),
    sbFetch(env, "settings?select=user_id,data").then((r) => r.json()),
    // sent_at rides along so the daily cap can count today's rows per user
    // from the fetch we already make — no extra request, no schema change.
    sbFetch(env, "auto_reminder_log?select=user_id,invoice_id,sent_at").then((r) => r.json()),
    // Needed so selectInvoicesToRemind can exclude a pre-work deposit
    // invoice whose job isn't done yet — "overdue" on that due date doesn't
    // mean the customer is late on a finished bill.
    sbFetch(env, "jobs?deleted=is.false&select=id,user_id,data").then((r) => r.json()),
  ]);

  const settingsByUser = new Map((setRows || []).map((r) => [r.user_id, r.data]));
  const dayStart = new Date(today);
  dayStart.setUTCHours(0, 0, 0, 0);
  const sentByUser = new Map();
  const todayCountByUser = new Map();
  for (const row of logRows || []) {
    if (!sentByUser.has(row.user_id)) sentByUser.set(row.user_id, new Set());
    sentByUser.get(row.user_id).add(row.invoice_id);
    // An unparseable sent_at simply doesn't count toward the cap — the row
    // still blocks its invoice via the one-and-done set above.
    const stamped = Date.parse(row.sent_at);
    if (Number.isFinite(stamped) && stamped >= dayStart.getTime()) {
      todayCountByUser.set(row.user_id, (todayCountByUser.get(row.user_id) || 0) + 1);
    }
  }

  const invByUser = new Map();
  for (const row of invRows || []) {
    const invoice = { ...row.data, id: row.id };
    if (!invByUser.has(row.user_id)) invByUser.set(row.user_id, []);
    invByUser.get(row.user_id).push(invoice);
  }

  const jobsByUser = new Map();
  for (const row of jobRows || []) {
    const job = { ...row.data, id: row.id };
    if (!jobsByUser.has(row.user_id)) jobsByUser.set(row.user_id, []);
    jobsByUser.get(row.user_id).push(job);
  }

  for (const [userId, invoices] of invByUser) {
    const settings = settingsByUser.get(userId);
    const alreadySent = [...(sentByUser.get(userId) || [])];
    const jobs = jobsByUser.get(userId) || [];
    const toSend = selectInvoicesToRemind({ invoices, settings, alreadySentInvoiceIds: alreadySent, jobs, today });
    // Rows this user already claimed today plus claims made in this run.
    let claimedToday = todayCountByUser.get(userId) || 0;
    let deferred = 0;

    for (const invoice of toSend) {
      // Daily cap: everything past the ceiling simply waits — no log row is
      // written for it, so tomorrow's run picks it up via one-and-done.
      if (claimedToday >= MAX_REMINDERS_PER_USER_PER_DAY) {
        deferred++;
        continue;
      }
      scanned++;
      // Per-invoice isolation: a network throw on the claim below must not
      // abort the whole daily batch.
      try {
        // CLAIM: insert first as 'pending'. A conflict on (user_id, invoice_id)
        // returns [] → already handled by a prior run (one-and-done), skip.
        const claimRes = await sbFetch(env, "auto_reminder_log?on_conflict=user_id,invoice_id", {
          method: "POST",
          headers: { Prefer: "return=representation,resolution=ignore-duplicates" },
          body: JSON.stringify({ user_id: userId, invoice_id: invoice.id, to_email: invoice.email, status: "pending" }),
        });
        if (!claimRes.ok) {
          // e.g. table missing (migration not applied) or a permissions error —
          // surface it instead of silently treating it as a duplicate.
          failed++;
          console.error("[send-reminders] claim failed", invoice.id, claimRes.status, await claimRes.text());
          continue;
        }
        const claimed = await claimRes.json().catch(() => []);
        if (!Array.isArray(claimed) || claimed.length === 0) continue; // already claimed
        const logId = claimed[0].id;
        // A fresh row exists — count it against today's cap regardless of
        // send outcome, matching what the DB count will say next run.
        claimedToday++;

        // SEND, then record the outcome via best-effort markLog (never throws).
        try {
          const email = buildReminderEmail({ invoice, settings, today });
          const r = await fetch("https://api.resend.com/emails", {
            method: "POST",
            headers: { Authorization: `Bearer ${env.RESEND_API_KEY}`, "Content-Type": "application/json" },
            body: JSON.stringify(email),
          });
          if (!r.ok) throw new Error(`Resend ${r.status}: ${await r.text()}`);
          sent++;
          await markLog(env, logId, { status: "sent", sent_at: new Date().toISOString() });
        } catch (sendErr) {
          failed++;
          console.error("[send-reminders] send failed", invoice.id, sendErr.message);
          await markLog(env, logId, { status: "failed", error: String(sendErr.message).slice(0, 500) });
        }
      } catch (invErr) {
        failed++;
        console.error("[send-reminders] invoice error", invoice.id, invErr.message);
      }
    }

    if (deferred > 0) {
      capped += deferred;
      // Worth a look when it fires: either a genuine backlog or an account
      // generating mail volume on purpose.
      console.error("[send-reminders] daily cap reached", userId, "deferred", deferred);
    }
  }

  return { scanned, sent, failed, capped };
}

module.exports = { runReminders, MAX_REMINDERS_PER_USER_PER_DAY };

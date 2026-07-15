// GET /api/cron/send-reminders
// Vercel Cron (daily). Emails a one-and-done payment reminder for each overdue
// invoice whose owner opted in (settings.autoSendEmailEnabled) once it passes
// the owner's earliest reminder age. Idempotency + audit via auto_reminder_log.
//
// Required Vercel env vars:
//   CRON_SECRET               — Vercel Cron sends "Authorization: Bearer <CRON_SECRET>"
//   SUPABASE_URL
//   SUPABASE_SERVICE_ROLE_KEY — service role (bypasses RLS to scan all users)
//   RESEND_API_KEY            — Resend REST API key (sender domain already verified)

const { selectInvoicesToRemind } = require("../../lib/selectInvoicesToRemind");
const { buildReminderEmail } = require("../../lib/reminderEmail");

const SUPABASE_URL = process.env.SUPABASE_URL;
const SUPABASE_SERVICE_ROLE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY;
const RESEND_API_KEY = process.env.RESEND_API_KEY;
const CRON_SECRET = process.env.CRON_SECRET;

function sbFetch(path, init = {}) {
  return fetch(`${SUPABASE_URL}/rest/v1/${path}`, {
    ...init,
    headers: {
      Authorization: `Bearer ${SUPABASE_SERVICE_ROLE_KEY}`,
      apikey: SUPABASE_SERVICE_ROLE_KEY,
      "Content-Type": "application/json",
      ...(init.headers || {}),
    },
  });
}

// Best-effort status write for an already-claimed log row. NEVER throws — a
// failure to record status must not flip a delivered email to 'failed', abort
// the batch, or double-count. A missed status write just leaves the row at its
// prior value (logged for investigation).
async function markLog(logId, patch) {
  try {
    const r = await sbFetch(`auto_reminder_log?id=eq.${logId}`, {
      method: "PATCH",
      body: JSON.stringify(patch),
    });
    if (!r.ok) console.error("[send-reminders] status write non-2xx", logId, r.status);
  } catch (e) {
    console.error("[send-reminders] status write threw", logId, e.message);
  }
}

module.exports = async function handler(req, res) {
  // Fail closed with a log if the secret is unset (misconfiguration); 401 on a
  // wrong/missing header — mirrors backend/api/subscription/webhook.js.
  if (!CRON_SECRET) {
    console.error("[send-reminders] CRON_SECRET not configured");
    return res.status(500).json({ error: "Cron not configured" });
  }
  if (req.headers["authorization"] !== `Bearer ${CRON_SECRET}`) {
    return res.status(401).json({ error: "Unauthorized" });
  }
  if (!SUPABASE_URL || !SUPABASE_SERVICE_ROLE_KEY || !RESEND_API_KEY) {
    return res.status(500).json({ error: "Server misconfiguration: SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, RESEND_API_KEY required." });
  }

  const today = new Date();
  let scanned = 0;
  let sent = 0;
  let failed = 0;

  try {
    const [invRows, setRows, logRows] = await Promise.all([
      // All non-deleted invoices; selectInvoicesToRemind filters out paid ones.
      // (Avoids fragile JSONB-filter URL encoding; scale is small at launch.)
      sbFetch("invoices?deleted=is.false&select=id,user_id,data").then((r) => r.json()),
      sbFetch("settings?select=user_id,data").then((r) => r.json()),
      sbFetch("auto_reminder_log?select=user_id,invoice_id").then((r) => r.json()),
    ]);

    const settingsByUser = new Map((setRows || []).map((r) => [r.user_id, r.data]));
    const sentByUser = new Map();
    for (const row of logRows || []) {
      if (!sentByUser.has(row.user_id)) sentByUser.set(row.user_id, new Set());
      sentByUser.get(row.user_id).add(row.invoice_id);
    }

    const invByUser = new Map();
    for (const row of invRows || []) {
      const invoice = { ...row.data, id: row.id };
      if (!invByUser.has(row.user_id)) invByUser.set(row.user_id, []);
      invByUser.get(row.user_id).push(invoice);
    }

    for (const [userId, invoices] of invByUser) {
      const settings = settingsByUser.get(userId);
      const alreadySent = [...(sentByUser.get(userId) || [])];
      const toSend = selectInvoicesToRemind({ invoices, settings, alreadySentInvoiceIds: alreadySent, today });

      for (const invoice of toSend) {
        scanned++;
        // Per-invoice isolation: a network throw on the claim below must not
        // abort the whole daily batch.
        try {
          // CLAIM: insert first as 'pending'. A conflict on (user_id, invoice_id)
          // returns [] → already handled by a prior run (one-and-done), skip.
          const claimRes = await sbFetch("auto_reminder_log?on_conflict=user_id,invoice_id", {
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

          // SEND, then record the outcome via best-effort markLog (never throws).
          try {
            const email = buildReminderEmail({ invoice, settings, today });
            const r = await fetch("https://api.resend.com/emails", {
              method: "POST",
              headers: { Authorization: `Bearer ${RESEND_API_KEY}`, "Content-Type": "application/json" },
              body: JSON.stringify(email),
            });
            if (!r.ok) throw new Error(`Resend ${r.status}: ${await r.text()}`);
            sent++;
            await markLog(logId, { status: "sent", sent_at: new Date().toISOString() });
          } catch (sendErr) {
            failed++;
            console.error("[send-reminders] send failed", invoice.id, sendErr.message);
            await markLog(logId, { status: "failed", error: String(sendErr.message).slice(0, 500) });
          }
        } catch (invErr) {
          failed++;
          console.error("[send-reminders] invoice error", invoice.id, invErr.message);
        }
      }
    }

    return res.status(200).json({ scanned, sent, failed });
  } catch (err) {
    console.error("[send-reminders] fatal", err.message);
    return res.status(500).json({ error: "Reminder run failed" });
  }
};

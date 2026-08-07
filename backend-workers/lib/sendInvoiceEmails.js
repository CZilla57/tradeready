// 15-minute invoice auto-email batch (2026-08-06 spec) — structural sibling
// of sendReminders.js: this is the business logic both the Workers
// scheduled() trigger (*/15 cron) and the manual HTTP fallback route
// (src/routes/cron.js) call. Emails each client-stamped auto-invoice once
// (idempotency + audit via auto_invoice_email_log) for owners who opted in
// (settings.autoEmailInvoiceOnComplete).
//
// Required bindings:
//   SUPABASE_URL
//   SUPABASE_SERVICE_ROLE_KEY — service role (bypasses RLS to scan all users)
//   RESEND_API_KEY            — Resend REST API key (sender domain already verified)

const { selectInvoicesToAutoEmail } = require("./selectInvoicesToAutoEmail");
const { buildInvoiceEmail } = require("./invoiceEmail");
const { attachmentDecision, invoicePdfName } = require("./invoicePdfAttach");

// Same rationale as sendReminders.js's cap: sends are one-and-done per
// invoice, so honest volume is bounded by NEW auto-invoices in a day; 25
// covers a solo operator's busiest day while capping the blast radius of a
// hostile account. Counted from log rows stamped today (UTC) — the claim
// insert defaults sent_at to now(), so pending/failed attempts count too.
const MAX_INVOICE_EMAILS_PER_USER_PER_DAY = 25;

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
// the batch, or double-count.
async function markLog(env, logId, patch) {
  try {
    const r = await sbFetch(env, `auto_invoice_email_log?id=eq.${logId}`, {
      method: "PATCH",
      body: JSON.stringify(patch),
    });
    if (!r.ok) console.error("[send-invoice-emails] status write non-2xx", logId, r.status);
  } catch (e) {
    console.error("[send-invoice-emails] status write threw", logId, e.message);
  }
}

// Runs one sweep. Returns { scanned, sent, failed, capped, waitingOnPdf };
// throws on a fatal (whole-batch) error — callers map that to a 500 /
// scheduled-run log.
async function runInvoiceEmails(env) {
  if (!env.SUPABASE_URL || !env.SUPABASE_SERVICE_ROLE_KEY || !env.RESEND_API_KEY) {
    throw new Error("Server misconfiguration: SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, RESEND_API_KEY required.");
  }

  const today = new Date();
  let scanned = 0;
  let sent = 0;
  let failed = 0;
  let capped = 0;
  let waitingOnPdf = 0;
  let warnedMissingBucket = false;

  const [invRows, setRows, logRows] = await Promise.all([
    // All non-deleted invoices; the selector filters to stamped+fresh+unpaid.
    // No jobs fetch (unlike sendReminders.js): a deposit-finalize job never
    // enters this path — shouldAutoInvoice refuses jobs with an invoiceId.
    sbFetch(env, "invoices?deleted=is.false&select=id,user_id,data").then((r) => r.json()),
    sbFetch(env, "settings?select=user_id,data").then((r) => r.json()),
    sbFetch(env, "auto_invoice_email_log?select=user_id,invoice_id,sent_at").then((r) => r.json()),
  ]);

  const settingsByUser = new Map((setRows || []).map((r) => [r.user_id, r.data]));
  const dayStart = new Date(today);
  dayStart.setUTCHours(0, 0, 0, 0);
  const handledByUser = new Map();
  const todayCountByUser = new Map();
  for (const row of logRows || []) {
    if (!handledByUser.has(row.user_id)) handledByUser.set(row.user_id, new Set());
    handledByUser.get(row.user_id).add(row.invoice_id);
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

  for (const [userId, invoices] of invByUser) {
    const settings = settingsByUser.get(userId);
    const alreadyHandled = [...(handledByUser.get(userId) || [])];
    const toSend = selectInvoicesToAutoEmail({ invoices, settings, alreadyHandledInvoiceIds: alreadyHandled, today });
    let claimedToday = todayCountByUser.get(userId) || 0;
    let deferred = 0;

    for (const invoice of toSend) {
      // Daily cap: everything past the ceiling waits — no log row is written,
      // so a later run picks it up (within the 7-day freshness window).
      if (claimedToday >= MAX_INVOICE_EMAILS_PER_USER_PER_DAY) {
        deferred++;
        continue;
      }

      // Resolve the R2 PDF + grace decision BEFORE claiming: a deferral must
      // write no log row so a later sweep retries once the upload lands.
      let attachment = null;
      let pdfKey = null;
      try {
        const bucket = env.INVOICE_PDFS;
        let obj = null;
        if (bucket) {
          pdfKey = `${userId}/${invoice.id}.pdf`;
          obj = await bucket.get(pdfKey);
        } else if (!warnedMissingBucket) {
          warnedMissingBucket = true;
          console.error("[send-invoice-emails] INVOICE_PDFS binding missing — sending plain");
        }
        const stamped = Date.parse(invoice.autoEmailRequestedAt);
        const ageMs = Number.isFinite(stamped) ? today.getTime() - stamped : Infinity;
        const decision = attachmentDecision({ hasObject: !!obj, ageMs });
        if (decision === "defer") {
          waitingOnPdf++;
          continue; // no claim; retried next sweep
        }
        if (obj) {
          const buf = await obj.arrayBuffer();
          attachment = {
            filename: invoicePdfName(invoice),
            content: Buffer.from(buf).toString("base64"),
          };
        }
        // decision === "plain" → attachment stays null
      } catch (pdfErr) {
        // An R2 read glitch must never block billing — fall through to plain.
        console.error("[send-invoice-emails] pdf fetch error", invoice.id, pdfErr.message);
      }

      scanned++;
      // Per-invoice isolation: a network throw on the claim must not abort
      // the whole batch.
      try {
        // CLAIM: insert first as 'pending'. A conflict on (user_id, invoice_id)
        // returns [] → already handled by a prior run (one-and-done), skip.
        const claimRes = await sbFetch(env, "auto_invoice_email_log?on_conflict=user_id,invoice_id", {
          method: "POST",
          headers: { Prefer: "return=representation,resolution=ignore-duplicates" },
          body: JSON.stringify({ user_id: userId, invoice_id: invoice.id, to_email: invoice.email, status: "pending" }),
        });
        if (!claimRes.ok) {
          // e.g. table missing (migration not applied) or a permissions error —
          // surface it instead of silently treating it as a duplicate.
          failed++;
          console.error("[send-invoice-emails] claim failed", invoice.id, claimRes.status, await claimRes.text());
          continue;
        }
        const claimed = await claimRes.json().catch(() => []);
        if (!Array.isArray(claimed) || claimed.length === 0) continue; // already claimed
        const logId = claimed[0].id;
        claimedToday++;

        // SEND, then record the outcome via best-effort markLog (never throws).
        try {
          const email = buildInvoiceEmail({ invoice, settings, attachment });
          const r = await fetch("https://api.resend.com/emails", {
            method: "POST",
            headers: { Authorization: `Bearer ${env.RESEND_API_KEY}`, "Content-Type": "application/json" },
            body: JSON.stringify(email),
          });
          if (!r.ok) throw new Error(`Resend ${r.status}: ${await r.text()}`);
          sent++;
          await markLog(env, logId, { status: "sent", sent_at: new Date().toISOString() });
          if (pdfKey && env.INVOICE_PDFS) {
            try {
              await env.INVOICE_PDFS.delete(pdfKey);
            } catch (delErr) {
              console.error("[send-invoice-emails] pdf delete failed", invoice.id, delErr.message);
            }
          }
        } catch (sendErr) {
          failed++;
          console.error("[send-invoice-emails] send failed", invoice.id, sendErr.message);
          await markLog(env, logId, { status: "failed", error: String(sendErr.message).slice(0, 500) });
        }
      } catch (invErr) {
        failed++;
        console.error("[send-invoice-emails] invoice error", invoice.id, invErr.message);
      }
    }

    if (deferred > 0) {
      capped += deferred;
      console.error("[send-invoice-emails] daily cap reached", userId, "deferred", deferred);
    }
  }

  return { scanned, sent, failed, capped, waitingOnPdf };
}

module.exports = { runInvoiceEmails, MAX_INVOICE_EMAILS_PER_USER_PER_DAY };

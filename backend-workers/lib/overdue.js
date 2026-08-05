// backend/lib/overdue.js
// Pure date/money helpers for the auto-reminder cron. No I/O. Mirrors the app's
// invoiceHelpers.daysPastDue (local-midnight, whole days) — duplicated here
// because the backend is a separate package and cannot import the RN util.

function daysPastDue(dueDate, today = new Date()) {
  const due = new Date(dueDate);
  const t = new Date(today);
  t.setHours(0, 0, 0, 0);
  return Math.floor((t.getTime() - due.getTime()) / 86400000);
}

function formatMoney(n) {
  return Number(n || 0).toLocaleString("en-US", { style: "currency", currency: "USD" });
}

module.exports = { daysPastDue, formatMoney };

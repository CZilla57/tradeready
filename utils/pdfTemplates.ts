import type { Invoice, Job, Customer, Settings } from '../types/models';
import { formatMoney, formatQuote } from "./format";
import { parseLocalDate } from "./moneyUtils";
import { computeEstimateBreakdown } from "./pricingEngine";
import { isFullyPaid, isPartlyPaid, amountPaid, balanceDue, effectivePayments } from "./invoicePayments";

const ACCENT = "#007aff";

const METHOD_LABELS: Record<string, string> = {
  cash: "Cash", check: "Cheque", card: "Card", stripe: "Card", other: "Payment",
};

function escapeHtml(str: string): string {
  return str
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#39;');
}

function safe(value: string | number | undefined | null): string {
  if (value == null) return '';
  return escapeHtml(String(value));
}

function fmtDate(dateStr: string | undefined): string {
  if (!dateStr) return "";
  // Date-only strings (due dates, payment dates) are calendar dates — a bare
  // new Date() would parse them as UTC midnight and render the PREVIOUS day
  // in any negative-offset timezone. Full ISO timestamps pass through
  // parseLocalDate unchanged.
  return parseLocalDate(dateStr).toLocaleDateString("en-US", {
    month: "short",
    day: "numeric",
    year: "numeric",
  });
}

const BASE_CSS = `
  * { box-sizing: border-box; margin: 0; padding: 0; }
  body {
    font-family: -apple-system, Helvetica, Arial, sans-serif;
    color: #1c1c1e;
    background: #fff;
    padding: 48px 48px 64px;
    font-size: 14px;
    line-height: 1.5;
  }
  .header {
    display: flex;
    justify-content: space-between;
    align-items: flex-start;
    margin-bottom: 40px;
    padding-bottom: 24px;
    border-bottom: 2px solid ${ACCENT};
  }
  .logo { max-height: 56px; max-width: 140px; object-fit: contain; margin-bottom: 8px; display: block; }
  .biz-name { font-size: 22px; font-weight: 700; color: ${ACCENT}; }
  .biz-sub { font-size: 12px; color: #636366; margin-top: 4px; }
  /* The address gets its own line: appended to .biz-sub it made the contact line
     long enough to wrap mid-address. Tighter margin so it reads as a continuation
     of the same block rather than a separate one. */
  .biz-addr { font-size: 12px; color: #636366; margin-top: 2px; }
  .section-header td {
    padding: 10px 0 6px;
    font-size: 11px;
    font-weight: 700;
    letter-spacing: 1px;
    text-transform: uppercase;
    color: #636366;
    border-bottom: 1px solid #e5e5ea;
  }
  .doc-type {
    font-size: 28px;
    font-weight: 300;
    letter-spacing: 6px;
    color: #8e8e93;
    text-transform: uppercase;
  }
  .meta-grid {
    display: grid;
    grid-template-columns: 1fr 1fr;
    gap: 24px;
    margin-bottom: 32px;
  }
  .meta-block .label {
    font-size: 10px;
    font-weight: 700;
    letter-spacing: 1.2px;
    text-transform: uppercase;
    color: #8e8e93;
    margin-bottom: 4px;
  }
  .meta-block .value { font-size: 14px; color: #1c1c1e; }
  table { width: 100%; border-collapse: collapse; margin-bottom: 16px; }
  thead th {
    font-size: 10px;
    font-weight: 700;
    letter-spacing: 1px;
    text-transform: uppercase;
    color: #8e8e93;
    padding: 8px 0;
    border-bottom: 1px solid #e5e5ea;
    text-align: left;
  }
  thead th:last-child { text-align: right; }
  tbody td {
    padding: 12px 0;
    border-bottom: 1px solid #f2f2f7;
    font-size: 14px;
    vertical-align: top;
  }
  tbody td:last-child { text-align: right; font-weight: 500; }
  .total-row {
    background: #f0f6ff;
    border-radius: 8px;
    padding: 14px 16px;
    display: flex;
    justify-content: space-between;
    align-items: center;
    margin-top: 8px;
  }
  .total-label { font-size: 13px; font-weight: 600; color: #1c1c1e; }
  .total-amount { font-size: 24px; font-weight: 700; color: ${ACCENT}; }
  .badge {
    display: inline-block;
    padding: 3px 12px;
    border-radius: 20px;
    font-size: 11px;
    font-weight: 700;
    letter-spacing: 0.5px;
    text-transform: uppercase;
  }
  .badge-paid   { background: #e8f9f0; color: #25a65b; }
  .badge-unpaid { background: #fff3e0; color: #c47a00; }
  .footer {
    margin-top: 56px;
    padding-top: 16px;
    border-top: 1px solid #e5e5ea;
    font-size: 11px;
    color: #8e8e93;
    text-align: center;
  }
`;

// Invoice-only rules (the "Partly paid" badge, the payment-history table, the
// sub-total rows above BALANCE DUE). estimateHtml has no payment ledger and
// never emits these classes, so they must not be part of the CSS shared with
// it — see Finding 3. invoiceHtml injects this itself, and only when an
// invoice's own render actually uses one of these classes, so pre-existing
// invoices (no partial payment, no history) keep a <style> block that is
// byte-identical to what commit fbadd88 produced.
const INVOICE_ONLY_CSS = `
  .badge-partial { background: #eaf2ff; color: #2f6fd0; }
  .history { margin-top: 18px; }
  .history-title { font-size: 12px; font-weight: 600; color: #6b6b70; text-transform: uppercase; letter-spacing: 0.4px; }
  .history table { width: 100%; margin-top: 6px; }
  .history td { font-size: 12px; color: #48484a; padding: 3px 0; }
  .history td.amt { text-align: right; color: #1c1c1e; font-weight: 600; }
  .sub-row { display: flex; justify-content: space-between; padding: 2px 0; font-size: 13px; color: #48484a; }
  .sub-row .sub-amount { font-weight: 600; color: #1c1c1e; }
`;

/**
 * Invoice has no `created` field, so the issue date is recovered from the ms
 * timestamp both creation paths embed in the id (`inv${Date.now()}` from
 * CreateInvoiceFromJobScreen, `String(Date.now())` from AddInvoiceScreen).
 * Sample and legacy rows use non-timestamp ids (e.g. `1-<seed>`) — those fall
 * back to today, which is the old behaviour for every invoice.
 */
export function invoiceIssueDate(id: string, now: Date = new Date()): string {
  const raw = id.replace(/^inv/, "");
  const ms = /^\d+$/.test(raw) ? Number(raw) : NaN;
  const year = Number.isFinite(ms) ? new Date(ms).getUTCFullYear() : NaN;
  // The range guard rejects all-digit ids that aren't plausible timestamps.
  return year >= 2000 && year <= 2100
    ? new Date(ms).toISOString()
    : now.toISOString();
}

/**
 * Splits the business header into two lines. The address used to be joined onto
 * the contact line, which made it long enough to wrap mid-address on both the
 * invoice and the estimate — so the address now starts on its own line.
 *
 * Either line can come back empty (a business with no address, or one with an
 * address but no contact details); callers must skip an empty line rather than
 * emit a blank div.
 */
function bizHeaderLines(biz: Partial<Settings>): { contactLine: string; addressLine: string } {
  return {
    contactLine: [biz.contactName, biz.phone, biz.email].filter(Boolean).join(" · "),
    addressLine: biz.address || "",
  };
}

export function invoiceHtml(invoice: Invoice, biz: Partial<Settings> = {}, logoDataUri?: string): string {
  const bizName = biz.businessName || "Your Business";
  const { contactLine, addressLine } = bizHeaderLines(biz);

  const issueDate = fmtDate(invoiceIssueDate(invoice.id));
  const dueDate   = fmtDate(invoice.due);
  const isPaid    = isFullyPaid(invoice);
  const isPartly = isPartlyPaid(invoice);
  const paidToDate = amountPaid(invoice);
  const balance = balanceDue(invoice);

  // The customer's copy excludes voided entries (internal bookkeeping) and the
  // synthesized legacy_<id> entry (internal language about an app migration).
  // Between those two rules a pre-existing invoice has nothing left to show,
  // which is what keeps its PDF byte-identical.
  const historyPayments = effectivePayments(invoice)
    .filter((p) => !p.voidedAt && !p.id.startsWith("legacy_"));

  const items = invoice.lineItems ?? [];
  const primaryItems = items.filter((li) => li.category === "labor");
  const additionalItems = items.filter((li) => li.category !== "labor");

  let tableRows = "";
  if (items.length > 0) {
    for (const li of primaryItems) {
      tableRows += `<tr><td>${safe(li.description)}</td><td>${formatMoney(li.amount)}</td></tr>`;
    }
    if (additionalItems.length > 0) {
      tableRows += `<tr class="section-header"><td colspan="2">Additional Charges</td></tr>`;
      for (const li of additionalItems) {
        tableRows += `<tr><td>${safe(li.description)}</td><td>${formatMoney(li.amount)}</td></tr>`;
      }
    }
  } else {
    tableRows = `<tr><td>${safe(invoice.desc) || "Services rendered"}</td><td>${formatMoney(invoice.amount)}</td></tr>`;
  }

  // Built procedurally (rather than inline in the returned literal) so the
  // "old" branch below can reproduce the pre-db70741 literal exactly — no
  // extra newlines get introduced around it. See Finding 1.
  const totalBlock = isPartly
    ? `<div class="sub-row">
  <span>Invoice total</span>
  <span class="sub-amount">${formatMoney(invoice.amount)}</span>
</div>
<div class="sub-row">
  <span>Paid to date</span>
  <span class="sub-amount">−${formatMoney(paidToDate)}</span>
</div>
<div class="total-row">
  <span class="total-label">BALANCE DUE</span>
  <span class="total-amount">${formatMoney(balance)}</span>
</div>`
    : `<div class="total-row">
  <span class="total-label">TOTAL DUE</span>
  <span class="total-amount">${formatMoney(invoice.amount)}</span>
</div>`;

  const historyBlock = historyPayments.length
    ? `\n\n<div class="history">
  <div class="history-title">Payment history</div>
  <table>
    <tbody>
      ${historyPayments.map((p) => `<tr><td>${fmtDate(p.date)}</td><td>${safe(METHOD_LABELS[p.method] ?? p.method)}</td><td class="amt">${formatMoney(p.amount)}</td></tr>`).join("")}
    </tbody>
  </table>
</div>`
    : "";

  // The badge-partial/history/sub-row CSS only matters when this specific
  // invoice actually renders one of those elements — see Finding 3.
  const needsInvoiceCss = isPartly || historyPayments.length > 0;

  return `<!DOCTYPE html><html><head><meta charset="utf-8">
<style>${BASE_CSS}${needsInvoiceCss ? INVOICE_ONLY_CSS : ""}</style></head><body>

<div class="header">
  <div>
    ${logoDataUri ? `<img class="logo" src="${logoDataUri}" />` : ""}
    <div class="biz-name">${safe(bizName)}</div>
    ${contactLine ? `<div class="biz-sub">${safe(contactLine)}</div>` : ""}
    ${addressLine ? `<div class="biz-addr">${safe(addressLine)}</div>` : ""}
  </div>
  <div class="doc-type">Invoice</div>
</div>

<div class="meta-grid">
  <div class="meta-block">
    <div class="label">Bill To</div>
    <div class="value"><strong>${safe(invoice.customer)}</strong></div>
    ${invoice.email ? `<div class="value">${safe(invoice.email)}</div>` : ""}
    ${invoice.phone ? `<div class="value">${safe(invoice.phone)}</div>` : ""}
  </div>
  <div class="meta-block" style="text-align:right">
    <div class="label">Invoice #</div>
    <div class="value"><strong>${safe(invoice.number) || "—"}</strong></div>
    ${issueDate ? `<div style="margin-top:8px"><span class="label">Issue date</span><br><span class="value">${issueDate}</span></div>` : ""}
    ${dueDate ? `<div style="margin-top:8px"><span class="label">Due date</span><br><span class="value">${dueDate}</span></div>` : ""}
    <div style="margin-top:10px">
      <span class="badge ${isPaid ? "badge-paid" : isPartly ? "badge-partial" : "badge-unpaid"}">${isPaid ? "Paid" : isPartly ? "Partly paid" : "Outstanding"}</span>
    </div>
  </div>
</div>

<table>
  <thead>
    <tr><th>Description</th><th>Amount</th></tr>
  </thead>
  <tbody>
    ${tableRows}
  </tbody>
</table>

${totalBlock}${historyBlock}

<div class="footer">Thank you for your business — ${safe(bizName)}</div>

</body></html>`;
}

export function estimateHtml(job: Job, customer: Partial<Customer> = {}, biz: Partial<Settings> = {}, logoDataUri?: string): string {
  const bizName = biz.businessName || "Your Business";
  const { contactLine, addressLine } = bizHeaderLines(biz);

  const { laborCost, materialCost, overheadLine, hasMaterials } = computeEstimateBreakdown(job);
  const hasOverhead = overheadLine > 1;
  const customerName  = customer.name || job.customerName || "";
  const customerEmail = customer.email || "";
  const customerPhone = customer.phone || "";

  const issueDate = fmtDate(new Date().toISOString());

  let rows = "";
  rows += `<tr><td>Labor — ${job.laborHours || 0} hrs @ ${formatQuote(job.laborRate || 0)}/hr</td><td>${formatQuote(laborCost)}</td></tr>`;
  if (hasMaterials) {
    const label = job.materials.length === 1
      ? safe(job.materials[0].name) || "Materials"
      : `Materials (${job.materials.length} items)`;
    rows += `<tr><td>${label}</td><td>${formatQuote(materialCost)}</td></tr>`;
  }
  if (hasOverhead) {
    rows += `<tr><td>Overhead &amp; operating costs</td><td>${formatQuote(overheadLine)}</td></tr>`;
  }

  return `<!DOCTYPE html><html><head><meta charset="utf-8">
<style>${BASE_CSS}</style></head><body>

<div class="header">
  <div>
    ${logoDataUri ? `<img class="logo" src="${logoDataUri}" />` : ""}
    <div class="biz-name">${safe(bizName)}</div>
    ${contactLine ? `<div class="biz-sub">${safe(contactLine)}</div>` : ""}
    ${addressLine ? `<div class="biz-addr">${safe(addressLine)}</div>` : ""}
  </div>
  <div class="doc-type">Estimate</div>
</div>

<div class="meta-grid">
  <div class="meta-block">
    <div class="label">Prepared For</div>
    <div class="value"><strong>${safe(customerName)}</strong></div>
    ${customerEmail ? `<div class="value">${safe(customerEmail)}</div>` : ""}
    ${customerPhone ? `<div class="value">${safe(customerPhone)}</div>` : ""}
  </div>
  <div class="meta-block" style="text-align:right">
    <div class="label">Job</div>
    <div class="value"><strong>${safe(job.title)}</strong></div>
    ${issueDate ? `<div style="margin-top:8px"><span class="label">Date</span><br><span class="value">${issueDate}</span></div>` : ""}
    <div style="margin-top:10px">
      <span class="badge badge-unpaid">Pending Approval</span>
    </div>
  </div>
</div>

<table>
  <thead>
    <tr><th>Item</th><th>Amount</th></tr>
  </thead>
  <tbody>
    ${rows}
  </tbody>
</table>

<div class="total-row">
  <span class="total-label">TOTAL ESTIMATE</span>
  <span class="total-amount">${formatQuote(job.estimateTotal || 0)}</span>
</div>

<p style="margin-top:24px; font-size:12px; color:#636366;">
  This estimate is valid for 30 days. Reply to approve and we'll get you scheduled.
</p>

<div class="footer">Thank you for considering ${safe(bizName)}</div>

</body></html>`;
}

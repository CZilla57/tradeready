import type { Invoice, Job, Customer, Settings } from '../types/models';
import { formatMoney, formatQuote } from "./format";
import { computeEstimateBreakdown } from "./pricingEngine";

const ACCENT = "#007aff";

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
  return new Date(dateStr).toLocaleDateString("en-US", {
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

export function invoiceHtml(invoice: Invoice, biz: Partial<Settings> = {}, logoDataUri?: string): string {
  const bizName    = biz.businessName || "Your Business";
  const bizPhone   = biz.phone   || "";
  const bizEmail   = biz.email   || "";
  const bizAddress = biz.address || "";
  const bizContact = biz.contactName || "";

  const bizSubLines = [bizContact, bizPhone, bizEmail, bizAddress]
    .filter(Boolean)
    .join(" · ");

  const issueDate = fmtDate(new Date().toISOString());
  const dueDate   = fmtDate(invoice.due);
  const isPaid    = invoice.paid;

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

  return `<!DOCTYPE html><html><head><meta charset="utf-8">
<style>${BASE_CSS}</style></head><body>

<div class="header">
  <div>
    ${logoDataUri ? `<img class="logo" src="${logoDataUri}" />` : ""}
    <div class="biz-name">${safe(bizName)}</div>
    ${bizSubLines ? `<div class="biz-sub">${safe(bizSubLines)}</div>` : ""}
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
      <span class="badge ${isPaid ? "badge-paid" : "badge-unpaid"}">${isPaid ? "Paid" : "Outstanding"}</span>
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

<div class="total-row">
  <span class="total-label">TOTAL DUE</span>
  <span class="total-amount">${formatMoney(invoice.amount)}</span>
</div>

<div class="footer">Thank you for your business — ${safe(bizName)}</div>

</body></html>`;
}

export function estimateHtml(job: Job, customer: Partial<Customer> = {}, biz: Partial<Settings> = {}, logoDataUri?: string): string {
  const bizName    = biz.businessName || "Your Business";
  const bizPhone   = biz.phone   || "";
  const bizEmail   = biz.email   || "";
  const bizAddress = biz.address || "";
  const bizContact = biz.contactName || "";

  const bizSubLines = [bizContact, bizPhone, bizEmail, bizAddress]
    .filter(Boolean)
    .join(" · ");

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
    ${bizSubLines ? `<div class="biz-sub">${safe(bizSubLines)}</div>` : ""}
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

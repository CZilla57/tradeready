// utils/invoiceHelpers.js
// Pure functions that don't touch the UI — easy to test and reuse.

import Constants from 'expo-constants';

export function daysPastDue(dueDate) {
  const due = new Date(dueDate);
  const today = new Date();
  today.setHours(0, 0, 0, 0);
  return Math.floor((today - due) / (1000 * 60 * 60 * 24));
}

export function getStatus(invoice) {
  if (invoice.paid) {
    return { label: "Paid", color: "success", days: 0 };
  }
  const days = daysPastDue(invoice.due);
  if (days <= 0) {
    return { label: days === 0 ? "Due today" : "Due soon", color: "accent", days };
  }
  if (days <= 14) {
    return { label: `${days}d overdue`, color: "warning", days };
  }
  return { label: `${days}d overdue`, color: "danger", days };
}

export function formatCurrency(amount) {
  return amount.toLocaleString("en-US", {
    style: "currency",
    currency: "USD",
    maximumFractionDigits: 0,
  });
}

export function formatDate(dateString) {
  const d = new Date(dateString);
  return d.toLocaleDateString("en-US", { month: "short", day: "numeric", year: "numeric" });
}

export function buildPaymentLink(invoice, provider, providerKey) {
  const amt = invoice.amount.toFixed(2);
  const desc = encodeURIComponent(`${invoice.number} - ${invoice.desc}`);
  const key = providerKey || "YOUR_KEY";

  switch (provider) {
    case "stripe":
      // providerKey for Stripe is the backend API token, not a Stripe payment
      // link slug — there is no valid client-side fallback URL for Stripe.
      // Callers should surface an error rather than generating a broken link.
      throw new Error("Stripe payment links require the backend to be configured. Check your Vercel setup in Settings.");
    case "square":
      return `https://squareup.com/pay/${key}?amount=${amt}&note=${desc}`;
    case "paypal":
      return `https://www.paypal.com/invoice/p/#${invoice.number}`;
    case "venmo":
      return `https://venmo.com/${key || "yourusername"}?txn=pay&amount=${amt}&note=${desc}`;
    case "quickbooks":
      return `https://app.qbo.intuit.com/app/invoice?id=${invoice.number}`;
    default:
      return `${key || "https://yourpaymentpage.com"}?amount=${amt}&invoice=${invoice.number}`;
  }
}

// Returns the invoice's already-cached payment link, or fetches a new one.
// Centralising this decision prevents duplicate Stripe/Square objects from being
// created every time the Outreach screen is opened for the same invoice.
export async function resolvePaymentLink(invoice, provider, providerKey) {
  if (invoice.paymentLinkUrl) return invoice.paymentLinkUrl;
  return fetchPaymentLink(invoice, provider, providerKey);
}

// Calls the Vercel serverless function to create a Stripe Payment Link.
//
// SECURITY: The Stripe secret key lives in STRIPE_SECRET_KEY on the server.
// The app never sends an sk_ key over the network. providerKey here is the
// BACKEND_API_TOKEN — a simple shared secret that authenticates this request.
const VERCEL_URL = Constants.expoConfig?.extra?.backendUrl ?? '';
const VERCEL_URL_IS_PLACEHOLDER = Constants.expoConfig?.extra?.backendUrlIsPlaceholder ?? true;

export async function fetchPaymentLink(invoice, provider, providerKey) {
  const endpoints = {
    stripe: `${VERCEL_URL}/api/create-payment-link`,
    // square and paypal have no backend implementation yet — fall through to buildPaymentLink
  };

  const endpoint = endpoints[provider];

  // Fall back to client-side link builder when there's no server configured
  // or for providers that don't need a server call (Venmo, custom URL).
  if (!endpoint || VERCEL_URL_IS_PLACEHOLDER) {
    return buildPaymentLink(invoice, provider, providerKey);
  }

  const headers = { "Content-Type": "application/json" };
  if (providerKey) {
    // providerKey is the BACKEND_API_TOKEN — authenticates the request, not the Stripe key
    headers["Authorization"] = `Bearer ${providerKey}`;
  }

  const res = await fetch(endpoint, {
    method: "POST",
    headers,
    body: JSON.stringify({
      amount: invoice.amount,
      invoiceNumber: invoice.number,
      description: invoice.desc,
      customerEmail: invoice.email,
      // No stripeKey — it lives in STRIPE_SECRET_KEY env var on the server
    }),
  });

  const data = await res.json();
  if (data.error) {
    const msg = typeof data.error === "string"
      ? data.error
      : data.error?.message || JSON.stringify(data.error);
    throw new Error(msg);
  }
  return data.url;
}

function buildGenericMessage({ invoice, channel, biz, paymentLink, paymentPlan }) {
  const days = daysPastDue(invoice.due);
  const amt = formatCurrency(invoice.amount);
  const overdueText = days > 0 ? `${days} days overdue` : days === 0 ? 'due today' : `due in ${Math.abs(days)} days`;

  let planText = '';
  if (paymentPlan?.enabled) {
    const per = (invoice.amount / parseInt(paymentPlan.installments)).toLocaleString('en-US', { style: 'currency', currency: 'USD' });
    planText = ` We can also arrange ${paymentPlan.installments} payments of ${per} ${paymentPlan.frequency.toLowerCase()} if that works better for you.`;
  }

  if (channel === 'text') {
    return `Hi ${invoice.customer}, this is ${biz.businessName}. Invoice ${invoice.number} for ${amt} is ${overdueText}.${planText} Pay here: ${paymentLink} — ${biz.phone}`;
  }

  return `Subject: Payment reminder – ${invoice.number}

Hi ${invoice.customer},

I hope you're doing well. I'm reaching out regarding invoice ${invoice.number} for ${amt}, which is currently ${overdueText}.

You can pay securely online here:
Pay now → ${paymentLink}
${planText ? `\n${planText}\n` : ''}
If you have any questions or concerns, please don't hesitate to get in touch.

${biz.paymentNotes ? `${biz.paymentNotes}\n\n` : ''}Best regards,
${biz.contactName}
${biz.businessName}
${biz.phone}`;
}

// ── Estimate messaging ─────────────────────────────────────────────────────

function buildGenericEstimateMessage({ job, customer, channel, biz }) {
  const laborCost = job.laborHours * job.laborRate;
  const rawMaterialCost = (job.materials || []).reduce(
    (s, m) => s + m.quantity * m.unitCost, 0
  );
  const materialCost = rawMaterialCost * (1 + job.materialMarkup / 100);
  const overheadLine = job.estimateTotal - laborCost - materialCost;
  const hasMaterials = (job.materials || []).length > 0;

  if (channel === 'text') {
    const parts = [
      `Hi ${customer.name}, ${biz.businessName} here.`,
      `Estimate for "${job.title}":`,
      `Labor: ${formatCurrency(laborCost)}`,
    ];
    if (hasMaterials) parts.push(`Materials: ${formatCurrency(materialCost)}`);
    parts.push(`Total: ${formatCurrency(job.estimateTotal)}.`);
    parts.push(`Reply YES to approve or call ${biz.phone}.`);
    return parts.join(' ');
  }

  const lines = [
    `Subject: Estimate for ${job.title} – ${biz.businessName}`,
    '',
    `Hi ${customer.name},`,
    '',
    `Thank you for reaching out. Here's your estimate for ${job.title}:`,
    '',
    `  Labor (${job.laborHours} hrs @ $${job.laborRate}/hr)  ${formatCurrency(laborCost)}`,
  ];
  if (hasMaterials) {
    lines.push(`  Materials (${job.materials.length} item${job.materials.length !== 1 ? 's' : ''})  ${formatCurrency(materialCost)}`);
  }
  if (overheadLine > 0) {
    lines.push(`  Overhead & operating costs  ${formatCurrency(overheadLine)}`);
  }
  lines.push(`  ${'─'.repeat(36)}`);
  lines.push(`  TOTAL ESTIMATE  ${formatCurrency(job.estimateTotal)}`);
  if (job.description) lines.push('', job.description);
  lines.push(
    '',
    'To approve this estimate, simply reply to this email or give me a call.',
    'I can typically schedule work within a few business days of approval.',
  );
  if (biz.paymentNotes) lines.push('', biz.paymentNotes);
  lines.push('', `Best regards,`, `${biz.contactName}`, `${biz.businessName}`, `${biz.phone}`);
  return lines.join('\n');
}

export async function generateEstimateMessage({ job, customer, channel, biz, apiKey }) {
  if (!apiKey) return buildGenericEstimateMessage({ job, customer, channel, biz });

  const laborCost = job.laborHours * job.laborRate;
  const rawMaterialCost = (job.materials || []).reduce(
    (s, m) => s + m.quantity * m.unitCost, 0
  );
  const materialCost = rawMaterialCost * (1 + job.materialMarkup / 100);
  const overheadLine = job.estimateTotal - laborCost - materialCost;
  const hasMaterials = (job.materials || []).length > 0;

  const breakdown = [
    `Labor: ${job.laborHours} hrs @ $${job.laborRate}/hr = ${formatCurrency(laborCost)}`,
    ...(hasMaterials ? [`Materials (${job.materials.length} items, with markup): ${formatCurrency(materialCost)}`] : []),
    ...(overheadLine > 0 ? [`Overhead & operating costs: ${formatCurrency(overheadLine)}`] : []),
    `Total estimate: ${formatCurrency(job.estimateTotal)}`,
  ].join('\n');

  const isText = channel === 'text';
  const prompt = `Draft a ${isText ? 'text message (SMS)' : 'professional email'} from ${biz.businessName} (${biz.contactName}) presenting a job estimate to a customer.

Customer: ${customer.name}${customer.email ? ` | ${customer.email}` : ''}${customer.phone ? ` | ${customer.phone}` : ''}
Job: ${job.title}
${job.description ? `Description: ${job.description}` : ''}

Estimate breakdown:
${breakdown}

Business contact: ${biz.phone}${biz.email ? ` | ${biz.email}` : ''}
${biz.paymentNotes ? `Payment terms: ${biz.paymentNotes}` : ''}

${isText
  ? 'For SMS: Keep under 300 characters. Include the job name, total, and how to approve. Friendly and professional.'
  : 'For email: First line must be "Subject: [subject line]" then a blank line then the body. Include the full breakdown. Explain how to approve. Professional, warm tone.'
}

Write only the message, no commentary.`;

  try {
    const res = await fetch('https://api.anthropic.com/v1/messages', {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'x-api-key': apiKey,
        'anthropic-version': '2023-06-01',
      },
      body: JSON.stringify({
        model: 'claude-sonnet-4-6',
        max_tokens: 800,
        messages: [{ role: 'user', content: prompt }],
      }),
    });
    const data = await res.json();
    if (data.error) throw new Error(data.error.message || JSON.stringify(data.error));
    return data.content?.map(b => b.text || '').join('') || buildGenericEstimateMessage({ job, customer, channel, biz });
  } catch {
    return buildGenericEstimateMessage({ job, customer, channel, biz });
  }
}

// Calls the Anthropic API to generate a collection message.
// Falls back to a pre-written template if no API key is set or the call fails.
export async function generateOutreachMessage({ invoice, channel, biz, paymentLink, paymentPlan, apiKey }) {
  if (!apiKey) return buildGenericMessage({ invoice, channel, biz, paymentLink, paymentPlan });

  const days = daysPastDue(invoice.due);
  const amt = formatCurrency(invoice.amount);
  const isText = channel === "text";

  let planInfo = "";
  if (paymentPlan?.enabled) {
    const per = (invoice.amount / parseInt(paymentPlan.installments)).toLocaleString("en-US", {
      style: "currency",
      currency: "USD",
    });
    planInfo = `\n\nOffer a payment plan: ${paymentPlan.installments} payments of ${per} ${paymentPlan.frequency.toLowerCase()}. Weave this in naturally.`;
  }

  const prompt = `Draft a ${isText ? "text message (SMS)" : "professional email"} from ${biz.businessName} (${biz.contactName}) to collect an overdue invoice.

Customer: ${invoice.customer}
Invoice: ${invoice.number} for ${amt}
Work: ${invoice.desc}
Days overdue: ${days > 0 ? days + " days past due" : days === 0 ? "due today" : "due in " + Math.abs(days) + " days"}
Customer email: ${invoice.email} | phone: ${invoice.phone}

Business contact: ${biz.phone} | ${biz.email}
Payment info: ${biz.paymentNotes}

PAYMENT LINK: ${paymentLink}
${planInfo}

${
  isText
    ? `For SMS: Keep it under 300 characters. Include the payment link as plain text. Natural, friendly but firm tone.`
    : `For email: First line must be "Subject: [subject]" then blank line then body. Include the payment link prominently labeled as "Pay now → ${paymentLink}". Professional, warm, firm tone.`
}

Write only the message, no commentary.`;

  try {
    const res = await fetch("https://api.anthropic.com/v1/messages", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "x-api-key": apiKey,
        "anthropic-version": "2023-06-01",
      },
      body: JSON.stringify({
        model: "claude-sonnet-4-6",
        max_tokens: 1000,
        messages: [{ role: "user", content: prompt }],
      }),
    });

    const data = await res.json();
    if (data.error) throw new Error(data.error.message || JSON.stringify(data.error));
    return data.content?.map((b) => b.text || "").join("") || buildGenericMessage({ invoice, channel, biz, paymentLink, paymentPlan });
  } catch {
    return buildGenericMessage({ invoice, channel, biz, paymentLink, paymentPlan });
  }
}

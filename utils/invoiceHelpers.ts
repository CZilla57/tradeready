import Constants from 'expo-constants';
import { supabase } from './supabase';
import { formatMoney, formatQuote } from './format';
import { computeEstimateBreakdown } from './pricingEngine';
import { generateOneShot } from './oneShotAI';
import type { Invoice, Job, Customer, Settings, PaymentPlan, PaymentProvider } from '../types/models';
import type { BadgeColor } from '../components/UI';

export function daysPastDue(dueDate: string): number {
  const due = new Date(dueDate);
  const today = new Date();
  today.setHours(0, 0, 0, 0);
  return Math.floor((today.getTime() - due.getTime()) / (1000 * 60 * 60 * 24));
}

export interface InvoiceStatus {
  label: string;
  color: BadgeColor;
  days: number;
}

export function getStatus(invoice: Invoice): InvoiceStatus {
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

export function formatDate(dateString: string): string {
  const d = new Date(dateString);
  return d.toLocaleDateString("en-US", { month: "short", day: "numeric", year: "numeric" });
}

export function getProviderKey(settings: Partial<Settings>, provider?: PaymentProvider): string {
  const p = provider ?? settings.provider;
  if (p === "stripe") return settings.providerKey || "";
  return settings.providerKeys?.[p as string] || "";
}

export function buildPaymentLink(invoice: Invoice, provider: PaymentProvider, providerKey: string): string {
  const amt = invoice.amount.toFixed(2);
  const desc = encodeURIComponent(`${invoice.number} - ${invoice.desc}`);
  const key = providerKey || "YOUR_KEY";

  switch (provider) {
    case "stripe":
      throw new Error("Stripe payment links require the backend to be configured. Check your Vercel setup in Settings.");
    case "square":
      return `https://squareup.com/pay/${key}?amount=${amt}&note=${desc}`;
    case "paypal":
      return `https://paypal.me/${providerKey || "yourusername"}/${amt}`;
    case "venmo":
      return `https://venmo.com/${providerKey || "yourusername"}?txn=pay&amount=${amt}&note=${desc}`;
    default: {
      const base = providerKey || "https://yourpaymentpage.com";
      const sep = base.includes("?") ? "&" : "?";
      return `${base}${sep}amount=${amt}&invoice=${invoice.number}`;
    }
  }
}

export async function resolvePaymentLink(invoice: Invoice, provider: PaymentProvider, providerKey: string): Promise<string> {
  if (invoice.paymentLinkUrl && invoice.paymentLinkAmount === invoice.amount) {
    return invoice.paymentLinkUrl;
  }
  return fetchPaymentLink(invoice, provider, providerKey);
}

const VERCEL_URL = Constants.expoConfig?.extra?.backendUrl ?? '';
const VERCEL_URL_IS_PLACEHOLDER = Constants.expoConfig?.extra?.backendUrlIsPlaceholder ?? true;

export async function fetchPaymentLink(invoice: Invoice, provider: PaymentProvider, providerKey: string): Promise<string> {
  const endpoints: Record<string, string> = {
    stripe: `${VERCEL_URL}/api/create-payment-link`,
  };

  const endpoint = endpoints[provider as string];

  if (!endpoint || VERCEL_URL_IS_PLACEHOLDER) {
    return buildPaymentLink(invoice, provider, providerKey);
  }

  const headers: Record<string, string> = { "Content-Type": "application/json" };

  if (provider === "stripe") {
    const { data: { session } } = await supabase.auth.getSession();
    if (!session?.access_token) {
      throw new Error("You must be signed in to generate a Stripe payment link.");
    }
    headers["Authorization"] = `Bearer ${session.access_token}`;
  } else if (providerKey) {
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
      invoiceId: invoice.id,
    }),
  });

  const data = await res.json();
  if (data.error) {
    const msg = typeof data.error === "string"
      ? data.error
      : data.error?.message || JSON.stringify(data.error);
    throw new Error(msg);
  }
  return data.url as string;
}

interface OutreachMessageParams {
  invoice: Invoice;
  channel: 'text' | 'email';
  biz: Partial<Settings>;
  paymentLink?: string;
  paymentPlan?: PaymentPlan;
}

function buildGenericMessage({ invoice, channel, biz, paymentLink, paymentPlan }: OutreachMessageParams): string {
  const days = daysPastDue(invoice.due);
  const amt = formatMoney(invoice.amount);
  const overdueText = days > 0 ? `${days} days overdue` : days === 0 ? 'due today' : `due in ${Math.abs(days)} days`;

  let planText = '';
  if (paymentPlan?.enabled) {
    const per = formatMoney(invoice.amount / parseInt(String(paymentPlan.installments)));
    planText = ` We can also arrange ${paymentPlan.installments} payments of ${per} ${paymentPlan.frequency.toLowerCase()} if that works better for you.`;
  }

  if (channel === 'text') {
    const linkPart = paymentLink ? ` Pay here: ${paymentLink}` : '';
    return `Hi ${invoice.customer}, this is ${biz.businessName}. Invoice ${invoice.number} for ${amt} is ${overdueText}.${planText}${linkPart} — ${biz.phone}`;
  }

  const linkSection = paymentLink
    ? `You can pay securely online here:\nPay now → ${paymentLink}\n`
    : '';

  return `Subject: Payment reminder – ${invoice.number}

Hi ${invoice.customer},

I hope you're doing well. I'm reaching out regarding invoice ${invoice.number} for ${amt}, which is currently ${overdueText}.

${linkSection}${planText ? `${planText}\n\n` : ''}If you have any questions or concerns, please don't hesitate to get in touch.

${biz.paymentNotes ? `${biz.paymentNotes}\n\n` : ''}Best regards,
${biz.contactName}
${biz.businessName}
${biz.phone}`;
}

interface EstimateMessageParams {
  job: Job;
  customer: Customer;
  channel: 'text' | 'email';
  biz: Partial<Settings>;
  approvalLink?: string;
}

export function buildGenericEstimateMessage({ job, customer, channel, biz, approvalLink }: EstimateMessageParams): string {
  const { laborCost, materialCost, overheadLine, hasMaterials } = computeEstimateBreakdown(job);

  if (channel === 'text') {
    const parts = [
      `Hi ${customer.name}, ${biz.businessName} here.`,
      `Estimate for "${job.title}":`,
      `Labor: ${formatQuote(laborCost)}`,
    ];
    if (hasMaterials) parts.push(`Materials: ${formatQuote(materialCost)}`);
    parts.push(`Total: ${formatQuote(job.estimateTotal)}.`);
    parts.push(approvalLink ? `View & approve: ${approvalLink}` : `Reply YES to approve or call ${biz.phone}.`);
    return parts.join(' ');
  }

  const lines = [
    `Subject: Estimate for ${job.title} – ${biz.businessName}`,
    '',
    `Hi ${customer.name},`,
    '',
    `Thank you for reaching out. Here's your estimate for ${job.title}:`,
    '',
    `  Labor (${job.laborHours} hrs @ $${job.laborRate}/hr)  ${formatQuote(laborCost)}`,
  ];
  if (hasMaterials) {
    lines.push(`  Materials (${job.materials.length} item${job.materials.length !== 1 ? 's' : ''})  ${formatQuote(materialCost)}`);
  }
  if (overheadLine > 0) {
    lines.push(`  Overhead & operating costs  ${formatQuote(overheadLine)}`);
  }
  lines.push(`  ${'─'.repeat(36)}`);
  lines.push(`  TOTAL ESTIMATE  ${formatQuote(job.estimateTotal)}`);
  if (job.description) lines.push('', job.description);
  lines.push(
    '',
    'To approve this estimate, simply reply to this email or give me a call.',
    'I can typically schedule work within a few business days of approval.',
  );
  if (approvalLink) lines.push('', `View and approve your estimate here:\n${approvalLink}`);
  if (biz.paymentNotes) lines.push('', biz.paymentNotes);
  lines.push('', `Best regards,`, `${biz.contactName}`, `${biz.businessName}`, `${biz.phone}`);
  return lines.join('\n');
}

export async function generateEstimateMessage({
  job,
  customer,
  channel,
  biz,
  apiKey,
  approvalLink,
}: EstimateMessageParams & { apiKey?: string }): Promise<string> {
  const fallback = () => buildGenericEstimateMessage({ job, customer, channel, biz, approvalLink });
  if (!apiKey) return fallback();

  const { laborCost, materialCost, overheadLine, hasMaterials } = computeEstimateBreakdown(job);

  const breakdown = [
    `Labor: ${job.laborHours} hrs @ $${job.laborRate}/hr = ${formatQuote(laborCost)}`,
    ...(hasMaterials ? [`Materials (${job.materials.length} items, with markup): ${formatQuote(materialCost)}`] : []),
    ...(overheadLine > 0 ? [`Overhead & operating costs: ${formatQuote(overheadLine)}`] : []),
    `Total estimate: ${formatQuote(job.estimateTotal)}`,
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

  const promptWithLink = approvalLink
    ? `${prompt}\n\nEnd with a clear call to action to review and approve online at this link (include it verbatim): ${approvalLink}`
    : prompt;

  return generateOneShot({ prompt: promptWithLink, apiKey, max_tokens: 800, fallback });
}

export async function generateOutreachMessage({
  invoice,
  channel,
  biz,
  paymentLink,
  paymentPlan,
  apiKey,
}: OutreachMessageParams & { apiKey?: string }): Promise<string> {
  const fallback = () => buildGenericMessage({ invoice, channel, biz, paymentLink, paymentPlan });
  if (!apiKey) return fallback();

  const days = daysPastDue(invoice.due);
  const amt = formatMoney(invoice.amount);
  const isText = channel === "text";

  let planInfo = "";
  if (paymentPlan?.enabled) {
    const per = formatMoney(invoice.amount / parseInt(String(paymentPlan.installments)));
    planInfo = `\n\nOffer a payment plan: ${paymentPlan.installments} payments of ${per} ${paymentPlan.frequency.toLowerCase()}. Weave this in naturally.`;
  }

  const paymentLinkInfo = paymentLink
    ? `PAYMENT LINK: ${paymentLink}`
    : `No payment link — do not include a payment URL. Ask the customer to contact you directly to arrange payment.`;

  const channelInstruction = isText
    ? `For SMS: Keep it under 300 characters. ${paymentLink ? "Include the payment link as plain text." : "No payment URL."} Natural, friendly but firm tone.`
    : `For email: First line must be "Subject: [subject]" then blank line then body. ${paymentLink ? `Include the payment link prominently labeled as "Pay now → ${paymentLink}".` : "Do not include any payment URL."} Professional, warm, firm tone.`;

  const prompt = `Draft a ${isText ? "text message (SMS)" : "professional email"} from ${biz.businessName} (${biz.contactName}) to collect an overdue invoice.

Customer: ${invoice.customer}
Invoice: ${invoice.number} for ${amt}
Work: ${invoice.desc}
Days overdue: ${days > 0 ? days + " days past due" : days === 0 ? "due today" : "due in " + Math.abs(days) + " days"}
Customer email: ${invoice.email} | phone: ${invoice.phone}

Business contact: ${biz.phone} | ${biz.email}
Payment info: ${biz.paymentNotes}

${paymentLinkInfo}
${planInfo}

${channelInstruction}

Write only the message, no commentary.`;

  return generateOneShot({ prompt, apiKey, max_tokens: 1000, fallback });
}

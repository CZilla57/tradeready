import Constants from 'expo-constants';
import { supabase } from './supabase';
import { formatMoney, formatQuote } from './format';
import { computeEstimateBreakdown } from './pricingEngine';
import { generateOneShot } from './oneShotAI';
import { PAID_EPSILON, balanceDue, isPartlyPaid } from './invoicePayments';
import { parseLocalDate } from './moneyUtils';
import type { Invoice, Job, Customer, Settings, PaymentPlan, PaymentProvider } from '../types/models';
import type { BadgeColor } from '../components/UI';

/**
 * How to describe what a customer owes, in one place for both message builders.
 *
 * A partly-paid invoice names BOTH numbers so the customer can see their
 * deposit was credited — quoting only the balance misstates the invoice, and
 * quoting only the total asks them to pay money they already sent.
 */
function describeAmountOwed(invoice: Invoice): string {
  const balance = balanceDue(invoice);
  if (isPartlyPaid(invoice)) {
    return `${formatMoney(balance)} of ${formatMoney(invoice.amount)} still outstanding`;
  }
  return formatMoney(balance);
}

export function daysPastDue(dueDate: string): number {
  // Both sides in the LOCAL frame: a bare "YYYY-MM-DD" due date parsed as UTC
  // midnight lags a local-midnight "today" by the UTC offset, which made every
  // overdue transition land a day late east of UTC (floor happened to absorb
  // the skew in negative-offset timezones). Local midnight minus local
  // midnight is an exact day count ± a DST hour — round, not floor, so a
  // spring-forward interval doesn't lose a day.
  const due = parseLocalDate(dueDate);
  due.setHours(0, 0, 0, 0);
  const today = new Date();
  today.setHours(0, 0, 0, 0);
  return Math.round((today.getTime() - due.getTime()) / (1000 * 60 * 60 * 24));
}

export interface InvoiceStatus {
  label: string;
  color: BadgeColor;
  days: number;
}

export function getStatus(invoice: Invoice): InvoiceStatus {
  // The one remaining raw-flag read app-wide, and intentionally so: it's a fast
  // path ahead of the partly-paid branch below. Safe because every write path
  // (reconcilePaidFields, applyPayment, mergePaymentLedgers, the Stripe webhook)
  // maintains `paid` from the ledger, so this stays consistent with isFullyPaid.
  // That includes sync's pull path (utils/syncMerge.ts mergeRemoteRecord): it
  // derives `paid` via reconcilePaidFields/mergePaymentLedgers for BOTH a
  // remote record that merges with a local copy AND one arriving with no local
  // copy at all — a fresh install can't cache a stale `paid` any more than an
  // existing device can.
  if (invoice.paid) {
    return { label: "Paid", color: "success", days: 0 };
  }
  const days = daysPastDue(invoice.due);
  if (days <= 0) {
    // Partly paid only wins while the invoice is NOT past due — overdue is the
    // more urgent signal, and the row shows the balance next to the badge
    // either way.
    if (isPartlyPaid(invoice)) {
      return { label: "Partly paid", color: "accent", days };
    }
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

export function buildPaymentLink(
  invoice: Invoice,
  provider: PaymentProvider,
  providerKey: string,
  requestedAmount: number,
): string {
  const amt = requestedAmount.toFixed(2);
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

/**
 * Return the cached payment link when it was minted for the amount being
 * requested NOW; otherwise fetch a fresh one.
 *
 * `requestedAmount` is explicit because the amount is a choice, not a property
 * of the invoice: the full remaining balance by default, or a deposit the user
 * picked on the Outreach screen. The epsilon compare (not `===`) is deliberate —
 * a ledger-derived balance is a float sum and can drift a fraction of a cent
 * from the stored `paymentLinkAmount`, and half a cent of drift is the same
 * link (Stripe charges whole cents anyway).
 *
 * Anyone DISPLAYING a cached `paymentLinkUrl` without going through here must
 * apply the same amount check — a link minted for a stale amount quietly asks
 * the customer to overpay (see cachedLinkMatches).
 */
export async function resolvePaymentLink(
  invoice: Invoice,
  provider: PaymentProvider,
  providerKey: string,
  requestedAmount: number,
): Promise<string> {
  if (cachedLinkMatches(invoice, requestedAmount)) {
    return invoice.paymentLinkUrl as string;
  }
  return fetchPaymentLink(invoice, provider, providerKey, requestedAmount);
}

/**
 * Is the invoice's cached payment link good for this amount? The display-side
 * twin of resolvePaymentLink's cache check: screens showing a stored
 * `paymentLinkUrl` gate on this instead of showing whatever was cached, so a
 * link minted before a partial payment (or for a different deposit) is never
 * presented as current.
 */
export function cachedLinkMatches(invoice: Invoice, requestedAmount: number): boolean {
  return Boolean(
    invoice.paymentLinkUrl &&
    typeof invoice.paymentLinkAmount === "number" &&
    Math.abs(invoice.paymentLinkAmount - requestedAmount) <= PAID_EPSILON,
  );
}

const VERCEL_URL = Constants.expoConfig?.extra?.backendUrl ?? '';
const VERCEL_URL_IS_PLACEHOLDER = Constants.expoConfig?.extra?.backendUrlIsPlaceholder ?? true;

export async function fetchPaymentLink(
  invoice: Invoice,
  provider: PaymentProvider,
  providerKey: string,
  requestedAmount: number,
): Promise<string> {
  const endpoints: Record<string, string> = {
    stripe: `${VERCEL_URL}/api/create-payment-link`,
  };

  const endpoint = endpoints[provider as string];

  if (!endpoint || VERCEL_URL_IS_PLACEHOLDER) {
    return buildPaymentLink(invoice, provider, providerKey, requestedAmount);
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
      amount: requestedAmount,
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

/** The partial amount being asked for right now, when the user chose one. */
export interface DepositAsk {
  amount: number;
  /** Set when the user picked a percentage rather than a fixed dollar amount. */
  percent?: number;
}

interface OutreachMessageParams {
  invoice: Invoice;
  channel: 'text' | 'email';
  biz: Partial<Settings>;
  paymentLink?: string;
  paymentPlan?: PaymentPlan;
  /**
   * When set, the message asks for this partial amount instead of the full
   * balance — and the caller GUARANTEES any paymentLink passed alongside was
   * minted for exactly this amount. The message says the link is for the
   * deposit; pairing it with a full-balance link would make that a lie.
   */
  deposit?: DepositAsk;
}

function describeDepositAsk(deposit: DepositAsk, hasLink: boolean, channel: 'text' | 'email'): string {
  const base = `We're asking for a deposit of ${formatMoney(deposit.amount)}${
    deposit.percent ? ` (${deposit.percent}% of the total)` : ''
  } for now`;
  if (!hasLink) return `${base}.`;
  return channel === 'email'
    ? `${base} — the payment link below is for that amount.`
    : `${base} — the payment link is for that amount.`;
}

function buildGenericMessage({ invoice, channel, biz, paymentLink, paymentPlan, deposit }: OutreachMessageParams): string {
  const days = daysPastDue(invoice.due);
  const amt = describeAmountOwed(invoice);
  const overdueText = days > 0 ? `${days} days overdue` : days === 0 ? 'due today' : `due in ${Math.abs(days)} days`;

  const depositText = deposit ? ` ${describeDepositAsk(deposit, Boolean(paymentLink), channel)}` : '';

  let planText = '';
  if (paymentPlan?.enabled) {
    const per = formatMoney(balanceDue(invoice) / parseInt(String(paymentPlan.installments)));
    planText = ` We can also arrange ${paymentPlan.installments} payments of ${per} ${paymentPlan.frequency.toLowerCase()} if that works better for you.`;
  }

  if (channel === 'text') {
    const linkPart = paymentLink ? ` Pay here: ${paymentLink}` : '';
    return `Hi ${invoice.customer}, this is ${biz.businessName}. Invoice ${invoice.number} — ${amt}, ${overdueText}.${depositText}${planText}${linkPart} — ${biz.phone}`;
  }

  const linkSection = paymentLink
    ? `You can pay securely online here:\nPay now → ${paymentLink}\n`
    : '';

  return `Subject: Payment reminder – ${invoice.number}

Hi ${invoice.customer},

I hope you're doing well. I'm reaching out regarding invoice ${invoice.number} — ${amt}, currently ${overdueText}.${depositText}

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
  deposit,
  apiKey,
}: OutreachMessageParams & { apiKey?: string }): Promise<string> {
  const fallback = () => buildGenericMessage({ invoice, channel, biz, paymentLink, paymentPlan, deposit });
  if (!apiKey) return fallback();

  const days = daysPastDue(invoice.due);
  const amt = describeAmountOwed(invoice);
  const isText = channel === "text";

  let planInfo = "";
  if (paymentPlan?.enabled) {
    const per = formatMoney(balanceDue(invoice) / parseInt(String(paymentPlan.installments)));
    planInfo = `\n\nOffer a payment plan: ${paymentPlan.installments} payments of ${per} ${paymentPlan.frequency.toLowerCase()}. Weave this in naturally.`;
  }

  let depositInfo = "";
  if (deposit) {
    const remainder = formatMoney(Math.max(0, balanceDue(invoice) - deposit.amount));
    depositInfo = `\n\nDEPOSIT REQUEST: ask for a deposit of ${formatMoney(deposit.amount)}${
      deposit.percent ? ` (${deposit.percent}% of the invoice total)` : ""
    } now rather than the full balance${
      paymentLink ? ` — the payment link is for exactly that deposit amount` : ""
    }. Make clear the remaining ${remainder} is still due by the due date.`;
  }

  const paymentLinkInfo = paymentLink
    ? `PAYMENT LINK: ${paymentLink}`
    : `No payment link — do not include a payment URL. Ask the customer to contact you directly to arrange payment.`;

  const channelInstruction = isText
    ? `For SMS: Keep it under 300 characters. ${paymentLink ? "Include the payment link as plain text." : "No payment URL."} Natural, friendly but firm tone.`
    : `For email: First line must be "Subject: [subject]" then blank line then body. ${paymentLink ? `Include the payment link prominently labeled as "Pay now → ${paymentLink}".` : "Do not include any payment URL."} Professional, warm, firm tone.`;

  const prompt = `Draft a ${isText ? "text message (SMS)" : "professional email"} from ${biz.businessName} (${biz.contactName}) to collect an overdue invoice.

Customer: ${invoice.customer}
Invoice: ${invoice.number} — ${amt}
Work: ${invoice.desc}
Days overdue: ${days > 0 ? days + " days past due" : days === 0 ? "due today" : "due in " + Math.abs(days) + " days"}
Customer email: ${invoice.email} | phone: ${invoice.phone}

Business contact: ${biz.phone} | ${biz.email}
Payment info: ${biz.paymentNotes}

${paymentLinkInfo}
${depositInfo}${planInfo}

${channelInstruction}

Write only the message, no commentary.`;

  return generateOneShot({ prompt, apiKey, max_tokens: 1000, fallback });
}

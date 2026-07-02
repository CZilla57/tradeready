// utils/invoiceHelpers.js
// Pure functions that don't touch the UI — easy to test and reuse.

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
      return key ? `https://buy.stripe.com/${key}` : "https://stripe.com";
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

// Calls your Vercel serverless function to get a real Stripe/Square/PayPal link.
// Replace VERCEL_URL with your actual deployed backend URL.
const VERCEL_URL = "https://backend-88mlg0243-tradeready1.vercel.app";
const VERCEL_URL_IS_PLACEHOLDER = false;

export async function fetchPaymentLink(invoice, provider, providerKey) {
  const endpoints = {
    stripe: `${VERCEL_URL}/api/create-payment-link`,
    square: `${VERCEL_URL}/api/create-square-link`,
    paypal: `${VERCEL_URL}/api/create-paypal-link`,
  };

  const endpoint = endpoints[provider];

  // Fall back to client-side link builder when there's no server configured
  // or for providers that don't need a server call (Venmo, custom URL).
  if (!endpoint || VERCEL_URL_IS_PLACEHOLDER) {
    return buildPaymentLink(invoice, provider, providerKey);
  }

  const res = await fetch(endpoint, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      amount: invoice.amount,
      invoiceNumber: invoice.number,
      description: invoice.desc,
      customerEmail: invoice.email,
      stripeKey: providerKey,
    }),
  });

  const data = await res.json();
  if (data.error) throw new Error(data.error);
  return data.url;
}

// Calls the Anthropic API to generate a collection message.
export async function generateOutreachMessage({ invoice, channel, biz, paymentLink, paymentPlan, apiKey }) {
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

  const res = await fetch("https://api.anthropic.com/v1/messages", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "x-api-key": apiKey || "",
      "anthropic-version": "2023-06-01",
    },
    body: JSON.stringify({
      model: "claude-sonnet-4-6",
      max_tokens: 1000,
      messages: [{ role: "user", content: prompt }],
    }),
  });

  const data = await res.json();
  return data.content?.map((b) => b.text || "").join("") || "Could not generate message.";
}

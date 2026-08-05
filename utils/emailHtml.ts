// utils/emailHtml.ts
// Turns a plain-text email body (often user-edited, often containing a
// capability or payment URL) into HTML for composeEmail's isHtml path: the
// text is escaped, newlines become <br>, and KNOWN link shapes render as
// anchors with friendly labels instead of giant character strings (owner
// feedback 2026-08-05). Unknown URLs stay clickable with the URL itself as
// the label, so nothing the user pasted ever silently disappears.
//
// The message editor keeps plain text — the label swap happens only at send
// time. SMS bodies never come through here (no markup exists in SMS).

import { escapeHtml } from "./pdfTemplates";

const LINK_LABELS: { match: RegExp; label: string }[] = [
  { match: /\/estimate\.html\?/, label: "View & approve your estimate" },
  { match: /\/change\.html\?/, label: "Review & approve this change" },
  { match: /\/portal\.html\?/, label: "View your jobs & invoices" },
  { match: /\/book\.html\?/, label: "Request a booking" },
  { match: /buy\.stripe\.com\//, label: "Pay online securely" },
  { match: /paypal\.me\//i, label: "Pay with PayPal" },
  { match: /venmo\.com\//, label: "Pay with Venmo" },
  { match: /squareup\.com\/pay/, label: "Pay online" },
];

const URL_RE = /https?:\/\/[^\s<>"']+/g;
// Sentence punctuation that commonly trails a pasted URL but isn't part of it.
const TRAILING_PUNCT = /[.,;:!?)\]]+$/;

/** The friendly label for a known link shape, or null for unknown URLs. */
export function labelForUrl(url: string): string | null {
  const hit = LINK_LABELS.find((l) => l.match.test(url));
  return hit ? hit.label : null;
}

/**
 * Escape a plain-text body and wrap every URL in an anchor — labeled when the
 * link shape is known, the (escaped) URL itself otherwise. `\n` → `<br>`.
 */
export function emailHtmlFromText(body: string): string {
  let out = "";
  let last = 0;
  for (const m of body.matchAll(URL_RE)) {
    const start = m.index ?? 0;
    const raw = m[0];
    const url = raw.replace(TRAILING_PUNCT, "");
    const trailing = raw.slice(url.length);
    out += escapeHtml(body.slice(last, start));
    const label = labelForUrl(url);
    out += `<a href="${escapeHtml(url)}">${escapeHtml(label ?? url)}</a>${escapeHtml(trailing)}`;
    last = start + raw.length;
  }
  out += escapeHtml(body.slice(last));
  // Safe after escaping: URLs can't contain newlines, so no <br> lands in an href.
  return out.replace(/\r?\n/g, "<br>");
}

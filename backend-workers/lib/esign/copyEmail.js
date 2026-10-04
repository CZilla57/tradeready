// The signer's emailed copy (spec §3.5 step 5, decision 19-Q7). Pure: builds
// the Resend payload; service.js sends it. Same hardened header helpers as
// the invoice and reminder emails (sanitizeFromPhrase / sanitizeSubject),
// because the business name is device-synced data landing in mail headers.
// Wording avoids every §7 "must not say" phrase.

const { sanitizeFromPhrase, sanitizeSubject } = require('../reminderEmail.js');
const { businessNameOf, contactOf, nounFor } = require('./texts.js');
const { isEmailAddress } = require('./validate.js');
const { utcStamp } = require('./pdf.js');

// Any address on the verified gettradereadyapp.com Resend domain sends; this
// one names what it carries.
const SENDER = 'estimates@gettradereadyapp.com';
const VERIFY_URL = 'https://gettradereadyapp.com/verify';

function isPlainObject(v) {
  return v !== null && typeof v === 'object' && !Array.isArray(v);
}

function verifyLink(recordId, recordDigest) {
  return `${VERIFY_URL}?r=${encodeURIComponent(recordId)}&d=${encodeURIComponent(recordDigest)}`;
}

function buildCopyEmail({ record, recordDigest, pdfBase64, filename }) {
  const doc = isPlainObject(record.document) ? record.document : {};
  const signer = isPlainObject(record.signer) ? record.signer : {};
  const biz = businessNameOf(doc);
  const noun = nounFor(record.documentType);
  const title = typeof doc.jobTitle === 'string' && doc.jobTitle.trim() ? ` "${doc.jobTitle.trim()}"` : '';
  const { phone, email } = contactOf(doc);
  const reach = [phone, email].filter(Boolean).join(' or ');

  const text = [
    `Hi ${signer.typedName || 'there'},`,
    '',
    `Here is your signed copy of the ${noun}${title} from ${biz}. You signed it on ${utcStamp(record.signedAt)}.`,
    '',
    'The PDF is attached. Keep it for your records.',
    '',
    `Record ID: ${record.recordId}`,
    `Fingerprint (SHA-256): ${recordDigest}`,
    `Check this record: ${verifyLink(record.recordId, recordDigest)}`,
    '',
    `Questions about this ${noun}? Contact ${biz}${reach ? ` at ${reach}` : ''}.`,
    '',
    `Sent by TradeReady for ${biz}. You're receiving this because you asked for a copy when you signed.`,
  ].join('\n');

  const fromPhrase = sanitizeFromPhrase(doc.businessName);
  const out = {
    from: fromPhrase ? `${fromPhrase} via TradeReady <${SENDER}>` : `TradeReady <${SENDER}>`,
    to: [signer.email],
    subject: sanitizeSubject(`Your signed ${noun} from ${fromPhrase || 'TradeReady'}`),
    text,
    attachments: [{ filename, content: pdfBase64 }],
  };
  if (email && isEmailAddress(email)) out.reply_to = email;
  return out;
}

module.exports = { SENDER, VERIFY_URL, verifyLink, buildCopyEmail };

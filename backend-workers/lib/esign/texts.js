// Customer-facing e-signature wording (spec §3.1, §3.2). DRAFT, pending one
// lawyer review (owner decision 19-Q2) — change it only together with a new
// CONSENT_VERSION, because the version and the SHA-256 of the exact rendered
// text are sealed into every record.
//
// The Worker is the single source of this text: view / change-view send the
// rendered disclosure, checkbox label and intent statement to the page, the
// page shows exactly that, and respond hashes the same rendering. So the hash
// in a record is the hash of what that signer was shown.
//
// Never "legally binding", "enforceable", "certified" etc. (§7, decision 19-Q5);
// tests/esign.test.cjs scans every string here for the must-not-say list.

const { createHash } = require('node:crypto');

const CONSENT_VERSIONS = [1];
const CURRENT_CONSENT_VERSION = 1;

const NOUNS = {
  estimate: 'estimate',
  change_order: 'change order',
};

function isPlainObject(v) {
  return v !== null && typeof v === 'object' && !Array.isArray(v);
}

function sha256Hex(text) {
  return createHash('sha256').update(String(text), 'utf8').digest('hex');
}

function nounFor(documentType) {
  return NOUNS[documentType] || NOUNS.estimate;
}

function businessNameOf(snapshot) {
  const name = isPlainObject(snapshot) && typeof snapshot.businessName === 'string'
    ? snapshot.businessName.trim() : '';
  return name || 'Your tradesperson';
}

function contactOf(snapshot) {
  const bc = isPlainObject(snapshot) && isPlainObject(snapshot.businessContact) ? snapshot.businessContact : {};
  const phone = typeof bc.phone === 'string' ? bc.phone.trim() : '';
  const email = typeof bc.email === 'string' ? bc.email.trim() : '';
  return { phone, email };
}

function drawPadOn(snapshot) {
  const sig = isPlainObject(snapshot) && isPlainObject(snapshot.signature) ? snapshot.signature : {};
  return sig.drawPad !== false;
}

// §3.2, version 1. Structured for the page; `disclosurePlainText` is the
// canonical rendering that gets hashed.
function disclosure(version, snapshot, documentType) {
  if (version !== 1) return null;
  const biz = businessNameOf(snapshot);
  const noun = nounFor(documentType);
  const { phone, email } = contactOf(snapshot);
  const reach = [phone, email].filter(Boolean).join(' · ');
  const scope = documentType === 'change_order'
    ? 'this agreement covers this change order and any other change orders to this job.'
    : 'this agreement covers this estimate and any change orders to this job.';
  return {
    version: 1,
    title: 'Using electronic records and signatures.',
    intro: `${biz} uses TradeReady to send you this ${noun} electronically. If you agree, you'll sign it electronically and receive your copy electronically.`,
    items: [
      { label: 'Paper copy:', text: `you can ask ${biz} for a paper copy at no charge${reach ? ` — ${reach}` : ''}.` },
      { label: 'Your choice:', text: `you don't have to sign electronically. To sign on paper instead, contact ${biz}. Withdrawing your agreement later doesn't affect anything you already signed.` },
      { label: 'Scope:', text: scope },
      { label: 'Contact details:', text: `to change the email address for your copies, tell ${biz}.` },
      { label: 'What you need:', text: `a device with a current web browser that can open and save PDF files. You can open this page, so you can view these records; use "Download this ${noun} (PDF)" to check that you can open and save the PDF.` },
    ],
  };
}

function disclosurePlainText(d) {
  if (!d) return '';
  return [`${d.title} ${d.intro}`, ...d.items.map((i) => `- ${i.label} ${i.text}`)].join('\n');
}

function checkboxLabel(documentType) {
  return `I agree to use electronic records and signatures for this ${nounFor(documentType)}.`;
}

// §3.1 item 5 (Q3). When the owner turned the pad off the page shows no
// drawing, so the statement doesn't mention one (variant flagged for the
// same lawyer review).
function intentText(documentType, drawPad) {
  const noun = nounFor(documentType);
  return drawPad
    ? `By selecting Approve and sign, you are signing this ${noun} electronically. Your typed name — and your drawing, if you add one — is your signature.`
    : `By selecting Approve and sign, you are signing this ${noun} electronically. Your typed name is your signature.`;
}

// Everything the page needs to render the "Agree and sign" block.
function signingTexts(snapshot, documentType, version = CURRENT_CONSENT_VERSION) {
  const d = disclosure(version, snapshot, documentType);
  const drawPad = drawPadOn(snapshot);
  return {
    version,
    disclosure: d,
    disclosureText: disclosurePlainText(d),
    checkboxLabel: checkboxLabel(documentType),
    disclosureLinkLabel: 'Read the electronic records disclosure',
    intent: intentText(documentType, drawPad),
    approveLabel: 'Approve and sign',
    drawPad,
  };
}

module.exports = {
  CONSENT_VERSIONS,
  CURRENT_CONSENT_VERSION,
  sha256Hex,
  nounFor,
  businessNameOf,
  contactOf,
  drawPadOn,
  disclosure,
  disclosurePlainText,
  checkboxLabel,
  intentText,
  signingTexts,
};

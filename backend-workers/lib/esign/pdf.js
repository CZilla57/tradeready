// Deterministic, dependency-free PDF 1.4 writer for e-signature copies
// (spec §3.6, D8). Renderer "pdf-v1".
//
// - Helvetica / Helvetica-Bold, the standard (unembedded) fonts, WinAnsi text.
//   A character outside WinAnsi prints as "?"; the sealed JSON keeps the exact
//   text, and the certificate says so.
// - Word-wrap from the AFM width table in pdfFontMetrics.js; multi-page.
// - The drawn signature is drawn as line paths from its vector strokes.
// - No wall clock, no randomness, uncompressed streams: the same record (and
//   seal) always gives the same bytes. CreationDate is the record's signedAt
//   and /ID comes from the record digest. Golden-byte tests freeze this
//   output; a layout change ships as "pdf-v2" and never alters old copies.
//
// PDF bytes are never stored — the sealed record is the evidence and this is
// a reproducible rendering of it.

const { HELVETICA, HELVETICA_BOLD } = require('./pdfFontMetrics.js');
const { formatValidUntil } = require('../estimate/estimateExpiry.js');

const RENDERER = 'pdf-v1';
const PAGE_W = 612;
const PAGE_H = 792;
const MARGIN = 54;
const CONTENT_W = PAGE_W - 2 * MARGIN;
const TOP = PAGE_H - MARGIN;
const BOTTOM = 72;
const FOOTER_Y = 36;
const LABEL_W = 130;
const VALUE_X = MARGIN + LABEL_W + 6;
const VALUE_W = CONTENT_W - LABEL_W - 6;
const AMOUNT_W = 110;
const SIG_BOX_W = 300;
const SIG_BOX_H = 100;

const FONTS = { regular: { name: 'F1', widths: HELVETICA }, bold: { name: 'F2', widths: HELVETICA_BOLD } };
const BLACK = 0;
const MUTED = 0.4;

// Unicode → WinAnsiEncoding for the code points outside Latin-1 that
// WinAnsi places in 0x80–0x9F.
const WIN_ANSI_EXTRA = new Map([
  [0x20ac, 0x80], [0x201a, 0x82], [0x0192, 0x83], [0x201e, 0x84], [0x2026, 0x85], [0x2020, 0x86],
  [0x2021, 0x87], [0x02c6, 0x88], [0x2030, 0x89], [0x0160, 0x8a], [0x2039, 0x8b], [0x0152, 0x8c],
  [0x017d, 0x8e], [0x2018, 0x91], [0x2019, 0x92], [0x201c, 0x93], [0x201d, 0x94], [0x2022, 0x95],
  [0x2013, 0x96], [0x2014, 0x97], [0x02dc, 0x98], [0x2122, 0x99], [0x0161, 0x9a], [0x203a, 0x9b],
  [0x0153, 0x9c], [0x017e, 0x9e], [0x0178, 0x9f],
]);

function isPlainObject(v) {
  return v !== null && typeof v === 'object' && !Array.isArray(v);
}

// One line of text (no newlines) → a "byte string" (each char 0..255).
function encodeWinAnsi(text) {
  let out = '';
  for (const ch of String(text == null ? '' : text)) {
    const cp = ch.codePointAt(0);
    if (cp === 0x09) out += ' ';
    else if ((cp >= 0x20 && cp <= 0x7e) || (cp >= 0xa0 && cp <= 0xff)) out += String.fromCharCode(cp);
    else if (WIN_ANSI_EXTRA.has(cp)) out += String.fromCharCode(WIN_ANSI_EXTRA.get(cp));
    else out += '?';
  }
  return out;
}

function widthOf(bytes, font, size) {
  const widths = FONTS[font].widths;
  let units = 0;
  for (let i = 0; i < bytes.length; i += 1) units += widths[bytes.charCodeAt(i) - 32] || 0;
  return (units * size) / 1000;
}

// Greedy wrap of one encoded paragraph; over-long words break by character.
function wrapLine(bytes, font, size, maxW) {
  const words = bytes.split(' ');
  const lines = [];
  let cur = '';
  for (let word of words) {
    const candidate = cur === '' ? word : `${cur} ${word}`;
    if (widthOf(candidate, font, size) <= maxW) {
      cur = candidate;
      continue;
    }
    if (cur !== '') lines.push(cur);
    while (word.length > 1 && widthOf(word, font, size) > maxW) {
      let n = 1;
      while (n < word.length && widthOf(word.slice(0, n + 1), font, size) <= maxW) n += 1;
      lines.push(word.slice(0, n));
      word = word.slice(n);
    }
    cur = word;
  }
  lines.push(cur);
  return lines;
}

// Text with newlines → wrapped encoded lines.
function wrapText(text, font, size, maxW) {
  return String(text == null ? '' : text)
    .replace(/\r\n?/g, '\n')
    .split('\n')
    .flatMap((para) => wrapLine(encodeWinAnsi(para), font, size, maxW));
}

// Deterministic number formatting for content streams (no exponents, no -0).
function num(n) {
  const r = Math.round(n * 100) / 100;
  if (Object.is(r, -0) || r === 0) return '0';
  return String(r);
}

function pdfString(bytes) {
  let out = '(';
  for (let i = 0; i < bytes.length; i += 1) {
    const c = bytes.charCodeAt(i);
    if (c === 0x5c) out += '\\\\';
    else if (c === 0x28) out += '\\(';
    else if (c === 0x29) out += '\\)';
    else if (c < 0x20 || c > 0x7e) out += `\\${c.toString(8).padStart(3, '0')}`;
    else out += bytes[i];
  }
  return `${out})`;
}

// "$1,234.5" → "$1,234.50"; whole amounts print without cents, like the
// estimate page's money() (integer-cent rounding, minus before the $).
function money(amount) {
  const c = Math.round((Number(amount) || 0) * 100);
  const abs = Math.abs(c);
  const whole = String(Math.floor(abs / 100)).replace(/\B(?=(\d{3})+(?!\d))/g, ',');
  const frac = abs % 100;
  return `${c < 0 ? '-' : ''}$${whole}${frac ? `.${String(frac).padStart(2, '0')}` : ''}`;
}

// "2026-10-03T14:05:09.000Z" → "2026-10-03 14:05:09 UTC" (string slicing,
// no Date formatting, so the runtime zone can never leak in).
function utcStamp(iso) {
  const s = String(iso || '');
  if (!/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}/.test(s)) return s;
  return `${s.slice(0, 10)} ${s.slice(11, 19)} UTC`;
}

function pdfDate(iso) {
  const s = String(iso || '');
  if (!/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}/.test(s)) return null;
  return `D:${s.slice(0, 4)}${s.slice(5, 7)}${s.slice(8, 10)}${s.slice(11, 13)}${s.slice(14, 16)}${s.slice(17, 19)}Z`;
}

// The signing time in the owner's zone: "2026-10-03 07:05:09 (America/Phoenix, UTC-07:00)".
function zonedStamp(iso, timeZone) {
  const ms = Date.parse(String(iso || ''));
  if (!Number.isFinite(ms) || typeof timeZone !== 'string' || !timeZone) return null;
  let parts;
  try {
    parts = new Intl.DateTimeFormat('en-US', {
      timeZone, hourCycle: 'h23', year: 'numeric', month: '2-digit', day: '2-digit',
      hour: '2-digit', minute: '2-digit', second: '2-digit',
    }).formatToParts(new Date(ms));
  } catch {
    return null;
  }
  const p = {};
  for (const x of parts) p[x.type] = x.value;
  const wall = Date.UTC(Number(p.year), Number(p.month) - 1, Number(p.day), Number(p.hour) % 24, Number(p.minute), Number(p.second));
  const offMin = Math.round((wall - Math.floor(ms / 1000) * 1000) / 60000);
  const sign = offMin < 0 ? '-' : '+';
  const a = Math.abs(offMin);
  const off = `UTC${sign}${String(Math.floor(a / 60)).padStart(2, '0')}:${String(a % 60).padStart(2, '0')}`;
  return `${p.year}-${p.month}-${p.day} ${String(Number(p.hour) % 24).padStart(2, '0')}:${p.minute}:${p.second} (${timeZone}, ${off})`;
}

// ── Layout ──────────────────────────────────────────────────────────────

class Layout {
  constructor() {
    this.pages = [];
    this.newPage();
  }

  newPage() {
    this.ops = [];
    this.pages.push(this.ops);
    this.y = TOP;
  }

  ensure(height) {
    if (this.y - height < BOTTOM && this.y < TOP) this.newPage();
  }

  gap(h) {
    this.y -= h;
  }

  textAt(x, y, bytes, font, size, gray = BLACK) {
    this.ops.push(`${num(gray)} g BT /${FONTS[font].name} ${num(size)} Tf 1 0 0 1 ${num(x)} ${num(y)} Tm ${pdfString(bytes)} Tj ET`);
  }

  // Wrapped text block at x with width w.
  para(text, { font = 'regular', size = 10, x = MARGIN, w = CONTENT_W, gray = BLACK, after = 4 } = {}) {
    const lh = size * 1.35;
    for (const line of wrapText(text, font, size, w)) {
      this.ensure(lh);
      this.y -= lh;
      this.textAt(x, this.y + size * 0.3, line, font, size, gray);
    }
    this.y -= after;
  }

  heading(text, size = 12) {
    this.ensure(size * 1.35 + 24);
    this.gap(6);
    this.para(text, { font: 'bold', size, after: 2 });
  }

  rule(gray = 0.8) {
    this.ensure(10);
    this.y -= 5;
    this.ops.push(`${num(gray)} G 0.75 w ${num(MARGIN)} ${num(this.y)} m ${num(MARGIN + CONTENT_W)} ${num(this.y)} l S`);
    this.y -= 5;
  }

  // Label in a left column, wrapped value on the right.
  kv(label, value, { size = 9.5, valueFont = 'regular' } = {}) {
    const lh = size * 1.35;
    const labelSize = 9;
    const labels = wrapText(label, 'bold', labelSize, LABEL_W);
    const values = wrapText(value, valueFont, size, VALUE_W);
    const rows = Math.max(labels.length, values.length);
    this.ensure(Math.min(rows, 3) * lh);
    for (let i = 0; i < rows; i += 1) {
      this.ensure(lh);
      this.y -= lh;
      if (labels[i]) this.textAt(MARGIN, this.y + size * 0.3, labels[i], 'bold', labelSize, MUTED);
      if (values[i]) this.textAt(VALUE_X, this.y + size * 0.3, values[i], valueFont, size);
    }
    this.y -= 3;
  }

  // Line-item row: wrapped label, amount right-aligned on the first line.
  amountRow(label, amountText, { font = 'regular', size = 10 } = {}) {
    const lh = size * 1.35;
    const lines = wrapText(label, font, size, CONTENT_W - AMOUNT_W - 8);
    const amount = encodeWinAnsi(amountText);
    this.ensure(lh * Math.min(lines.length, 3));
    lines.forEach((line, i) => {
      this.ensure(lh);
      this.y -= lh;
      this.textAt(MARGIN, this.y + size * 0.3, line, font, size);
      if (i === 0) {
        const w = widthOf(amount, font, size);
        this.textAt(MARGIN + CONTENT_W - w, this.y + size * 0.3, amount, font, size);
      }
    });
    this.y -= 2;
  }

  // The drawn mark, scaled from the 600×200 capture box into a 300×100 pt box.
  signatureBox(drawn) {
    this.ensure(SIG_BOX_H + 8);
    this.y -= SIG_BOX_H + 4;
    const bx = VALUE_X;
    const by = this.y;
    this.ops.push(`0.8 G 0.5 w ${num(bx)} ${num(by)} ${num(SIG_BOX_W)} ${num(SIG_BOX_H)} re S`);
    const sx = SIG_BOX_W / 600;
    const sy = SIG_BOX_H / 200;
    const paths = [];
    for (const stroke of drawn.strokes) {
      const pts = stroke.map(([x, y]) => [bx + x * sx, by + SIG_BOX_H - y * sy]);
      if (pts.length === 1) pts.push([pts[0][0] + 0.01, pts[0][1]]);
      paths.push(pts.map(([x, y], i) => `${num(x)} ${num(y)} ${i === 0 ? 'm' : 'l'}`).join(' '));
    }
    this.ops.push(`q 0 G 1.2 w 1 J 1 j ${paths.join(' ')} S Q`);
    this.y -= 4;
  }
}

// ── Document content ────────────────────────────────────────────────────

function documentTitle(documentType) {
  return documentType === 'change_order' ? 'Change order' : 'Estimate';
}

function totalLabel(documentType) {
  return documentType === 'change_order' ? 'Total for this change' : 'Total estimate';
}

function lineItemsOf(list) {
  return (Array.isArray(list) ? list : []).filter(isPlainObject);
}

function writeDocument(L, { document, documentType, selection, subtitle }) {
  const s = isPlainObject(document) ? document : {};
  L.para(s.businessName || 'Your tradesperson', { font: 'bold', size: 18, after: 2 });
  L.para(subtitle, { size: 11, gray: MUTED, after: 8 });
  if (s.jobTitle) L.kv('Job', s.jobTitle);
  if (s.customerName) L.kv('Prepared for', s.customerName);
  if (s.businessName) L.kv('From', s.businessName);
  const bc = isPlainObject(s.businessContact) ? s.businessContact : {};
  const contact = [bc.phone, bc.email].filter((v) => typeof v === 'string' && v.trim()).join(' · ');
  if (contact) L.kv('Contact', contact);
  if (typeof s.validUntil === 'string' && s.validUntil) L.kv('Valid until', formatValidUntil(s.validUntil));
  L.rule();

  if (typeof s.scope === 'string' && s.scope.trim()) {
    L.heading(documentType === 'change_order' ? 'Description of the change' : 'Scope of work');
    L.para(s.scope, { size: 10 });
  }

  const options = isPlainObject(s.options) && Array.isArray(s.options.tiers) ? s.options : null;
  if (isPlainObject(selection)) {
    L.heading(`Chosen option: ${selection.tierName || ''}`);
    for (const li of lineItemsOf(selection.lineItems)) L.amountRow(li.label, money(li.amount));
    L.rule();
    L.amountRow('Total', money(selection.total), { font: 'bold', size: 11 });
  } else if (options) {
    L.heading('Options');
    for (const tier of options.tiers.filter(isPlainObject)) {
      const rec = tier.id === options.recommendedTierId ? ' (recommended)' : '';
      L.gap(4);
      L.amountRow(`${tier.name || ''}${rec}`, money(tier.total), { font: 'bold', size: 10.5 });
      if (typeof tier.description === 'string' && tier.description) L.para(tier.description, { size: 9, gray: MUTED, after: 1 });
      for (const li of lineItemsOf(tier.lineItems)) L.amountRow(`   ${li.label}`, money(li.amount), { size: 9 });
    }
    const addOns = lineItemsOf(options.addOns);
    if (addOns.length) {
      L.heading('Optional add-ons', 11);
      for (const a of addOns) {
        L.amountRow(a.label, `+${money(a.amount)}`, { size: 10 });
        if (typeof a.description === 'string' && a.description) L.para(a.description, { size: 9, gray: MUTED, after: 1 });
      }
    }
  } else {
    L.heading(documentType === 'change_order' ? 'Change' : 'Line items');
    for (const li of lineItemsOf(s.lineItems)) L.amountRow(li.label, money(li.amount));
    L.rule();
    L.amountRow(totalLabel(documentType), money(s.total), { font: 'bold', size: 11 });
  }

  if (typeof s.terms === 'string' && s.terms.trim()) {
    L.heading('Terms');
    L.para(s.terms, { size: 9.5 });
  }
}

const EVENT_LABELS = {
  link_created: 'Link sent by the business',
  viewed: 'Opened by the signer',
  declined: 'Declined',
  signed: 'Signed',
};

function writeCertificate(L, { record, recordDigest, seal }) {
  L.newPage();
  L.para('Signature certificate', { font: 'bold', size: 18, after: 2 });
  L.para(`How and when this ${documentTitle(record.documentType).toLowerCase()} was signed electronically through TradeReady. This certificate is a rendering of the sealed signature record.`, { size: 9, gray: MUTED, after: 6 });

  L.heading('Signer');
  const signer = isPlainObject(record.signer) ? record.signer : {};
  L.kv('Typed name', signer.typedName || '', { size: 12, valueFont: 'bold' });
  if (isPlainObject(signer.drawn) && Array.isArray(signer.drawn.strokes)) {
    L.kv('Drawn signature', '');
    L.signatureBox(signer.drawn);
  } else {
    L.kv('Drawn signature', 'None (typed name only)');
  }
  L.kv('Signature method', record.signatureMethod === 'typed_drawn' ? 'Typed name and drawn signature' : 'Typed name');
  if (signer.email) L.kv('Copy emailed to', signer.email);

  L.heading('When and where');
  L.kv('Signed at (UTC)', utcStamp(record.signedAt));
  const doc = isPlainObject(record.document) ? record.document : {};
  const zone = (isPlainObject(doc.esign) && typeof doc.esign.timeZone === 'string' && doc.esign.timeZone)
    || (typeof doc.validUntilTimeZone === 'string' && doc.validUntilTimeZone) || null;
  const local = zone ? zonedStamp(record.signedAt, zone) : null;
  if (local) L.kv('Signed at (business time)', local);
  L.kv('IP address', record.ip || 'Not recorded');
  L.kv('Device', record.userAgent || 'Not recorded');
  L.kv('Signed through', 'A private link the business sent to the signer');

  L.heading('Agreement');
  if (isPlainObject(record.consent)) {
    L.kv('Electronic records', `Agreed (disclosure version ${record.consent.version}) at ${utcStamp(record.consent.acceptedAt)}`);
    L.kv('Disclosure shown', record.consent.text || '', { size: 8.5 });
  } else {
    L.kv('Electronic records', 'No agreement recorded (signed on an earlier version of the page)');
  }
  L.kv('Intent statement', isPlainObject(record.intent) ? record.intent.text : 'Not shown (earlier version of the page)');

  L.heading('Audit trail');
  for (const e of Array.isArray(record.events) ? record.events : []) {
    if (!isPlainObject(e)) continue;
    const what = EVENT_LABELS[e.type] || String(e.type || '');
    L.kv(utcStamp(e.at), e.ip ? `${what} · ${e.ip}` : what);
  }
  L.kv(utcStamp(record.signedAt), record.ip ? `${EVENT_LABELS.signed} · ${record.ip}` : EVENT_LABELS.signed);

  L.heading('Record');
  L.kv('Record ID', record.recordId || '');
  L.kv('Document SHA-256', record.documentDigest || '');
  L.kv('Record SHA-256', recordDigest || '');
  if (seal) {
    L.kv('Seal', `${seal.alg || 'Ed25519'}, key ${seal.keyId || ''}`);
    L.kv('Seal value', seal.signature || '', { size: 8.5 });
  } else {
    L.kv('Seal', 'Pending. Download the copy again from your link later to get the sealed version.');
  }
  L.kv('Renderer', record.renderer || RENDERER);
  L.gap(6);
  L.para('Verify at gettradereadyapp.com/verify with the record ID and the record SHA-256.', { size: 9.5, font: 'bold' });
  L.para('Characters this PDF cannot show appear as "?". The sealed record (JSON, available from the same link) keeps the exact text.', { size: 8.5, gray: MUTED });
  L.para("This is not a PDF-viewer digital signature, so PDF apps won't show a signature banner. The record's seal is checked with TradeReady's published key.", { size: 8.5, gray: MUTED });
}

// ── Assembly ────────────────────────────────────────────────────────────

function footerOps(index, count, label) {
  const left = encodeWinAnsi(label);
  const right = encodeWinAnsi(`Page ${index + 1} of ${count}`);
  const size = 8;
  return [
    `${num(MUTED)} g BT /F1 ${size} Tf 1 0 0 1 ${num(MARGIN)} ${FOOTER_Y} Tm ${pdfString(left)} Tj ET`,
    `${num(MUTED)} g BT /F1 ${size} Tf 1 0 0 1 ${num(MARGIN + CONTENT_W - widthOf(right, 'regular', size))} ${FOOTER_Y} Tm ${pdfString(right)} Tj ET`,
  ];
}

function bytesOf(str) {
  const out = new Uint8Array(str.length);
  for (let i = 0; i < str.length; i += 1) out[i] = str.charCodeAt(i) & 0xff;
  return out;
}

function assemble(pages, { title, footer, creationDate, idHex }) {
  const objects = [];
  const pageCount = pages.length;
  objects[1] = '<< /Type /Catalog /Pages 2 0 R >>';
  const kids = pages.map((_, i) => `${6 + 2 * i} 0 R`).join(' ');
  objects[2] = `<< /Type /Pages /Kids [${kids}] /Count ${pageCount} >>`;
  objects[3] = '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>';
  objects[4] = '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica-Bold /Encoding /WinAnsiEncoding >>';
  objects[5] = `<< /Producer (TradeReady ${RENDERER}) /Title ${pdfString(encodeWinAnsi(title))}${creationDate ? ` /CreationDate (${creationDate})` : ''} >>`;
  pages.forEach((ops, i) => {
    const content = [...ops, ...footerOps(i, pageCount, footer)].join('\n');
    objects[6 + 2 * i] = `<< /Type /Page /Parent 2 0 R /MediaBox [0 0 ${PAGE_W} ${PAGE_H}] /Resources << /Font << /F1 3 0 R /F2 4 0 R >> >> /Contents ${7 + 2 * i} 0 R >>`;
    objects[7 + 2 * i] = `<< /Length ${content.length} >>\nstream\n${content}\nendstream`;
  });

  let out = '%PDF-1.4\n%âãÏÓ\n';
  const offsets = [];
  for (let n = 1; n < objects.length; n += 1) {
    offsets[n] = out.length;
    out += `${n} 0 obj\n${objects[n]}\nendobj\n`;
  }
  const xref = out.length;
  out += `xref\n0 ${objects.length}\n0000000000 65535 f \n`;
  for (let n = 1; n < objects.length; n += 1) out += `${String(offsets[n]).padStart(10, '0')} 00000 n \n`;
  out += `trailer\n<< /Size ${objects.length} /Root 1 0 R /Info 5 0 R /ID [<${idHex}> <${idHex}>] >>\nstartxref\n${xref}\n%%EOF\n`;
  return bytesOf(out);
}

// The signed copy: the document as signed, then the signature certificate.
// `seal` may be null (sealing pending); everything else comes from the record.
function renderSignedPdf({ record, recordDigest, seal = null }) {
  const L = new Layout();
  const noun = documentTitle(record.documentType);
  writeDocument(L, {
    document: record.document,
    documentType: record.documentType,
    selection: record.selection,
    subtitle: `Signed ${noun.toLowerCase()}`,
  });
  L.gap(8);
  const signer = isPlainObject(record.signer) ? record.signer : {};
  L.para(`Signed electronically by ${signer.typedName || ''} on ${utcStamp(record.signedAt)}. See the signature certificate.`, { size: 10, font: 'bold' });
  writeCertificate(L, { record, recordDigest, seal });
  return assemble(L.pages, {
    title: `Signed ${noun.toLowerCase()}`,
    footer: `TradeReady signed ${noun.toLowerCase()} · Record ${String(record.recordId || '').slice(0, 8)}`,
    creationDate: pdfDate(record.signedAt),
    idHex: String(recordDigest || '').slice(0, 32).padEnd(32, '0'),
  });
}

// The unsigned rendering offered before signing (§3.1), so the signer can
// check that the PDF form opens. `idHex` is the snapshot digest prefix.
function renderPreviewPdf({ snapshot, documentType, snapshotDigest }) {
  const L = new Layout();
  const noun = documentTitle(documentType);
  writeDocument(L, {
    document: snapshot,
    documentType,
    selection: null,
    subtitle: `${noun}: unsigned copy for review`,
  });
  return assemble(L.pages, {
    title: `${noun} (unsigned)`,
    footer: `TradeReady ${noun.toLowerCase()} · Unsigned copy for review`,
    creationDate: null,
    idHex: String(snapshotDigest || '').slice(0, 32).padEnd(32, '0'),
  });
}

function signedPdfFilename(record) {
  const kind = record && record.documentType === 'change_order' ? 'change-order' : 'estimate';
  return `signed-${kind}-${String((record && record.recordId) || '').slice(0, 8)}.pdf`;
}

function previewPdfFilename(documentType) {
  return documentType === 'change_order' ? 'change-order-unsigned.pdf' : 'estimate-unsigned.pdf';
}

module.exports = {
  RENDERER,
  encodeWinAnsi,
  widthOf,
  wrapText,
  money,
  utcStamp,
  zonedStamp,
  renderSignedPdf,
  renderPreviewPdf,
  signedPdfFilename,
  previewPdfFilename,
};

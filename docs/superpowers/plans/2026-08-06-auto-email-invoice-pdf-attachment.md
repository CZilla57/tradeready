# Auto-Emailed Invoice PDF Attachment (R2) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Attach the exact device-generated invoice PDF to the unattended auto-invoice emails, delivered through Cloudflare R2.

**Architecture:** The device builds the PDF at auto-invoice mint time (reusing `buildInvoicePdfFile`) and POSTs it to a new authenticated Worker endpoint that stores it in R2 at `{user_id}/{invoice_id}.pdf`. The 15-minute invoice sweep fetches that object from R2 and attaches it to the Resend email; when the object isn't there yet it defers while the invoice is young, then falls back to a plain send. The object is deleted after a successful send.

**Tech Stack:** Cloudflare Workers (Hono), R2 bindings, Resend REST, Supabase (JWT verify + service role), Expo/React Native client, Jest.

## Global Constraints

- **Gate green before every commit:** `npm run typecheck`, `npm test`, `npm run lint` must all pass (change-control Rule 2). Run from the `tradeready/` project root.
- **No new npm dependency, no `app.json`/Expo SDK change** (change-control Rule 3). R2 is a Worker binding only.
- **Worker `lib/` is CommonJS** (`require`/`module.exports`) and is unit-tested from the top-level `__tests__/` directory via `require("../backend-workers/lib/...")`. Worker `src/routes/` is ESM and is **not** unit-tested (no route handler has a unit test today); route logic that needs testing lives in `lib/`.
- **Fire-and-forget client calls never throw** — completion is local-first and must never wait on or be broken by the network.
- **PDF grace window = 24h** (`PDF_GRACE_MS = 24 * 60 * 60 * 1000`).
- **Max upload = 5 MB decoded** (`MAX_PDF_BYTES = 5 * 1024 * 1024`).
- **R2 object key = `` `${userId}/${invoiceId}.pdf` ``**.
- **Invoice id charset for the endpoint = `/^[A-Za-z0-9_-]{1,64}$/`.**
- Spec: `docs/superpowers/specs/2026-08-06-auto-email-invoice-pdf-attachment-design.md`.

---

## File Structure

- **Create** `backend-workers/lib/invoicePdfUpload.js` — pure upload validation (id/size/magic-byte). Used by the route; unit-tested.
- **Create** `backend-workers/lib/invoicePdfAttach.js` — pure send-side helpers: `PDF_GRACE_MS`, `attachmentDecision(...)`, `invoicePdfName(...)`. Unit-tested.
- **Create** `backend-workers/src/routes/invoicePdf.js` — the `POST /api/invoice-pdf` handler (auth + R2 put). Wired, not unit-tested.
- **Modify** `backend-workers/lib/invoiceEmail.js` — optional `attachment` on `buildInvoiceEmail`.
- **Modify** `backend-workers/lib/sendInvoiceEmails.js` — R2 fetch + grace decision + attach + delete-after-send.
- **Modify** `backend-workers/src/index.js` — route wiring.
- **Modify** `backend-workers/wrangler.toml` — `[[r2_buckets]]` binding.
- **Modify** `utils/autoInvoice.ts` — `uploadAutoInvoicePdf()` + call it from `createAutoInvoiceForJob`.
- **Modify** `jest.setup.js` — add `EncodingType` to the `expo-file-system/legacy` mock.
- **Create/Modify tests:** `__tests__/invoicePdfUpload.test.js`, `__tests__/invoicePdfAttach.test.js`, `__tests__/invoiceEmailHardening.test.js` (extend), `__tests__/sendInvoiceEmailsAttachment.test.js`, `__tests__/uploadAutoInvoicePdf.test.ts`.

---

## Task 1: `buildInvoiceEmail` optional attachment

**Files:**
- Modify: `backend-workers/lib/invoiceEmail.js`
- Test: `__tests__/invoiceEmailHardening.test.js`

**Interfaces:**
- Consumes: nothing new.
- Produces: `buildInvoiceEmail({ invoice, settings, attachment })` where `attachment` is `{ filename: string, content: string /* base64 */ } | null | undefined`. When truthy, the returned payload has `attachments: [attachment]`; when falsy the payload is byte-identical to today's.

- [ ] **Step 1: Write the failing tests** — append inside the existing `describe("buildInvoiceEmail", …)` block in `__tests__/invoiceEmailHardening.test.js`:

```js
  test("attachment present → email.attachments is set", () => {
    const email = buildInvoiceEmail({
      invoice: inv(),
      settings,
      attachment: { filename: "Invoice-INV-0001.pdf", content: "JVBERi0=" },
    });
    expect(email.attachments).toEqual([
      { filename: "Invoice-INV-0001.pdf", content: "JVBERi0=" },
    ]);
  });

  test("no attachment → no attachments key (guards the plain-send path)", () => {
    const email = buildInvoiceEmail({ invoice: inv(), settings });
    expect(email.attachments).toBeUndefined();
  });
```

- [ ] **Step 2: Run to verify it fails**

Run: `npx jest invoiceEmailHardening -t attachment`
Expected: FAIL — `email.attachments` is `undefined` in the first new test.

- [ ] **Step 3: Implement** — in `backend-workers/lib/invoiceEmail.js`, change the signature and add the attachment line. The function currently starts `function buildInvoiceEmail({ invoice, settings }) {`:

```js
function buildInvoiceEmail({ invoice, settings, attachment }) {
```

and immediately before `return email;` (just after the `if (settings.email) email.reply_to = settings.email;` line) add:

```js
  if (attachment) email.attachments = [attachment];
```

- [ ] **Step 4: Run to verify it passes**

Run: `npx jest invoiceEmailHardening`
Expected: PASS (all existing tests + 2 new).

- [ ] **Step 5: Commit**

```bash
git add backend-workers/lib/invoiceEmail.js __tests__/invoiceEmailHardening.test.js
git commit -m "feat(invoice-email): optional PDF attachment on buildInvoiceEmail"
```

---

## Task 2: Pure send-side helpers (`invoicePdfAttach.js`)

**Files:**
- Create: `backend-workers/lib/invoicePdfAttach.js`
- Test: `__tests__/invoicePdfAttach.test.js`

**Interfaces:**
- Produces:
  - `PDF_GRACE_MS: number` (= 86_400_000).
  - `attachmentDecision({ hasObject: boolean, ageMs: number, graceMs?: number }): 'attach' | 'defer' | 'plain'` — `attach` when the object exists; else `defer` while `ageMs < graceMs`; else `plain`. A non-finite `ageMs` → `plain`.
  - `invoicePdfName(invoice): string` — `` `Invoice-${ref}.pdf` `` where `ref` is `invoice.number || invoice.id || 'invoice'` with path-hostile characters folded to `-`.

- [ ] **Step 1: Write the failing test** — create `__tests__/invoicePdfAttach.test.js`:

```js
const {
  PDF_GRACE_MS,
  attachmentDecision,
  invoicePdfName,
} = require("../backend-workers/lib/invoicePdfAttach");

describe("attachmentDecision", () => {
  test("object present → attach regardless of age", () => {
    expect(attachmentDecision({ hasObject: true, ageMs: 0 })).toBe("attach");
    expect(attachmentDecision({ hasObject: true, ageMs: PDF_GRACE_MS * 5 })).toBe("attach");
  });
  test("absent + young → defer", () => {
    expect(attachmentDecision({ hasObject: false, ageMs: 0 })).toBe("defer");
    expect(attachmentDecision({ hasObject: false, ageMs: PDF_GRACE_MS - 1 })).toBe("defer");
  });
  test("absent + at/after grace → plain", () => {
    expect(attachmentDecision({ hasObject: false, ageMs: PDF_GRACE_MS })).toBe("plain");
    expect(attachmentDecision({ hasObject: false, ageMs: PDF_GRACE_MS + 1 })).toBe("plain");
  });
  test("absent + non-finite age → plain", () => {
    expect(attachmentDecision({ hasObject: false, ageMs: Infinity })).toBe("plain");
    expect(attachmentDecision({ hasObject: false, ageMs: NaN })).toBe("plain");
  });
  test("future-dated (negative age) is treated as young → defer", () => {
    expect(attachmentDecision({ hasObject: false, ageMs: -5000 })).toBe("defer");
  });
});

describe("invoicePdfName", () => {
  test("uses invoice number", () => {
    expect(invoicePdfName({ number: "INV-0001", id: "invA" })).toBe("Invoice-INV-0001.pdf");
  });
  test("falls back to id when number is empty", () => {
    expect(invoicePdfName({ number: "", id: "inv123" })).toBe("Invoice-inv123.pdf");
  });
  test("folds path-hostile characters and collapses dashes", () => {
    expect(invoicePdfName({ number: "INV/01 02", id: "x" })).toBe("Invoice-INV-01-02.pdf");
  });
  test("fully-hostile ref degrades to a safe default", () => {
    expect(invoicePdfName({ number: "///", id: "" })).toBe("Invoice-invoice.pdf");
  });
});
```

- [ ] **Step 2: Run to verify it fails**

Run: `npx jest invoicePdfAttach`
Expected: FAIL — `Cannot find module ...invoicePdfAttach`.

- [ ] **Step 3: Implement** — create `backend-workers/lib/invoicePdfAttach.js`:

```js
// backend-workers/lib/invoicePdfAttach.js
// Pure send-side helpers for the auto-invoice PDF attachment (2026-08-06 spec).
// No I/O. Shared by sendInvoiceEmails.js and unit-tested directly.

// Grace window: the client uploads the PDF within seconds of completing the
// job, so 24h is a generous margin for a device that was offline at
// completion. Past it, billing must not stall on a missing PDF — send plain.
const PDF_GRACE_MS = 24 * 60 * 60 * 1000;

// Decide what the sweep does with one invoice given whether its PDF is in R2
// and how old the auto-email request is.
//   attach → the object exists, attach it
//   defer  → not there yet but still young; skip this run, retry next sweep
//   plain  → give up waiting (or age is unknowable); send without the PDF
function attachmentDecision({ hasObject, ageMs, graceMs = PDF_GRACE_MS }) {
  if (hasObject) return "attach";
  if (Number.isFinite(ageMs) && ageMs < graceMs) return "defer";
  return "plain";
}

// Customer-facing attachment name. The file's real identity is the R2 key;
// this only needs the invoice number, so it deliberately does NOT import the
// RN app's invoicePdfFilename (which pulls in expo-*). Blocklist matches
// utils/invoicePdfFile.ts: filesystem-reserved + URI-significant + whitespace.
const UNSAFE_IN_FILENAME = /[\\/:*?"<>|#%\s]+/g;
function invoicePdfName(invoice) {
  const ref = String((invoice && (invoice.number || invoice.id)) || "invoice")
    .replace(UNSAFE_IN_FILENAME, "-")
    .replace(/-{2,}/g, "-")
    .replace(/^-+|-+$/g, "");
  return `Invoice-${ref || "invoice"}.pdf`;
}

module.exports = { PDF_GRACE_MS, attachmentDecision, invoicePdfName };
```

- [ ] **Step 4: Run to verify it passes**

Run: `npx jest invoicePdfAttach`
Expected: PASS (all cases).

- [ ] **Step 5: Commit**

```bash
git add backend-workers/lib/invoicePdfAttach.js __tests__/invoicePdfAttach.test.js
git commit -m "feat(invoice-email): pure grace-decision + attachment-name helpers"
```

---

## Task 3: Pure upload validation (`invoicePdfUpload.js`)

**Files:**
- Create: `backend-workers/lib/invoicePdfUpload.js`
- Test: `__tests__/invoicePdfUpload.test.js`

**Interfaces:**
- Produces:
  - `INVOICE_ID_RE: RegExp` (`/^[A-Za-z0-9_-]{1,64}$/`).
  - `MAX_PDF_BYTES: number` (= 5_242_880).
  - `base64ByteLength(b64: string): number` — decoded byte length without allocating.
  - `looksLikePdf(bytes: Buffer|Uint8Array): boolean` — true when the first bytes are `%PDF-`.
  - `validateUpload({ invoiceId, pdfBase64 }): { ok: boolean, status: number, error?: string, bytes?: Buffer }` — `ok:true` returns `{ status:200, bytes }`; otherwise `{ ok:false, status, error }`.

- [ ] **Step 1: Write the failing test** — create `__tests__/invoicePdfUpload.test.js`:

```js
const {
  INVOICE_ID_RE,
  MAX_PDF_BYTES,
  base64ByteLength,
  looksLikePdf,
  validateUpload,
} = require("../backend-workers/lib/invoicePdfUpload");

// "%PDF-1.4\n" as base64
const PDF_B64 = Buffer.from("%PDF-1.4\n").toString("base64");

describe("base64ByteLength", () => {
  test("matches the decoded length for padded and unpadded input", () => {
    for (const s of ["", "aa==", "aaa=", "aaaa", PDF_B64]) {
      expect(base64ByteLength(s)).toBe(Buffer.from(s, "base64").length);
    }
  });
});

describe("looksLikePdf", () => {
  test("true for %PDF- header, false otherwise", () => {
    expect(looksLikePdf(Buffer.from("%PDF-1.7"))).toBe(true);
    expect(looksLikePdf(Buffer.from("PK"))).toBe(false);
    expect(looksLikePdf(Buffer.from("%PD"))).toBe(false);
  });
});

describe("validateUpload", () => {
  test("accepts a well-formed PDF upload", () => {
    const r = validateUpload({ invoiceId: "inv123", pdfBase64: PDF_B64 });
    expect(r.ok).toBe(true);
    expect(r.status).toBe(200);
    expect(Buffer.isBuffer(r.bytes)).toBe(true);
  });
  test("rejects a bad invoiceId", () => {
    for (const bad of ["", "a/b", "../x", "x".repeat(65), 42, null]) {
      const r = validateUpload({ invoiceId: bad, pdfBase64: PDF_B64 });
      expect(r.ok).toBe(false);
      expect(r.status).toBe(400);
    }
    expect(INVOICE_ID_RE.test("inv123")).toBe(true);
  });
  test("rejects missing/empty pdfBase64", () => {
    expect(validateUpload({ invoiceId: "inv1", pdfBase64: "" }).status).toBe(400);
    expect(validateUpload({ invoiceId: "inv1", pdfBase64: undefined }).status).toBe(400);
  });
  test("rejects an over-cap payload before decoding", () => {
    // base64 length that decodes to just over MAX_PDF_BYTES, made of valid chars.
    const overChars = Math.ceil((MAX_PDF_BYTES + 1) * 4 / 3) + 4;
    const big = "A".repeat(overChars);
    const r = validateUpload({ invoiceId: "inv1", pdfBase64: big });
    expect(r.ok).toBe(false);
    expect(r.status).toBe(413);
  });
  test("rejects a non-PDF body", () => {
    const notPdf = Buffer.from("hello world, not a pdf").toString("base64");
    const r = validateUpload({ invoiceId: "inv1", pdfBase64: notPdf });
    expect(r.ok).toBe(false);
    expect(r.status).toBe(400);
  });
});
```

- [ ] **Step 2: Run to verify it fails**

Run: `npx jest invoicePdfUpload`
Expected: FAIL — module not found.

- [ ] **Step 3: Implement** — create `backend-workers/lib/invoicePdfUpload.js`:

```js
// backend-workers/lib/invoicePdfUpload.js
// Pure validation for the POST /api/invoice-pdf upload (2026-08-06 spec).
// No I/O — the route (src/routes/invoicePdf.js) does auth + R2 put around it.
// Buffer is available under wrangler's nodejs_compat and in Jest (Node).

const INVOICE_ID_RE = /^[A-Za-z0-9_-]{1,64}$/;
const MAX_PDF_BYTES = 5 * 1024 * 1024;

// Decoded byte length from base64 length alone, so a hostile oversized body is
// rejected before it is decoded/allocated.
function base64ByteLength(b64) {
  const len = b64.length;
  if (len === 0) return 0;
  const padding = b64.endsWith("==") ? 2 : b64.endsWith("=") ? 1 : 0;
  return Math.floor((len * 3) / 4) - padding;
}

// %PDF- magic bytes: 0x25 0x50 0x44 0x46 0x2D.
function looksLikePdf(bytes) {
  return (
    bytes.length >= 5 &&
    bytes[0] === 0x25 &&
    bytes[1] === 0x50 &&
    bytes[2] === 0x44 &&
    bytes[3] === 0x46 &&
    bytes[4] === 0x2d
  );
}

function validateUpload({ invoiceId, pdfBase64 }) {
  if (typeof invoiceId !== "string" || !INVOICE_ID_RE.test(invoiceId)) {
    return { ok: false, status: 400, error: "Invalid invoiceId" };
  }
  if (typeof pdfBase64 !== "string" || pdfBase64.length === 0) {
    return { ok: false, status: 400, error: "Missing pdfBase64" };
  }
  if (base64ByteLength(pdfBase64) > MAX_PDF_BYTES) {
    return { ok: false, status: 413, error: "PDF too large" };
  }
  const bytes = Buffer.from(pdfBase64, "base64");
  if (!looksLikePdf(bytes)) {
    return { ok: false, status: 400, error: "Not a PDF" };
  }
  return { ok: true, status: 200, bytes };
}

module.exports = {
  INVOICE_ID_RE,
  MAX_PDF_BYTES,
  base64ByteLength,
  looksLikePdf,
  validateUpload,
};
```

- [ ] **Step 4: Run to verify it passes**

Run: `npx jest invoicePdfUpload`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add backend-workers/lib/invoicePdfUpload.js __tests__/invoicePdfUpload.test.js
git commit -m "feat(invoice-pdf): pure upload validation (id/size/magic-byte)"
```

---

## Task 4: Wire the sweep to fetch, attach, and delete the PDF

**Files:**
- Modify: `backend-workers/lib/sendInvoiceEmails.js`
- Test: `__tests__/sendInvoiceEmailsAttachment.test.js`

**Interfaces:**
- Consumes: `attachmentDecision`, `invoicePdfName` (Task 2); `buildInvoiceEmail({…, attachment})` (Task 1); an `env.INVOICE_PDFS` R2 binding exposing `get(key) → { arrayBuffer() } | null` and `delete(key)`.
- Produces: `runInvoiceEmails(env)` now also returns `waitingOnPdf: number` in its stats and attaches the PDF when present.

- [ ] **Step 1: Write the failing test** — create `__tests__/sendInvoiceEmailsAttachment.test.js`:

```js
// Drives runInvoiceEmails with a mocked Supabase REST + Resend fetch and a
// mock R2 binding, asserting the PDF attach / defer / plain branches.
const { runInvoiceEmails } = require("../backend-workers/lib/sendInvoiceEmails");

const NOW = new Date("2026-08-06T12:00:00.000Z");
const USER = "user-1";

function invoiceRow(overrides = {}) {
  return {
    id: "inv1",
    user_id: USER,
    data: {
      customer: "Jane",
      number: "INV-0001",
      amount: 500,
      due: "2026-09-05",
      email: "jane@example.com",
      autoEmailRequestedAt: overrides.__stampIso || "2026-08-06T11:59:00.000Z",
      ...(overrides.data || {}),
    },
  };
}

const SETTINGS_ROW = {
  user_id: USER,
  data: { autoEmailInvoiceOnComplete: true, businessName: "Smith Plumbing" },
};

// A router over the REST/Resend calls runInvoiceEmails makes. Returns a
// Response-like object. `resendBodies` captures what was sent to Resend.
function makeFetch({ invoices, settings, log = [], resendBodies }) {
  return jest.fn(async (url, init = {}) => {
    const u = String(url);
    const json = (v) => ({ ok: true, status: 200, json: async () => v, text: async () => "" });
    if (u.includes("/rest/v1/invoices")) return json(invoices);
    if (u.includes("/rest/v1/settings")) return json(settings);
    if (u.includes("auto_invoice_email_log") && (init.method || "GET") === "GET") return json(log);
    if (u.includes("auto_invoice_email_log") && init.method === "POST") return json([{ id: "log1" }]);
    if (u.includes("auto_invoice_email_log") && init.method === "PATCH") return json(null);
    if (u === "https://api.resend.com/emails") {
      resendBodies.push(JSON.parse(init.body));
      return json({ id: "email1" });
    }
    throw new Error("unexpected fetch " + u + " " + (init.method || "GET"));
  });
}

function makeEnv(bucket) {
  return {
    SUPABASE_URL: "https://x.supabase.co",
    SUPABASE_SERVICE_ROLE_KEY: "svc",
    RESEND_API_KEY: "re_x",
    INVOICE_PDFS: bucket,
  };
}

const realFetch = global.fetch;
afterEach(() => { global.fetch = realFetch; jest.useRealTimers(); });
beforeEach(() => { jest.useFakeTimers().setSystemTime(NOW); });

test("PDF present → email carries the attachment and the object is deleted", async () => {
  const del = jest.fn(async () => {});
  const bucket = {
    get: jest.fn(async () => ({ arrayBuffer: async () => Buffer.from("%PDF-1.4\n") })),
    delete: del,
  };
  const resendBodies = [];
  global.fetch = makeFetch({ invoices: [invoiceRow()], settings: [SETTINGS_ROW], resendBodies });

  const res = await runInvoiceEmails(makeEnv(bucket));

  expect(bucket.get).toHaveBeenCalledWith(`${USER}/inv1.pdf`);
  expect(resendBodies).toHaveLength(1);
  expect(resendBodies[0].attachments).toHaveLength(1);
  expect(resendBodies[0].attachments[0].filename).toBe("Invoice-INV-0001.pdf");
  expect(Buffer.from(resendBodies[0].attachments[0].content, "base64").toString()).toContain("%PDF-");
  expect(del).toHaveBeenCalledWith(`${USER}/inv1.pdf`);
  expect(res.sent).toBe(1);
});

test("PDF absent + young invoice → deferred, no send", async () => {
  const bucket = { get: jest.fn(async () => null), delete: jest.fn() };
  const resendBodies = [];
  // Stamped 1 minute ago → well within the 24h grace.
  global.fetch = makeFetch({
    invoices: [invoiceRow({ __stampIso: "2026-08-06T11:59:00.000Z" })],
    settings: [SETTINGS_ROW],
    resendBodies,
  });

  const res = await runInvoiceEmails(makeEnv(bucket));

  expect(resendBodies).toHaveLength(0);
  expect(res.sent).toBe(0);
  expect(res.waitingOnPdf).toBe(1);
});

test("PDF absent + old invoice → plain send without attachment", async () => {
  const bucket = { get: jest.fn(async () => null), delete: jest.fn() };
  const resendBodies = [];
  // Stamped ~2 days ago → past the 24h grace.
  global.fetch = makeFetch({
    invoices: [invoiceRow({ __stampIso: "2026-08-04T12:00:00.000Z" })],
    settings: [SETTINGS_ROW],
    resendBodies,
  });

  const res = await runInvoiceEmails(makeEnv(bucket));

  expect(resendBodies).toHaveLength(1);
  expect(resendBodies[0].attachments).toBeUndefined();
  expect(res.sent).toBe(1);
});

test("missing INVOICE_PDFS binding → plain send, no throw", async () => {
  const resendBodies = [];
  global.fetch = makeFetch({
    invoices: [invoiceRow({ __stampIso: "2026-08-04T12:00:00.000Z" })],
    settings: [SETTINGS_ROW],
    resendBodies,
  });

  const res = await runInvoiceEmails(makeEnv(undefined));

  expect(resendBodies).toHaveLength(1);
  expect(resendBodies[0].attachments).toBeUndefined();
  expect(res.sent).toBe(1);
});
```

- [ ] **Step 2: Run to verify it fails**

Run: `npx jest sendInvoiceEmailsAttachment`
Expected: FAIL — the attach path test fails (no `attachments` on the Resend body; `res.waitingOnPdf` undefined).

- [ ] **Step 3: Implement** — edit `backend-workers/lib/sendInvoiceEmails.js`:

(3a) At the top, add the helper import next to the existing requires:

```js
const { selectInvoicesToAutoEmail } = require("./selectInvoicesToAutoEmail");
const { buildInvoiceEmail } = require("./invoiceEmail");
const { attachmentDecision, invoicePdfName } = require("./invoicePdfAttach");
```

(3b) In `runInvoiceEmails`, add two counters and a one-time warn flag beside the existing `let scanned = 0; …` block:

```js
  let scanned = 0;
  let sent = 0;
  let failed = 0;
  let capped = 0;
  let waitingOnPdf = 0;
  let warnedMissingBucket = false;
```

(3c) Inside `for (const invoice of toSend) {`, **after** the daily-cap `if (claimedToday >= …) { deferred++; continue; }` block and **before** `scanned++;`, insert the PDF resolution + grace gate:

```js
      // Resolve the R2 PDF + grace decision BEFORE claiming: a deferral must
      // write no log row so a later sweep retries once the upload lands.
      let attachment = null;
      let pdfKey = null;
      try {
        const bucket = env.INVOICE_PDFS;
        let obj = null;
        if (bucket) {
          pdfKey = `${userId}/${invoice.id}.pdf`;
          obj = await bucket.get(pdfKey);
        } else if (!warnedMissingBucket) {
          warnedMissingBucket = true;
          console.error("[send-invoice-emails] INVOICE_PDFS binding missing — sending plain");
        }
        const stamped = Date.parse(invoice.autoEmailRequestedAt);
        const ageMs = Number.isFinite(stamped) ? today.getTime() - stamped : Infinity;
        const decision = attachmentDecision({ hasObject: !!obj, ageMs });
        if (decision === "defer") {
          waitingOnPdf++;
          continue; // no claim; retried next sweep
        }
        if (obj) {
          const buf = await obj.arrayBuffer();
          attachment = {
            filename: invoicePdfName(invoice),
            content: Buffer.from(buf).toString("base64"),
          };
        }
        // decision === "plain" → attachment stays null
      } catch (pdfErr) {
        // An R2 read glitch must never block billing — fall through to plain.
        console.error("[send-invoice-emails] pdf fetch error", invoice.id, pdfErr.message);
      }
```

(3d) Change the email build call from `buildInvoiceEmail({ invoice, settings })` to pass the attachment:

```js
          const email = buildInvoiceEmail({ invoice, settings, attachment });
```

(3e) In the send `try`, after `sent++;` and the `await markLog(env, logId, { status: "sent", … })` line, add the delete-after-send:

```js
          sent++;
          await markLog(env, logId, { status: "sent", sent_at: new Date().toISOString() });
          if (pdfKey && env.INVOICE_PDFS) {
            try {
              await env.INVOICE_PDFS.delete(pdfKey);
            } catch (delErr) {
              console.error("[send-invoice-emails] pdf delete failed", invoice.id, delErr.message);
            }
          }
```

(3f) Update the return to include the new counter:

```js
  return { scanned, sent, failed, capped, waitingOnPdf };
```

- [ ] **Step 4: Run to verify it passes**

Run: `npx jest sendInvoiceEmailsAttachment`
Expected: PASS (all four branch tests).

- [ ] **Step 5: Regression-check the neighboring suites**

Run: `npx jest selectInvoicesToAutoEmail invoiceEmailHardening autoEmailPlausibilityParity`
Expected: PASS (no behavior change to selection or the plain payload).

- [ ] **Step 6: Commit**

```bash
git add backend-workers/lib/sendInvoiceEmails.js __tests__/sendInvoiceEmailsAttachment.test.js
git commit -m "feat(invoice-email): attach R2 PDF in the sweep (grace-then-plain, delete-after-send)"
```

---

## Task 5: Upload endpoint + R2 binding wiring

**Files:**
- Create: `backend-workers/src/routes/invoicePdf.js`
- Modify: `backend-workers/src/index.js`
- Modify: `backend-workers/wrangler.toml`

No unit test (consistent with the other route handlers, which have none; the validation logic is fully covered by Task 3). Verified by `wrangler deploy --dry-run` and a manual `wrangler dev` smoke.

**Interfaces:**
- Consumes: `validateUpload` (Task 3), `appCors`, `clientIp`, `jsonBody` (existing `src/appCors.js`), `env.INVOICE_PDFS`.
- Produces: `POST /api/invoice-pdf` — `{ invoiceId, pdfBase64 }` with `Authorization: Bearer <supabase jwt>` → `200 { ok: true }`; writes `env.INVOICE_PDFS.put(`${userId}/${invoiceId}.pdf`, bytes)`.

- [ ] **Step 1: Create the handler** — `backend-workers/src/routes/invoicePdf.js`:

```js
// Workers route: POST /api/invoice-pdf — stores a device-generated invoice PDF
// in R2 so the auto-email sweep can attach it (2026-08-06 spec).
//
// SECURITY MODEL:
//   Caller sends their Supabase JWT ("Authorization: Bearer <token>"); the
//   server verifies it (anon key), extracts the user id, and writes the object
//   under that user's prefix only. The service role key is never involved —
//   R2 access is via the binding.
//
// Required bindings: SUPABASE_URL, SUPABASE_ANON_KEY, INVOICE_PDFS (R2).

import { appCors, clientIp, jsonBody } from "../appCors.js";
import { validateUpload } from "../../lib/invoicePdfUpload.js";

// One PDF per completed job — 20 per IP per minute is generous headroom.
const rateLimitMap = new Map();
const RATE_LIMIT = 20;
const WINDOW_MS = 60_000;

function isRateLimited(ip) {
  const now = Date.now();
  const timestamps = (rateLimitMap.get(ip) || []).filter((t) => now - t < WINDOW_MS);
  if (timestamps.length >= RATE_LIMIT) {
    rateLimitMap.set(ip, timestamps);
    return true;
  }
  timestamps.push(now);
  rateLimitMap.set(ip, timestamps);
  return false;
}

export async function invoicePdfHandler(c) {
  appCors(c, "POST, OPTIONS");
  if (c.req.method === "OPTIONS") return c.body(null, 200);
  if (c.req.method !== "POST") return c.json({ error: "Method not allowed" }, 405);

  const ip = clientIp(c);
  if (isRateLimited(ip)) {
    return c.json({ error: "Too many requests. Please wait a moment." }, 429);
  }

  const { SUPABASE_URL, SUPABASE_ANON_KEY, INVOICE_PDFS } = c.env;
  if (!SUPABASE_URL || !SUPABASE_ANON_KEY || !INVOICE_PDFS) {
    return c.json({ error: "Server misconfiguration: SUPABASE_URL, SUPABASE_ANON_KEY, and the INVOICE_PDFS R2 binding are required." }, 500);
  }

  const auth = c.req.header("authorization");
  if (!auth || !auth.startsWith("Bearer ")) {
    return c.json({ error: "Unauthorized" }, 401);
  }
  const userJwt = auth.slice(7);
  const userRes = await fetch(`${SUPABASE_URL}/auth/v1/user`, {
    headers: { Authorization: `Bearer ${userJwt}`, apikey: SUPABASE_ANON_KEY },
  });
  if (!userRes.ok) return c.json({ error: "Invalid or expired session. Please sign in again." }, 401);
  const user = await userRes.json();
  const userId = user?.id;
  if (!userId) return c.json({ error: "Unauthorized" }, 401);

  const body = (await jsonBody(c)) || {};
  const check = validateUpload({ invoiceId: body.invoiceId, pdfBase64: body.pdfBase64 });
  if (!check.ok) return c.json({ error: check.error }, check.status);

  try {
    await INVOICE_PDFS.put(`${userId}/${body.invoiceId}.pdf`, check.bytes, {
      httpMetadata: { contentType: "application/pdf" },
    });
    return c.json({ ok: true }, 200);
  } catch (err) {
    console.error("[invoice-pdf] R2 put failed:", err.message);
    return c.json({ error: "Could not store the PDF. Please try again." }, 500);
  }
}
```

- [ ] **Step 2: Wire the route** — in `backend-workers/src/index.js`, add the import beside the others (after the `createPaymentLinkHandler` import):

```js
import { invoicePdfHandler } from './routes/invoicePdf.js';
```

and register it in the app-facing block, after the `create-payment-link` line:

```js
app.all('/api/invoice-pdf', invoicePdfHandler);
```

- [ ] **Step 3: Add the R2 binding** — append to `backend-workers/wrangler.toml`:

```toml

[[r2_buckets]]
binding = "INVOICE_PDFS"
bucket_name = "tradeready-invoice-pdfs"
```

- [ ] **Step 4: Validate the Worker builds and binds**

Run: `cd backend-workers && npx wrangler deploy --dry-run --outdir=dist 2>&1 | tail -20; cd ..`
Expected: dry-run succeeds and the output lists an R2 bucket binding `INVOICE_PDFS` (bucket `tradeready-invoice-pdfs`). No syntax/import errors.

- [ ] **Step 5: Keep the app gate green** (this task touched no app-jest files, but run to be safe)

Run: `npm test -- invoicePdf sendInvoiceEmailsAttachment`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add backend-workers/src/routes/invoicePdf.js backend-workers/src/index.js backend-workers/wrangler.toml
git commit -m "feat(invoice-pdf): POST /api/invoice-pdf endpoint + INVOICE_PDFS R2 binding"
```

---

## Task 6: Client uploads the PDF at auto-invoice mint

**Files:**
- Modify: `utils/autoInvoice.ts`
- Modify: `jest.setup.js` (add `EncodingType` to the `expo-file-system/legacy` mock)
- Test: `__tests__/uploadAutoInvoicePdf.test.ts`

**Interfaces:**
- Consumes: `buildInvoicePdfFile(invoice, settings)` (`utils/invoicePdfFile.ts`), `supabase.auth.getSession()` (`utils/supabase.ts`), `Constants.expoConfig.extra.backendUrl` / `backendUrlIsPlaceholder`, `FileSystem.readAsStringAsync` (`expo-file-system/legacy`), `reportError` (`utils/analytics.ts`).
- Produces: `uploadAutoInvoicePdf(invoiceId: string): Promise<void>` — fire-and-forget, never throws; POSTs `{ invoiceId, pdfBase64 }` to `${backendUrl}/api/invoice-pdf` with the session bearer. Called from `createAutoInvoiceForJob`.

- [ ] **Step 1: Add `EncodingType` to the test mock** — in `jest.setup.js`, inside the `jest.mock("expo-file-system/legacy", () => ({ … }))` object, add a field (the client reads base64 via `FileSystem.EncodingType.Base64`, which is otherwise `undefined` in the mock and would throw):

```js
  EncodingType: { Base64: "base64", UTF8: "utf8" },
```

- [ ] **Step 2: Write the failing test** — create `__tests__/uploadAutoInvoicePdf.test.ts`:

```ts
import AsyncStorage from "@react-native-async-storage/async-storage";
import { uploadAutoInvoicePdf } from "../utils/autoInvoice";
import { buildInvoicePdfFile } from "../utils/invoicePdfFile";
import { supabase } from "../utils/supabase";
import { reportError } from "../utils/analytics";
import * as FileSystem from "expo-file-system/legacy";
import type { Invoice } from "../types/models";

jest.mock("../utils/sync", () => ({
  enqueue: jest.fn(),
  enqueueCollectionChanges: jest.fn(),
  trySync: jest.fn(),
}));
jest.mock("../utils/notifications", () => ({ syncNotifications: jest.fn() }));
jest.mock("../utils/widgetBridge", () => ({
  refreshWidgetSnapshot: jest.fn().mockResolvedValue(undefined),
  clearWidgetSnapshot: jest.fn().mockResolvedValue(undefined),
}));
jest.mock("../utils/analytics", () => ({ track: jest.fn(), reportError: jest.fn() }));
jest.mock("../utils/invoicePdfFile", () => ({ buildInvoicePdfFile: jest.fn() }));

const INVOICE: Invoice = {
  id: "inv1",
  customer: "Jane",
  number: "INV-0001",
  amount: 500,
  due: "2026-09-05",
  email: "jane@example.com",
  paid: false,
} as Invoice;

async function seedInvoice() {
  await AsyncStorage.setItem("invoices", JSON.stringify([INVOICE]));
  await AsyncStorage.setItem("settings", JSON.stringify({ businessName: "Smith" }));
}

beforeEach(async () => {
  await AsyncStorage.clear();
  jest.clearAllMocks();
  (buildInvoicePdfFile as jest.Mock).mockResolvedValue("file:///mock/Invoice.pdf");
  (FileSystem.readAsStringAsync as jest.Mock).mockResolvedValue("JVBERi0xLjQK"); // "%PDF-1.4\n"
  jest.spyOn(supabase.auth, "getSession").mockResolvedValue({
    data: { session: { access_token: "tok123" } },
  } as any);
});

const realFetch = global.fetch;
afterEach(() => { global.fetch = realFetch; });

test("posts the PDF to /api/invoice-pdf with the session bearer", async () => {
  await seedInvoice();
  const fetchMock = jest.fn().mockResolvedValue({ ok: true, status: 200 });
  global.fetch = fetchMock;

  await uploadAutoInvoicePdf("inv1");

  expect(fetchMock).toHaveBeenCalledTimes(1);
  const [url, init] = fetchMock.mock.calls[0];
  expect(String(url)).toContain("/api/invoice-pdf");
  expect(init.method).toBe("POST");
  expect(init.headers.Authorization).toBe("Bearer tok123");
  expect(JSON.parse(init.body)).toEqual({ invoiceId: "inv1", pdfBase64: "JVBERi0xLjQK" });
  expect(reportError).not.toHaveBeenCalled();
});

test("no invoice → no upload, no throw", async () => {
  await AsyncStorage.setItem("invoices", JSON.stringify([]));
  const fetchMock = jest.fn();
  global.fetch = fetchMock;
  await expect(uploadAutoInvoicePdf("missing")).resolves.toBeUndefined();
  expect(fetchMock).not.toHaveBeenCalled();
});

test("null PDF (build failed) → no upload", async () => {
  await seedInvoice();
  (buildInvoicePdfFile as jest.Mock).mockResolvedValue(null);
  const fetchMock = jest.fn();
  global.fetch = fetchMock;
  await uploadAutoInvoicePdf("inv1");
  expect(fetchMock).not.toHaveBeenCalled();
});

test("no session → no upload", async () => {
  await seedInvoice();
  (supabase.auth.getSession as jest.Mock).mockResolvedValue({ data: { session: null } });
  const fetchMock = jest.fn();
  global.fetch = fetchMock;
  await uploadAutoInvoicePdf("inv1");
  expect(fetchMock).not.toHaveBeenCalled();
});

test("a fetch failure is swallowed and reported", async () => {
  await seedInvoice();
  global.fetch = jest.fn().mockRejectedValue(new Error("network"));
  await expect(uploadAutoInvoicePdf("inv1")).resolves.toBeUndefined();
  expect(reportError).toHaveBeenCalledWith(expect.any(Error), { context: "autoInvoiceUploadPdf" });
});
```

- [ ] **Step 3: Run to verify it fails**

Run: `npx jest uploadAutoInvoicePdf`
Expected: FAIL — `uploadAutoInvoicePdf` is not exported.

- [ ] **Step 4: Implement** — in `utils/autoInvoice.ts`:

(4a) Add imports at the top of the file (near the existing imports). `Constants`, `supabase`, `buildInvoicePdfFile`, and `FileSystem` are not yet imported here:

```ts
import Constants from "expo-constants";
import * as FileSystem from "expo-file-system/legacy";
import { supabase } from "./supabase";
import { buildInvoicePdfFile } from "./invoicePdfFile";
```

(4b) Add module-level backend-URL constants (mirroring `utils/invoiceHelpers.ts`), placed just above `createAutoInvoiceForJob`:

```ts
const BACKEND_URL: string = Constants.expoConfig?.extra?.backendUrl ?? "";
const BACKEND_URL_IS_PLACEHOLDER: boolean =
  Constants.expoConfig?.extra?.backendUrlIsPlaceholder ?? true;
```

(4c) Add the function (place it next to `mintAutoInvoicePaymentLink`):

```ts
/**
 * Best-effort upload of a freshly auto-created invoice's PDF to the backend,
 * which stores it in R2 so the auto-email sweep can attach the SAME PDF the
 * manual send produces (2026-08-06 spec). Reuses buildInvoicePdfFile verbatim
 * — no second layout. Fire-and-forget: never awaited on the completion path,
 * never throws. A placeholder backend URL, a missing PDF, no session, or any
 * network error → no upload; the sweep's grace-then-plain path covers it.
 */
export async function uploadAutoInvoicePdf(invoiceId: string): Promise<void> {
  try {
    if (!BACKEND_URL || BACKEND_URL_IS_PLACEHOLDER) return;
    const [invoices, settings] = await Promise.all([loadInvoices(), loadSettings()]);
    const invoice = invoices.find((i) => i.id === invoiceId);
    if (!invoice) return;

    const uri = await buildInvoicePdfFile(invoice, settings);
    if (!uri) return; // buildInvoicePdfFile already reported the failure

    const pdfBase64 = await FileSystem.readAsStringAsync(uri, {
      encoding: FileSystem.EncodingType.Base64,
    });
    if (!pdfBase64) return;

    const { data: { session } } = await supabase.auth.getSession();
    if (!session?.access_token) return;

    const res = await fetch(`${BACKEND_URL}/api/invoice-pdf`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: `Bearer ${session.access_token}`,
      },
      body: JSON.stringify({ invoiceId, pdfBase64 }),
    });
    if (!res.ok) throw new Error(`invoice-pdf upload ${res.status}`);
  } catch (err: unknown) {
    reportError(err, { context: "autoInvoiceUploadPdf" });
  }
}
```

(4d) Call it from `createAutoInvoiceForJob`, in the existing `if (autoEmailQueued) { … }` block — right after the `void mintAutoInvoicePaymentLink(invoice.id);` line:

```ts
  if (autoEmailQueued) {
    // Fire-and-forget (local-first: completion never waits on the network).
    void mintAutoInvoicePaymentLink(invoice.id);
    void uploadAutoInvoicePdf(invoice.id);
  }
```

- [ ] **Step 5: Run to verify it passes**

Run: `npx jest uploadAutoInvoicePdf`
Expected: PASS (all five tests).

- [ ] **Step 6: Regression-check the existing auto-invoice suite**

Run: `npx jest autoInvoice`
Expected: PASS — the new fire-and-forget call must not disturb `createAutoInvoiceForJob`'s existing assertions.

- [ ] **Step 7: Commit**

```bash
git add utils/autoInvoice.ts jest.setup.js __tests__/uploadAutoInvoicePdf.test.ts
git commit -m "feat(auto-invoice): upload the invoice PDF to R2 at mint time"
```

---

## Task 7: Full gate + docs

**Files:**
- Modify (if needed): `ARCHITECTURE.md` or the auto-email doc references — only if they enumerate the auto-email behavior that just changed.

- [ ] **Step 1: Run the full gate**

Run: `npm run typecheck && npm test && npm run lint`
Expected: typecheck 0 errors; all suites pass (including the new `invoicePdfUpload`, `invoicePdfAttach`, `sendInvoiceEmailsAttachment`, `uploadAutoInvoicePdf`, and extended `invoiceEmailHardening`); lint 0 warnings.

- [ ] **Step 2: Update the auto-email doc note (if present)** — if `ARCHITECTURE.md` or `docs/superpowers/specs/2026-08-06-auto-email-invoice-design.md` states "text only / no attachment," add a one-line pointer that auto-emails now attach the R2-stored PDF (grace-then-plain). Skip if no such statement exists.

- [ ] **Step 3: Commit any doc change**

```bash
git add ARCHITECTURE.md
git commit -m "docs: note auto-emailed invoices now attach the R2 PDF"
```

---

## Owner operations (outside this plan — required before it works in production)

1. Create the bucket: `cd backend-workers && npx wrangler r2 bucket create tradeready-invoice-pdfs`
2. Deploy the Worker with the new binding: `npx wrangler deploy`
3. Device smoke: complete a job with auto-email enabled and an emailable customer; confirm the customer's email arrives with `Invoice-<number>.pdf` attached and that the PDF matches the manual "Save PDF" output.

---

## Self-Review

**Spec coverage:**
- R2 bucket + binding → Task 5 (wrangler.toml) + Owner ops.
- Upload endpoint (auth, size cap, magic-byte, R2 put) → Task 3 (validation) + Task 5 (handler).
- Client `uploadAutoInvoicePdf` + call site → Task 6.
- Sweep fetch + attach + grace-then-plain + delete-after-send → Task 4 (+ Task 2 helpers).
- `buildInvoiceEmail` attachment → Task 1.
- Miss/edge cases (missing binding, young/old, null PDF, placeholder URL, no session) → Tasks 4 & 6 tests.
- Filename helper → Task 2.
- Tests enumerated in the spec → Tasks 1–6.

**Placeholder scan:** none — every code step contains full source.

**Type/name consistency:** `attachmentDecision`, `invoicePdfName`, `PDF_GRACE_MS`, `MAX_PDF_BYTES`, `INVOICE_ID_RE`, `validateUpload`, `uploadAutoInvoicePdf`, `INVOICE_PDFS`, and the `{ invoiceId, pdfBase64 }` body shape are used identically across the route, sweep, client, and tests. The `attachment` shape `{ filename, content }` matches between Task 1, Task 4, and the Resend payload.

**Known deviations from a naive reading of the spec (intentional):**
- The route handler has no unit test — matches the codebase (no route handler is unit-tested); all of its branchy logic is in `validateUpload`, which is fully tested in Task 3.
- The client placeholder-URL and missing-`EncodingType` branches: `BACKEND_URL` is captured at module load (mirroring `invoiceHelpers.ts`), so the placeholder branch isn't exercised by a per-test override; it's guarded identically to the existing shipped pattern.

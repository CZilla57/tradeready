# Auto-Emailed Invoices Carry the Real PDF (R2-backed)

**Date:** 2026-08-06
**Status:** Design approved (approach + miss-behavior), spec under review

## Problem

The opt-in auto-invoice-on-complete flow (2026-08-06 spec) emails the customer
their invoice unattended, from the Cloudflare Worker 15-minute sweep
(`backend-workers/lib/sendInvoiceEmails.js` → `invoiceEmail.js`). That email is
**text only** — no PDF is attached. The manual send path
(`OutreachScreen` → `buildInvoicePdfFile`) does attach the styled invoice PDF,
so a customer's experience differs depending on whether the tradesperson sent
the invoice by hand or let the app send it automatically.

Every auto-emailed invoice should carry the **same** PDF the manual path
produces, at a reasonable file size for email.

## Why this is not a one-line change

The auto-email is generated entirely server-side, in a Worker cron with no
device context. The app's PDF is produced by `expo-print` **on the device**
(`utils/invoicePdfFile.ts` → `utils/pdfTemplates.ts`), which the Worker cannot
run. So the PDF must be produced on the device and handed to the Worker.

Decisions settled with the owner before design:

1. **Reuse the exact device PDF** — not a second, server-generated layout. The
   owner explicitly does not want two invoice styles that can drift. This rules
   out generating a PDF in the Worker (`pdf-lib`, Browser Rendering).
2. **Store it in Cloudflare R2**, not Supabase Storage (free-tier storage is too
   small) and not a new dependency. R2 is now unblocked: the App Store review
   that gated it is complete and the Vercel→Cloudflare migration is done. R2 is
   a Worker binding, so this adds **no npm dependency**.
3. **File size is already handled.** The 40 MB PDFs seen historically were an
   oversized-logo bug on the client; `readLogoForPdf` (utils/photoStorage.ts)
   now downscales and PNG-compresses the logo. Reusing `buildInvoicePdfFile`
   verbatim inherits that fix — the attached PDF is the same reasonable-size
   file the manual path already sends.
4. **Miss behavior: grace period, then send plain.** If the sweep runs before
   the PDF has uploaded (offline device or a failed upload), skip and retry
   while the invoice is young; once it crosses the grace threshold, send the
   email without the attachment so the customer is still billed. Never drop a
   bill; near-universal attachment in practice.

**Scope: invoices only.** Job photos ride the same R2 foundation but are a
separate, larger effort (`project_job_photos_r2_sync_plan`) and are not folded
in here.

## Architecture

```
Device (job marked complete)
  createAutoInvoiceForJob()               utils/autoInvoice.ts
    ├─ saves invoice (stamped autoEmailRequestedAt)
    ├─ void mintAutoInvoicePaymentLink(id)   [existing, fire-and-forget]
    └─ void uploadAutoInvoicePdf(id)         [NEW, fire-and-forget]
         buildInvoicePdfFile() → base64 → POST /api/invoice-pdf

Worker
  POST /api/invoice-pdf                     src/routes/invoicePdf.js [NEW]
    verify Supabase JWT → userId
    INVOICE_PDFS.put(`${userId}/${invoiceId}.pdf`, bytes)

  scheduled() */15 sweep                    lib/sendInvoiceEmails.js
    for each invoice to send (has user_id):
      obj = INVOICE_PDFS.get(`${userId}/${invoiceId}.pdf`)
      present → buildInvoiceEmail({..., attachment}) → Resend → delete object
      absent + young → defer (no log row; retried next sweep)
      absent + old   → send plain (no attachment)
```

R2 object key: `{user_id}/{invoice_id}.pdf`. The `user_id` scoping means the
upload endpoint writes only under the authenticated caller's prefix, and the
sweep (which already groups invoices by `user_id`) reads the matching key.

## Components

### New — R2 bucket + binding

- Bucket `tradeready-invoice-pdfs`, created by the owner:
  `wrangler r2 bucket create tradeready-invoice-pdfs` (an owner op, like
  `wrangler secret put`). A separate preview bucket is not required; local dev
  uses wrangler's simulated R2.
- `wrangler.toml` gains:
  ```toml
  [[r2_buckets]]
  binding = "INVOICE_PDFS"
  bucket_name = "tradeready-invoice-pdfs"
  ```

### New — `backend-workers/src/routes/invoicePdf.js`

`invoicePdfHandler(c)`, wired in `src/index.js` as
`app.all('/api/invoice-pdf', invoicePdfHandler)`.

- `appCors(c, 'POST, OPTIONS')`; OPTIONS → 200; non-POST → 405 (sibling shape).
- Rate limit per IP (reuse the sliding-window pattern; 20/60s — an honest device
  uploads one PDF per completed job).
- Auth exactly like `create-payment-link.js`: `Authorization: Bearer <jwt>` →
  verify at `${SUPABASE_URL}/auth/v1/user` with `SUPABASE_ANON_KEY` → `userId`;
  401 on any failure.
- Body: JSON `{ invoiceId, pdfBase64 }` via `jsonBody(c)`.
  - `invoiceId`: required, string, matched against `^[A-Za-z0-9_-]{1,64}$`
    (invoice ids are `inv<ms>` or storage ids — reject anything that could
    escape the key path).
  - `pdfBase64`: required, string. Reject when the decoded size exceeds a cap.
    Cap = **5 MB** decoded; checked from base64 length
    (`Math.floor(len * 3 / 4)`) before decoding to avoid allocating a hostile
    payload. 413 on over-cap.
  - Decode with `Buffer.from(pdfBase64, 'base64')` (nodejs_compat is on). A
    lightweight `%PDF-` magic-byte check on the first bytes rejects non-PDF
    uploads with 400.
- `await c.env.INVOICE_PDFS.put(`${userId}/${invoiceId}.pdf`, bytes, {
  httpMetadata: { contentType: 'application/pdf' } })`; upsert semantics
  (a re-generated invoice overwrites).
- 200 `{ ok: true }`; 500 on an R2 error (the client treats any failure as
  "no upload" — honest degradation, the sweep's grace path covers it).
- `INVOICE_PDFS` missing from `c.env` (binding not deployed yet) → 500 with a
  clear server-misconfiguration message, same shape as the sibling routes'
  env guards.

### Changed — `utils/autoInvoice.ts`

New exported `uploadAutoInvoicePdf(invoiceId: string): Promise<void>`,
fire-and-forget, mirroring `mintAutoInvoicePaymentLink`:

- Load invoices + settings; find the invoice; return if gone.
- `const uri = await buildInvoicePdfFile(invoice, settings)`; return if `null`
  (that helper already reported the error).
- Read the file as base64:
  `FileSystem.readAsStringAsync(uri, { encoding: Base64 })`
  (import `expo-file-system/legacy`, matching `invoicePdfFile.ts`).
- Resolve backend URL + placeholder guard the same way `invoiceHelpers.ts`
  does (`Constants.expoConfig?.extra?.backendUrl`,
  `backendUrlIsPlaceholder`); if placeholder/unset, return (no endpoint to
  hit — the sweep falls back to plain).
- `const { data: { session } } = await supabase.auth.getSession()`; return if
  no `access_token`.
- `POST ${backendUrl}/api/invoice-pdf` with
  `Authorization: Bearer <token>`, JSON `{ invoiceId, pdfBase64 }`.
- Wrap the whole thing in try/catch → `reportError(err, { context:
  'autoInvoiceUploadPdf' })`. **Never throws** — the completion path calls it
  as `void uploadAutoInvoicePdf(invoice.id)`.

Called from `createAutoInvoiceForJob`, in the existing `if (autoEmailQueued)`
block, right after `void mintAutoInvoicePaymentLink(invoice.id)`:

```ts
if (autoEmailQueued) {
  void mintAutoInvoicePaymentLink(invoice.id);
  void uploadAutoInvoicePdf(invoice.id);
}
```

The two are independent (the PDF template renders no payment link — see
`pdfTemplates.invoiceHtml`), so ordering between them does not matter and
neither waits on the other.

### Changed — `backend-workers/lib/invoiceEmail.js`

`buildInvoiceEmail` gains an optional attachment, keeping the function pure:

```js
function buildInvoiceEmail({ invoice, settings, attachment }) { … }
```

When `attachment` (`{ filename, content }`, `content` = base64 string) is
provided, set `email.attachments = [attachment]`. Absent → unchanged payload,
so every existing test and the plain-send fallback are byte-identical.

### Changed — `backend-workers/lib/sendInvoiceEmails.js`

`runInvoiceEmails(env)` gains the PDF lookup + grace logic. Per invoice in
`toSend`, **before** the claim insert:

```js
const key = `${userId}/${invoice.id}.pdf`;
const obj = await env.INVOICE_PDFS.get(key);        // null when absent
let attachment = null;
if (obj) {
  const buf = await obj.arrayBuffer();
  attachment = {
    filename: invoicePdfName(invoice),               // "Invoice-<number>.pdf"
    content: Buffer.from(buf).toString('base64'),
  };
} else {
  // Grace: while the invoice is young, defer so the upload can land.
  const stamped = Date.parse(invoice.autoEmailRequestedAt);
  const ageMs = Number.isFinite(stamped) ? today.getTime() - stamped : Infinity;
  if (ageMs < PDF_GRACE_MS) { continue; }            // no claim, retried next sweep
  // else: fall through and send plain (attachment stays null)
}
```

- `PDF_GRACE_MS = 24 * 60 * 60 * 1000` (24h). Rationale: the client uploads
  within seconds of completion, so 24h is a generous margin for a device that
  was offline at completion; past it, billing must not stall on a missing PDF.
- The claim/send below is unchanged except `buildInvoiceEmail({ invoice,
  settings, attachment })` and, **after a `sent` outcome**, a best-effort
  `env.INVOICE_PDFS.delete(key)` (wrapped so a delete failure never flips a
  delivered email to failed — same discipline as `markLog`). Delete-after-sent
  is safe because sends are one-and-done (the log row blocks re-sends).
- If `env.INVOICE_PDFS` is undefined (binding not yet deployed), treat every
  invoice as "absent" and rely on the grace/plain path — the sweep must not
  throw a whole-batch error because a binding is missing. A one-time
  `console.error` notes the missing binding.
- New tiny helper `invoicePdfName(invoice)` builds
  `Invoice-${(invoice.number || invoice.id)}.pdf` with path-hostile characters
  (`\ / : * ? " < > | # %` and whitespace) folded to `-`. It intentionally does
  **not** import the client's `invoicePdfFilename` (that lives in the RN app and
  pulls in `expo-*`); the customer-facing attachment name only needs the invoice
  number, and the file's real identity is the R2 key.

### Changed — tests

- `__tests__/autoInvoice.test.ts` (or a new `autoInvoiceUploadPdf.test.ts`):
  happy path posts base64 with the bearer token to the right URL; a null PDF,
  a placeholder backend URL, and a missing session each short-circuit without
  posting; a thrown fetch is swallowed (never rejects) and reports.
- New `backend-workers/__tests__/invoicePdfRoute.test.js`: 405 on GET, 401
  without/with-bad JWT, 400 on missing/oversized/non-PDF body, 200 puts to a
  mock R2 binding under `${userId}/${invoiceId}.pdf`.
- Extend `__tests__/invoiceEmailHardening.test.js`: `attachment` present →
  `email.attachments` set; absent → key absent (guards the plain path).
- New/extended sweep test with a mock `env.INVOICE_PDFS`: present → attaches
  and deletes after send; absent+young → deferred (no log claim, no send);
  absent+old → sends plain; missing binding → sends plain without throwing.

Gate (`npm run typecheck`, `npm test`, `npm run lint`) must be green before any
commit (change-control Rule 2).

## Edge cases

| Case | Behavior |
|---|---|
| PDF uploaded before sweep (normal) | Attached; object deleted after a `sent` outcome |
| Device offline at completion, back before 24h | Deferred each sweep until the upload lands, then attached |
| Upload permanently fails / never happens | Sent plain after 24h; customer still billed |
| `buildInvoicePdfFile` returns null (logo/print glitch) | No upload; sweep sends plain after grace |
| Backend URL still placeholder | Upload short-circuits; sweep sends plain after grace |
| Not signed in at upload time | Upload short-circuits; sweep sends plain after grace |
| R2 binding not deployed yet | Endpoint 500s (client degrades to no-upload); sweep treats all as absent → plain |
| Same invoice re-generated | `put` upserts the object; `get` returns the latest |
| Oversized/hostile upload body | 413/400 before decode; nothing written |
| `invoiceId` with path characters | Rejected by the `^[A-Za-z0-9_-]{1,64}$` guard |
| Delete-after-send fails | Non-fatal; the email already delivered; object is orphaned (harmless, small) |
| Manual send happened first | `clearAutoEmailRequest` already unstamps it, so the sweep never selects it; any orphaned R2 object ages out unused |

## Out of scope

- Job-photo R2 sync (separate plan).
- PDF attachments on SMS/text (decision from the 2026-07-29 PDF spec stands).
- Changing the manual-send PDF or the in-app template.
- The reminder-email path (`reminderEmail.js`) — untouched.
- Any lifecycle/TTL rule on the bucket beyond delete-after-send (orphaned
  objects are tiny; a bucket lifecycle rule can be added later if needed).
- Any new npm dependency or `app.json` change.

## Owner operations (not code)

1. `wrangler r2 bucket create tradeready-invoice-pdfs`
2. Deploy the Worker with the new `[[r2_buckets]]` binding.
3. (No new secret required — R2 access is via the binding.)

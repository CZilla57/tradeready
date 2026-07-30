# Invoice PDF Always Attached on Email Send

**Date:** 2026-07-29
**Status:** Design approved, not implemented

## Problem

When a tradesperson sends an invoice to a customer, the email carries only the
generated message text and a payment link. The PDF invoice exists — `invoiceHtml()`
in `utils/pdfTemplates.ts` renders it and `exportPdf()` in `utils/pdfExport.ts`
shares it — but it is reachable only as a separate, manual "Save PDF" action on the
Invoices screen. Customers who want a document for their records (or whose
bookkeeper requires one) don't get it unless the sender remembers a second,
unrelated step.

The invoice PDF should be attached to every emailed invoice, automatically.

## Current behavior

Send paths that reach the customer, all converging on one screen:

| Entry | Route | Sends via |
|---|---|---|
| Jobs → JobDetail (`invoiced`) → "View invoice & send outreach" | `JobDetailScreen.tsx:485` → `Outreach` | `OutreachScreen` |
| Jobs → CreateInvoiceFromJob → "Create invoice →" | `CreateInvoiceFromJobScreen.tsx:185` → `Outreach` | `OutreachScreen` |
| Invoices list → invoice modal → outreach | `InvoicesScreen.tsx:290` → `Outreach` | `OutreachScreen` |
| Customer detail → outreach | `CustomerStack` → `Outreach` | `OutreachScreen` |

`OutreachScreen.sendEmail()` (lines 173–180) calls `composeEmail({ recipients,
subject, body })`. `composeEmail` in `utils/messaging.ts` forwards exactly those
three fields to `MailComposer.composeAsync` — there is no attachment plumbing
anywhere in the app today.

## Decisions

Settled with the owner before design:

1. **Email only.** Text messages continue to send the body alone. SMS attachments
   convert the message to MMS and fail inconsistently across carriers and devices;
   the payment link already carries the actionable part.
2. **All entry points.** Any invoice email sent from `OutreachScreen` attaches the
   PDF, regardless of which tab the user came from. One behavior, no per-stack
   branching, and the same invoice never behaves differently depending on where it
   was tapped.
3. **PDF failure does not block the send.** On failure the user sees a brief alert
   and the composer still opens with the message and payment link. A rare PDF glitch
   must never stand between a tradesperson and getting paid.

## Design

### New — `utils/invoicePdfFile.ts`

```ts
buildInvoicePdfFile(invoice: Invoice, settings: Partial<Settings>): Promise<string | null>
```

Steps:

1. If `settings.logoPhoto` is set, read it with `readPhotoAsDataUri`. Best-effort:
   a logo that fails to read must still produce a PDF (logo omitted).
2. `invoiceHtml(invoice, settings, logoDataUri)` → `Print.printToFileAsync({ html })`.
3. `expo-print` writes to a random cache filename, which would become the attachment
   name in the customer's inbox. Copy the file to
   `${FileSystem.cacheDirectory}Invoice-<number>-<Customer>.pdf` so the customer sees
   a meaningful name. Filename segments are sanitized: runs of characters outside
   `[A-Za-z0-9]` collapse to a single `-`, leading/trailing `-` trimmed. Falls back
   to `invoice.id` when `invoice.number` is empty (matching the existing
   `handleExportPdf` filename logic in `InvoicesScreen.tsx:69`).
   Import is `expo-file-system/legacy`, matching `utils/photoStorage.ts`.
   Because the destination name is deterministic, re-sending the same invoice would
   copy onto an existing file — which `copyAsync` rejects on iOS — so the destination
   is cleared first with `deleteAsync(dest, { idempotent: true })`.
4. Returns the copied file's URI. On any throw: `reportError(err, { context:
   'invoicePdfAttachment' })` and return `null`. **No `Alert` inside the util** — the
   caller owns the UX decision, which is why this does not live in `pdfExport.ts`
   (that module swallows errors behind its own alert).

Reusing `invoiceHtml` + `readPhotoAsDataUri` unchanged means the emailed PDF and the
"Save PDF" PDF cannot drift apart.

### Changed — `utils/messaging.ts`

`EmailOptions` gains an optional field:

```ts
type EmailOptions = {
  recipients: string[];
  subject: string;
  body: string;
  attachments?: string[];   // file URIs
};
```

`composeEmail` spreads `attachments` into `MailComposer.composeAsync` **only when
present**, so the call shape for existing callers (`SendEstimateScreen`,
`PricingCalculatorScreen`) is byte-identical and their behavior is unchanged.

### Changed — `screens/OutreachScreen.tsx`

New state `preparingPdf: boolean`. `sendEmail()` becomes:

1. `setPreparingPdf(true)`
2. `const uri = await buildInvoicePdfFile(invoice, settings)`
3. `setPreparingPdf(false)`
4. If `uri === null`: `Alert.alert("PDF not attached", "Couldn't attach the invoice
   PDF. The message is ready to send without it.")`
5. `composeEmail({ recipients: [invoice.email], subject: subject || \`Payment
   reminder: ${invoice.number}\`, body: message, attachments: uri ? [uri] : undefined })`

The "Open in Mail" `Button` receives `loading={preparingPdf}`. The shared `Button`
(`components/UI.tsx:55`) already renders an `ActivityIndicator` and sets
`disabled` + `accessibilityState.busy` when `loading` is true, so the ~1s print
reads as progress rather than a frozen tap, and double-taps can't fire two prints.

`sendSMS` is untouched.

## Edge cases

| Case | Behavior |
|---|---|
| PDF generation fails | Alert, then open Mail without the attachment (decision 3) |
| Logo file missing/corrupt | PDF renders without a logo; send proceeds normally |
| Mail app not set up | `composeEmail`'s existing "Mail not available" alert; unchanged |
| Invoice already paid | No send UI is rendered for paid invoices; nothing to do |
| Customer name with spaces or `/` | Sanitized in the filename |
| Empty invoice number | Filename falls back to `invoice.id` |
| Same invoice emailed twice | Destination file is deleted (`idempotent`) before the copy, so the second send re-uses the same name without erroring |
| Cache growth | Files land in the OS-reclaimable cache directory with no cleanup code, matching how `exportPdf` already behaves |

## Testing

New suite `__tests__/invoicePdfFile.test.js`:

- happy path returns the renamed cache URI, and `invoiceHtml` receives the logo data URI
- logo read failure still yields a PDF (no logo passed, no throw)
- `printToFileAsync` rejection → returns `null` and calls `reportError`
- `copyAsync` rejection → returns `null`
- filename sanitizing: spaces, slashes, and an empty `number` falling back to `id`

Extended `__tests__/messaging.test.js`:

- `attachments` reaches `composeAsync` when provided
- the `composeAsync` payload contains no `attachments` key when not provided
  (guards the existing callers)

**Test-infra change:** `jest.setup.js`'s `expo-file-system/legacy` mock currently
lacks `copyAsync`; add `copyAsync: jest.fn(() => Promise.resolve())` to it. Mocks for
`expo-print` and `expo-mail-composer` already exist and need no changes.

Gate (`npm run typecheck`, `npm test`, `npm run lint`) must be green before any
commit, per change-control Rule 2.

## Out of scope

Deliberately excluded, flagged rather than folded in:

- PDF attachments on text messages (decision 1)
- Any new analytics event
- Changes to the generated message copy
- Any dependency or `app.json` change — `expo-print`, `expo-file-system`,
  `expo-mail-composer` are all already installed, so change-control Rule 3 is not
  engaged
- Marking the invoice "sent" or recording send history

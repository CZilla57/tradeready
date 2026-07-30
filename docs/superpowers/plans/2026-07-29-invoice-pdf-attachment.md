# Invoice PDF Attachment Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Every invoice emailed to a customer from the Outreach screen carries the invoice PDF as an attachment.

**Architecture:** A new typed util (`utils/invoicePdfFile.ts`) renders the existing `invoiceHtml` template to a PDF file in the cache directory under a customer-facing filename and returns its URI, or `null` on failure without alerting. `utils/messaging.ts`'s `composeEmail` gains an optional `attachments` passthrough to `MailComposer.composeAsync`. `OutreachScreen.sendEmail` builds the PDF, warns if it failed, and composes either way.

**Tech Stack:** Expo 54 / React Native 0.81 / React 19 / TypeScript (strict) / Jest via jest-expo. Uses already-installed `expo-print`, `expo-file-system` (legacy API), `expo-mail-composer`.

**Spec:** `docs/superpowers/specs/2026-07-29-invoice-pdf-attachment-design.md`

## Global Constraints

- **No dependency, `package.json`, `app.json`, or Expo SDK changes.** `expo-print`, `expo-file-system`, and `expo-mail-composer` are already installed. (Change-control Rule 3.)
- **No persisted data-shape changes.** No new fields on `Invoice`/`Settings`, no new AsyncStorage keys.
- **Gate must be green before every commit**, run from `C:\Users\Chadr\OneDrive\Documents\TraderPro App\tradeready\`: `npm run typecheck` → 0 errors, `npm test` → all pass, `npm run lint` → 0 warnings. (Change-control Rule 2.)
- **No `eslint-disable`, `@ts-ignore`, or `@ts-expect-error`.**
- **Email only.** Do not touch `sendSMS` or add SMS attachments.
- **Behavior on PDF failure:** alert, then open the mail composer anyway. Never block the send.
- **Alert copy, verbatim:** title `"PDF not attached"`, body `"Couldn't attach the invoice PDF. The message is ready to send without it."`
- **Filename format, verbatim:** `Invoice-<number-or-id>-<Customer>.pdf`, each segment sanitized so runs of non-alphanumerics become a single `-` with leading/trailing `-` trimmed.
- **Repo:** git repo root is `tradeready/`, branch `master`, HEAD `9f8e17b`. Run all commands from `tradeready/`.
- **Commit style:** imperative subject, optional `feat:`/`fix:`/`chore:` prefix, one coherent change per commit.
- **Existing `composeEmail` callers must not change behavior:** `SendEstimateScreen` and `PricingCalculatorScreen` call it without attachments, and the `composeAsync` payload for those calls must stay free of an `attachments` key.

---

### Task 1: `buildInvoicePdfFile` util

Renders an invoice to a PDF file with a customer-facing filename. Owns no UX — returns `null` on failure so the caller decides what to do.

**Files:**
- Create: `utils/invoicePdfFile.ts`
- Create: `__tests__/invoicePdfFile.test.js`
- Modify: `jest.setup.js:37-44` (add `copyAsync` to the `expo-file-system/legacy` mock)

**Interfaces:**
- Consumes: `invoiceHtml(invoice, biz, logoDataUri?)` from `utils/pdfTemplates.ts:133`; `readPhotoAsDataUri(uri): Promise<string | null>` from `utils/photoStorage.ts:23`; `reportError(err, context?)` from `utils/analytics.ts:41`.
- Produces:
  - `buildInvoicePdfFile(invoice: Invoice, settings?: Partial<Settings>): Promise<string | null>` — resolves to a `file://` URI, or `null` on any failure.
  - `invoicePdfFilename(invoice: Invoice): string` — e.g. `Invoice-INV-0001-Jane-Smith.pdf`.

- [ ] **Step 1: Add `copyAsync` to the file-system mock**

The `expo-file-system/legacy` mock in `jest.setup.js` currently has no `copyAsync`, so the util under test would call `undefined`. Change the existing block at `jest.setup.js:37-44` to:

```js
jest.mock("expo-file-system/legacy", () => ({
  documentDirectory: "file:///mock/",
  cacheDirectory: "file:///mock/cache/",
  readAsStringAsync: jest.fn(() => Promise.resolve("")),
  writeAsStringAsync: jest.fn(() => Promise.resolve()),
  copyAsync: jest.fn(() => Promise.resolve()),
  deleteAsync: jest.fn(() => Promise.resolve()),
  getInfoAsync: jest.fn(() => Promise.resolve({ exists: false })),
}));
```

Only `copyAsync` is added; leave every other key exactly as it was.

- [ ] **Step 2: Write the failing test**

Create `__tests__/invoicePdfFile.test.js`:

```js
import * as Print from "expo-print";
import * as FileSystem from "expo-file-system/legacy";
import { readPhotoAsDataUri } from "../utils/photoStorage";
import { invoiceHtml } from "../utils/pdfTemplates";
import { reportError } from "../utils/analytics";
import { buildInvoicePdfFile, invoicePdfFilename } from "../utils/invoicePdfFile";

// photoStorage's real readPhotoAsDataUri touches FileSystem.EncodingType (absent
// from the jest mock) and would always return null; mock it so the logo path is
// actually observable.
jest.mock("../utils/photoStorage", () => ({
  readPhotoAsDataUri: jest.fn(() => Promise.resolve(null)),
}));
jest.mock("../utils/pdfTemplates", () => ({
  invoiceHtml: jest.fn(() => "<html>invoice</html>"),
}));
jest.mock("../utils/analytics", () => ({
  reportError: jest.fn(),
  track: jest.fn(),
}));

const invoice = {
  id: "inv1700000000000",
  number: "INV-0001",
  customer: "Jane Smith",
  customerId: "cust1",
  amount: 500,
  due: "2026-08-01",
  email: "jane@example.com",
  phone: "5551234567",
  desc: "Water heater replacement",
  paid: false,
};

describe("invoicePdfFilename", () => {
  test("builds Invoice-<number>-<Customer>.pdf", () => {
    expect(invoicePdfFilename(invoice)).toBe("Invoice-INV-0001-Jane-Smith.pdf");
  });

  test("collapses runs of non-alphanumerics and trims stray dashes", () => {
    expect(invoicePdfFilename({ ...invoice, customer: "Smith & Co. / West" }))
      .toBe("Invoice-INV-0001-Smith-Co-West.pdf");
  });

  test("falls back to the invoice id when the number is empty", () => {
    expect(invoicePdfFilename({ ...invoice, number: "" }))
      .toBe("Invoice-inv1700000000000-Jane-Smith.pdf");
  });

  test("omits the customer segment when there is no customer name", () => {
    expect(invoicePdfFilename({ ...invoice, customer: "" }))
      .toBe("Invoice-INV-0001.pdf");
  });
});

describe("buildInvoicePdfFile", () => {
  beforeEach(() => jest.clearAllMocks());

  test("prints the invoice html and returns the renamed cache uri", async () => {
    const uri = await buildInvoicePdfFile(invoice, {});
    expect(Print.printToFileAsync).toHaveBeenCalledWith({ html: "<html>invoice</html>" });
    expect(FileSystem.copyAsync).toHaveBeenCalledWith({
      from: "file:///mock/print.pdf",
      to: "file:///mock/cache/Invoice-INV-0001-Jane-Smith.pdf",
    });
    expect(uri).toBe("file:///mock/cache/Invoice-INV-0001-Jane-Smith.pdf");
  });

  test("clears any previous file at the destination before copying", async () => {
    await buildInvoicePdfFile(invoice, {});
    expect(FileSystem.deleteAsync).toHaveBeenCalledWith(
      "file:///mock/cache/Invoice-INV-0001-Jane-Smith.pdf",
      { idempotent: true }
    );
  });

  test("passes the logo data uri into the template when a logo is set", async () => {
    readPhotoAsDataUri.mockResolvedValueOnce("data:image/png;base64,AAA");
    await buildInvoicePdfFile(invoice, { logoPhoto: "file:///mock/logo.png" });
    expect(readPhotoAsDataUri).toHaveBeenCalledWith("file:///mock/logo.png");
    expect(invoiceHtml).toHaveBeenCalledWith(
      invoice,
      { logoPhoto: "file:///mock/logo.png" },
      "data:image/png;base64,AAA"
    );
  });

  test("renders without a logo when none is set", async () => {
    await buildInvoicePdfFile(invoice, {});
    expect(readPhotoAsDataUri).not.toHaveBeenCalled();
    expect(invoiceHtml).toHaveBeenCalledWith(invoice, {}, undefined);
  });

  test("renders without a logo when the logo file can't be read", async () => {
    readPhotoAsDataUri.mockResolvedValueOnce(null);
    const uri = await buildInvoicePdfFile(invoice, { logoPhoto: "file:///mock/gone.png" });
    expect(invoiceHtml).toHaveBeenCalledWith(
      invoice,
      { logoPhoto: "file:///mock/gone.png" },
      undefined
    );
    expect(uri).toBe("file:///mock/cache/Invoice-INV-0001-Jane-Smith.pdf");
  });

  test("returns null and reports when printing fails", async () => {
    Print.printToFileAsync.mockRejectedValueOnce(new Error("no space"));
    const uri = await buildInvoicePdfFile(invoice, {});
    expect(uri).toBeNull();
    expect(reportError).toHaveBeenCalledWith(expect.any(Error), {
      context: "invoicePdfAttachment",
    });
  });

  test("returns null when the copy fails", async () => {
    FileSystem.copyAsync.mockRejectedValueOnce(new Error("denied"));
    const uri = await buildInvoicePdfFile(invoice, {});
    expect(uri).toBeNull();
    expect(reportError).toHaveBeenCalledWith(expect.any(Error), {
      context: "invoicePdfAttachment",
    });
  });
});
```

- [ ] **Step 3: Run the test to verify it fails**

```bash
npx jest __tests__/invoicePdfFile.test.js
```

Expected: FAIL — `Cannot find module '../utils/invoicePdfFile'`.

- [ ] **Step 4: Write the implementation**

Create `utils/invoicePdfFile.ts`:

```ts
// utils/invoicePdfFile.ts
// Renders an invoice to a PDF file on disk so it can be attached to an email.
//
// Deliberately separate from utils/pdfExport.ts: that module owns the share-sheet
// path and shows its own alerts, which is the wrong contract for a caller that
// needs to decide whether to proceed. This one reports and returns null.

import * as Print from "expo-print";
import * as FileSystem from "expo-file-system/legacy";
import { invoiceHtml } from "./pdfTemplates";
import { readPhotoAsDataUri } from "./photoStorage";
import { reportError } from "./analytics";
import type { Invoice, Settings } from "../types/models";

// "Smith & Co. / West" -> "Smith-Co-West"
function slug(value: string): string {
  return value.replace(/[^A-Za-z0-9]+/g, "-").replace(/^-+|-+$/g, "");
}

// The customer sees this name in their inbox, so it gets the invoice number and
// their own name rather than expo-print's random cache filename.
export function invoicePdfFilename(invoice: Invoice): string {
  const ref = slug(invoice.number || invoice.id);
  const who = slug(invoice.customer || "");
  return who ? `Invoice-${ref}-${who}.pdf` : `Invoice-${ref}.pdf`;
}

export async function buildInvoicePdfFile(
  invoice: Invoice,
  settings: Partial<Settings> = {}
): Promise<string | null> {
  try {
    const logoDataUri = settings.logoPhoto
      ? await readPhotoAsDataUri(settings.logoPhoto)
      : null;
    const html = invoiceHtml(invoice, settings, logoDataUri ?? undefined);
    const { uri } = await Print.printToFileAsync({ html });

    // Re-sending the same invoice would hit an existing destination file, which
    // copyAsync rejects on iOS — clear it first.
    const dest = `${FileSystem.cacheDirectory}${invoicePdfFilename(invoice)}`;
    await FileSystem.deleteAsync(dest, { idempotent: true });
    await FileSystem.copyAsync({ from: uri, to: dest });
    return dest;
  } catch (err: unknown) {
    reportError(err, { context: "invoicePdfAttachment" });
    return null;
  }
}
```

- [ ] **Step 5: Run the test to verify it passes**

```bash
npx jest __tests__/invoicePdfFile.test.js
```

Expected: PASS — 11 tests.

- [ ] **Step 6: Run the full gate**

```bash
npm run typecheck && npm test && npm run lint
```

Expected: `tsc` 0 errors; all suites pass (one suite and 11 tests more than the pre-task baseline); `0 problems`.

- [ ] **Step 7: Commit**

```bash
git add utils/invoicePdfFile.ts __tests__/invoicePdfFile.test.js jest.setup.js
git commit -m "feat: add buildInvoicePdfFile for emailable invoice PDFs"
```

---

### Task 2: `composeEmail` attachment passthrough

**Files:**
- Modify: `utils/messaging.ts:17-39`
- Modify: `__tests__/messaging.test.js` (add two tests to the existing `composeEmail` describe block)

**Interfaces:**
- Consumes: nothing from Task 1.
- Produces: `composeEmail({ recipients, subject, body, attachments? }: EmailOptions): Promise<boolean>` — `attachments` is `string[]` of file URIs, forwarded to `MailComposer.composeAsync` only when non-empty.

- [ ] **Step 1: Write the failing tests**

Add these two tests inside the existing `describe("composeEmail", ...)` block in `__tests__/messaging.test.js`, after the `"alerts and skips compose when Mail isn't set up"` test:

```js
  test("forwards attachments to the composer when provided", async () => {
    MailComposer.isAvailableAsync.mockResolvedValueOnce(true);
    await composeEmail({
      recipients: ["jane@example.com"],
      subject: "Invoice INV-0001",
      body: "Attached.",
      attachments: ["file:///mock/cache/Invoice-INV-0001-Jane-Smith.pdf"],
    });
    expect(MailComposer.composeAsync).toHaveBeenCalledWith({
      recipients: ["jane@example.com"],
      subject: "Invoice INV-0001",
      body: "Attached.",
      attachments: ["file:///mock/cache/Invoice-INV-0001-Jane-Smith.pdf"],
    });
  });

  test("sends no attachments key when none are given or the list is empty", async () => {
    MailComposer.isAvailableAsync.mockResolvedValueOnce(true);
    await composeEmail({ recipients: [], subject: "s", body: "b", attachments: [] });
    const payload = MailComposer.composeAsync.mock.calls[0][0];
    expect(Object.keys(payload)).toEqual(["recipients", "subject", "body"]);
  });
```

The second test guards the existing `SendEstimateScreen` / `PricingCalculatorScreen`
callers: their `composeAsync` payload must not grow an `attachments` key.

- [ ] **Step 2: Run the tests to verify they fail**

```bash
npx jest __tests__/messaging.test.js
```

Expected: FAIL — the first new test reports `composeAsync` called without `attachments`.

- [ ] **Step 3: Write the implementation**

In `utils/messaging.ts`, replace the `EmailOptions` type and `composeEmail` function (lines 17-39) with:

```ts
type EmailOptions = {
  recipients: string[];
  subject: string;
  body: string;
  /** File URIs to attach (e.g. an invoice PDF from utils/invoicePdfFile.ts). */
  attachments?: string[];
};

// Returns true if the mail composer opened, false if Mail isn't set up.
export async function composeEmail({
  recipients,
  subject,
  body,
  attachments,
}: EmailOptions): Promise<boolean> {
  const available = await MailComposer.isAvailableAsync();
  if (!available) {
    Alert.alert(
      "Mail not available",
      "Please set up the Mail app on this device first."
    );
    return false;
  }
  await MailComposer.composeAsync({
    recipients,
    subject,
    body,
    // Omit the key entirely when there's nothing to attach, so callers that
    // never attach keep their exact previous call shape.
    ...(attachments?.length ? { attachments } : {}),
  });
  return true;
}
```

Leave the file's header comment and `composeSMS` untouched.

- [ ] **Step 4: Run the tests to verify they pass**

```bash
npx jest __tests__/messaging.test.js
```

Expected: PASS — 6 tests.

- [ ] **Step 5: Run the full gate**

```bash
npm run typecheck && npm test && npm run lint
```

Expected: `tsc` 0 errors; all suites pass; `0 problems`.

- [ ] **Step 6: Commit**

```bash
git add utils/messaging.ts __tests__/messaging.test.js
git commit -m "feat: allow composeEmail to carry file attachments"
```

---

### Task 3: Attach the PDF on every invoice email

**Files:**
- Modify: `screens/OutreachScreen.tsx` — imports (~line 16), state (~line 60), `sendEmail` (lines 173-180), the "Open in Mail" `Button` (lines 363-367)

**Interfaces:**
- Consumes: `buildInvoicePdfFile(invoice, settings)` from Task 1; `composeEmail({ ..., attachments })` from Task 2; `Button`'s existing `loading?: boolean` prop (`components/UI.tsx:47-53`), which already renders a spinner and sets `disabled` + `accessibilityState.busy`.
- Produces: no new exports.

- [ ] **Step 1: Add the import**

In `screens/OutreachScreen.tsx`, immediately after the existing `invoiceHelpers` import (line 16), add:

```tsx
import { buildInvoicePdfFile } from "../utils/invoicePdfFile";
```

`Alert` is already imported (line 9); do not add it again.

- [ ] **Step 2: Add the state flag**

After the `const [copied, setCopied] = useState(false);` line (line 60), add:

```tsx
  const [preparingPdf, setPreparingPdf] = useState(false);
```

- [ ] **Step 3: Rewrite `sendEmail`**

Replace the whole `sendEmail` function (lines 173-180) with:

```tsx
  async function sendEmail() {
    if (!invoice) return;
    setPreparingPdf(true);
    const pdfUri = await buildInvoicePdfFile(invoice, settings ?? {});
    setPreparingPdf(false);
    if (!pdfUri) {
      Alert.alert(
        "PDF not attached",
        "Couldn't attach the invoice PDF. The message is ready to send without it."
      );
    }
    await composeEmail({
      recipients: [invoice.email],
      subject: subject || `Payment reminder: ${invoice.number}`,
      body: message,
      attachments: pdfUri ? [pdfUri] : undefined,
    });
  }
```

Do not touch `sendSMS` (lines 182-185).

- [ ] **Step 4: Show progress on the send button**

Replace the "Open in Mail" `Button` (lines 363-367) with:

```tsx
            <Button
              label={`Open in ${channel === "email" ? "Mail" : "Messages"}`}
              onPress={channel === "email" ? sendEmail : sendSMS}
              loading={channel === "email" && preparingPdf}
              style={{ marginBottom: spacing.sm }}
            />
```

Printing takes roughly a second; `loading` makes that read as progress and blocks a
double-tap from firing two prints. The `channel === "email"` guard keeps the Messages
button unaffected.

- [ ] **Step 5: Run the full gate**

```bash
npm run typecheck && npm test && npm run lint
```

Expected: `tsc` 0 errors; all suites pass; `0 problems`.

- [ ] **Step 6: Commit**

```bash
git add screens/OutreachScreen.tsx
git commit -m "feat: always attach the invoice PDF when emailing a customer"
```

- [ ] **Step 7: Report and STOP**

Per change-control Rule 1, write the phase report — Confidence Level / Missing
Context / Recommended Next Step — including the exact gate numbers, and stop for the
owner's go-ahead. Device verification is the expected next step: `expo-print`,
`expo-file-system`, and `expo-mail-composer` are all mocked in Jest, so the only
proof that a real PDF reaches a real Mail draft is a device run (Jobs → an
`invoiced` job → "View invoice & send outreach" → Email → "Open in Mail", confirming
the draft carries `Invoice-INV-XXXX-<Customer>.pdf`).

---

## Notes for the implementer

- Run every command from `C:\Users\Chadr\OneDrive\Documents\TraderPro App\tradeready\`. The path contains a space — quote it.
- The design spec is at `docs/superpowers/specs/2026-07-29-invoice-pdf-attachment-design.md`; read it if any decision here looks arbitrary.
- If the gate is red *before* you start, stop and report — do not build on a red gate, and do not commit a change that adds errors or warnings.
- Do not add analytics events, change the generated message copy, attach PDFs to text messages, or mark invoices as "sent". All four are explicitly out of scope.

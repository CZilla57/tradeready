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

// Blocklist, not an allowlist: only characters a filesystem rejects, or that change
// the meaning of the file:// URI this path gets embedded in, are replaced. An
// A-Za-z0-9 allowlist mangled ordinary customer names — "José Núñez" came out as
// "Jos-N-ez".
//   \ / : * ? " < > |  reserved on Windows; / on every platform
//   # %                significant once the path is parsed as a URI
//   whitespace         folded to dashes, as before
// Everything else survives, so accented and non-Latin names stay readable. Control
// codes are not covered: they can't come from the TextInput these names are typed
// into, and matching them would need an eslint-disable for no-control-regex.
const UNSAFE_IN_FILENAME = /[\\/:*?"<>|#%\s]+/g;

// "Smith & Co. / West" -> "Smith-&-Co.-West"; "José Núñez" -> "José-Núñez"
function slug(value: string): string {
  return value
    .replace(UNSAFE_IN_FILENAME, "-")
    // A literal dash beside a replaced run ("Smith - Jones") would double up.
    .replace(/-{2,}/g, "-")
    .replace(/^-+|-+$/g, "");
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
    await FileSystem.deleteAsync(dest, { idempotent: true }).catch(() => {});
    await FileSystem.copyAsync({ from: uri, to: dest });
    return dest;
  } catch (err: unknown) {
    reportError(err, { context: "invoicePdfAttachment" });
    return null;
  }
}

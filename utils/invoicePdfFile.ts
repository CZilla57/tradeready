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

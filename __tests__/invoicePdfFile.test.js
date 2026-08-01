import * as Print from "expo-print";
import * as FileSystem from "expo-file-system/legacy";
import { readLogoForPdf } from "../utils/photoStorage";
import { invoiceHtml } from "../utils/pdfTemplates";
import { reportError } from "../utils/analytics";
import { buildInvoicePdfFile, invoicePdfFilename } from "../utils/invoicePdfFile";

// photoStorage's real readLogoForPdf drives expo-image-manipulator and the
// filesystem; mock it so the logo path is actually observable.
jest.mock("../utils/photoStorage", () => ({
  readLogoForPdf: jest.fn(() => Promise.resolve(null)),
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

  test("replaces path-hostile characters and collapses the runs they leave", () => {
    // `/` is replaced, `&` and `.` are legal in a filename and survive.
    expect(invoicePdfFilename({ ...invoice, customer: "Smith & Co. / West" }))
      .toBe("Invoice-INV-0001-Smith-&-Co.-West.pdf");
  });

  test("keeps accented and non-Latin names readable", () => {
    expect(invoicePdfFilename({ ...invoice, customer: "José Núñez" }))
      .toBe("Invoice-INV-0001-José-Núñez.pdf");
    expect(invoicePdfFilename({ ...invoice, customer: "Müller Bau" }))
      .toBe("Invoice-INV-0001-Müller-Bau.pdf");
  });

  test("replaces every character a filesystem or file:// URI would reject", () => {
    expect(invoicePdfFilename({ ...invoice, customer: 'a\\b/c:d*e?f"g<h>i|j#k%l' }))
      .toBe("Invoice-INV-0001-a-b-c-d-e-f-g-h-i-j-k-l.pdf");
  });

  test("does not double up dashes around a literal dash", () => {
    expect(invoicePdfFilename({ ...invoice, customer: "Smith - Jones" }))
      .toBe("Invoice-INV-0001-Smith-Jones.pdf");
  });

  test("trims leading and trailing dashes from a replaced edge", () => {
    expect(invoicePdfFilename({ ...invoice, customer: " /Smith/ " }))
      .toBe("Invoice-INV-0001-Smith.pdf");
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

  test("passes the capped logo data uri into the template when a logo is set", async () => {
    readLogoForPdf.mockResolvedValueOnce("data:image/png;base64,AAA");
    await buildInvoicePdfFile(invoice, { logoPhoto: "file:///mock/logo.png" });
    expect(readLogoForPdf).toHaveBeenCalledWith("file:///mock/logo.png");
    expect(invoiceHtml).toHaveBeenCalledWith(
      invoice,
      { logoPhoto: "file:///mock/logo.png" },
      "data:image/png;base64,AAA"
    );
  });

  test("renders without a logo when none is set", async () => {
    await buildInvoicePdfFile(invoice, {});
    expect(readLogoForPdf).not.toHaveBeenCalled();
    expect(invoiceHtml).toHaveBeenCalledWith(invoice, {}, undefined);
  });

  test("renders without a logo when the logo file can't be read", async () => {
    readLogoForPdf.mockResolvedValueOnce(null);
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

  test("still returns the pdf when only the pre-clear delete fails", async () => {
    FileSystem.deleteAsync.mockRejectedValueOnce(new Error("locked"));
    const uri = await buildInvoicePdfFile(invoice, {});
    expect(uri).toBe("file:///mock/cache/Invoice-INV-0001-Jane-Smith.pdf");
    expect(FileSystem.copyAsync).toHaveBeenCalled();
    expect(reportError).not.toHaveBeenCalled();
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

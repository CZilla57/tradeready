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

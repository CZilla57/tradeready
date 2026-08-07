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

// The repo's global AsyncStorage mock (jest.setup.js) does NOT persist —
// getItem always resolves null. Back it with an in-memory `store`, matching
// the pattern in autoInvoice.test.ts, so loadInvoices/loadSettings read the
// seeded data instead of falling back to sample defaults.
let store: Record<string, string> = {};

function seedInvoice() {
  store = {
    invoices: JSON.stringify([INVOICE]),
    settings: JSON.stringify({ businessName: "Smith" }),
  };
}

beforeEach(() => {
  jest.clearAllMocks();
  store = {};
  (AsyncStorage.getItem as jest.Mock).mockImplementation((k: string) =>
    Promise.resolve(store[k] ?? null)
  );
  (AsyncStorage.setItem as jest.Mock).mockImplementation((k: string, v: string) => {
    store[k] = v;
    return Promise.resolve();
  });
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

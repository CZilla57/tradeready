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

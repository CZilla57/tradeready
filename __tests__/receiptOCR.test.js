// __tests__/receiptOCR.test.js
// Receipt scanning: the pure parser/clamp table and the routing contract
// (user anthropicKey → generateMessage with image; keyless → backend
// receipt-extract with Supabase JWT; every failure → null, never throws).

jest.mock("../utils/anthropicMessage", () => ({
  generateMessage: jest.fn(),
}));
jest.mock("../utils/supabase", () => ({
  supabase: { auth: { getSession: jest.fn() } },
}));
jest.mock("../utils/storage/settings", () => ({
  loadSettings: jest.fn(),
}));

const { generateMessage } = require("../utils/anthropicMessage");
const { supabase } = require("../utils/supabase");
const { loadSettings } = require("../utils/storage/settings");
const {
  parseReceiptExtraction,
  splitDataUri,
  extractReceipt,
  buildReceiptPrompt,
  MAX_RECEIPT_BASE64_CHARS,
} = require("../utils/receiptOCR");

let originalFetch;

beforeEach(() => {
  jest.clearAllMocks();
  originalFetch = global.fetch;
  global.fetch = jest.fn();
});

afterEach(() => {
  global.fetch = originalFetch;
});

const VALID = {
  merchant: "Home Depot",
  amount: 84.17,
  date: "2026-07-18",
  category: "materials",
  confidence: "high",
};

const jpegUri = (base64 = "abc123") => `data:image/jpeg;base64,${base64}`;

describe("parseReceiptExtraction", () => {
  test("parses a valid full payload", () => {
    expect(parseReceiptExtraction(JSON.stringify(VALID))).toEqual(VALID);
  });

  test("finds the JSON object inside surrounding prose", () => {
    const text = `Here is what I found:\n${JSON.stringify(VALID)}\nHope that helps!`;
    expect(parseReceiptExtraction(text)).toEqual(VALID);
  });

  test("clamps an unknown category to null without sinking other fields", () => {
    const out = parseReceiptExtraction(
      JSON.stringify({ ...VALID, category: "groceries" })
    );
    expect(out).toEqual({ ...VALID, category: null });
  });

  test("rejects malformed and impossible dates independently", () => {
    expect(
      parseReceiptExtraction(JSON.stringify({ ...VALID, date: "07/18/2026" })).date
    ).toBeNull();
    expect(
      parseReceiptExtraction(JSON.stringify({ ...VALID, date: "2026-02-31" })).date
    ).toBeNull();
    expect(
      parseReceiptExtraction(JSON.stringify({ ...VALID, date: "2026-13-01" })).date
    ).toBeNull();
  });

  test("rejects zero, negative, and non-numeric amounts independently", () => {
    for (const amount of [0, -5, "84.17", null, Infinity]) {
      const out = parseReceiptExtraction(JSON.stringify({ ...VALID, amount }));
      expect(out.amount).toBeNull();
      expect(out.merchant).toBe("Home Depot");
    }
  });

  test("trims and caps the merchant name", () => {
    const long = "  " + "x".repeat(200) + "  ";
    const out = parseReceiptExtraction(JSON.stringify({ ...VALID, merchant: long }));
    expect(out.merchant).toBe("x".repeat(80));
  });

  test("defaults confidence to low unless explicitly high", () => {
    expect(
      parseReceiptExtraction(JSON.stringify({ ...VALID, confidence: "medium" })).confidence
    ).toBe("low");
    expect(
      parseReceiptExtraction(JSON.stringify({ ...VALID, confidence: undefined })).confidence
    ).toBe("low");
  });

  test("returns null when merchant, amount, and date are all unusable", () => {
    expect(
      parseReceiptExtraction(
        JSON.stringify({ merchant: "", amount: -1, date: "junk", category: "materials" })
      )
    ).toBeNull();
  });

  test("returns null for non-JSON and empty input", () => {
    expect(parseReceiptExtraction("I couldn't read this receipt.")).toBeNull();
    expect(parseReceiptExtraction("")).toBeNull();
    expect(parseReceiptExtraction("{not json}")).toBeNull();
  });
});

describe("splitDataUri", () => {
  test("splits jpeg and png data URIs", () => {
    expect(splitDataUri("data:image/jpeg;base64,AAAA")).toEqual({
      mediaType: "image/jpeg",
      base64: "AAAA",
    });
    expect(splitDataUri("data:image/png;base64,BBBB")).toEqual({
      mediaType: "image/png",
      base64: "BBBB",
    });
  });

  test("rejects unsupported types and non-data-URIs", () => {
    expect(splitDataUri("data:image/gif;base64,AAAA")).toBeNull();
    expect(splitDataUri("file:///photos/receipt.jpg")).toBeNull();
    expect(splitDataUri("")).toBeNull();
  });
});

describe("extractReceipt routing", () => {
  test("uses the user's Anthropic key with the image attached (backend untouched)", async () => {
    loadSettings.mockResolvedValue({ anthropicKey: "sk-ant-x" });
    generateMessage.mockResolvedValue(JSON.stringify(VALID));

    const out = await extractReceipt(jpegUri("IMGDATA"));

    expect(out).toEqual({ extraction: VALID, route: "user_key" });
    expect(generateMessage).toHaveBeenCalledWith(
      expect.objectContaining({
        prompt: buildReceiptPrompt(),
        apiKey: "sk-ant-x",
        max_tokens: 300,
        image: { base64: "IMGDATA", mediaType: "image/jpeg" },
      })
    );
    expect(global.fetch).not.toHaveBeenCalled();
  });

  test("returns null when the user-key path yields no text", async () => {
    loadSettings.mockResolvedValue({ anthropicKey: "sk-ant-x" });
    generateMessage.mockResolvedValue(""); // fallback fired inside the transport
    expect(await extractReceipt(jpegUri())).toBeNull();
  });

  test("routes keyless users to the backend with the Supabase JWT", async () => {
    loadSettings.mockResolvedValue({});
    supabase.auth.getSession.mockResolvedValue({
      data: { session: { access_token: "jwt-123" } },
    });
    global.fetch.mockResolvedValue({ ok: true, json: async () => VALID });

    const out = await extractReceipt(jpegUri("IMGDATA"));

    expect(out).toEqual({ extraction: VALID, route: "backend" });
    const [url, init] = global.fetch.mock.calls[0];
    expect(url).toBe("https://backend-tradeready1.vercel.app/api/receipt-extract");
    expect(init.headers.Authorization).toBe("Bearer jwt-123");
    expect(JSON.parse(init.body)).toEqual({
      imageBase64: "IMGDATA",
      mediaType: "image/jpeg",
    });
    expect(generateMessage).not.toHaveBeenCalled();
  });

  test("returns null on a backend error status", async () => {
    loadSettings.mockResolvedValue({});
    supabase.auth.getSession.mockResolvedValue({
      data: { session: { access_token: "jwt-123" } },
    });
    global.fetch.mockResolvedValue({ ok: false, status: 429, json: async () => ({}) });
    expect(await extractReceipt(jpegUri())).toBeNull();
  });

  test("returns null without a network call when there is no session", async () => {
    loadSettings.mockResolvedValue({});
    supabase.auth.getSession.mockResolvedValue({ data: { session: null } });
    expect(await extractReceipt(jpegUri())).toBeNull();
    expect(global.fetch).not.toHaveBeenCalled();
  });

  test("rejects oversize images locally — no settings read, no network", async () => {
    const big = "a".repeat(MAX_RECEIPT_BASE64_CHARS + 1);
    expect(await extractReceipt(jpegUri(big))).toBeNull();
    expect(loadSettings).not.toHaveBeenCalled();
    expect(global.fetch).not.toHaveBeenCalled();
    expect(generateMessage).not.toHaveBeenCalled();
  });

  test("rejects non-image and unsupported URIs locally", async () => {
    expect(await extractReceipt("file:///photos/receipt.jpg")).toBeNull();
    expect(await extractReceipt("data:image/gif;base64,AAAA")).toBeNull();
    expect(loadSettings).not.toHaveBeenCalled();
  });

  test("never throws — settings loader blowing up yields null", async () => {
    loadSettings.mockRejectedValue(new Error("storage exploded"));
    await expect(extractReceipt(jpegUri())).resolves.toBeNull();
  });

  test("never throws — backend fetch rejection yields null", async () => {
    loadSettings.mockResolvedValue({});
    supabase.auth.getSession.mockResolvedValue({
      data: { session: { access_token: "jwt-123" } },
    });
    global.fetch.mockRejectedValue(new Error("network down"));
    await expect(extractReceipt(jpegUri())).resolves.toBeNull();
  });
});

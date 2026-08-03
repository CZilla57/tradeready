// __tests__/aiUsageCap.test.js
// Tests for the durable per-user daily AI usage cap (security roadmap item 8):
// backend/lib/aiUsage.js and its wiring into the three AI proxy endpoints.
//
// Key invariants under test:
//   - Under cap → request allowed AND a usage row insert is attempted.
//   - At/over cap (cleanly read count >= cap) → hard block, 429 shape.
//   - Counter infrastructure failure (fetch rejects, non-2xx, unparseable
//     count) → FAIL OPEN: request allowed, console.warn emitted.
//   - Each endpoint (ai-chat, pricebook-suggest, receipt-extract) actually
//     calls enforceDailyCap with the authenticated user id and its own
//     endpoint name, and returns the 429 without calling the AI provider
//     when blocked.
//
// All keys/ids below are deliberately low-entropy fakes (gitleaks-safe).

// Backend endpoint modules read env at require time — set fakes before any
// require of backend files (same reason the backend itself validates these).
process.env.GROQ_API_KEY = "test-groq-key";
process.env.SUPABASE_URL = "https://unit-test-supabase.example";
process.env.SUPABASE_ANON_KEY = "test-anon-key";
process.env.SUPABASE_SERVICE_ROLE_KEY = "test-service-role-key";

// The endpoints get a mocked enforceDailyCap (wiring tests); the unit tests
// use the real implementation via jest.requireActual.
jest.mock("../backend/lib/aiUsage", () => {
  const actual = jest.requireActual("../backend/lib/aiUsage");
  return { ...actual, enforceDailyCap: jest.fn() };
});

const mockedAiUsage = require("../backend/lib/aiUsage");
const realAiUsage = jest.requireActual("../backend/lib/aiUsage");
const { DAILY_CAPS, DAILY_CAP_MESSAGE } = realAiUsage;

const aiChatHandler = require("../backend/api/ai-chat");
const pricebookHandler = require("../backend/api/pricebook-suggest");
const receiptHandler = require("../backend/api/receipt-extract");

let originalFetch;
let warnSpy;

beforeEach(() => {
  originalFetch = global.fetch;
  global.fetch = jest.fn();
  warnSpy = jest.spyOn(console, "warn").mockImplementation(() => {});
});

afterEach(() => {
  global.fetch = originalFetch;
  warnSpy.mockRestore();
});

// ---- helpers -------------------------------------------------------------

// PostgREST count response: HEAD with Prefer: count=exact reports the total
// after the slash in Content-Range ("0-0/42", or "*/0" when no rows).
function countResponse(contentRange) {
  return {
    ok: true,
    headers: { get: (name) => (name.toLowerCase() === "content-range" ? contentRange : null) },
  };
}

const insertOk = { ok: true, headers: { get: () => null } };

function mockRes() {
  const res = { statusCode: null, body: null };
  res.setHeader = jest.fn();
  res.status = jest.fn((code) => {
    res.statusCode = code;
    return res;
  });
  res.json = jest.fn((body) => {
    res.body = body;
    return res;
  });
  res.end = jest.fn(() => res);
  return res;
}

function mockReq(body) {
  return {
    method: "POST",
    headers: { authorization: "Bearer fake-user-jwt" },
    body,
  };
}

function authResponse(userId) {
  return { ok: true, json: async () => ({ id: userId }) };
}

function groqTextResponse(content) {
  return { ok: true, json: async () => ({ choices: [{ message: { content } }] }) };
}

// ---- enforceDailyCap unit tests (real implementation) --------------------

describe("enforceDailyCap — real implementation", () => {
  const enforce = realAiUsage.enforceDailyCap;

  test("under cap: allows and attempts to insert one usage row", async () => {
    global.fetch
      .mockResolvedValueOnce(countResponse("0-0/5"))
      .mockResolvedValueOnce(insertOk);

    const result = await enforce("fake-user-1", "ai-chat");
    expect(result).toEqual({ allowed: true });
    expect(global.fetch).toHaveBeenCalledTimes(2);

    // Count query: HEAD, scoped to user + endpoint + today's UTC window.
    const [countUrl, countOpts] = global.fetch.mock.calls[0];
    expect(countOpts.method).toBe("HEAD");
    expect(countUrl).toContain("/rest/v1/ai_usage_log");
    expect(countUrl).toContain("user_id=eq.fake-user-1");
    expect(countUrl).toContain("endpoint=eq.ai-chat");
    const dayStart = new Date();
    dayStart.setUTCHours(0, 0, 0, 0);
    expect(decodeURIComponent(countUrl)).toContain(`created_at=gte.${dayStart.toISOString()}`);
    expect(countOpts.headers.Prefer).toBe("count=exact");
    expect(countOpts.headers.Authorization).toBe("Bearer test-service-role-key");

    // Insert: POST one row for this user + endpoint.
    const [insertUrl, insertOpts] = global.fetch.mock.calls[1];
    expect(insertUrl).toContain("/rest/v1/ai_usage_log");
    expect(insertOpts.method).toBe("POST");
    expect(JSON.parse(insertOpts.body)).toEqual({ user_id: "fake-user-1", endpoint: "ai-chat" });
    expect(warnSpy).not.toHaveBeenCalled();
  });

  test("no rows yet: PostgREST '*/0' counts as zero and allows", async () => {
    global.fetch
      .mockResolvedValueOnce(countResponse("*/0"))
      .mockResolvedValueOnce(insertOk);

    const result = await enforce("fake-user-2", "receipt-extract");
    expect(result).toEqual({ allowed: true });
    expect(global.fetch).toHaveBeenCalledTimes(2);
  });

  test("at exactly the cap: blocks with the shared message, no insert", async () => {
    global.fetch.mockResolvedValueOnce(countResponse(`0-0/${DAILY_CAPS["ai-chat"]}`));

    const result = await enforce("fake-user-3", "ai-chat");
    expect(result).toEqual({ allowed: false, error: DAILY_CAP_MESSAGE });
    expect(global.fetch).toHaveBeenCalledTimes(1); // count only — over-cap requests are not recorded
  });

  test("over the cap: blocks", async () => {
    global.fetch.mockResolvedValueOnce(countResponse(`0-0/${DAILY_CAPS["pricebook-suggest"] + 50}`));

    const result = await enforce("fake-user-4", "pricebook-suggest");
    expect(result).toEqual({ allowed: false, error: DAILY_CAP_MESSAGE });
  });

  test("fail-open: count request rejects (network) → allowed with warning", async () => {
    global.fetch.mockRejectedValueOnce(new Error("connect timeout"));

    const result = await enforce("fake-user-5", "ai-chat");
    expect(result).toEqual({ allowed: true });
    expect(global.fetch).toHaveBeenCalledTimes(1); // no insert after a failed read
    expect(warnSpy).toHaveBeenCalled();
  });

  test("fail-open: count request returns 500 → allowed with warning", async () => {
    global.fetch.mockResolvedValueOnce({ ok: false, status: 500, headers: { get: () => null } });

    const result = await enforce("fake-user-6", "ai-chat");
    expect(result).toEqual({ allowed: true });
    expect(warnSpy).toHaveBeenCalled();
  });

  test("fail-open: unparseable content-range → allowed with warning", async () => {
    global.fetch.mockResolvedValueOnce(countResponse("garbage"));

    const result = await enforce("fake-user-7", "ai-chat");
    expect(result).toEqual({ allowed: true });
    expect(warnSpy).toHaveBeenCalled();
  });

  test("insert failure never blocks: allowed with warning", async () => {
    global.fetch
      .mockResolvedValueOnce(countResponse("0-0/1"))
      .mockRejectedValueOnce(new Error("insert refused"));

    const result = await enforce("fake-user-8", "receipt-extract");
    expect(result).toEqual({ allowed: true });
    expect(warnSpy).toHaveBeenCalled();
  });

  test("unknown endpoint or missing user id: allowed without any network call", async () => {
    expect(await enforce("fake-user-9", "not-a-real-endpoint")).toEqual({ allowed: true });
    expect(await enforce(null, "ai-chat")).toEqual({ allowed: true });
    expect(global.fetch).not.toHaveBeenCalled();
  });

  test("fail-open: service env vars missing → allowed with warning, no network call", async () => {
    const savedUrl = process.env.SUPABASE_URL;
    delete process.env.SUPABASE_URL;
    try {
      const result = await enforce("fake-user-10", "ai-chat");
      expect(result).toEqual({ allowed: true });
      expect(global.fetch).not.toHaveBeenCalled();
      expect(warnSpy).toHaveBeenCalled();
    } finally {
      process.env.SUPABASE_URL = savedUrl;
    }
  });
});

// ---- endpoint wiring tests (helper mocked) -------------------------------

describe("endpoint wiring — each AI proxy enforces the daily cap", () => {
  beforeEach(() => {
    mockedAiUsage.enforceDailyCap.mockReset();
  });

  const CHAT_BODY = { messages: [{ role: "user", text: "hello" }] };
  const PRICEBOOK_BODY = { serviceName: "Faucet swap" };
  const RECEIPT_BODY = { imageBase64: "QUJDREVG", mediaType: "image/jpeg" };

  test("ai-chat calls enforceDailyCap(userId, 'ai-chat') and proceeds when allowed", async () => {
    mockedAiUsage.enforceDailyCap.mockResolvedValue({ allowed: true });
    global.fetch
      .mockResolvedValueOnce(authResponse("fake-user-chat-a"))
      .mockResolvedValueOnce(groqTextResponse("hi there"));

    const res = mockRes();
    await aiChatHandler(mockReq(CHAT_BODY), res);

    expect(mockedAiUsage.enforceDailyCap).toHaveBeenCalledWith("fake-user-chat-a", "ai-chat");
    expect(res.statusCode).toBe(200);
    expect(res.body).toEqual({ text: "hi there" });
  });

  test("ai-chat returns 429 and never calls the provider when the cap blocks", async () => {
    mockedAiUsage.enforceDailyCap.mockResolvedValue({ allowed: false, error: DAILY_CAP_MESSAGE });
    global.fetch.mockResolvedValueOnce(authResponse("fake-user-chat-b"));

    const res = mockRes();
    await aiChatHandler(mockReq(CHAT_BODY), res);

    expect(res.statusCode).toBe(429);
    expect(res.body).toEqual({ error: DAILY_CAP_MESSAGE });
    expect(global.fetch).toHaveBeenCalledTimes(1); // auth only — no Groq call
  });

  test("pricebook-suggest calls enforceDailyCap(userId, 'pricebook-suggest') and proceeds when allowed", async () => {
    mockedAiUsage.enforceDailyCap.mockResolvedValue({ allowed: true });
    global.fetch
      .mockResolvedValueOnce(authResponse("fake-user-pb-a"))
      .mockResolvedValueOnce(groqTextResponse('{"laborHours":{"suggested":2}}'));

    const res = mockRes();
    await pricebookHandler(mockReq(PRICEBOOK_BODY), res);

    expect(mockedAiUsage.enforceDailyCap).toHaveBeenCalledWith("fake-user-pb-a", "pricebook-suggest");
    expect(res.statusCode).toBe(200);
  });

  test("pricebook-suggest returns 429 and never calls the provider when the cap blocks", async () => {
    mockedAiUsage.enforceDailyCap.mockResolvedValue({ allowed: false, error: DAILY_CAP_MESSAGE });
    global.fetch.mockResolvedValueOnce(authResponse("fake-user-pb-b"));

    const res = mockRes();
    await pricebookHandler(mockReq(PRICEBOOK_BODY), res);

    expect(res.statusCode).toBe(429);
    expect(res.body).toEqual({ error: DAILY_CAP_MESSAGE });
    expect(global.fetch).toHaveBeenCalledTimes(1);
  });

  test("receipt-extract calls enforceDailyCap(userId, 'receipt-extract') and proceeds when allowed", async () => {
    mockedAiUsage.enforceDailyCap.mockResolvedValue({ allowed: true });
    global.fetch
      .mockResolvedValueOnce(authResponse("fake-user-rc-a"))
      .mockResolvedValueOnce(groqTextResponse('{"merchant":"Test Store"}'));

    const res = mockRes();
    await receiptHandler(mockReq(RECEIPT_BODY), res);

    expect(mockedAiUsage.enforceDailyCap).toHaveBeenCalledWith("fake-user-rc-a", "receipt-extract");
    expect(res.statusCode).toBe(200);
  });

  test("receipt-extract returns 429 and never calls the provider when the cap blocks", async () => {
    mockedAiUsage.enforceDailyCap.mockResolvedValue({ allowed: false, error: DAILY_CAP_MESSAGE });
    global.fetch.mockResolvedValueOnce(authResponse("fake-user-rc-b"));

    const res = mockRes();
    await receiptHandler(mockReq(RECEIPT_BODY), res);

    expect(res.statusCode).toBe(429);
    expect(res.body).toEqual({ error: DAILY_CAP_MESSAGE });
    expect(global.fetch).toHaveBeenCalledTimes(1);
  });
});

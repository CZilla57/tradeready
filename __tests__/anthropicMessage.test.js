// __tests__/anthropicMessage.test.js
// Tests for generateMessage — the single client-side Anthropic Messages API call
// shared by the estimate + outreach generators and the pricing calculator
// (jobs defect #2 dedup). Covers the four outcomes the callers rely on:
// no key, success, API error, empty content — every failure routes to fallback,
// and the call never throws.

import { generateMessage } from "../utils/anthropicMessage";

let originalFetch;

beforeEach(() => {
  originalFetch = global.fetch;
  global.fetch = jest.fn();
});

afterEach(() => {
  global.fetch = originalFetch;
});

const FALLBACK = "TEMPLATE";
const opts = (over = {}) => ({
  prompt: "Write an estimate.",
  apiKey: "sk-ant-test",
  max_tokens: 800,
  fallback: () => FALLBACK,
  ...over,
});

describe("generateMessage", () => {
  test("returns fallback without touching the network when no key", async () => {
    const result = await generateMessage(opts({ apiKey: "" }));
    expect(result).toBe(FALLBACK);
    expect(global.fetch).not.toHaveBeenCalled();
  });

  test("returns fallback for null/undefined key without a network call", async () => {
    expect(await generateMessage(opts({ apiKey: null }))).toBe(FALLBACK);
    expect(await generateMessage(opts({ apiKey: undefined }))).toBe(FALLBACK);
    expect(global.fetch).not.toHaveBeenCalled();
  });

  test("returns the concatenated content text on success", async () => {
    global.fetch.mockResolvedValue({
      json: async () => ({ content: [{ text: "Hello " }, { text: "world" }] }),
    });
    const result = await generateMessage(opts());
    expect(result).toBe("Hello world");
  });

  test("sends the prompt, model, version, and key correctly", async () => {
    global.fetch.mockResolvedValue({
      json: async () => ({ content: [{ text: "ok" }] }),
    });
    await generateMessage(opts({ prompt: "PROMPT", apiKey: "KEY", max_tokens: 1500 }));

    const [url, init] = global.fetch.mock.calls[0];
    expect(url).toBe("https://api.anthropic.com/v1/messages");
    expect(init.headers["x-api-key"]).toBe("KEY");
    expect(init.headers["anthropic-version"]).toBe("2023-06-01");
    const body = JSON.parse(init.body);
    expect(body.model).toBe("claude-sonnet-4-6");
    expect(body.max_tokens).toBe(1500);
    expect(body.messages).toEqual([{ role: "user", content: "PROMPT" }]);
  });

  test("falls back when the API returns an error object", async () => {
    global.fetch.mockResolvedValue({
      json: async () => ({ error: { message: "overloaded" } }),
    });
    expect(await generateMessage(opts())).toBe(FALLBACK);
  });

  test("falls back when the API returns a string error", async () => {
    global.fetch.mockResolvedValue({ json: async () => ({ error: "bad key" }) });
    expect(await generateMessage(opts())).toBe(FALLBACK);
  });

  test("falls back when content is empty or missing", async () => {
    global.fetch.mockResolvedValue({ json: async () => ({ content: [] }) });
    expect(await generateMessage(opts())).toBe(FALLBACK);

    global.fetch.mockResolvedValue({ json: async () => ({}) });
    expect(await generateMessage(opts())).toBe(FALLBACK);
  });

  test("falls back (never throws) when the network rejects", async () => {
    global.fetch.mockRejectedValue(new Error("network down"));
    await expect(generateMessage(opts())).resolves.toBe(FALLBACK);
  });
});

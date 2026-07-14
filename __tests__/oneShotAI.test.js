// Routing for one-shot AI generation: user's Anthropic key when present,
// otherwise the backend Groq proxy, otherwise the caller's template fallback.
// Mirrors generateMessage's contract — never throws.

jest.mock("../utils/anthropicMessage", () => ({
  generateMessage: jest.fn(),
}));
jest.mock("../utils/aiService", () => ({
  sendBackendGroqMessage: jest.fn(),
}));

const { generateMessage } = require("../utils/anthropicMessage");
const { sendBackendGroqMessage } = require("../utils/aiService");
const { generateOneShot } = require("../utils/oneShotAI");

beforeEach(() => jest.clearAllMocks());

describe("generateOneShot", () => {
  test("uses the user's Anthropic key when present (backend untouched)", async () => {
    generateMessage.mockResolvedValueOnce("claude text");
    const fallback = jest.fn(() => "template");
    const out = await generateOneShot({
      prompt: "p", apiKey: "sk-ant-x", max_tokens: 800, fallback,
    });
    expect(out).toBe("claude text");
    expect(generateMessage).toHaveBeenCalledWith({
      prompt: "p", apiKey: "sk-ant-x", max_tokens: 800, fallback,
    });
    expect(sendBackendGroqMessage).not.toHaveBeenCalled();
  });

  test("routes keyless calls to the backend proxy as a single user message", async () => {
    sendBackendGroqMessage.mockResolvedValueOnce("backend text");
    const out = await generateOneShot({
      prompt: "write it", apiKey: "", max_tokens: 800, fallback: () => "template",
    });
    expect(out).toBe("backend text");
    expect(sendBackendGroqMessage).toHaveBeenCalledWith({
      messages: [{ role: "user", text: "write it" }],
    });
    expect(generateMessage).not.toHaveBeenCalled();
  });

  test("falls back to the template when the backend throws", async () => {
    sendBackendGroqMessage.mockRejectedValueOnce(new Error("Sign in to use the AI assistant."));
    const out = await generateOneShot({
      prompt: "p", apiKey: undefined, max_tokens: 800, fallback: () => "template",
    });
    expect(out).toBe("template");
  });

  test("falls back to the template when the backend returns blank", async () => {
    sendBackendGroqMessage.mockResolvedValueOnce("   ");
    const out = await generateOneShot({
      prompt: "p", apiKey: "", max_tokens: 800, fallback: () => "template",
    });
    expect(out).toBe("template");
  });
});

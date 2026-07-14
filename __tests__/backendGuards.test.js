const {
  createRateLimiter,
  validateChatPayload,
  validatePricebookPayload,
  MAX_MESSAGES,
  MAX_MESSAGE_CHARS,
  MAX_SYSTEM_PROMPT_CHARS,
  MAX_FIELD_CHARS,
  MAX_MATERIALS,
} = require("../backend/lib/guards");

describe("createRateLimiter", () => {
  it("allows requests under the limit", () => {
    const allow = createRateLimiter({ limit: 3 });
    expect(allow("u1", 1000)).toBe(true);
    expect(allow("u1", 1001)).toBe(true);
    expect(allow("u1", 1002)).toBe(true);
  });

  it("blocks the request that exceeds the limit", () => {
    const allow = createRateLimiter({ limit: 2 });
    expect(allow("u1", 1000)).toBe(true);
    expect(allow("u1", 1001)).toBe(true);
    expect(allow("u1", 1002)).toBe(false);
  });

  it("tracks keys independently", () => {
    const allow = createRateLimiter({ limit: 1 });
    expect(allow("u1", 1000)).toBe(true);
    expect(allow("u2", 1001)).toBe(true);
    expect(allow("u1", 1002)).toBe(false);
    expect(allow("u2", 1003)).toBe(false);
  });

  it("frees capacity once old hits fall outside the window", () => {
    const allow = createRateLimiter({ limit: 2, windowMs: 1000 });
    expect(allow("u1", 1000)).toBe(true);
    expect(allow("u1", 1100)).toBe(true);
    expect(allow("u1", 1200)).toBe(false);
    // First hit (t=1000) ages out after t=2000.
    expect(allow("u1", 2101)).toBe(true);
  });
});

describe("validateChatPayload", () => {
  const msg = (text) => ({ role: "user", text });

  it("accepts a normal payload", () => {
    expect(validateChatPayload([msg("hello")], "be helpful")).toBeNull();
  });

  it("accepts a payload with no system prompt", () => {
    expect(validateChatPayload([msg("hello")], undefined)).toBeNull();
  });

  it("rejects a missing or empty messages array", () => {
    expect(validateChatPayload(undefined, "")).toBe("messages array is required.");
    expect(validateChatPayload([], "")).toBe("messages array is required.");
    expect(validateChatPayload("not an array", "")).toBe("messages array is required.");
  });

  it("rejects too many messages", () => {
    const messages = Array.from({ length: MAX_MESSAGES + 1 }, () => msg("hi"));
    expect(validateChatPayload(messages)).toMatch(/Too many messages/);
  });

  it("rejects an over-long message", () => {
    const messages = [msg("x".repeat(MAX_MESSAGE_CHARS + 1))];
    expect(validateChatPayload(messages)).toMatch(/Message too long/);
  });

  it("reads content when text is absent (backend accepts both shapes)", () => {
    const messages = [{ role: "user", content: "x".repeat(MAX_MESSAGE_CHARS + 1) }];
    expect(validateChatPayload(messages)).toMatch(/Message too long/);
    expect(validateChatPayload([{ role: "user", content: "ok" }])).toBeNull();
  });

  it("rejects an over-long system prompt", () => {
    const messages = [msg("hello")];
    expect(validateChatPayload(messages, "x".repeat(MAX_SYSTEM_PROMPT_CHARS + 1))).toMatch(
      /System prompt too long/
    );
  });

  it("rejects a non-string message body", () => {
    expect(validateChatPayload([{ role: "user", text: 42 }])).toMatch(/Message too long/);
  });
});

describe("validatePricebookPayload", () => {
  const base = { serviceName: "Water heater install" };

  it("accepts a minimal payload", () => {
    expect(validatePricebookPayload(base)).toBeNull();
  });

  it("accepts a full payload", () => {
    expect(
      validatePricebookPayload({
        ...base,
        description: "Replace 40gal unit",
        category: "Plumbing",
        trade: "plumber",
        region: "Ohio",
        materials: [{ name: "40gal heater", quantity: 1, unitCost: 450 }],
        laborHours: 3,
        laborRate: 85,
      })
    ).toBeNull();
  });

  it("rejects a missing serviceName", () => {
    expect(validatePricebookPayload({})).toBe("serviceName is required.");
    expect(validatePricebookPayload(undefined)).toBe("serviceName is required.");
  });

  it("rejects an over-long field", () => {
    expect(
      validatePricebookPayload({ ...base, description: "x".repeat(MAX_FIELD_CHARS + 1) })
    ).toMatch(/description too long/);
  });

  it("rejects too many materials", () => {
    const materials = Array.from({ length: MAX_MATERIALS + 1 }, (_, i) => ({ name: `m${i}` }));
    expect(validatePricebookPayload({ ...base, materials })).toMatch(/materials must be a list/);
  });

  it("rejects a non-array materials value", () => {
    expect(validatePricebookPayload({ ...base, materials: "nope" })).toMatch(
      /materials must be a list/
    );
  });

  it("rejects an over-long material name", () => {
    const materials = [{ name: "x".repeat(MAX_FIELD_CHARS + 1) }];
    expect(validatePricebookPayload({ ...base, materials })).toMatch(/material name too long/);
  });
});

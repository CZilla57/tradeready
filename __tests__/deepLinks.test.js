// __tests__/deepLinks.test.js
// Widget deep-link parsing (utils/deepLinks.ts): strict scheme/path matching —
// the URL arrives from outside the app and must be treated as untrusted input.

import { parseWidgetDeepLink, parsePendingOpenUrl } from "../utils/deepLinks";

describe("parseWidgetDeepLink", () => {
  test("parses a widget job link", () => {
    expect(parseWidgetDeepLink("tradeready://job/j1722_4")).toEqual({
      type: "job",
      jobId: "j1722_4",
    });
  });

  test("is case-insensitive on the scheme and trims whitespace", () => {
    expect(parseWidgetDeepLink(" TradeReady://job/abc ")).toEqual({
      type: "job",
      jobId: "abc",
    });
  });

  test("decodes percent-encoded ids", () => {
    expect(parseWidgetDeepLink("tradeready://job/a%2Bb")).toEqual({
      type: "job",
      jobId: "a+b",
    });
  });

  test.each([
    null,
    undefined,
    "",
    "tradeready://job/", // empty id
    "tradeready://job/a/b", // extra path segment
    "tradeready://job/a?x=1", // query string
    "tradeready://invoice/i1", // unknown host
    "otherapp://job/j1", // wrong scheme
    "https://gettradereadyapp.com/job/j1", // web URL
    "tradeready://job/%zz", // malformed percent-encoding
  ])("rejects %s", (url) => {
    expect(parseWidgetDeepLink(url)).toBeNull();
  });
});

// "On my way" links (widget button + Siri OnMyWayIntent, docs/widget-plan.md
// Phase 3-4) — same untrusted-input posture as the job link above.
describe("parseWidgetDeepLink — onmyway", () => {
  test("parses an on-my-way link", () => {
    expect(parseWidgetDeepLink("tradeready://onmyway/j1722_4")).toEqual({
      type: "onmyway",
      jobId: "j1722_4",
    });
  });

  test("is case-insensitive on the scheme and trims whitespace", () => {
    expect(parseWidgetDeepLink(" TradeReady://onmyway/abc ")).toEqual({
      type: "onmyway",
      jobId: "abc",
    });
  });

  test("decodes percent-encoded ids", () => {
    expect(parseWidgetDeepLink("tradeready://onmyway/a%2Bb")).toEqual({
      type: "onmyway",
      jobId: "a+b",
    });
  });

  test.each([
    "tradeready://onmyway/", // empty id
    "tradeready://onmyway/a/b", // extra path segment
    "tradeready://onmyway/a?x=1", // query string
    "otherapp://onmyway/j1", // wrong scheme
    "tradeready://onmyway/%zz", // malformed percent-encoding
  ])("rejects %s", (url) => {
    expect(parseWidgetDeepLink(url)).toBeNull();
  });
});

// The cold-launch stash the Siri on-my-way intent writes into the App Group
// container. Native-written, so the same "anything that fails a guard is
// dropped" discipline as the deep-link parser above — plus a freshness window,
// since the stash exists for the launch happening right now and must never
// hijack an unrelated one later.
describe("parsePendingOpenUrl", () => {
  const NOW = Date.parse("2026-08-03T18:00:00Z");
  const stash = (url, at) => JSON.stringify({ url, at });

  test("returns the url for a stash written moments ago", () => {
    const raw = stash("tradeready://onmyway/j1", "2026-08-03T17:59:58Z");
    expect(parsePendingOpenUrl(raw, NOW)).toBe("tradeready://onmyway/j1");
  });

  test("accepts a stash written exactly now", () => {
    const raw = stash("tradeready://onmyway/j1", "2026-08-03T18:00:00Z");
    expect(parsePendingOpenUrl(raw, NOW)).toBe("tradeready://onmyway/j1");
  });

  test("accepts fractional-second timestamps (the JS toISOString shape)", () => {
    const raw = stash("tradeready://onmyway/j1", "2026-08-03T17:59:30.512Z");
    expect(parsePendingOpenUrl(raw, NOW)).toBe("tradeready://onmyway/j1");
  });

  test("accepts a stash just inside the five-minute window", () => {
    const raw = stash("tradeready://onmyway/j1", "2026-08-03T17:55:01Z");
    expect(parsePendingOpenUrl(raw, NOW)).toBe("tradeready://onmyway/j1");
  });

  test("drops a stale stash past five minutes", () => {
    const raw = stash("tradeready://onmyway/j1", "2026-08-03T17:54:00Z");
    expect(parsePendingOpenUrl(raw, NOW)).toBeNull();
  });

  test("drops a stash dated in the future", () => {
    const raw = stash("tradeready://onmyway/j1", "2026-08-03T18:00:05Z");
    expect(parsePendingOpenUrl(raw, NOW)).toBeNull();
  });

  test.each([
    ["null input", null],
    ["empty string", ""],
    ["malformed JSON", "{not json"],
    ["a JSON array", '[{"url":"tradeready://onmyway/j1","at":"2026-08-03T18:00:00Z"}]'],
    ["a bare JSON string", '"tradeready://onmyway/j1"'],
    ["missing url", '{"at":"2026-08-03T18:00:00Z"}'],
    ["empty url", '{"url":"","at":"2026-08-03T18:00:00Z"}'],
    ["non-string url", '{"url":42,"at":"2026-08-03T18:00:00Z"}'],
    ["missing at", '{"url":"tradeready://onmyway/j1"}'],
    ["non-string at", '{"url":"tradeready://onmyway/j1","at":1754251200000}'],
    ["unparseable at", '{"url":"tradeready://onmyway/j1","at":"whenever"}'],
  ])("drops %s", (_label, raw) => {
    expect(parsePendingOpenUrl(raw, NOW)).toBeNull();
  });

  test("does not vet the url itself — that stays parseWidgetDeepLink's job", () => {
    const raw = stash("otherapp://evil", "2026-08-03T18:00:00Z");
    expect(parsePendingOpenUrl(raw, NOW)).toBe("otherapp://evil");
    expect(parseWidgetDeepLink(parsePendingOpenUrl(raw, NOW))).toBeNull();
  });
});

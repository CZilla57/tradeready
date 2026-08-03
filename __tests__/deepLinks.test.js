// __tests__/deepLinks.test.js
// Widget deep-link parsing (utils/deepLinks.ts): strict scheme/path matching —
// the URL arrives from outside the app and must be treated as untrusted input.

import { parseWidgetDeepLink } from "../utils/deepLinks";

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

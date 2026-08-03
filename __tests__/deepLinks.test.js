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

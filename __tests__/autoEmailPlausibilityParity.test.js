// __tests__/autoEmailPlausibilityParity.test.js
// ANTI-DRIFT GATE, mirrors jobDunningParity.test.js's pattern. Client
// (utils/autoInvoice.ts isPlausiblyEmailable) and backend
// (backend-workers/lib/selectInvoicesToRemind.js isPlausibleEmail) implement
// the same recipient-plausibility rule and cannot share code — backend-workers/
// is a separate CommonJS package. A divergence here would re-open the
// false-promise gap the client gate exists to close: the client would stamp
// an invoice for the backend's 15-min sweep to email, and the sweep would
// silently skip it forever.

import { isPlausiblyEmailable } from "../utils/autoInvoice";

const backend = require("../backend-workers/lib/selectInvoicesToRemind");

const VECTORS = [
  "jane@example.com",
  "a@b.co",
  "user+tag@sub.domain.org",
  "",
  "no-at-sign",
  "a@b",
  "jane@example",
  "a@b.c, c@d.e",
  "a@b.c;d@e.f",
  "a@b.c\r\nBcc: x@y.z",
  '"quoted"@host.com',
  "spaces in@local.part",
  "x@y.",
  "a".repeat(250) + "@b.c",
];

describe.each(VECTORS)("email %j", (email) => {
  test("app implementation", () => {
    expect(typeof isPlausiblyEmailable(email)).toBe("boolean");
  });

  test("backend implementation", () => {
    expect(typeof backend.isPlausibleEmail(email)).toBe("boolean");
  });

  test("the two implementations agree with each other", () => {
    expect(isPlausiblyEmailable(email)).toBe(backend.isPlausibleEmail(email));
  });
});

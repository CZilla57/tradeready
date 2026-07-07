// __tests__/paymentLink.test.js
// Tests for resolvePaymentLink and fetchPaymentLink — the utilities used by
// OutreachScreen to decide whether to return a cached payment URL or fetch a
// new one from the backend.
//
// Key security invariants under test:
//   - The request body must NEVER contain a stripeKey field (sk_... stays on server).
//   - Stripe requests authenticate via the Supabase session JWT (Connect flow).
//   - Cached links are returned without any network call.

// Mock the Supabase client so fetchPaymentLink can retrieve a test JWT without
// hitting the real auth server.
const TEST_JWT = "test-supabase-jwt-xyz";
jest.mock("../utils/supabase", () => ({
  supabase: {
    auth: {
      getSession: jest.fn().mockResolvedValue({
        data: { session: { access_token: TEST_JWT } },
      }),
    },
  },
}));

import { buildPaymentLink, resolvePaymentLink, fetchPaymentLink } from "../utils/invoiceHelpers";

const INVOICE = {
  id: "inv1",
  number: "INV-001",
  desc: "Plumbing repair",
  amount: 350,
  email: "customer@example.com",
  customer: "Jane Smith",
};

let originalFetch;

beforeEach(() => {
  originalFetch = global.fetch;
  global.fetch = jest.fn();
});

afterEach(() => {
  global.fetch = originalFetch;
});

describe("buildPaymentLink — Venmo", () => {
  const inv = { number: "INV-042", desc: "Deck repair", amount: 750 };

  test("builds a venmo.com URL with the username in the path", () => {
    const url = buildPaymentLink(inv, "venmo", "johndoe");
    expect(url).toBe(
      `https://venmo.com/johndoe?txn=pay&amount=750.00&note=${encodeURIComponent("INV-042 - Deck repair")}`
    );
  });

  test("includes txn=pay so Venmo opens in pay mode", () => {
    const url = buildPaymentLink(inv, "venmo", "johndoe");
    expect(new URL(url).searchParams.get("txn")).toBe("pay");
  });

  test("amount always has 2 decimal places (Venmo accepts decimals)", () => {
    const url = buildPaymentLink({ ...inv, amount: 500 }, "venmo", "johndoe");
    expect(new URL(url).searchParams.get("amount")).toBe("500.00");
  });

  test("note is URL-encoded", () => {
    const url = buildPaymentLink(inv, "venmo", "johndoe");
    expect(new URL(url).searchParams.get("note")).toBe("INV-042 - Deck repair");
  });

  test("falls back to 'yourusername' when no key is provided", () => {
    const url = buildPaymentLink(inv, "venmo", "");
    expect(url).toMatch(/^https:\/\/venmo\.com\/yourusername\?/);
  });
});

describe("buildPaymentLink — Custom URL", () => {
  const inv = { number: "INV-007", desc: "Fence install", amount: 1200 };

  test("appends amount and invoice params to the user's URL", () => {
    const url = buildPaymentLink(inv, "custom", "https://pay.example.com");
    expect(url).toBe("https://pay.example.com?amount=1200.00&invoice=INV-007");
  });

  test("amount always has 2 decimal places", () => {
    const url = buildPaymentLink({ ...inv, amount: 99.5 }, "custom", "https://pay.example.com");
    expect(new URL(url).searchParams.get("amount")).toBe("99.50");
  });

  test("uses & separator when base URL already has query params", () => {
    const url = buildPaymentLink(inv, "custom", "https://pay.example.com?ref=abc");
    expect(url).toBe("https://pay.example.com?ref=abc&amount=1200.00&invoice=INV-007");
  });

  test("falls back to example URL when no key is provided", () => {
    const url = buildPaymentLink(inv, "custom", "");
    expect(url).toMatch(/^https:\/\/yourpaymentpage\.com\?/);
  });

  test("invoice number is passed as the invoice param", () => {
    const url = buildPaymentLink(inv, "custom", "https://pay.example.com");
    expect(new URL(url).searchParams.get("invoice")).toBe("INV-007");
  });
});

describe("buildPaymentLink — PayPal.Me", () => {
  const inv = { number: "INV-010", desc: "Roof repair", amount: 1850 };

  test("builds a paypal.me URL with username and amount", () => {
    const url = buildPaymentLink(inv, "paypal", "johndoe");
    expect(url).toBe("https://paypal.me/johndoe/1850.00");
  });

  test("amount always has 2 decimal places", () => {
    const url = buildPaymentLink({ ...inv, amount: 500 }, "paypal", "johndoe");
    expect(url).toBe("https://paypal.me/johndoe/500.00");
  });

  test("falls back to 'yourusername' when no key is provided", () => {
    const url = buildPaymentLink(inv, "paypal", "");
    expect(url).toMatch(/^https:\/\/paypal\.me\/yourusername\//);
  });

  test("invoice number does not appear in the URL (PayPal.Me has no reference param)", () => {
    const url = buildPaymentLink(inv, "paypal", "johndoe");
    expect(url).not.toContain("INV-010");
  });
});

describe("resolvePaymentLink — cache reuse", () => {
  test("returns the cached paymentLinkUrl without touching the network", async () => {
    const invoiceWithCache = {
      ...INVOICE,
      paymentLinkUrl: "https://pay.stripe.com/cached_abc123",
      paymentLinkAmount: INVOICE.amount,
    };

    const result = await resolvePaymentLink(invoiceWithCache, "stripe", "");

    expect(result).toBe("https://pay.stripe.com/cached_abc123");
    expect(global.fetch).not.toHaveBeenCalled();
  });

  test("cached URL wins even when providerKey is empty", async () => {
    const invoiceWithCache = {
      ...INVOICE,
      paymentLinkUrl: "https://pay.stripe.com/cached_no_key",
      paymentLinkAmount: INVOICE.amount,
    };

    const result = await resolvePaymentLink(invoiceWithCache, "stripe", "");

    expect(result).toBe("https://pay.stripe.com/cached_no_key");
    expect(global.fetch).not.toHaveBeenCalled();
  });

  test("fetches a new link when the cached amount no longer matches the invoice amount", async () => {
    global.fetch.mockResolvedValueOnce({
      json: () => Promise.resolve({ url: "https://pay.stripe.com/new_link_updated_amount" }),
    });

    const invoiceWithStaleCache = {
      ...INVOICE,
      amount: 500,                            // amount was edited
      paymentLinkUrl: "https://pay.stripe.com/old_link_350",
      paymentLinkAmount: 350,                 // link was generated for the old amount
    };

    const result = await resolvePaymentLink(invoiceWithStaleCache, "stripe", "");

    expect(global.fetch).toHaveBeenCalledTimes(1);
    expect(result).toBe("https://pay.stripe.com/new_link_updated_amount");
  });
});

describe("resolvePaymentLink — network call behaviour", () => {
  test("fetch is never called for a cached Stripe invoice", async () => {
    const invoiceWithCache = {
      ...INVOICE,
      paymentLinkUrl: "https://buy.stripe.com/cached",
      paymentLinkAmount: INVOICE.amount,
    };

    await resolvePaymentLink(invoiceWithCache, "stripe", "");

    expect(global.fetch).toHaveBeenCalledTimes(0);
  });

  test("fetch IS called when there is no cached URL and provider is Stripe", async () => {
    global.fetch.mockResolvedValueOnce({
      json: () => Promise.resolve({ url: "https://pay.stripe.com/new_link" }),
    });

    const result = await resolvePaymentLink(INVOICE, "stripe", "");

    expect(global.fetch).toHaveBeenCalledTimes(1);
    expect(result).toBe("https://pay.stripe.com/new_link");
  });

  test("non-Stripe providers never reach the network even without a cached URL", async () => {
    const venmoResult = await resolvePaymentLink(INVOICE, "venmo", "mytrades");
    expect(venmoResult).toContain("venmo.com");

    const paypalResult = await resolvePaymentLink(INVOICE, "paypal", "johndoe");
    expect(paypalResult).toContain("paypal.me");

    expect(global.fetch).not.toHaveBeenCalled();
  });
});

describe("fetchPaymentLink — security: sk_ key never in request body", () => {
  test("request body does not contain a stripeKey field", async () => {
    global.fetch.mockResolvedValueOnce({
      json: () => Promise.resolve({ url: "https://pay.stripe.com/link" }),
    });

    await fetchPaymentLink(INVOICE, "stripe", "");

    expect(global.fetch).toHaveBeenCalledTimes(1);
    const [, options] = global.fetch.mock.calls[0];
    const body = JSON.parse(options.body);

    expect(body).not.toHaveProperty("stripeKey");
    expect(body).toHaveProperty("amount", INVOICE.amount);
    expect(body).toHaveProperty("invoiceNumber", INVOICE.number);
  });

  test("Stripe requests use the Supabase JWT as Authorization header, not the providerKey", async () => {
    global.fetch.mockResolvedValueOnce({
      json: () => Promise.resolve({ url: "https://pay.stripe.com/link" }),
    });

    await fetchPaymentLink(INVOICE, "stripe", "some-old-token");

    const [, options] = global.fetch.mock.calls[0];
    // Must be the session JWT, not the passed-in providerKey.
    expect(options.headers["Authorization"]).toBe(`Bearer ${TEST_JWT}`);
    const body = JSON.parse(options.body);
    expect(body).not.toHaveProperty("stripeKey");
  });

  test("throws when the user has no active session", async () => {
    const { supabase } = require("../utils/supabase");
    supabase.auth.getSession.mockResolvedValueOnce({ data: { session: null } });

    await expect(fetchPaymentLink(INVOICE, "stripe", "")).rejects.toThrow(
      "You must be signed in"
    );
  });

  test("throws when backend returns an error", async () => {
    global.fetch.mockResolvedValueOnce({
      json: () => Promise.resolve({ error: "No Stripe account connected." }),
    });

    await expect(fetchPaymentLink(INVOICE, "stripe", "")).rejects.toThrow(
      "No Stripe account connected."
    );
  });

  test("throws when backend returns 401 Unauthorized", async () => {
    global.fetch.mockResolvedValueOnce({
      json: () => Promise.resolve({ error: "Unauthorized" }),
    });

    await expect(fetchPaymentLink(INVOICE, "stripe", "")).rejects.toThrow(
      "Unauthorized"
    );
  });
});

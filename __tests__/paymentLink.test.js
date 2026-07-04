// __tests__/paymentLink.test.js
// Tests for resolvePaymentLink — the utility used by OutreachScreen to decide
// whether to return a cached payment URL or fetch a new one from the backend.
//
// Test #3: reuses an existing paymentLinkUrl rather than generating a new one.
// Test #4: no network call fires when a cached link is already present.

import { resolvePaymentLink } from "../utils/invoiceHelpers";

const INVOICE = {
  id: "inv1",
  number: "INV-001",
  desc: "Plumbing repair",
  amount: 350,
  email: "customer@example.com",
  customer: "Jane Smith",
};

// Stripe is the only provider that reaches the network (via the Vercel backend).
// Venmo / PayPal / Square fall back to client-side link builders with no fetch call.
const STRIPE_KEY = "sk_test_abc123";

let originalFetch;

beforeEach(() => {
  originalFetch = global.fetch;
  global.fetch = jest.fn();
});

afterEach(() => {
  global.fetch = originalFetch;
});

describe("resolvePaymentLink — cache reuse (test #3)", () => {
  test("returns the cached paymentLinkUrl without touching the network", async () => {
    const invoiceWithCache = {
      ...INVOICE,
      paymentLinkUrl: "https://pay.stripe.com/cached_abc123",
    };

    const result = await resolvePaymentLink(invoiceWithCache, "stripe", STRIPE_KEY);

    expect(result).toBe("https://pay.stripe.com/cached_abc123");
    expect(global.fetch).not.toHaveBeenCalled();
  });

  test("cached URL wins even when providerKey is empty", async () => {
    // Ensures the cache-first logic doesn't break when key is missing later.
    const invoiceWithCache = {
      ...INVOICE,
      paymentLinkUrl: "https://pay.stripe.com/cached_no_key",
    };

    const result = await resolvePaymentLink(invoiceWithCache, "stripe", "");

    expect(result).toBe("https://pay.stripe.com/cached_no_key");
    expect(global.fetch).not.toHaveBeenCalled();
  });
});

describe("resolvePaymentLink — no auto-fetch when link already exists (test #4)", () => {
  test("fetch is never called for a cached Stripe invoice", async () => {
    const invoiceWithCache = {
      ...INVOICE,
      paymentLinkUrl: "https://buy.stripe.com/cached",
    };

    await resolvePaymentLink(invoiceWithCache, "stripe", STRIPE_KEY);

    expect(global.fetch).toHaveBeenCalledTimes(0);
  });

  test("fetch IS called when there is no cached URL and provider is Stripe", async () => {
    // Confirms the fetch path is still exercised for new invoices.
    global.fetch.mockResolvedValueOnce({
      json: () => Promise.resolve({ url: "https://pay.stripe.com/new_link" }),
    });

    const result = await resolvePaymentLink(INVOICE, "stripe", STRIPE_KEY);

    expect(global.fetch).toHaveBeenCalledTimes(1);
    expect(result).toBe("https://pay.stripe.com/new_link");
  });

  test("non-Stripe providers never reach the network even without a cached URL", async () => {
    // Venmo, PayPal, Square, and custom providers are all client-side only.
    const venmoResult = await resolvePaymentLink(INVOICE, "venmo", "mytrades");
    expect(venmoResult).toContain("venmo.com");

    const paypalResult = await resolvePaymentLink(INVOICE, "paypal", "");
    expect(paypalResult).toContain("paypal.com");

    expect(global.fetch).not.toHaveBeenCalled();
  });
});

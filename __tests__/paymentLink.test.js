// __tests__/paymentLink.test.js
// Tests for resolvePaymentLink and fetchPaymentLink — the utilities used by
// OutreachScreen to decide whether to return a cached payment URL or fetch a
// new one from the backend.
//
// Key security invariants under test:
//   - The request body must NEVER contain a stripeKey field (sk_... stays on server).
//   - providerKey is sent as Authorization: Bearer, not in the request body.
//   - Cached links are returned without any network call.

import { resolvePaymentLink, fetchPaymentLink } from "../utils/invoiceHelpers";

const INVOICE = {
  id: "inv1",
  number: "INV-001",
  desc: "Plumbing repair",
  amount: 350,
  email: "customer@example.com",
  customer: "Jane Smith",
};

// providerKey for Stripe is now the BACKEND_API_TOKEN, not an sk_ Stripe secret key.
const BACKEND_API_TOKEN = "test-api-token-abc123";

let originalFetch;

beforeEach(() => {
  originalFetch = global.fetch;
  global.fetch = jest.fn();
});

afterEach(() => {
  global.fetch = originalFetch;
});

describe("resolvePaymentLink — cache reuse", () => {
  test("returns the cached paymentLinkUrl without touching the network", async () => {
    const invoiceWithCache = {
      ...INVOICE,
      paymentLinkUrl: "https://pay.stripe.com/cached_abc123",
    };

    const result = await resolvePaymentLink(invoiceWithCache, "stripe", BACKEND_API_TOKEN);

    expect(result).toBe("https://pay.stripe.com/cached_abc123");
    expect(global.fetch).not.toHaveBeenCalled();
  });

  test("cached URL wins even when providerKey is empty", async () => {
    const invoiceWithCache = {
      ...INVOICE,
      paymentLinkUrl: "https://pay.stripe.com/cached_no_key",
    };

    const result = await resolvePaymentLink(invoiceWithCache, "stripe", "");

    expect(result).toBe("https://pay.stripe.com/cached_no_key");
    expect(global.fetch).not.toHaveBeenCalled();
  });
});

describe("resolvePaymentLink — network call behaviour", () => {
  test("fetch is never called for a cached Stripe invoice", async () => {
    const invoiceWithCache = {
      ...INVOICE,
      paymentLinkUrl: "https://buy.stripe.com/cached",
    };

    await resolvePaymentLink(invoiceWithCache, "stripe", BACKEND_API_TOKEN);

    expect(global.fetch).toHaveBeenCalledTimes(0);
  });

  test("fetch IS called when there is no cached URL and provider is Stripe", async () => {
    global.fetch.mockResolvedValueOnce({
      json: () => Promise.resolve({ url: "https://pay.stripe.com/new_link" }),
    });

    const result = await resolvePaymentLink(INVOICE, "stripe", BACKEND_API_TOKEN);

    expect(global.fetch).toHaveBeenCalledTimes(1);
    expect(result).toBe("https://pay.stripe.com/new_link");
  });

  test("non-Stripe providers never reach the network even without a cached URL", async () => {
    const venmoResult = await resolvePaymentLink(INVOICE, "venmo", "mytrades");
    expect(venmoResult).toContain("venmo.com");

    const paypalResult = await resolvePaymentLink(INVOICE, "paypal", "");
    expect(paypalResult).toContain("paypal.com");

    expect(global.fetch).not.toHaveBeenCalled();
  });
});

describe("fetchPaymentLink — security: sk_ key never in request body", () => {
  test("request body does not contain a stripeKey field", async () => {
    global.fetch.mockResolvedValueOnce({
      json: () => Promise.resolve({ url: "https://pay.stripe.com/link" }),
    });

    await fetchPaymentLink(INVOICE, "stripe", BACKEND_API_TOKEN);

    expect(global.fetch).toHaveBeenCalledTimes(1);
    const [, options] = global.fetch.mock.calls[0];
    const body = JSON.parse(options.body);

    expect(body).not.toHaveProperty("stripeKey");
    expect(body).toHaveProperty("amount", INVOICE.amount);
    expect(body).toHaveProperty("invoiceNumber", INVOICE.number);
  });

  test("providerKey is sent as Authorization Bearer header, not in the body", async () => {
    global.fetch.mockResolvedValueOnce({
      json: () => Promise.resolve({ url: "https://pay.stripe.com/link" }),
    });

    await fetchPaymentLink(INVOICE, "stripe", BACKEND_API_TOKEN);

    const [, options] = global.fetch.mock.calls[0];
    expect(options.headers["Authorization"]).toBe(`Bearer ${BACKEND_API_TOKEN}`);
    const body = JSON.parse(options.body);
    expect(body).not.toHaveProperty("stripeKey");
  });

  test("Authorization header is omitted when providerKey is empty", async () => {
    global.fetch.mockResolvedValueOnce({
      json: () => Promise.resolve({ url: "https://pay.stripe.com/link" }),
    });

    await fetchPaymentLink(INVOICE, "stripe", "");

    const [, options] = global.fetch.mock.calls[0];
    expect(options.headers).not.toHaveProperty("Authorization");
  });

  test("throws when backend returns an error", async () => {
    global.fetch.mockResolvedValueOnce({
      json: () => Promise.resolve({ error: "STRIPE_SECRET_KEY is not configured." }),
    });

    await expect(fetchPaymentLink(INVOICE, "stripe", BACKEND_API_TOKEN)).rejects.toThrow(
      "STRIPE_SECRET_KEY is not configured."
    );
  });

  test("throws when backend returns 401 Unauthorized", async () => {
    global.fetch.mockResolvedValueOnce({
      json: () => Promise.resolve({ error: "Unauthorized" }),
    });

    await expect(fetchPaymentLink(INVOICE, "stripe", "wrong-token")).rejects.toThrow(
      "Unauthorized"
    );
  });
});

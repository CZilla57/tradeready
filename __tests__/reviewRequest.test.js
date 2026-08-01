// Review-request message rendering + missing-link guard.
// When the template still references {googleReviewLink} but no link is set,
// the message must not render a blank hole, and the screen blocks sending
// (see ReviewRequestScreen). These cover the two pure helpers.

const {
  buildReviewMessage,
  reviewMessageMissingLink,
} = require("../utils/reviewRequest");

// The shipped default template (utils/storage/defaults.ts) — the realistic case.
const DEFAULT_TEMPLATE =
  "Hi {customerName}, thanks for choosing {businessName}! If you were happy with the work, we'd really appreciate a Google review:\n\n{googleReviewLink}\n\nThank you!";

describe("reviewMessageMissingLink", () => {
  test("true when template has the placeholder and the link is empty", () => {
    expect(reviewMessageMissingLink(DEFAULT_TEMPLATE, "")).toBe(true);
  });

  test("true when the link is only whitespace", () => {
    expect(reviewMessageMissingLink(DEFAULT_TEMPLATE, "   ")).toBe(true);
  });

  test("false when a real link is set", () => {
    expect(
      reviewMessageMissingLink(DEFAULT_TEMPLATE, "https://g.page/r/abc/review"),
    ).toBe(false);
  });

  test("false when the placeholder was removed from the template, even with no link", () => {
    const noPlaceholder =
      "Hi {customerName}, thanks for choosing {businessName}! Please leave us a review.";
    expect(reviewMessageMissingLink(noPlaceholder, "")).toBe(false);
  });
});

describe("buildReviewMessage", () => {
  test("substitutes all placeholders when a link is set", () => {
    const out = buildReviewMessage(
      DEFAULT_TEMPLATE,
      "Acme Plumbing",
      "Sam",
      "https://g.page/r/abc/review",
    );
    expect(out).toBe(
      "Hi Sam, thanks for choosing Acme Plumbing! If you were happy with the work, we'd really appreciate a Google review:\n\nhttps://g.page/r/abc/review\n\nThank you!",
    );
  });

  test("empty link leaves no blank hole and trims the dangling colon", () => {
    const out = buildReviewMessage(DEFAULT_TEMPLATE, "Acme Plumbing", "Sam", "");
    expect(out).toBe(
      "Hi Sam, thanks for choosing Acme Plumbing! If you were happy with the work, we'd really appreciate a Google review\n\nThank you!",
    );
  });

  test("empty link never produces three or more consecutive newlines", () => {
    const out = buildReviewMessage(DEFAULT_TEMPLATE, "Acme Plumbing", "Sam", "");
    expect(out).not.toMatch(/\n{3,}/);
  });

  test("business and customer names still substitute when the link is empty", () => {
    const out = buildReviewMessage(DEFAULT_TEMPLATE, "Acme Plumbing", "Sam", "");
    expect(out).toContain("Sam");
    expect(out).toContain("Acme Plumbing");
    expect(out).not.toContain("{");
  });
});

describe("markReviewRequestSent", () => {
  const AsyncStorage = require("@react-native-async-storage/async-storage");
  const Notifications = require("expo-notifications");
  const { markReviewRequestSent } = require("../utils/reviewRequest");

  const rec = (jobId, overrides = {}) => ({
    jobId,
    customerId: "c1",
    customerName: "Sam",
    customerPhone: "555-0100",
    customerEmail: "sam@example.com",
    scheduledAt: "2026-07-30T10:00:00.000Z",
    sentAt: null,
    ...overrides,
  });

  const savedRecords = () =>
    JSON.parse(AsyncStorage.setItem.mock.calls.at(-1)[1]);

  beforeEach(() => {
    jest.clearAllMocks();
  });

  test("sets sentAt on the matching record and leaves others untouched", async () => {
    AsyncStorage.getItem.mockResolvedValueOnce(
      JSON.stringify([rec("j1"), rec("j2")]),
    );
    await markReviewRequestSent("j1");
    const out = savedRecords();
    expect(out).toHaveLength(2);
    expect(out[0].sentAt).toEqual(expect.any(String));
    expect(out[1].sentAt).toBeNull();
    expect(AsyncStorage.setItem.mock.calls.at(-1)[0]).toBe("review_requests");
  });

  test("creates a sent record from the fallback when none exists (manual send)", async () => {
    AsyncStorage.getItem.mockResolvedValueOnce(null);
    await markReviewRequestSent("j9", {
      customerId: "c9",
      customerName: "Pat",
      customerPhone: "555-0199",
      customerEmail: "pat@example.com",
    });
    const out = savedRecords();
    expect(out).toHaveLength(1);
    expect(out[0]).toMatchObject({
      jobId: "j9",
      customerId: "c9",
      customerName: "Pat",
      customerPhone: "555-0199",
      customerEmail: "pat@example.com",
    });
    expect(out[0].sentAt).toEqual(expect.any(String));
    expect(out[0].scheduledAt).toEqual(expect.any(String));
  });

  test("no matching record and no fallback appends nothing", async () => {
    AsyncStorage.getItem.mockResolvedValueOnce(JSON.stringify([rec("j1")]));
    await markReviewRequestSent("j9");
    const out = savedRecords();
    expect(out).toHaveLength(1);
    expect(out[0].jobId).toBe("j1");
    expect(out[0].sentAt).toBeNull();
  });

  test("cancels the pending auto-notification for the job", async () => {
    AsyncStorage.getItem.mockResolvedValueOnce(JSON.stringify([rec("j1")]));
    await markReviewRequestSent("j1");
    expect(Notifications.cancelScheduledNotificationAsync).toHaveBeenCalledWith(
      "review_j1",
    );
  });

  test("a failed cancel does not block marking sent", async () => {
    Notifications.cancelScheduledNotificationAsync.mockRejectedValueOnce(
      new Error("no such notification"),
    );
    AsyncStorage.getItem.mockResolvedValueOnce(JSON.stringify([rec("j1")]));
    await expect(markReviewRequestSent("j1")).resolves.toBeUndefined();
    expect(savedRecords()[0].sentAt).toEqual(expect.any(String));
  });
});

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

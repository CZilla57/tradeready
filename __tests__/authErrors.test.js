// Mapping raw Supabase auth errors to human-readable copy.

const { friendlyAuthError } = require("../utils/authErrors");

describe("friendlyAuthError", () => {
  test("translates email rate-limit errors into actionable copy", () => {
    const msg = friendlyAuthError("email rate limit exceeded");
    expect(msg).toMatch(/most recent link/i);
    expect(msg).not.toMatch(/rate limit exceeded/i);
    // Supabase phrases it several ways
    expect(friendlyAuthError("Email rate limit exceeded")).toBe(msg);
    expect(friendlyAuthError("over_email_send_rate_limit")).toBe(msg);
    expect(friendlyAuthError("For security purposes, you can only request this after 45 seconds.")).toBe(msg);
  });

  test("translates invalid credentials", () => {
    expect(friendlyAuthError("Invalid login credentials")).toBe(
      "Email or password is incorrect."
    );
  });

  test("passes through anything it does not recognize", () => {
    expect(friendlyAuthError("Network request failed")).toBe("Network request failed");
    expect(friendlyAuthError("")).toBe("Something went wrong. Please try again.");
  });
});

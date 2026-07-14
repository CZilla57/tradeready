// Signup-confirmation resend cooldown — pure logic, injected clock.

const {
  RESEND_COOLDOWN_MS,
  canResend,
  resendSecondsRemaining,
} = require("../utils/resendCooldown");

describe("canResend", () => {
  test("allows resend when nothing has been sent yet", () => {
    expect(canResend(null, 1_000_000)).toBe(true);
  });

  test("blocks resend immediately after sending", () => {
    expect(canResend(1_000_000, 1_000_000)).toBe(false);
  });

  test("blocks resend one second before the cooldown ends", () => {
    expect(canResend(1_000_000, 1_000_000 + RESEND_COOLDOWN_MS - 1_000)).toBe(false);
  });

  test("allows resend exactly when the cooldown ends", () => {
    expect(canResend(1_000_000, 1_000_000 + RESEND_COOLDOWN_MS)).toBe(true);
  });

  test("allows resend after the cooldown has passed", () => {
    expect(canResend(1_000_000, 1_000_000 + RESEND_COOLDOWN_MS + 5_000)).toBe(true);
  });
});

describe("resendSecondsRemaining", () => {
  test("zero when nothing has been sent yet", () => {
    expect(resendSecondsRemaining(null, 1_000_000)).toBe(0);
  });

  test("full cooldown right after sending", () => {
    expect(resendSecondsRemaining(1_000_000, 1_000_000)).toBe(RESEND_COOLDOWN_MS / 1000);
  });

  test("rounds partial seconds up so the label never shows 0s while blocked", () => {
    // 500ms into the cooldown → 59.5s left → display 60
    expect(resendSecondsRemaining(1_000_000, 1_000_500)).toBe(60);
    // 59.1s in → 0.9s left → display 1
    expect(resendSecondsRemaining(1_000_000, 1_000_000 + 59_100)).toBe(1);
  });

  test("zero once the cooldown has ended", () => {
    expect(resendSecondsRemaining(1_000_000, 1_000_000 + RESEND_COOLDOWN_MS)).toBe(0);
    expect(resendSecondsRemaining(1_000_000, 1_000_000 + RESEND_COOLDOWN_MS + 9_000)).toBe(0);
  });
});

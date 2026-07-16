import * as Sentry from "@sentry/react-native";
import { track, identifyUser, resetUser, reportError, posthogRef } from "../utils/analytics";

const mockPostHog = {
  capture: jest.fn(),
  identify: jest.fn(),
  reset: jest.fn(),
};

beforeEach(() => {
  jest.clearAllMocks();
  posthogRef.current = mockPostHog as any;
});

afterEach(() => {
  posthogRef.current = null;
});

describe("analytics", () => {
  it("track() calls posthog.capture with event name and properties", () => {
    track("job_created", { jobId: "j1" });
    expect(mockPostHog.capture).toHaveBeenCalledWith("job_created", { jobId: "j1" });
  });

  it("track() is a no-op when posthog is not initialized", () => {
    posthogRef.current = null;
    expect(() => track("job_created")).not.toThrow();
  });

  it("track() swallows PostHog errors", () => {
    posthogRef.current = { capture: jest.fn(() => { throw new Error("SDK error"); }) } as any;
    expect(() => track("test_event")).not.toThrow();
  });

  it("identifyUser() calls posthog.identify and Sentry.setUser", () => {
    identifyUser("user-123");
    expect(mockPostHog.identify).toHaveBeenCalledWith("user-123");
    expect(Sentry.setUser).toHaveBeenCalledWith({ id: "user-123" });
  });

  it("resetUser() calls posthog.reset and Sentry.setUser(null)", () => {
    resetUser();
    expect(mockPostHog.reset).toHaveBeenCalled();
    expect(Sentry.setUser).toHaveBeenCalledWith(null);
  });

  it("reportError() calls Sentry.captureException with context", () => {
    const err = new Error("test");
    reportError(err, { screen: "JobDetail" });
    expect(Sentry.captureException).toHaveBeenCalled();
  });

  it("reportError() passes Error instances through unchanged", () => {
    const err = new Error("boom");
    reportError(err);
    expect(Sentry.captureException).toHaveBeenCalledWith(err);
  });

  it("reportError() wraps plain objects so the Sentry title carries the real message", () => {
    // Supabase/PostgREST errors are plain objects; unwrapped they title as
    // "Object captured as exception with keys: code, details, hint, message".
    const scope = { setExtra: jest.fn() };
    (Sentry.withScope as jest.Mock).mockImplementationOnce((cb: (s: unknown) => void) => cb(scope));
    const pgError = {
      code: "42501",
      details: null,
      hint: null,
      message: 'new row violates row-level security policy (USING expression) for table "customers"',
    };
    reportError(pgError, { context: "pushQueue" });
    const captured = (Sentry.captureException as jest.Mock).mock.calls[0][0];
    expect(captured).toBeInstanceOf(Error);
    expect(captured.message).toBe(
      '[42501] new row violates row-level security policy (USING expression) for table "customers"',
    );
    expect(scope.setExtra).toHaveBeenCalledWith("rawError", pgError);
    expect(scope.setExtra).toHaveBeenCalledWith("context", "pushQueue");
  });

  it("reportError() stringifies message-less values", () => {
    reportError({ status: 500 });
    const captured = (Sentry.captureException as jest.Mock).mock.calls[0][0];
    expect(captured).toBeInstanceOf(Error);
    expect(captured.message).toBe('{"status":500}');
  });
});

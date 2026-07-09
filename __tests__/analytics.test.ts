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
});

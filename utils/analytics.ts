import * as Sentry from "@sentry/react-native";
import type { PostHog } from "posthog-react-native";

/**
 * Set by App.tsx once the PostHog client is initialized (via usePostHog()).
 * All analytics calls go through this ref so screens can import track/identifyUser/etc.
 * without needing access to the PostHog React context directly.
 */
export const posthogRef: { current: PostHog | null } = { current: null };

export function track(event: string, properties?: Record<string, unknown>): void {
  // PostHog's capture() expects JSON-serializable properties (PostHogEventProperties),
  // which is stricter than our public Record<string, unknown> signature. Callers of
  // track() shouldn't need to know about PostHog's internal JsonType constraint, so we
  // cast at this single boundary rather than narrowing our public API.
  posthogRef.current?.capture(event, properties as Parameters<PostHog["capture"]>[1]);
}

export function identifyUser(userId: string): void {
  posthogRef.current?.identify(userId);
  Sentry.setUser({ id: userId });
}

export function resetUser(): void {
  posthogRef.current?.reset();
  Sentry.setUser(null);
}

export function reportError(error: unknown, context?: Record<string, unknown>): void {
  Sentry.withScope((scope) => {
    if (context) {
      Object.entries(context).forEach(([key, value]) => {
        scope.setExtra(key, value);
      });
    }
    Sentry.captureException(error);
  });
}

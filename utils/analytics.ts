import * as Sentry from "@sentry/react-native";
import type { PostHog } from "posthog-react-native";

/**
 * Set by App.tsx once the PostHog client is initialized (via usePostHog()).
 * All analytics calls go through this ref so screens can import track/identifyUser/etc.
 * without needing access to the PostHog React context directly.
 */
export const posthogRef: { current: PostHog | null } = { current: null };

export function track(event: string, properties?: Record<string, unknown>): void {
  try {
    // PostHog's capture() expects JSON-serializable properties (PostHogEventProperties),
    // which is stricter than our public Record<string, unknown> signature. Callers of
    // track() shouldn't need to know about PostHog's internal JsonType constraint, so we
    // cast at this single boundary rather than narrowing our public API.
    posthogRef.current?.capture(event, properties as Parameters<PostHog["capture"]>[1]);
  } catch {
    // Analytics must never crash the app.
  }
}

export function identifyUser(userId: string): void {
  try {
    posthogRef.current?.identify(userId);
    Sentry.setUser({ id: userId });
  } catch {
    // Analytics must never crash the app.
  }
}

export function resetUser(): void {
  try {
    posthogRef.current?.reset();
    Sentry.setUser(null);
  } catch {
    // Analytics must never crash the app.
  }
}

export function reportError(error: unknown, context?: Record<string, unknown>): void {
  // Supabase/PostgREST failures are plain objects ({code, message, details,
  // hint}), which Sentry titles "Object captured as exception with keys: ..."
  // — hiding the message that identifies the failure (2026-07-16 sync-wedge
  // diagnosis). Wrap non-Errors so the issue title carries the real message;
  // the original object is preserved as the `rawError` extra.
  const toCapture = error instanceof Error ? error : new Error(describeNonError(error));
  Sentry.withScope((scope) => {
    if (context) {
      Object.entries(context).forEach(([key, value]) => {
        scope.setExtra(key, value);
      });
    }
    if (toCapture !== error) {
      scope.setExtra("rawError", error);
    }
    Sentry.captureException(toCapture);
  });
}

function describeNonError(value: unknown): string {
  const obj = value as { message?: unknown; code?: unknown } | null | undefined;
  if (typeof obj?.message === "string" && obj.message) {
    const code = obj.code;
    return typeof code === "string" || typeof code === "number"
      ? `[${code}] ${obj.message}`
      : obj.message;
  }
  try {
    return JSON.stringify(value) ?? String(value);
  } catch {
    return String(value);
  }
}

// utils/deepLinks.ts
// Parser for the app's custom URL scheme (app.json "scheme": "tradeready").
// Producers: the home-screen widgets (targets/widget), tradeready://job/<id>;
// and the widget "on my way" button + Siri intent, tradeready://onmyway/<id>.
// Parse strictly — deep-link input is untrusted (any app can open a
// tradeready:// URL): unknown hosts/paths return null, and the extracted id
// is only ever used as a local record lookup.
// Also home to parsePendingOpenUrl, which validates the cold-launch link stash
// the Siri on-my-way intent leaves in the App Group container.

export interface JobDeepLink {
  type: "job";
  jobId: string;
}

export interface OnMyWayDeepLink {
  type: "onmyway";
  jobId: string;
}

export type WidgetDeepLink = JobDeepLink | OnMyWayDeepLink;

const JOB_LINK = /^tradeready:\/\/job\/([^/?#]+)$/i;
const ONMYWAY_LINK = /^tradeready:\/\/onmyway\/([^/?#]+)$/i;

export function parseWidgetDeepLink(url: string | null | undefined): WidgetDeepLink | null {
  if (!url) return null;
  const trimmed = url.trim();

  const jobMatch = JOB_LINK.exec(trimmed);
  if (jobMatch) {
    try {
      return { type: "job", jobId: decodeURIComponent(jobMatch[1]) };
    } catch {
      // Malformed percent-encoding — not a link we produced.
      return null;
    }
  }

  const onMyWayMatch = ONMYWAY_LINK.exec(trimmed);
  if (onMyWayMatch) {
    try {
      return { type: "onmyway", jobId: decodeURIComponent(onMyWayMatch[1]) };
    } catch {
      return null;
    }
  }

  return null;
}

/**
 * Max age of a stashed pendingOpenUrl. A Siri intent writes the stash for the
 * launch it is triggering right now, so anything older belongs to a launch that
 * already happened (or one the user abandoned) and must not hijack this one.
 */
const PENDING_OPEN_URL_MAX_AGE_MS = 5 * 60 * 1000;

/**
 * Parse the `pendingOpenUrl` container payload a Siri intent leaves behind for
 * a cold launch — `{ url: string, at: ISO string }` — and return the url only
 * while it is fresh. Pure; `nowMs` is injected so the freshness window is
 * testable. Returns null for malformed JSON, a non-object payload, a missing or
 * non-string `url`/`at`, an unparseable `at`, an age over five minutes, or a
 * timestamp in the future (a clock change, not a launch we caused).
 * Same discipline as parseWidgetDeepLink above: this is native-written input
 * the app does not fully control, so anything that fails a guard is dropped.
 * The returned string is NOT trusted as a link — the caller still runs it
 * through parseWidgetDeepLink.
 */
export function parsePendingOpenUrl(raw: string | null, nowMs: number): string | null {
  if (!raw) return null;
  let parsed: unknown;
  try {
    parsed = JSON.parse(raw);
  } catch {
    return null;
  }
  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) return null;

  const { url, at } = parsed as Record<string, unknown>;
  if (typeof url !== "string" || !url) return null;
  if (typeof at !== "string") return null;

  const stampedMs = Date.parse(at);
  if (Number.isNaN(stampedMs)) return null;

  const age = nowMs - stampedMs;
  if (age < 0 || age > PENDING_OPEN_URL_MAX_AGE_MS) return null;

  return url;
}

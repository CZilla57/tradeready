// utils/deepLinks.ts
// Parser for the app's custom URL scheme (app.json "scheme": "tradeready").
// Producers: the home-screen widgets (targets/widget), tradeready://job/<id>;
// and the widget "on my way" button + Siri intent, tradeready://onmyway/<id>.
// Parse strictly — deep-link input is untrusted (any app can open a
// tradeready:// URL): unknown hosts/paths return null, and the extracted id
// is only ever used as a local record lookup.

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

// utils/deepLinks.ts
// Parser for the app's custom URL scheme (app.json "scheme": "tradeready").
// Today the only producers are the home-screen widgets (targets/widget), which
// tap through with tradeready://job/<id>. Parse strictly — deep-link input is
// untrusted (any app can open a tradeready:// URL): unknown hosts/paths return
// null, and the extracted id is only ever used as a local record lookup.

export interface WidgetDeepLink {
  type: "job";
  jobId: string;
}

const JOB_LINK = /^tradeready:\/\/job\/([^/?#]+)$/i;

export function parseWidgetDeepLink(url: string | null | undefined): WidgetDeepLink | null {
  if (!url) return null;
  const match = JOB_LINK.exec(url.trim());
  if (!match) return null;
  try {
    return { type: "job", jobId: decodeURIComponent(match[1]) };
  } catch {
    // Malformed percent-encoding — not a link we produced.
    return null;
  }
}

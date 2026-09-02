// web/src/lib/dataSync.ts
//
// Same-origin cross-tab change notifications (roadmap: multi-tab refresh). When
// the portal writes in one tab, other open portal tabs should not keep showing
// the pre-edit rows until the owner reloads. This is the light half of the
// story: a `BroadcastChannel` ping naming the collections that changed, so a
// sibling tab reloads just those. The heavier half — catching writes from the
// mobile app, a Stripe webhook, or any non-portal client — is handled by
// DataContext's focus/visibility refresh, which re-pulls from the server when a
// backgrounded tab comes forward.
//
// `BroadcastChannel` isn't universal (older Safari, some test runners), so every
// entry point degrades to a no-op when it's missing — the focus refresh still
// keeps tabs eventually-consistent.

import type { ResourceKey } from './DataContext';

const CHANNEL_NAME = 'tradeready-data-sync';

/** The shape posted on the channel: which collections changed in the sender. */
export interface DataChangeMessage {
  keys: ResourceKey[];
}

// A lazily-created module singleton. `undefined` = not yet resolved; `null` =
// resolved-unsupported (so we only probe once). One channel per tab means the
// posting tab never receives its own message (the spec excludes the sender),
// which is exactly what we want — the writer already refreshed itself.
let channel: BroadcastChannel | null | undefined;

function getChannel(): BroadcastChannel | null {
  if (channel === undefined) {
    try {
      channel =
        typeof BroadcastChannel === 'undefined'
          ? null
          : new BroadcastChannel(CHANNEL_NAME);
    } catch {
      channel = null;
    }
  }
  return channel;
}

/**
 * Announce to other same-origin portal tabs that these collections changed here,
 * so they can reload without waiting for a focus. No-op on an empty list or when
 * `BroadcastChannel` is unavailable.
 */
export function publishDataChange(keys: ResourceKey[]): void {
  if (keys.length === 0) return;
  const ch = getChannel();
  if (!ch) return;
  try {
    ch.postMessage({ keys } satisfies DataChangeMessage);
  } catch {
    // A closed channel or an unclonable payload — nothing actionable; the
    // focus refresh remains the safety net.
  }
}

/**
 * Subscribe to change notices from other tabs. The callback receives the
 * announced keys; the caller decides how to reload them. Returns an unsubscribe
 * function (a no-op when unsupported).
 */
export function subscribeDataChange(
  cb: (keys: ResourceKey[]) => void,
): () => void {
  const ch = getChannel();
  if (!ch) return () => {};
  const handler = (event: MessageEvent) => {
    const data = event.data as DataChangeMessage | undefined;
    if (data && Array.isArray(data.keys) && data.keys.length > 0) {
      cb(data.keys);
    }
  };
  ch.addEventListener('message', handler);
  return () => ch.removeEventListener('message', handler);
}

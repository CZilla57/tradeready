import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
#if canImport(os)
import os

/// Phase 12 final review (M6): the busy-lock lines go to the unified log,
/// which a TestFlight or App Store build keeps (`print` never reaches it).
/// Fixed text only.
private let appGroupInboxLog = Logger(subsystem: "com.tradeready.native", category: "diagnostics")
#endif

/// The App Group key/value surface the app reads cross-process handoffs from.
/// UserDefaults cannot compare-and-delete across processes on its own, so
/// every read-and-remove runs inside `WidgetAppGroupLock` — the one advisory
/// lock every App Group writer holds (contract §4.2). Task 11.06 added
/// `removeValue(forKey:)` for the `pendingOpenUrl` read-and-remove (§6.2).
protocol NativeAppGroupInbox {
    func value(forKey key: String) -> String?
    func removeValue(forKey key: String)
}

final class NativeUserDefaultsAppGroupInbox: NativeAppGroupInbox {
    /// Task 11.01: the single App Group id lives in `WidgetAppGroup` (shared
    /// with the widget extension).
    static let suiteName = WidgetAppGroup.suiteName

    private let defaults: UserDefaults?
    private let lock = NSLock()

    init(defaults: UserDefaults? = UserDefaults(suiteName: suiteName)) {
        self.defaults = defaults
    }

    func value(forKey key: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return defaults?.string(forKey: key)
    }

    func removeValue(forKey key: String) {
        lock.lock()
        defer { lock.unlock() }
        defaults?.removeObject(forKey: key)
    }
}

enum NativeAppGroupAccountScrubError: Error {
    case unavailable
    case lockFailed
    case verificationFailed
}

/// Clears the established app/extension suite under the same advisory lock as
/// widget and Siri writers. This prevents an append from racing the explicit
/// sign-out boundary and exposing the previous account on a widget surface.
struct NativeAppGroupAccountScrubber {
    static let accountKeys = WidgetAppGroup.accountKeys

    let suiteName: String
    let defaults: UserDefaults?
    let lockFile: URL?

    init(
        suiteName: String = NativeUserDefaultsAppGroupInbox.suiteName,
        defaults: UserDefaults? = UserDefaults(suiteName: NativeUserDefaultsAppGroupInbox.suiteName),
        lockFile: URL? = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: NativeUserDefaultsAppGroupInbox.suiteName)?
            .appendingPathComponent(WidgetAppGroup.lockFileName)
    ) {
        self.suiteName = suiteName
        self.defaults = defaults
        self.lockFile = lockFile
    }

    func scrub() throws {
        guard let defaults, let lockFile else { throw NativeAppGroupAccountScrubError.unavailable }
        // Task 11.01: the one shared lock implementation (contract §4.2), the
        // same one the widget mirror and the extension's writers take.
        do {
            try WidgetAppGroupLock.withExclusiveLock(at: lockFile) {
                defaults.removePersistentDomain(forName: suiteName)
                guard Self.accountKeys.allSatisfy({ defaults.object(forKey: $0) == nil }) else {
                    throw NativeAppGroupAccountScrubError.verificationFailed
                }
            }
        } catch let error as NativeAppGroupAccountScrubError {
            throw error
        } catch WidgetAppGroupLockError.unavailable {
            // Directory creation failed: the pre-11.01 code rethrew the
            // FileManager error, which callers treat as a failed scrub too.
            throw NativeAppGroupAccountScrubError.unavailable
        } catch WidgetAppGroupLockError.busy {
            // Phase 12 review fix M3: one payload-free line per busy event;
            // still `lockFailed`, so the durable widget step stays pending.
            #if canImport(os)
            appGroupInboxLog.notice("TradeReadyWidgetLock stage=busy site=scrub")
            #endif
            throw NativeAppGroupAccountScrubError.lockFailed
        } catch {
            throw NativeAppGroupAccountScrubError.lockFailed
        }
    }
}

/// The result of one read-and-remove of the `pendingOpenUrl` stash.
enum NativePendingOpenURLTake: Equatable, Sendable {
    case nothingPending
    /// The container or the lock was unavailable: nothing was read or removed.
    case unavailable
    /// Read and removed, but unusable (malformed, oversized, stale, future,
    /// untagged, or not a link we produce). Dropped with no other effect.
    case discarded
    /// Read and removed: fresh, tagged, and a valid route. The caller still
    /// runs the auth/owner/record gate (`NativeDeepLinkRoutingPolicy`).
    case pending(NativeDeepLinkParser.PendingOpenURL)
}

/// Task 11.06 (contract §6.2 step 3): the consumer of the cold-launch
/// `{url, at, ownerTag}` stash that `OnMyWayIntent` writes. It reads AND
/// removes the stash in ONE hold of the shared `WidgetAppGroupLock`, whether
/// or not the value is valid (RN reads, then removes, then parses:
/// `App.tsx:537-550`), so a stash is presented at most once. It never touches
/// the action queue, the trip session or the snapshot.
struct NativePendingOpenURLConsumer {
    static let key = WidgetAppGroup.pendingOpenURLKey

    let inbox: any NativeAppGroupInbox
    let lockFile: URL

    /// The production App Group suite and lock file, or nil when the
    /// entitlement/container is unavailable (then nothing is ever consumed).
    static func live() -> NativePendingOpenURLConsumer? {
        guard let defaults = WidgetAppGroup.liveDefaults(),
              let lockFile = WidgetAppGroup.liveLockFile()
        else { return nil }
        return NativePendingOpenURLConsumer(
            inbox: NativeUserDefaultsAppGroupInbox(defaults: defaults),
            lockFile: lockFile
        )
    }

    /// Reads and removes the stash under the lock, then validates it
    /// (size, JSON shape, freshness `0 ≤ age ≤ 300 s`, grammar, tag present).
    func take(now: Date) -> NativePendingOpenURLTake {
        let raw: String?
        do {
            raw = try WidgetAppGroupLock.withExclusiveLock(at: lockFile) { () -> String? in
                guard let value = inbox.value(forKey: Self.key) else { return nil }
                inbox.removeValue(forKey: Self.key)
                return value
            }
        } catch WidgetAppGroupLockError.busy {
            // Phase 12 review fix M3: one payload-free line per busy event;
            // nothing was read or removed, so the stash keeps its 300 s window.
            #if canImport(os)
            appGroupInboxLog.notice("TradeReadyWidgetLock stage=busy site=stash")
            #endif
            return .unavailable
        } catch {
            return .unavailable
        }
        guard let raw else { return .nothingPending }
        guard let pending = NativeDeepLinkParser.parsePendingOpenURL(raw, now: now),
              let tag = pending.ownerTag, !tag.isEmpty
        else { return .discarded }
        return .pending(pending)
    }

    /// The warm-route dedupe (11.04 handoff; RN `App.tsx` removes the stash
    /// after navigating from the live URL event). Under the lock, removes the
    /// stash only when it names exactly `route`, and returns its `ownerTag`
    /// (nil when nothing matched or the stash was untagged). A stash for a
    /// different route is left for `take`.
    func takeMatching(_ route: NativeDeepLinkParser.Route) -> (removed: Bool, ownerTag: String?) {
        do {
            return try WidgetAppGroupLock.withExclusiveLock(at: lockFile) { () -> (Bool, String?) in
                guard let raw = inbox.value(forKey: Self.key),
                      let stash = NativeDeepLinkParser.decodePendingOpenURLPayload(raw),
                      NativeDeepLinkParser.parse(stash.url) == route
                else { return (false, nil) }
                inbox.removeValue(forKey: Self.key)
                return (true, stash.ownerTag)
            }
        } catch WidgetAppGroupLockError.busy {
            // Phase 12 review fix M3: as in `take`; the stash is left for it.
            #if canImport(os)
            appGroupInboxLog.notice("TradeReadyWidgetLock stage=busy site=stash")
            #endif
            return (false, nil)
        } catch {
            return (false, nil)
        }
    }
}

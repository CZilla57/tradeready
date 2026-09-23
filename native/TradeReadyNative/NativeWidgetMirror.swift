import Foundation
#if canImport(WidgetKit)
import WidgetKit
#endif

// Task 11.01 (W1): the app-side App Group snapshot writer.
//
// Contract: docs/native-phase-11-platform-hardening-contract-decisions.md
// §3.1 (write protocol), §2.3 (encoding, `ownerTag`), §2.5 (owner predicate),
// §4.2 (lock). Write protocol:
//   1. no owner binding → no-op (never a clear; wiping is the scrubber's job);
//   2. acquire the shared advisory lock;
//   3. re-check the owner inside the lock (a sign-out scrub that ran first
//      must win — the writer never re-populates a scrubbed suite);
//   4. write `widgetSnapshot`, release the lock;
//   5. reload widget timelines outside the lock.
// `NativeAppGroupAccountScrubber` stays the only wipe path.

/// The tiny WidgetKit seam: production reloads through `WidgetCenter`; host
/// tests inject a recorder.
protocol NativeWidgetTimelineReloading {
    func reloadAllTimelines()
}

struct NativeWidgetCenterTimelineReloader: NativeWidgetTimelineReloading {
    func reloadAllTimelines() {
        #if canImport(WidgetKit)
        WidgetCenter.shared.reloadAllTimelines()
        #endif
    }
}

enum NativeWidgetMirrorOutcome: Equatable {
    /// The snapshot was written under the lock and timelines were reloaded.
    case written
    /// A non-forced write found the same content already stored and fresh.
    case unchanged
    /// No owner binding: nothing was read or written.
    case skippedNoOwner
    /// The owner changed (or a scrub began) before the lock was acquired.
    case skippedOwnerChanged
    /// The App Group suite or container is unavailable.
    case unavailable
    case lockFailed
    case encodingFailed
}

/// Which canonical snapshot a seam (trigger 3) write projected (contract
/// §3.2 amendment, 11.01 fix round 1).
enum NativeWidgetSeamSource: Equatable {
    /// The canonical the publish delivered: nothing changed locally while it
    /// was suspended.
    case delivered
    /// The live snapshot: a local canonical write landed during the publish's
    /// suspension, so the delivered canonical is older than the mirror.
    case live
}

struct NativeWidgetMirror {
    /// A non-forced write skips an unchanged mirror only while the stored
    /// copy is younger than this, so `updatedAt` never drifts toward the
    /// 24-hour stale window (§3.3) while the app is in use.
    static let unchangedRefreshInterval: TimeInterval = 3_600

    let defaults: UserDefaults?
    let lockFile: URL?
    let reloader: any NativeWidgetTimelineReloading

    init(
        defaults: UserDefaults?,
        lockFile: URL?,
        reloader: any NativeWidgetTimelineReloading
    ) {
        self.defaults = defaults
        self.lockFile = lockFile
        self.reloader = reloader
    }

    /// The production mirror: the live App Group suite, its lock file and
    /// `WidgetCenter`.
    static func live(
        reloader: any NativeWidgetTimelineReloading = NativeWidgetCenterTimelineReloader()
    ) -> NativeWidgetMirror {
        NativeWidgetMirror(
            defaults: WidgetAppGroup.liveDefaults(),
            lockFile: WidgetAppGroup.liveLockFile(),
            reloader: reloader
        )
    }

    /// Writes `projection` stamped with `NativeWidgetOwnerTag.make(binding:)`.
    ///
    /// - Parameters:
    ///   - ownerBinding: the §2.5 predicate `O` (or the seam's
    ///     `expectedOwnerBinding`). Nil is a no-op.
    ///   - isCurrentOwner: evaluated INSIDE the lock; must return true only
    ///     when `ownerBinding` is still the live owner and no account
    ///     boundary is in progress.
    ///   - force: rewrite even when the stored content is unchanged and
    ///     fresh (used once at install/launch). Every other trigger passes
    ///     false and relies on the `unchangedRefreshInterval` dedupe.
    @discardableResult
    func write(
        projection: WidgetSnapshot,
        ownerBinding: String?,
        isCurrentOwner: (String) -> Bool,
        force: Bool,
        now: Date = Date()
    ) -> NativeWidgetMirrorOutcome {
        guard let ownerBinding else { return .skippedNoOwner }
        guard let defaults, let lockFile else { return .unavailable }

        var snapshot = projection
        snapshot.ownerTag = NativeWidgetOwnerTag.make(binding: ownerBinding)
        let json: String
        do { json = try snapshot.encodedJSON() } catch { return .encodingFailed }

        let outcome: NativeWidgetMirrorOutcome
        do {
            outcome = try WidgetAppGroupLock.withExclusiveLock(at: lockFile) {
                guard isCurrentOwner(ownerBinding) else { return .skippedOwnerChanged }
                if !force, let stored = WidgetSnapshot.load(from: defaults),
                   stored.hasSameContent(as: snapshot),
                   let storedAt = stored.updatedAtDate,
                   case let age = now.timeIntervalSince(storedAt),
                   age >= 0, age < Self.unchangedRefreshInterval {
                    return .unchanged
                }
                defaults.set(json, forKey: WidgetAppGroup.snapshotKey)
                return .written
            }
        } catch WidgetAppGroupLockError.unavailable {
            return .unavailable
        } catch {
            return .lockFailed
        }
        // §4.2 step 3: reload outside the lock.
        if outcome == .written { reloader.reloadAllTimelines() }
        return outcome
    }
}

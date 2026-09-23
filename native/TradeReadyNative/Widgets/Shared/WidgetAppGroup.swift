import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// Task 11.01 (W1): the App Group constants and the one advisory-lock
// implementation shared by the app and the widget extension.
//
// Target membership: every file in `N/Widgets/Shared/` compiles into BOTH the
// app target (through the app's synchronized root group) and the
// TradeReadyWidgets extension (through its own synchronized group rooted at
// this folder). Keep this file Foundation-only: no WidgetKit, no SwiftUI, no
// app types. Contract: docs/native-phase-11-platform-hardening-contract-decisions.md
// §2.1 (keys) and §4.2 (lock protocol).

enum WidgetAppGroup {
    /// Contract §2.1. Must match both targets' `.entitlements` files.
    static let suiteName = "group.com.gettradereadyapp.tradeready"

    /// JSON string: the `WidgetSnapshot` mirror written by the app only.
    static let snapshotKey = "widgetSnapshot"
    /// JSON array string: pending widget/Siri actions (11.04 appends, the app replays).
    static let actionsKey = "widgetActions"
    /// JSON object string: the Siri-private trip session (11.04).
    static let activeTripKey = "activeTrip"
    /// JSON object string: the cold-launch deep-link handoff (11.04 writes, 11.06 consumes).
    static let pendingOpenURLKey = "pendingOpenUrl"

    /// Every key that carries account data. The sign-out scrubber verifies
    /// each one is gone after `removePersistentDomain`.
    static let accountKeys = [snapshotKey, actionsKey, activeTripKey, pendingOpenURLKey]

    /// The advisory lock file inside the App Group container (contract §4.2).
    static let lockFileName = ".tradeready-widget-actions.lock"

    /// The live App Group suite, or nil when the entitlement is missing.
    static func liveDefaults() -> UserDefaults? {
        UserDefaults(suiteName: suiteName)
    }

    /// The live lock file URL, or nil when the container is unavailable.
    static func liveLockFile() -> URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: suiteName)?
            .appendingPathComponent(lockFileName)
    }
}

enum WidgetAppGroupLockError: Error, Equatable {
    case unavailable
    case lockFailed
}

/// Contract §4.2, steps 1 and 3: `open(O_CREAT|O_RDWR, 0600)`, then
/// `flock(LOCK_EX)`; run the critical section; then unlock and close.
/// `flock` locks belong to the open file description, so two descriptors in
/// one process exclude each other exactly as two processes do.
///
/// Callers must reload widget timelines OUTSIDE the lock (step 3), and must
/// never write the suite without holding it.
enum WidgetAppGroupLock {
    static func withExclusiveLock<T>(at lockFile: URL, _ body: () throws -> T) throws -> T {
        do {
            try FileManager.default.createDirectory(
                at: lockFile.deletingLastPathComponent(), withIntermediateDirectories: true
            )
        } catch {
            throw WidgetAppGroupLockError.unavailable
        }
        let descriptor = open(lockFile.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw WidgetAppGroupLockError.lockFailed }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw WidgetAppGroupLockError.lockFailed }
        defer { flock(descriptor, LOCK_UN) }
        return try body()
    }
}

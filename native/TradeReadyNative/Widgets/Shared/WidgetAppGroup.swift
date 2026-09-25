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
    /// Phase 12 (12.00b.2-B): another open file description held the lock for
    /// the whole bounded wait. Nothing ran; the caller fails closed and keeps
    /// its work for a retry.
    case busy
}

/// Contract §4.2, steps 1 and 3: `open(O_CREAT|O_RDWR, 0600)`, then take
/// `flock` exclusively; run the critical section; then unlock and close.
/// `flock` locks belong to the open file description, so two descriptors in
/// one process exclude each other exactly as two processes do.
///
/// Phase 12 (12.00b.2-B, charter L74/L96, 2026-09-25): the acquire is
/// bounded. It tries `LOCK_EX | LOCK_NB`, backs off 1 ms doubling to a 16 ms
/// cap between attempts, makes one last attempt at the deadline, then throws
/// `.busy` without running the body. The main thread waits at most
/// `mainThreadBudget` (100 ms, under the 250 ms at which iOS counts a hang);
/// any other thread waits at most `offMainThreadBudget` (2 s: nothing is
/// frozen by the wait, and a stuck holder still ends in `.busy`). Real holds
/// last a few ms (an append, a mirror write) up to tens of ms (a claim of
/// ≤512 actions), so a busy result means a stuck or starved holder. There is
/// no blocking variant.
///
/// Callers must reload widget timelines OUTSIDE the lock (step 3), and must
/// never write the suite without holding it.
enum WidgetAppGroupLock {
    /// The longest the main thread waits for the lock.
    static let mainThreadBudget: TimeInterval = 0.1
    /// The longest any other thread waits for the lock.
    static let offMainThreadBudget: TimeInterval = 2
    /// The first backoff between `LOCK_NB` attempts; it doubles per attempt.
    static let firstRetryDelay: TimeInterval = 0.001
    /// The backoff cap (about ten attempts fit in the main-thread budget).
    static let maximumRetryDelay: TimeInterval = 0.016

    static func budget(onMainThread: Bool) -> TimeInterval {
        onMainThread ? mainThreadBudget : offMainThreadBudget
    }

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
        try acquire(descriptor, budget: budget(onMainThread: Thread.isMainThread))
        defer { flock(descriptor, LOCK_UN) }
        return try body()
    }

    /// `LOCK_NB` attempts with backoff until `budget` (monotonic clock) runs
    /// out. `EINTR` is retried; any other error is `lockFailed`.
    private static func acquire(_ descriptor: Int32, budget: TimeInterval) throws {
        let deadline = ProcessInfo.processInfo.systemUptime + budget
        var delay = firstRetryDelay
        while true {
            if flock(descriptor, LOCK_EX | LOCK_NB) == 0 { return }
            let failure = errno
            guard failure == EWOULDBLOCK || failure == EINTR else {
                throw WidgetAppGroupLockError.lockFailed
            }
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { throw WidgetAppGroupLockError.busy }
            Thread.sleep(forTimeInterval: min(delay, remaining))
            delay = min(delay * 2, maximumRetryDelay)
        }
    }
}

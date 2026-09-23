import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Minimal read-only surface for cross-process handoffs. UserDefaults cannot
/// provide an atomic compare-and-delete across the app and extensions, so this
/// first consumer deliberately never clears or rewrites the producer's value.
protocol NativeAppGroupInbox {
    func value(forKey key: String) -> String?
}

final class NativeUserDefaultsAppGroupInbox: NativeAppGroupInbox {
    static let suiteName = "group.com.gettradereadyapp.tradeready"

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
    static let accountKeys = ["widgetSnapshot", "widgetActions", "activeTrip", "pendingOpenUrl"]

    let suiteName: String
    let defaults: UserDefaults?
    let lockFile: URL?

    init(
        suiteName: String = NativeUserDefaultsAppGroupInbox.suiteName,
        defaults: UserDefaults? = UserDefaults(suiteName: NativeUserDefaultsAppGroupInbox.suiteName),
        lockFile: URL? = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: NativeUserDefaultsAppGroupInbox.suiteName)?
            .appendingPathComponent(".tradeready-widget-actions.lock")
    ) {
        self.suiteName = suiteName
        self.defaults = defaults
        self.lockFile = lockFile
    }

    func scrub() throws {
        guard let defaults, let lockFile else { throw NativeAppGroupAccountScrubError.unavailable }
        try FileManager.default.createDirectory(
            at: lockFile.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let descriptor = open(lockFile.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw NativeAppGroupAccountScrubError.lockFailed }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else {
            throw NativeAppGroupAccountScrubError.lockFailed
        }
        defer { flock(descriptor, LOCK_UN) }

        defaults.removePersistentDomain(forName: suiteName)
        guard Self.accountKeys.allSatisfy({ defaults.object(forKey: $0) == nil }) else {
            throw NativeAppGroupAccountScrubError.verificationFailed
        }
    }
}

enum NativePendingOpenURLConsumption: Equatable, Sendable {
    case notAuthorized
    case nothingPending
    case retainedInvalid
    case retainedMissingJob
    case routedJob(id: String)
    case presentedOnMyWay(id: String)
}

/// Consumes only the read-only navigation portion of the App Group contract.
/// Mutating widget actions and active-trip state deliberately remain untouched.
struct NativePendingOpenURLConsumer {
    static let key = "pendingOpenUrl"

    let inbox: any NativeAppGroupInbox

    func consume(
        localOwnerVerified: Bool,
        now: Date,
        jobExists: (String) -> Bool,
        routeToJob: (String) -> Void,
        presentOnMyWay: (String) -> Void
    ) -> NativePendingOpenURLConsumption {
        // Reading is unnecessary until the current live identity is proven to
        // own the migrated local data. In particular, never clear another
        // account's handoff on mismatch, expiry, or an unavailable auth server.
        guard localOwnerVerified else { return .notAuthorized }
        guard let raw = inbox.value(forKey: Self.key) else { return .nothingPending }

        guard let pending = NativeDeepLinkParser.parsePendingOpenURL(raw, now: now) else {
            return .retainedInvalid
        }
        let jobID = pending.route.jobID
        guard jobExists(jobID) else {
            return .retainedMissingJob
        }

        switch pending.route {
        case .onMyWay:
            // This route means "present a reviewed message", never "send".
            // The source remains read-only; the caller owns one-shot in-memory
            // presentation and the system composer still requires user action.
            presentOnMyWay(jobID)
            return .presentedOnMyWay(id: jobID)
        case .job:
            // The caller invokes this once at the verified startup boundary.
            // The source remains untouched and naturally becomes ineligible
            // after its five-minute freshness window.
            routeToJob(jobID)
            return .routedJob(id: jobID)
        }
    }
}

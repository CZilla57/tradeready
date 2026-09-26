import Foundation

// Phase 12 (12.02): the privacy-safe support report and the per-pass sync
// monitoring behind the cutover charter's remote signals
// (`docs/native-phase-12-monitoring.md`).
//
// The report is what "Prepare support report" (`NativeSupportReportAction`,
// in Settings > Migration support and on both blocked screens) writes
// (`AppStore.createPersistenceSupportReport`) and the owner shares
// explicitly. It is a closed schema of versions, booleans, bounded counts,
// age buckets and bounded diagnostic codes. It never holds a record, a name,
// an email, a phone number, a path, a URL, a token, a key, a session, an
// account id or binding, or document bytes: every string passes
// `sanitizedCode`, which replaces anything that is not a short code with
// "unrecognized", and the encoded report is capped at `maximumReportBytes`.

enum NativeSupportDiagnostics {
    /// 3: the Phase 12 (12.02) report. The Phase 3 persistence report (v2,
    /// `Canonical.PersistenceSupportReport`) is nested unchanged under
    /// `persistence`. 4 (12.06): adds `rollbackReadiness`.
    static let reportSchemaVersion = 4
    static let maximumReportBytes = 16_384
    static let maximumRecentCodes = 16
    static let maximumCodeBytes = 96
    static let maximumCount = 9_999
    static let unrecognized = "unrecognized"
    static let none = "none"
    /// Charter TH-3: a change queued for over 24 hours.
    static let pendingAgeThreshold: TimeInterval = 24 * 60 * 60
    /// Charter §5.5 / TH-6: the throttled-pass streak that is a burst.
    static let throttleStreakThreshold = 3

    private static let codeCharacters = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._/-"
    )
    private static let digits = CharacterSet(charactersIn: "0123456789")
    private static let hexDigits = CharacterSet(charactersIn: "0123456789abcdefABCDEF")

    /// A bounded diagnostic code, or "none" / "unrecognized". A code is at
    /// most `maximumCodeBytes` of `[A-Za-z0-9._/-]` (no space, `:`, `@`, `=`
    /// or newline, so never a sentence, URL, email or key-value pair), is
    /// left unchanged by the Phase 11 redaction (no key, token, phone or
    /// bytes), and has no run of 6+ digits or 12+ hex characters (no
    /// phone-like number, timestamp or record id).
    static func sanitizedCode(_ value: String?) -> String {
        guard let value, !value.isEmpty else { return none }
        guard value.utf8.count <= maximumCodeBytes,
              value.unicodeScalars.allSatisfy(codeCharacters.contains),
              !hasRun(of: digits, minimum: 6, in: value),
              !hasHexIdentifierRun(in: value),
              NativeErrorRedaction.standard.redactString(value) == value
        else { return unrecognized }
        return value
    }

    /// An error as `<domain>/<code>` only: never its message, user info or
    /// path. A domain that is not a bounded code keeps only the number.
    static func errorCode(_ error: Error) -> String {
        let ns = error as NSError
        let code = sanitizedCode("\(ns.domain)/\(ns.code)")
        return code == unrecognized ? "\(unrecognized)/\(ns.code)" : code
    }

    static func boundedCount(_ value: Int) -> Int {
        min(maximumCount, max(0, value))
    }

    /// "none", "under-1h", "1h-to-24h" or "over-24h". A date ahead of the
    /// clock reads as fresh.
    static func ageBucket(from date: Date?, now: Date) -> String {
        guard let date else { return none }
        let age = now.timeIntervalSince(date)
        if age < 3_600 { return "under-1h" }
        if age < pendingAgeThreshold { return "1h-to-24h" }
        return "over-24h"
    }

    /// A queued change's `ts` (`Canonical.MutationItem`, ISO 8601).
    static func queuedDate(_ ts: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: ts) { return date }
        return ISO8601DateFormatter().date(from: ts)
    }

    /// A sync code for an HTTP 429 (`http-response/<table>/429`,
    /// `pull/<table>/429`): charter TH-6 / OI-3.
    static func isThrottleCode(_ code: String?) -> Bool {
        code?.hasSuffix("/429") == true
    }

    /// The code a `reportError` value carries: a `{code, message}` object's
    /// code, an error's domain and code, else none.
    static func reportedCode(_ value: Any?) -> String {
        if let error = value as? Error { return errorCode(error) }
        if let object = value as? [String: Any] {
            switch object["code"] {
            case let code as String: return sanitizedCode(code)
            case let code as Int: return sanitizedCode(String(code))
            default: return none
            }
        }
        return none
    }

    /// Sorted-key JSON within `maximumBytes`: over the cap, the oldest recent
    /// codes are dropped (and counted in `recentCodesOmitted`); a report that
    /// still does not fit throws.
    static func encode(_ report: NativeSupportReport, maximumBytes: Int = maximumReportBytes) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var candidate = report
        while true {
            let data = try encoder.encode(candidate)
            if data.count <= maximumBytes { return data }
            guard !candidate.sync.recentCodes.isEmpty else {
                throw NativeSupportDiagnosticsError.reportTooLarge(bytes: data.count)
            }
            candidate.sync.recentCodes.removeFirst()
            candidate.sync.recentCodesOmitted = boundedCount(candidate.sync.recentCodesOmitted + 1)
        }
    }

    private static func hasRun(of set: CharacterSet, minimum: Int, in value: String) -> Bool {
        var run = 0
        for scalar in value.unicodeScalars {
            run = set.contains(scalar) ? run + 1 : 0
            if run >= minimum { return true }
        }
        return false
    }

    /// 12+ consecutive hex characters with at least one digit: a UUID segment
    /// or a hash, not a word.
    private static func hasHexIdentifierRun(in value: String) -> Bool {
        var run = 0
        var sawDigit = false
        for scalar in value.unicodeScalars {
            if hexDigits.contains(scalar) {
                run += 1
                if digits.contains(scalar) { sawDigit = true }
                if run >= 12, sawDigit { return true }
            } else {
                run = 0
                sawDigit = false
            }
        }
        return false
    }
}

enum NativeSupportDiagnosticsError: Error, Equatable {
    case reportTooLarge(bytes: Int)
}

/// The last `maximumRecentCodes` reported `(context, code)` pairs, oldest
/// first; a repeat of the newest merges into its count. Fed by
/// `AppStore.reportError`, so it holds exactly the codes sent to Sentry (and
/// the codes a disabled reporter would have sent). Bounded codes only.
struct NativeSupportCodeHistory: Equatable {
    struct Entry: Encodable, Equatable {
        let context: String
        let code: String
        fileprivate(set) var count: Int
    }

    private(set) var entries: [Entry] = []
    private(set) var omittedCount = 0

    mutating func record(context: String?, code: String?) {
        let context = NativeSupportDiagnostics.sanitizedCode(context)
        let code = NativeSupportDiagnostics.sanitizedCode(code)
        if let last = entries.indices.last, entries[last].context == context, entries[last].code == code {
            entries[last].count = NativeSupportDiagnostics.boundedCount(entries[last].count + 1)
            return
        }
        entries.append(Entry(context: context, code: code, count: 1))
        if entries.count > NativeSupportDiagnostics.maximumRecentCodes {
            entries.removeFirst(entries.count - NativeSupportDiagnostics.maximumRecentCodes)
            omittedCount = NativeSupportDiagnostics.boundedCount(omittedCount + 1)
        }
    }
}

/// Phase 12 (12.02): what `AppStore.applySyncStatus` watches across sync
/// passes, beyond the per-pass `pushQueue` / `pullRemote` reports. Only a
/// pass that reached the network counts (`completed`, `partial`, `failed`);
/// an early exit (`offline`, `backoffDeferred`, signed out, idle, already
/// running) changes nothing.
///
/// - `discarded` (TH-5): every pass that dropped an unsendable change.
/// - `throttled` (TH-6, OI-3): `throttleStreakThreshold` network passes in a
///   row whose push or pull code is a 429; once per streak. Any other network
///   pass ends the streak.
/// - `pendingAge` (TH-3): the oldest queued change is over 24 hours old at
///   the end of a network pass; once until the oldest change is younger
///   again (the queue drained or moved on).
struct NativeSyncMonitor: Equatable {
    enum Signal: Equatable {
        case discarded(table: String, count: Int)
        case throttled(passes: Int)
        case pendingAge(count: Int)
    }

    private(set) var throttledPassCount = 0
    private(set) var consecutiveThrottledPasses = 0
    private(set) var maxConsecutiveThrottledPasses = 0
    private(set) var discardedChangeCount = 0
    private var throttleStreakReported = false
    private var pendingAgeReported = false

    static func isNetworkPass(_ outcome: NativeSyncOutcome?) -> Bool {
        switch outcome {
        case .completed?, .partial?, .failed?: return true
        default: return false
        }
    }

    /// Call once per ended pass. A pass's discards count whatever its last
    /// outcome: the coordinator runs a trigger that arrived mid-pass as a
    /// rerun inside the same pass, and that rerun can end early (offline,
    /// backoff) after the first run dropped a change (review fix 1). The
    /// throttle and age rules read only passes that reached the network.
    /// `discardedTable` is the pass's first dropped table only.
    mutating func recordPass(_ status: NativeSyncStatus, oldestPendingAt: Date?, now: Date) -> [Signal] {
        var signals: [Signal] = []
        if status.discardedCount > 0 {
            discardedChangeCount = NativeSupportDiagnostics.boundedCount(discardedChangeCount + status.discardedCount)
            signals.append(.discarded(
                table: status.discardedTable ?? "unknown",
                count: NativeSupportDiagnostics.boundedCount(status.discardedCount)
            ))
        }
        guard Self.isNetworkPass(status.lastOutcome) else { return signals }
        if NativeSupportDiagnostics.isThrottleCode(status.diagnosticCode)
            || NativeSupportDiagnostics.isThrottleCode(status.lastPullResult?.diagnosticCode) {
            throttledPassCount = NativeSupportDiagnostics.boundedCount(throttledPassCount + 1)
            consecutiveThrottledPasses = NativeSupportDiagnostics.boundedCount(consecutiveThrottledPasses + 1)
            maxConsecutiveThrottledPasses = max(maxConsecutiveThrottledPasses, consecutiveThrottledPasses)
            if consecutiveThrottledPasses >= NativeSupportDiagnostics.throttleStreakThreshold, !throttleStreakReported {
                throttleStreakReported = true
                signals.append(.throttled(passes: consecutiveThrottledPasses))
            }
        } else {
            consecutiveThrottledPasses = 0
            throttleStreakReported = false
        }
        if let oldestPendingAt, now.timeIntervalSince(oldestPendingAt) >= NativeSupportDiagnostics.pendingAgeThreshold {
            if !pendingAgeReported {
                pendingAgeReported = true
                signals.append(.pendingAge(count: NativeSupportDiagnostics.boundedCount(status.pendingCount)))
            }
        } else {
            pendingAgeReported = false
        }
        return signals
    }

    /// An account boundary: the next account starts a new streak and a new
    /// age episode. The totals stay (counts only, for the support report).
    mutating func resetForAccountBoundary() {
        consecutiveThrottledPasses = 0
        throttleStreakReported = false
        pendingAgeReported = false
    }
}

/// The last launch-migration or "Try again" result, for the support report.
struct NativeLegacyMigrationSummary: Equatable {
    var outcome = "not-attempted"
    var operation = NativeSupportDiagnostics.none
    var failureCode = NativeSupportDiagnostics.none
    var importedCount = 0
    var missingPhotoCount = 0
    var adoptedPhotoCount = 0
    var deferredPhotoCount = 0
}

/// Phase 12 (12.06, charter §6 item 2): whether this device's account is
/// safe to move to the Expo rollback build. The Expo build reads the legacy
/// AsyncStorage left at the upgrade, so anything still only on this device
/// (a queued change, a refused change, an unreplayed widget/Siri action, a
/// photo whose bytes never uploaded) would be missing there; unfinished
/// booking or portal link work is reported as a note only. Made by
/// `AppStore.rollbackReadiness()`, which reads local state only, and by the
/// "Check everything is saved" drain (`AppStore.prepareRollbackReadiness`).
struct NativeRollbackReadiness: Equatable {
    /// Every reason the account is not ready, in declaration order. The
    /// first nine fail closed: the check then sends nothing.
    enum Blocker: String, CaseIterable, Equatable {
        /// Not the verified signed-in owner with its exact workspace.
        case notVerifiedOwner = "not-verified-owner"
        /// The initial sync has not completed for this owner.
        case initialSyncIncomplete = "initial-sync-incomplete"
        case writesBlocked = "writes-blocked"
        /// An account scrub is pending or blocked, or a deletion is recorded
        /// without its marker (or its record could not be read).
        case accountScrubPending = "account-scrub-pending"
        /// A boundary step (widget scrub, AI-key wipe, rejected-store scrub)
        /// is pending or unverified, or a boundary is suspending the mirror.
        case boundaryStepPending = "boundary-step-pending"
        /// A sign-in, sign-out, deletion, account switch or identity check
        /// is running.
        case accountOperationInFlight = "account-operation-in-flight"
        /// The account changed while the check was suspended in its drain.
        case accountChanged = "account-changed"
        /// The journal records a started or failed import, or the legacy
        /// migration is blocked.
        case migrationIncomplete = "migration-incomplete"
        case migrationUnreadable = "migration-unreadable"
        case pendingChanges = "pending-changes"
        /// A queue file is on disk that does not decode (`load` reads it as
        /// empty; this check never does).
        case pendingChangesUnreadable = "pending-changes-unreadable"
        /// The I2 rejected store holds entries: the owner must Retry or
        /// Discard each one. The check never discards them.
        case rejectedChanges = "rejected-changes"
        case rejectedChangesUnreadable = "rejected-changes-unreadable"
        case widgetActionsPending = "widget-actions-pending"
        /// No claim transport, or the App Group lock or queue failed.
        case widgetActionsUnreadable = "widget-actions-unreadable"
        /// A photo with local bytes and no `uploadedAt`.
        case photosPendingUpload = "photos-pending-upload"

        /// The conditions under which the check sends nothing.
        var failsClosed: Bool {
            switch self {
            case .notVerifiedOwner, .initialSyncIncomplete, .writesBlocked, .accountScrubPending,
                 .boundaryStepPending, .accountOperationInFlight, .accountChanged,
                 .migrationIncomplete, .migrationUnreadable:
                return true
            case .pendingChanges, .pendingChangesUnreadable, .rejectedChanges, .rejectedChangesUnreadable,
                 .widgetActionsPending, .widgetActionsUnreadable, .photosPendingUpload:
                return false
            }
        }
    }

    /// The React Native import's last journal entry. A native-only install
    /// has none: its first launch found no previous-app data (`.noData`
    /// writes no entry), so there is nothing to migrate.
    enum JournalState: String, Equatable {
        case completed
        case noEntry = "no-entry"
        case started
        case failed
        case unreadable
    }

    /// Phase 12 (12.06 fix round 2, R46): reported, never blocking. Each
    /// is something only this device holds that is not business data the
    /// Expo build would miss, so "Ready" never depends on it.
    enum Note: String, CaseIterable, Equatable {
        /// This owner's 8.08 booking/portal link work
        /// (`NativeScheduleBookingPendingWorkStore`). A mirror item records
        /// a change the server already made (display copy only); a
        /// reschedule proof guards a server resolve whose job change is in
        /// the ordinary queue (counted by `pendingChanges`). Nothing
        /// finishes a stuck item yet (defect P12-013).
        case bookingWorkPending = "booking-work-pending"
        /// That file is on disk and does not decode.
        case bookingWorkUnreadable = "booking-work-unreadable"
    }

    private(set) var blockers: [Blocker] = []
    /// In declaration order.
    private(set) var notes: [Note] = []
    var pendingChangeCount = 0
    var rejectedChangeCount = 0
    /// The refused changes (`table/recordId`) the owner must Retry or Discard
    /// in Settings › Cloud Sync. In memory only: the report carries the count.
    var rejectedChangeIDs: [String] = []
    var widgetActionCount = 0
    var photosPendingUploadCount = 0
    /// This owner's unfinished booking/portal link work items.
    var bookingWorkCount = 0
    var migrationJournal: JournalState = .noEntry

    var isReady: Bool { blockers.isEmpty }
    var failsClosed: Bool { blockers.contains { $0.failsClosed } }

    mutating func block(_ blocker: Blocker) {
        guard !blockers.contains(blocker) else { return }
        blockers.append(blocker)
        let order = Blocker.allCases
        blockers.sort { order.firstIndex(of: $0)! < order.firstIndex(of: $1)! }
    }

    mutating func note(_ note: Note) {
        guard !notes.contains(note) else { return }
        notes.append(note)
        let order = Note.allCases
        notes.sort { order.firstIndex(of: $0)! < order.firstIndex(of: $1)! }
    }
}

/// One run of the check: the forced push pass's outcome and the readiness
/// after it.
struct NativeRollbackReadinessCheck: Equatable {
    var readiness: NativeRollbackReadiness
    /// A sync outcome code (`completed`, `partial`, `offline`, …), or
    /// `not-configured` (no sync in this build), or `skipped` (a fail-closed
    /// condition held, so nothing was sent).
    var drainOutcome: String
    var checkedAt: Date
    /// The account boundary it belongs to; another account never sees it.
    var accountGeneration: UInt64
}

/// The Settings › Cloud Sync line for a check.
enum NativeRollbackReadinessCopy {
    static let ready = "Ready: everything on this device is saved to the cloud."

    static func summary(_ readiness: NativeRollbackReadiness) -> String {
        guard !readiness.isReady else { return ready }
        func plural(_ count: Int, _ one: String, _ many: String) -> String {
            "\(count) \(count == 1 ? one : many)"
        }
        var parts: [String] = []
        func add(_ part: String) { if !parts.contains(part) { parts.append(part) } }
        for blocker in readiness.blockers {
            switch blocker {
            case .notVerifiedOwner: add("sign in to your account")
            case .initialSyncIncomplete: add("the first sync hasn't finished")
            case .writesBlocked: add("saving is paused on this device")
            case .accountScrubPending, .boundaryStepPending, .accountOperationInFlight:
                add("an account change is still finishing")
            case .accountChanged: add("the account changed during the check, so run it again")
            case .migrationIncomplete, .migrationUnreadable:
                add("moving data from the previous app hasn't finished")
            case .pendingChanges:
                add(plural(readiness.pendingChangeCount, "change waiting to upload", "changes waiting to upload"))
            case .pendingChangesUnreadable: add("the list of waiting changes can't be read")
            case .rejectedChanges:
                add(plural(readiness.rejectedChangeCount,
                           "change the cloud refused needs Retry or Discard above",
                           "changes the cloud refused need Retry or Discard above"))
            case .rejectedChangesUnreadable: add("the list of refused changes can't be read")
            case .widgetActionsPending:
                add(plural(readiness.widgetActionCount, "widget or Siri action not applied yet",
                           "widget or Siri actions not applied yet"))
            case .widgetActionsUnreadable: add("widget and Siri actions can't be checked")
            case .photosPendingUpload:
                add(plural(readiness.photosPendingUploadCount, "photo waiting to upload", "photos waiting to upload"))
            }
        }
        return "Not ready yet: " + parts.joined(separator: "; ") + "."
    }

    /// A neutral line under the result for the notes, or nil. It never
    /// changes the result above it.
    static func note(_ readiness: NativeRollbackReadiness) -> String? {
        var parts: [String] = []
        for note in readiness.notes {
            switch note {
            case .bookingWorkPending:
                let count = readiness.bookingWorkCount
                parts.append("\(count) booking or portal link update \(count == 1 ? "hasn't" : "haven't") finished on this device")
            case .bookingWorkUnreadable:
                parts.append("booking and portal link updates can't be checked on this device")
            }
        }
        guard !parts.isEmpty else { return nil }
        return "Also: " + parts.joined(separator: "; ")
            + ". This work holds no changes that need uploading, so it doesn't change the result."
    }
}

/// A string field of the report: always a bounded code.
struct NativeSupportCode: Encodable, Equatable, ExpressibleByStringLiteral {
    let value: String

    init(_ value: String?) { self.value = NativeSupportDiagnostics.sanitizedCode(value) }
    init(stringLiteral value: String) { self.init(value) }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
}

/// The v4 support report. A closed schema: every field is a version, a
/// boolean, a bounded count, an age bucket or a `NativeSupportCode`.
struct NativeSupportReport: Encodable, Equatable {
    /// Named `AppInfo`, not `App`: the 11.10b accessibility audit reads
    /// `: App` as a SwiftUI app declaration, and this file declares no UI.
    struct AppInfo: Encodable, Equatable {
        var version: NativeSupportCode
        var build: NativeSupportCode
    }

    struct LaunchMigration: Encodable, Equatable {
        var notice: NativeSupportCode
        var blocked: Bool
        var persistenceBlockReason: NativeSupportCode
        var persistenceBlockDetail: NativeSupportCode
        var lastOutcome: NativeSupportCode
        var lastOperation: NativeSupportCode
        var lastFailureCode: NativeSupportCode
        var importedCount: Int
        var missingPhotoCount: Int
        var adoptedPhotoCount: Int
        var deferredPhotoCount: Int
    }

    struct BoundaryStep: Encodable, Equatable {
        var step: NativeSupportCode
        var pending: Bool
        var unverified: Bool
    }

    struct AccountBoundary: Encodable, Equatable {
        var scrubPending: Bool
        /// none / live / all / unreadable / undecodable.
        var scrubPendingScope: NativeSupportCode
        var scrubBlocked: Bool
        /// none / live / all / unknown.
        var scrubBlockedScope: NativeSupportCode
        var scrubBlockedCount: Int
        var deletionPendingWithoutMarker: Bool
        var deletionRecordUnverified: Bool
        /// The Keychain `account-deletion-scrub-pending.v1` record: absent /
        /// present / unreadable (presence only).
        var deletionRecord: NativeSupportCode
        /// The P12-003 `store.json.account-scrub-cleared` record (presence).
        var workspaceClearedRecord: Bool
        var cleanupPending: Bool
        var boundarySteps: [BoundaryStep]
        var boundaryStepMarkerWriteFailureCount: Int
        var boundaryStepRecordFailureCount: Int
        var aiProviderKeyWipeFailureCount: Int
    }

    struct Sync: Encodable, Equatable {
        var pendingCount: Int
        var oldestPendingAge: NativeSupportCode
        var isSyncing: Bool
        var consecutiveFailures: Int
        var lastOutcome: NativeSupportCode
        var diagnosticCode: NativeSupportCode
        var lastPullState: NativeSupportCode
        var lastPullCode: NativeSupportCode
        var backoffActive: Bool
        var lastSuccessfulSyncAge: NativeSupportCode
        var rejectedChangeCount: Int
        var rejectedChangeOverflowCount: Int
        var rejectedChangeScrubFailureCount: Int
        var discardedChangeCount: Int
        var throttledPassCount: Int
        var consecutiveThrottledPasses: Int
        var maxConsecutiveThrottledPasses: Int
        var recentCodes: [NativeSupportCodeHistory.Entry]
        var recentCodesOmitted: Int
    }

    struct Widgets: Encodable, Equatable {
        var mirrorDirty: Bool
        var mirrorLockBusyCount: Int
        var ownerDroppedActionCount: Int
        var quarantinedQueueCount: Int
        var accountSwitchScrubFailureCount: Int
        var setAsideActionCount: Int
        var quarantinedClaimCount: Int
        var unreadableClaimCount: Int
    }

    struct LegacyBackupProtection: Encodable, Equatable {
        var checks: Int
        var enumeratorUnavailable: Int
        var lastProtectedFiles: Int
        var lastFailedFiles: Int
        var failedFileTotal: Int
    }

    /// Phase 12 (12.06): the last rollback-readiness check for this account
    /// (`lastCheck` `none`, zero counts and no blockers until one runs).
    struct RollbackReadiness: Encodable, Equatable {
        /// none / ready / not-ready.
        var lastCheck: NativeSupportCode
        var lastCheckAge: NativeSupportCode
        /// none / skipped / not-configured / a sync outcome code.
        var drainOutcome: NativeSupportCode
        /// `NativeRollbackReadiness.Blocker` codes.
        var blockers: [NativeSupportCode]
        /// `NativeRollbackReadiness.Note` codes: reported, never blocking
        /// (fix round 2).
        var notes: [NativeSupportCode]
        var pendingChangeCount: Int
        var rejectedChangeCount: Int
        var widgetActionCount: Int
        var photosPendingUploadCount: Int
        /// Unfinished booking/portal link work items (fix round 1; a note
        /// since fix round 2, never a blocker).
        var bookingWorkCount: Int
        /// none / completed / no-entry / started / failed / unreadable.
        var migrationJournal: NativeSupportCode
    }

    var reportSchemaVersion = NativeSupportDiagnostics.reportSchemaVersion
    var app: AppInfo
    /// The v2 persistence report, or null when the snapshot cannot be read
    /// (then `persistenceUnavailableCode` says why, as a code).
    var persistence: Canonical.PersistenceSupportReport?
    var persistenceUnavailableCode: NativeSupportCode
    var launchMigration: LaunchMigration
    var accountBoundary: AccountBoundary
    var sync: Sync
    var widgets: Widgets
    var legacyBackupProtection: LegacyBackupProtection
    var rollbackReadiness: RollbackReadiness

    private enum CodingKeys: String, CodingKey {
        case reportSchemaVersion, app, persistence, persistenceUnavailableCode, launchMigration
        case accountBoundary, sync, widgets, legacyBackupProtection, rollbackReadiness
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(reportSchemaVersion, forKey: .reportSchemaVersion)
        try values.encode(app, forKey: .app)
        if let persistence {
            try values.encode(persistence, forKey: .persistence)
        } else {
            try values.encodeNil(forKey: .persistence)
        }
        try values.encode(persistenceUnavailableCode, forKey: .persistenceUnavailableCode)
        try values.encode(launchMigration, forKey: .launchMigration)
        try values.encode(accountBoundary, forKey: .accountBoundary)
        try values.encode(sync, forKey: .sync)
        try values.encode(widgets, forKey: .widgets)
        try values.encode(legacyBackupProtection, forKey: .legacyBackupProtection)
        try values.encode(rollbackReadiness, forKey: .rollbackReadiness)
    }
}

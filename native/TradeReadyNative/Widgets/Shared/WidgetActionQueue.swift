import Foundation
import os

// Task 11.04 (A1–A3): the pure App Group write policy behind every App Intent.
//
// Target membership: `N/Widgets/Shared/` compiles into BOTH the app target and
// the TradeReadyWidgets extension (11.01 §7 file-placement rule). Keep this
// file Foundation-only — no AppIntents, WidgetKit, SwiftUI or app types — so
// host tests (native/run-app-intent-queue-tests.sh) compile it with swiftc.
// (`os` is the one other import, for the busy-lock line's `Logger`; Phase 12
// final review M6.)
// The intents themselves (`WidgetIntents.swift`, `N/Intents/`) are thin shells
// over `WidgetIntentEngine`.
//
// Contract: docs/native-phase-11-platform-hardening-contract-decisions.md
// - §4.1 action JSON shapes and field rules;
// - §4.2 lock protocol (only `WidgetAppGroupLock`, never a second flock).
//   Phase 12 (12.00b.2-B): the acquire is bounded (100 ms on the main
//   thread, 2 s elsewhere); a busy lock is `WidgetIntentFailure.busy` and
//   nothing is read or written;
// - §4.3 writer rules: refuse at 512, exact-duplicate ids are idempotent and
//   differing duplicates fail, never overwrite a malformed queue, validate the
//   new action before appending (string rules shared with the planner via
//   `WidgetActionFieldRules`; numeric ranges pinned to it by tests);
// - §4.4 the private `activeTrip` session;
// - §4.5 owner stamping: every snapshot read used to build an action (the
//   `ownerTag`, `nextJob`, `timer`, and the queue's last pending timer type)
//   happens in the SAME lock hold as the append. No snapshot or no tag →
//   refuse and write nothing. The extension never derives a tag; it copies
//   the snapshot's;
// - §6.2 the `pendingOpenUrl` stash `{url, at, ownerTag}`, written under the
//   lock in the same hold as the `nextJob`/`ownerTag` read.
// Nothing here writes canonical data: the app replays the queue through its
// normal save paths (`N/NativeWidgetActionReplay.swift`, contract §4.6).

/// Phase 12 final review (M6): the busy-lock line goes to the unified log,
/// which a TestFlight or App Store build keeps (`print` never reaches it).
private let widgetIntentLog = Logger(subsystem: "com.tradeready.native", category: "diagnostics")

// MARK: - Store

/// The App Group key-value surface the intents touch. `UserDefaults` conforms
/// as-is; host tests inject an in-memory store that also proves every access
/// happens while the advisory lock is held.
protocol WidgetAppGroupKeyValueStore: AnyObject {
    func string(forKey defaultName: String) -> String?
    func set(_ value: Any?, forKey defaultName: String)
    func removeObject(forKey defaultName: String)
}

extension UserDefaults: WidgetAppGroupKeyValueStore {}

/// Injected services: the store, the lock file, the clock, the action-id
/// source and the local time zone (for `yyyy-MM-dd` dates, FA-039).
struct WidgetIntentEnvironment {
    var store: (any WidgetAppGroupKeyValueStore)?
    var lockFile: URL?
    var now: () -> Date
    var makeActionID: () -> String
    var timeZone: TimeZone
    /// Phase 12 (12.00b.2-B): called once per busy lock acquire (the bounded
    /// wait ran out). A payload-free diagnostic seam; host tests count it.
    var onLockBusy: () -> Void = {}

    static func live() -> WidgetIntentEnvironment {
        WidgetIntentEnvironment(
            store: WidgetAppGroup.liveDefaults(),
            lockFile: WidgetAppGroup.liveLockFile(),
            now: { Date() },
            makeActionID: { UUID().uuidString },
            timeZone: .current,
            onLockBusy: { widgetIntentLog.notice("TradeReadyWidgetLock stage=busy site=intent") }
        )
    }
}

// MARK: - JSON values

/// A loss-aware JSON value for reading the untrusted queue and trip session.
/// Numbers are Doubles: the only numbers compared here are ones an intent
/// wrote (odometers, amounts), which round-trip exactly.
enum WidgetJSONValue: Codable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([WidgetJSONValue])
    case object([String: WidgetJSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null; return }
        if let value = try? container.decode(Bool.self) { self = .bool(value); return }
        if let value = try? container.decode(Double.self) { self = .number(value); return }
        if let value = try? container.decode(String.self) { self = .string(value); return }
        if let value = try? container.decode([WidgetJSONValue].self) { self = .array(value); return }
        self = .object(try container.decode([String: WidgetJSONValue].self))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var numberValue: Double? {
        if case .number(let value) = self { return value }
        return nil
    }

    /// `.sortedKeys` + `.withoutEscapingSlashes`. `JSONEncoder` writes the
    /// shortest round-trip form of a Double (`42.1`, not
    /// `42.100000000000001` as `JSONSerialization` does).
    static func encodeJSON<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let json = String(data: try encoder.encode(value), encoding: .utf8) else {
            throw WidgetIntentFailure.writeFailed
        }
        return json
    }

    static func decodeJSON(_ raw: String) -> WidgetJSONValue? {
        try? JSONDecoder().decode(WidgetJSONValue.self, from: Data(raw.utf8))
    }
}

// MARK: - Actions

/// Contract §4.1: `timer_start | timer_stop | trip_log | expense_log`.
enum WidgetPendingActionType: String {
    case timerStart = "timer_start"
    case timerStop = "timer_stop"
    case tripLog = "trip_log"
    case expenseLog = "expense_log"
}

/// One queued action. Every writer stamps `ownerTag` (§4.5).
struct WidgetPendingAction: Equatable {
    var fields: [String: WidgetJSONValue]

    var id: String { fields["id"]?.stringValue ?? "" }
    var type: String { fields["type"]?.stringValue ?? "" }

    func encodedJSON() throws -> String {
        try WidgetJSONValue.encodeJSON(fields)
    }
}

/// Contract §5.3: raw values equal RN `ExpenseCategoryId`; labels are the
/// app's display labels (spoken back so Siri confirms what the app shows).
enum WidgetExpenseCategory: String, CaseIterable {
    case materials, tools, fuel, labor, insurance, software, marketing, other

    var label: String {
        switch self {
        case .materials: return "Materials"
        case .tools: return "Tools & Equipment"
        case .fuel: return "Fuel & Transport"
        case .labor: return "Subcontractors"
        case .insurance: return "Insurance"
        case .software: return "Software & Apps"
        case .marketing: return "Marketing"
        case .other: return "Other"
        }
    }
}

// MARK: - Failures and outcomes

enum WidgetIntentFailure: Error, Equatable {
    /// No App Group container, or the lock could not be taken (§4.2). Nothing
    /// is written without the lock.
    case unavailable
    /// No decodable snapshot, or no valid `ownerTag` on it (§4.5): "Open
    /// TradeReady and sign in first."
    case signInRequired
    /// `widgetActions` exists but is not a JSON array of objects (§4.3). The
    /// stored value is left byte-for-byte untouched.
    case malformedQueue
    /// The queue already holds 512 entries (§4.3).
    case queueFull
    /// An entry with the same id but different content exists (§4.3).
    case duplicateConflict
    /// The new action fails a planner field rule (§4.1); nothing is appended.
    case invalidAction(field: String)
    /// A write did not read back as written.
    case writeFailed
    /// Phase 12 (12.00b.2-B): the shared lock stayed busy for the whole
    /// bounded wait. Nothing was read or written; the intent reports failure.
    case busy
}

enum WidgetTimerIntentOutcome: Equatable {
    case queued(WidgetPendingAction)
    /// An exact duplicate id was already queued (idempotent retry).
    case alreadyQueued(WidgetPendingAction)
    /// Start with an empty job id writes nothing (RN parity).
    case ignoredEmptyJobID
    /// Start refuses a stale snapshot (§3.3, defense in depth behind 11.03's
    /// hidden Start button).
    case stale
    case failed(WidgetIntentFailure)

    var wroteQueue: Bool {
        if case .queued = self { return true }
        return false
    }
}

enum WidgetClockInOutcome: Equatable {
    case clockedIn(jobTitle: String, action: WidgetPendingAction)
    case alreadyClockedIn
    case noUpcomingJob
    case stale
    case failed(WidgetIntentFailure)

    var wroteQueue: Bool {
        if case .clockedIn = self { return true }
        return false
    }
}

enum WidgetClockOutOutcome: Equatable {
    case clockedOut(action: WidgetPendingAction)
    case notClockedIn
    case failed(WidgetIntentFailure)

    var wroteQueue: Bool {
        if case .clockedOut = self { return true }
        return false
    }
}

enum WidgetStartTripOutcome: Equatable {
    case started(replacedStale: Bool, trip: WidgetActiveTrip)
    case alreadyRunning
    case invalidOdometer
    case failed(WidgetIntentFailure)
}

enum WidgetStopTripOutcome: Equatable {
    case logged(miles: Double, action: WidgetPendingAction)
    case noTrip
    /// The session started more than a day before it was stopped; it was
    /// removed and never logged (§4.4, brief item 5).
    case discardedStale
    case invalidOdometer
    case failed(WidgetIntentFailure)

    var wroteQueue: Bool {
        if case .logged = self { return true }
        return false
    }
}

enum WidgetLogExpenseOutcome: Equatable {
    case logged(amount: Double, category: WidgetExpenseCategory, action: WidgetPendingAction)
    case invalidAmount
    case failed(WidgetIntentFailure)

    var wroteQueue: Bool {
        if case .logged = self { return true }
        return false
    }
}

enum WidgetOnMyWayOutcome: Equatable {
    /// The stash was written and verified; `url` is what the app routes.
    case opening(url: String, customerName: String, stashJSON: String)
    case noUpcomingJob
    case stale
    case failed(WidgetIntentFailure)
}

enum WidgetNextJobOutcome: Equatable {
    /// Carries the engine's clock and zone so the spoken "today"/"tomorrow"
    /// uses the same instant as the upcoming check.
    case nextJob(WidgetSnapshot.NextJob, now: Date, timeZone: TimeZone)
    case noUpcomingJob
    case stale
    case failed(WidgetIntentFailure)
}

enum WidgetOutstandingOutcome: Equatable {
    case owed(Double)
    case nothingOutstanding
    case stale
    case failed(WidgetIntentFailure)
}

/// The queue as read inside the lock: its exact stored text plus its entries.
struct WidgetQueueContents {
    var raw: String
    var entries: [[String: WidgetJSONValue]]
}

// MARK: - Trip session and open-URL stash

/// Contract §4.4: `{id?, startedAt, odometerStart, stopAt?, odometerEnd?, ownerTag}`.
struct WidgetActiveTrip: Codable, Equatable {
    var id: String?
    var startedAt: String
    var odometerStart: Double
    var stopAt: String?
    var odometerEnd: Double?
    var ownerTag: String?

    /// Nil for anything that is not an object with a string `startedAt` and a
    /// numeric `odometerStart` (RN `siriLoadActiveTrip`).
    static func decode(_ raw: String?) -> WidgetActiveTrip? {
        guard let raw, case .object(let fields)? = WidgetJSONValue.decodeJSON(raw),
              let startedAt = fields["startedAt"]?.stringValue,
              let odometerStart = fields["odometerStart"]?.numberValue
        else { return nil }
        return WidgetActiveTrip(
            id: fields["id"]?.stringValue,
            startedAt: startedAt,
            odometerStart: odometerStart,
            stopAt: fields["stopAt"]?.stringValue,
            odometerEnd: fields["odometerEnd"]?.numberValue,
            ownerTag: fields["ownerTag"]?.stringValue
        )
    }
}

/// Contract §6.2: the cold-launch handoff `{url, at, ownerTag}`.
struct WidgetPendingOpenURLStash: Codable, Equatable {
    var url: String
    var at: String
    var ownerTag: String
}

// MARK: - Engine

struct WidgetIntentEngine {
    /// Contract §4.3.
    static let maximumQueueCount = 512
    /// RN `siriStaleActiveTripInterval` (§3.3, §4.4): one shared day boundary.
    static let staleTripInterval: TimeInterval = 86_400
    /// RN `expenseFromAction` ceiling (§4.1).
    static let maximumExpenseAmount: Double = 1_000_000
    /// The planner's expense floor (`Decimal(string: "0.0000000000000000001")`
    /// in `NativeWidgetActionBatchPlanner`). A positive Double below it would
    /// pass "> 0" here and then fail the whole batch at replay (§4.3).
    static let minimumExpenseAmount: Double = 1e-19
    /// Native ceiling for an odometer reading. The planner decodes numbers as
    /// `Decimal`, whose JSON decode fails at 1e128 and above, which would turn
    /// the whole queue into `malformedQueue` at replay (§4.3, §4.6). Ten
    /// million miles is far past any real odometer.
    static let maximumOdometer: Double = 10_000_000
    static let onMyWayURLPrefix = "tradeready://onmyway/"

    let environment: WidgetIntentEnvironment

    init(environment: WidgetIntentEnvironment = .live()) {
        self.environment = environment
    }

    // MARK: Timer (widget buttons; both targets)

    func startTimer(jobID: String) -> WidgetTimerIntentOutcome {
        guard !jobID.isEmpty else { return .ignoredEmptyJobID }
        let result = locked { store -> WidgetTimerIntentOutcome in
            let owned = try Self.ownedSnapshot(store)
            if owned.snapshot.isStale(now: environment.now()) { return .stale }
            let action = makeAction(.timerStart, ownerTag: owned.tag, extra: ["jobId": .string(jobID)])
            let queue = try Self.readQueue(store)
            return try append(action, store: store, queue: queue) ? .queued(action) : .alreadyQueued(action)
        }
        return result.fold(failure: WidgetTimerIntentOutcome.failed)
    }

    func stopTimer(jobID: String) -> WidgetTimerIntentOutcome {
        let result = locked { store -> WidgetTimerIntentOutcome in
            let owned = try Self.ownedSnapshot(store)
            // Stop stays allowed when stale (§3.3): replay clamps it and
            // ignores a stop with no open session.
            let extra: [String: WidgetJSONValue] = jobID.isEmpty ? [:] : ["jobId": .string(jobID)]
            let action = makeAction(.timerStop, ownerTag: owned.tag, extra: extra)
            let queue = try Self.readQueue(store)
            return try append(action, store: store, queue: queue) ? .queued(action) : .alreadyQueued(action)
        }
        return result.fold(failure: WidgetTimerIntentOutcome.failed)
    }

    // MARK: Clock in / out (Siri)

    func clockIn() -> WidgetClockInOutcome {
        let result = locked { store -> WidgetClockInOutcome in
            let owned = try Self.ownedSnapshot(store)
            let now = environment.now()
            if owned.snapshot.isStale(now: now) { return .stale }
            let queue = try Self.readQueue(store)
            if Self.isOnTheClock(snapshot: owned.snapshot, ownerTag: owned.tag, queue: queue) { return .alreadyClockedIn }
            guard let job = upcomingJob(owned.snapshot, now: now) else { return .noUpcomingJob }
            let action = makeAction(.timerStart, ownerTag: owned.tag, extra: ["jobId": .string(job.id)])
            _ = try append(action, store: store, queue: queue)
            return .clockedIn(jobTitle: job.title, action: action)
        }
        return result.fold(failure: WidgetClockInOutcome.failed)
    }

    func clockOut() -> WidgetClockOutOutcome {
        let result = locked { store -> WidgetClockOutOutcome in
            let owned = try Self.ownedSnapshot(store)
            let queue = try Self.readQueue(store)
            guard Self.isOnTheClock(snapshot: owned.snapshot, ownerTag: owned.tag, queue: queue) else { return .notClockedIn }
            var extra: [String: WidgetJSONValue] = [:]
            // Omitted when the snapshot does not know it (a queued clock-in has
            // not reached the snapshot yet): replay stops the single running job.
            if let jobID = owned.snapshot.timer?.jobId, !jobID.isEmpty {
                extra["jobId"] = .string(jobID)
            }
            let action = makeAction(.timerStop, ownerTag: owned.tag, extra: extra)
            _ = try append(action, store: store, queue: queue)
            return .clockedOut(action: action)
        }
        return result.fold(failure: WidgetClockOutOutcome.failed)
    }

    // MARK: Trips (Siri)

    func startTrip(odometerStart: Double) -> WidgetStartTripOutcome {
        guard Self.isValidOdometer(odometerStart) else { return .invalidOdometer }
        let result = locked { store -> WidgetStartTripOutcome in
            let owned = try Self.ownedSnapshot(store)
            let now = environment.now()
            var replacedStale = false
            if let existing = WidgetActiveTrip.decode(store.string(forKey: WidgetAppGroup.activeTripKey)),
               existing.ownerTag == owned.tag {
                guard Self.isStaleTrip(existing, reference: now) else { return .alreadyRunning }
                replacedStale = true
            }
            // A trip with another owner's tag (or none) is discarded, never
            // logged (§4.4 native addition); a malformed value is replaced.
            let trip = WidgetActiveTrip(
                id: environment.makeActionID(),
                startedAt: WidgetSnapshot.isoTimestamp(now),
                odometerStart: odometerStart,
                stopAt: nil,
                odometerEnd: nil,
                ownerTag: owned.tag
            )
            try Self.saveTrip(trip, store: store)
            return .started(replacedStale: replacedStale, trip: trip)
        }
        return result.fold(failure: WidgetStartTripOutcome.failed)
    }

    func stopTrip(odometerEnd: Double) -> WidgetStopTripOutcome {
        let result = locked { store -> WidgetStopTripOutcome in
            let owned = try Self.ownedSnapshot(store)
            guard var trip = WidgetActiveTrip.decode(store.string(forKey: WidgetAppGroup.activeTripKey))
            else { return .noTrip }
            guard trip.ownerTag == owned.tag else {
                try Self.removeTrip(store)
                return .noTrip
            }
            let now = environment.now()
            let reference = trip.stopAt.flatMap(WidgetSnapshot.parseISODate) ?? now
            if Self.isStaleTrip(trip, reference: reference) {
                try Self.removeTrip(store)
                return .discardedStale
            }
            // A crash retry logs the persisted reading, so the new one is
            // only validated when there is no persisted `odometerEnd` yet.
            guard Self.isValidOdometer(trip.odometerStart),
                  trip.odometerEnd != nil || Self.isValidOdometer(odometerEnd)
            else { return .invalidOdometer }
            // Persist a stable completion payload first so a retry after a
            // crash reuses the same id, stop time and odometer (RN parity).
            if trip.id == nil { trip.id = environment.makeActionID() }
            if trip.stopAt == nil { trip.stopAt = WidgetSnapshot.isoTimestamp(now) }
            if trip.odometerEnd == nil { trip.odometerEnd = odometerEnd }
            guard let id = trip.id, let stopAt = trip.stopAt, let stableEnd = trip.odometerEnd,
                  let started = WidgetSnapshot.parseISODate(trip.startedAt)
            else { throw WidgetIntentFailure.writeFailed }
            try Self.saveTrip(trip, store: store)

            let action = WidgetPendingAction(fields: [
                "id": .string(id),
                "type": .string(WidgetPendingActionType.tripLog.rawValue),
                "at": .string(stopAt),
                "date": .string(Self.localDateString(started, timeZone: environment.timeZone)),
                "odometerStart": .number(trip.odometerStart),
                "odometerEnd": .number(stableEnd),
                "ownerTag": .string(owned.tag),
            ])
            _ = try append(action, store: store, queue: Self.readQueue(store))
            try Self.removeTrip(store)
            return .logged(miles: max(0, stableEnd - trip.odometerStart), action: action)
        }
        return result.fold(failure: WidgetStopTripOutcome.failed)
    }

    // MARK: Expense (Siri)

    func logExpense(
        amount: Double,
        category: WidgetExpenseCategory,
        description: String?
    ) -> WidgetLogExpenseOutcome {
        guard Self.isValidExpenseAmount(amount) else { return .invalidAmount }
        let result = locked { store -> WidgetLogExpenseOutcome in
            let owned = try Self.ownedSnapshot(store)
            let now = environment.now()
            var extra: [String: WidgetJSONValue] = [
                // Local frame: an expense logged at 11 pm belongs to that day.
                "date": .string(Self.localDateString(now, timeZone: environment.timeZone)),
                "amount": .number(amount),
                "category": .string(category.rawValue),
            ]
            // Empty or absent → omitted; replay files it as "Logged via Siri".
            let trimmed = description?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !trimmed.isEmpty { extra["description"] = .string(trimmed) }
            let action = makeAction(.expenseLog, ownerTag: owned.tag, extra: extra, at: now)
            _ = try append(action, store: store, queue: Self.readQueue(store))
            return .logged(amount: amount, category: category, action: action)
        }
        return result.fold(failure: WidgetLogExpenseOutcome.failed)
    }

    // MARK: On My Way (Siri, runs in the app process)

    func stashOnMyWay() -> WidgetOnMyWayOutcome {
        let result = locked { store -> WidgetOnMyWayOutcome in
            let owned = try Self.ownedSnapshot(store)
            let now = environment.now()
            if owned.snapshot.isStale(now: now) { return .stale }
            guard let job = upcomingJob(owned.snapshot, now: now) else { return .noUpcomingJob }
            guard WidgetActionFieldRules.isValidIdentifier(job.id),
                  let url = Self.onMyWayURL(jobID: job.id)
            else { throw WidgetIntentFailure.invalidAction(field: "jobId") }
            let stash = WidgetPendingOpenURLStash(
                url: url, at: WidgetSnapshot.isoTimestamp(now), ownerTag: owned.tag
            )
            let json = try WidgetJSONValue.encodeJSON(stash)
            store.set(json, forKey: WidgetAppGroup.pendingOpenURLKey)
            guard store.string(forKey: WidgetAppGroup.pendingOpenURLKey) == json else {
                throw WidgetIntentFailure.writeFailed
            }
            return .opening(url: url, customerName: job.customerName, stashJSON: json)
        }
        return result.fold(failure: WidgetOnMyWayOutcome.failed)
    }

    /// `tradeready://onmyway/<id>`, with the id percent-encoded to the RFC 3986
    /// unreserved set so `NativeDeepLinkParser` decodes it back exactly (a
    /// no-op for the usual alphanumeric/-/_ ids).
    static func onMyWayURL(jobID: String) -> String? {
        let unreserved = CharacterSet(
            charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~"
        )
        guard let encoded = jobID.addingPercentEncoding(withAllowedCharacters: unreserved) else { return nil }
        return onMyWayURLPrefix + encoded
    }

    // MARK: Read-only (Siri): Next Job, Outstanding

    /// Reads only the projected snapshot fields; writes nothing and takes no
    /// lock (a display read, §4.5 applies to action builders).
    func nextJob() -> WidgetNextJobOutcome {
        switch readOnlySnapshot() {
        case .failure(let failure): return .failed(failure)
        case .success(let snapshot):
            let now = environment.now()
            if snapshot.isStale(now: now) { return .stale }
            guard let job = upcomingJob(snapshot, now: now) else { return .noUpcomingJob }
            return .nextJob(job, now: now, timeZone: environment.timeZone)
        }
    }

    func outstanding() -> WidgetOutstandingOutcome {
        switch readOnlySnapshot() {
        case .failure(let failure): return .failed(failure)
        case .success(let snapshot):
            if snapshot.isStale(now: environment.now()) { return .stale }
            let total = snapshot.outstandingTotal ?? 0
            guard total.isFinite, total > 0 else { return .nothingOutstanding }
            return .owed(total)
        }
    }

    private func readOnlySnapshot() -> Result<WidgetSnapshot, WidgetIntentFailure> {
        guard let store = environment.store else { return .failure(.unavailable) }
        do {
            return .success(try Self.ownedSnapshot(store).snapshot)
        } catch let failure as WidgetIntentFailure {
            return .failure(failure)
        } catch {
            return .failure(.unavailable)
        }
    }

    // MARK: Lock + snapshot

    /// Runs `body` inside ONE `WidgetAppGroupLock` hold (§4.2). Every store
    /// read and write an action writer makes happens inside it (§4.5).
    /// Phase 12 (12.00b.2-B): a busy lock (the bounded wait ran out) is
    /// `.busy`, reported once through `onLockBusy`; nothing ran.
    private func locked<T>(
        _ body: (any WidgetAppGroupKeyValueStore) throws -> T
    ) -> Result<T, WidgetIntentFailure> {
        guard let store = environment.store, let lockFile = environment.lockFile else {
            return .failure(.unavailable)
        }
        do {
            return .success(try WidgetAppGroupLock.withExclusiveLock(at: lockFile) { try body(store) })
        } catch let failure as WidgetIntentFailure {
            return .failure(failure)
        } catch WidgetAppGroupLockError.busy {
            environment.onLockBusy()
            return .failure(.busy)
        } catch {
            return .failure(.unavailable)
        }
    }

    /// The snapshot plus its tag, or `signInRequired` when either is missing.
    /// A tag must be 64 lowercase hex characters (§2.3).
    static func ownedSnapshot(
        _ store: any WidgetAppGroupKeyValueStore
    ) throws -> (snapshot: WidgetSnapshot, tag: String) {
        guard let raw = store.string(forKey: WidgetAppGroup.snapshotKey),
              let snapshot = WidgetSnapshot.decode(json: raw),
              let tag = snapshot.ownerTag, isOwnerTag(tag)
        else { throw WidgetIntentFailure.signInRequired }
        return (snapshot, tag)
    }

    static func isOwnerTag(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    /// §3.3: a `nextJob` scheduled before local today is never "next".
    private func upcomingJob(_ snapshot: WidgetSnapshot, now: Date) -> WidgetSnapshot.NextJob? {
        guard let job = snapshot.nextJob else { return nil }
        let today = Self.localDateString(now, timeZone: environment.timeZone)
        return job.scheduledDate < today ? nil : job
    }

    // MARK: Queue

    /// `nil` when the key is absent. Throws `malformedQueue` unless the value
    /// is a JSON array of objects (§4.3).
    static func readQueue(
        _ store: any WidgetAppGroupKeyValueStore
    ) throws -> WidgetQueueContents? {
        guard let raw = store.string(forKey: WidgetAppGroup.actionsKey) else { return nil }
        guard case .array(let values)? = WidgetJSONValue.decodeJSON(raw) else {
            throw WidgetIntentFailure.malformedQueue
        }
        var entries: [[String: WidgetJSONValue]] = []
        entries.reserveCapacity(values.count)
        for value in values {
            guard case .object(let fields) = value else { throw WidgetIntentFailure.malformedQueue }
            entries.append(fields)
        }
        return WidgetQueueContents(raw: raw, entries: entries)
    }

    /// RN `siriIsOnTheClock`: the last queued timer action wins; the snapshot
    /// decides only when none is queued. Only entries stamped with this
    /// owner's tag count: replay drops every other entry unapplied (§4.5), so
    /// an untagged or foreign `timer_start` is not a pending clock-in.
    static func isOnTheClock(
        snapshot: WidgetSnapshot,
        ownerTag: String,
        queue: WidgetQueueContents?
    ) -> Bool {
        var last: String?
        for entry in queue?.entries ?? [] {
            guard entry["ownerTag"]?.stringValue == ownerTag,
                  let type = entry["type"]?.stringValue else { continue }
            if type == WidgetPendingActionType.timerStart.rawValue
                || type == WidgetPendingActionType.timerStop.rawValue {
                last = type
            }
        }
        if last == WidgetPendingActionType.timerStart.rawValue { return true }
        if last == WidgetPendingActionType.timerStop.rawValue { return false }
        return snapshot.timer != nil
    }

    private func makeAction(
        _ type: WidgetPendingActionType,
        ownerTag: String,
        extra: [String: WidgetJSONValue],
        at: Date? = nil
    ) -> WidgetPendingAction {
        var fields = extra
        fields["id"] = .string(environment.makeActionID())
        fields["type"] = .string(type.rawValue)
        fields["at"] = .string(WidgetSnapshot.isoTimestamp(at ?? environment.now()))
        fields["ownerTag"] = .string(ownerTag)
        return WidgetPendingAction(fields: fields)
    }

    /// Validates, then appends under the caller's lock hold. Returns true for
    /// a new entry and false for an exact duplicate (idempotent success).
    /// Existing entries keep their exact bytes: the new object is spliced in
    /// before the closing bracket rather than re-encoding the whole queue.
    private func append(
        _ action: WidgetPendingAction,
        store: any WidgetAppGroupKeyValueStore,
        queue: WidgetQueueContents?
    ) throws -> Bool {
        try Self.validate(action)
        let entries = queue?.entries ?? []

        if let existing = entries.first(where: { $0["id"]?.stringValue == action.id }) {
            guard existing == action.fields else { throw WidgetIntentFailure.duplicateConflict }
            return false
        }
        guard entries.count < Self.maximumQueueCount else { throw WidgetIntentFailure.queueFull }

        let json = try action.encodedJSON()
        let updated: String
        if let queue, !entries.isEmpty {
            let trimmed = queue.raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasSuffix("]") else { throw WidgetIntentFailure.malformedQueue }
            updated = String(trimmed.dropLast()) + "," + json + "]"
        } else {
            updated = "[" + json + "]"
        }
        store.set(updated, forKey: WidgetAppGroup.actionsKey)
        guard store.string(forKey: WidgetAppGroup.actionsKey) == updated else {
            throw WidgetIntentFailure.writeFailed
        }
        return true
    }

    // MARK: Validation (§4.1; string rules shared with the planner via `WidgetActionFieldRules`)

    static func validate(_ action: WidgetPendingAction) throws {
        let fields = action.fields
        func requireIdentifier(_ key: String) throws {
            guard let value = fields[key]?.stringValue, WidgetActionFieldRules.isValidIdentifier(value) else {
                throw WidgetIntentFailure.invalidAction(field: key)
            }
        }
        try requireIdentifier("id")
        try requireIdentifier("type")
        guard let at = fields["at"]?.stringValue, WidgetSnapshot.parseISODate(at) != nil else {
            throw WidgetIntentFailure.invalidAction(field: "at")
        }
        guard let tag = fields["ownerTag"]?.stringValue, isOwnerTag(tag) else {
            throw WidgetIntentFailure.invalidAction(field: "ownerTag")
        }
        switch WidgetPendingActionType(rawValue: action.type) {
        case .timerStart:
            try requireIdentifier("jobId")
        case .timerStop:
            if fields["jobId"] != nil { try requireIdentifier("jobId") }
        case .tripLog:
            try requireLocalDate(fields)
            for key in ["odometerStart", "odometerEnd"] {
                guard let value = fields[key]?.numberValue, isValidOdometer(value) else {
                    throw WidgetIntentFailure.invalidAction(field: key)
                }
            }
        case .expenseLog:
            try requireLocalDate(fields)
            guard let amount = fields["amount"]?.numberValue, isValidExpenseAmount(amount)
            else { throw WidgetIntentFailure.invalidAction(field: "amount") }
            guard let category = fields["category"]?.stringValue,
                  WidgetExpenseCategory(rawValue: category) != nil
            else { throw WidgetIntentFailure.invalidAction(field: "category") }
            if let description = fields["description"], description.stringValue == nil {
                throw WidgetIntentFailure.invalidAction(field: "description")
            }
        case nil:
            throw WidgetIntentFailure.invalidAction(field: "type")
        }
    }

    private static func requireLocalDate(_ fields: [String: WidgetJSONValue]) throws {
        guard let date = fields["date"]?.stringValue, WidgetActionFieldRules.isValidLocalDate(date) else {
            throw WidgetIntentFailure.invalidAction(field: "date")
        }
    }

    /// RN `siriIsValidOdometer` (finite, ≥ 0) plus the native ceiling.
    static func isValidOdometer(_ value: Double) -> Bool {
        value.isFinite && value >= 0 && value <= maximumOdometer
    }

    /// RN `expenseFromAction` (finite, > 0, ≤ 1,000,000), with the planner's floor.
    static func isValidExpenseAmount(_ value: Double) -> Bool {
        value.isFinite && value >= minimumExpenseAmount && value <= maximumExpenseAmount
    }

    /// The local `yyyy-MM-dd` of an instant (FA-039: never the UTC day).
    static func localDateString(_ date: Date, timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    // MARK: Trip storage

    /// Stale iff the start is unparseable or more than 86,400 s before
    /// `reference` (RN `siriIsStaleActiveTrip`; exactly one day is fresh).
    static func isStaleTrip(_ trip: WidgetActiveTrip, reference: Date) -> Bool {
        guard let started = WidgetSnapshot.parseISODate(trip.startedAt) else { return true }
        return reference.timeIntervalSince(started) > staleTripInterval
    }

    private static func saveTrip(_ trip: WidgetActiveTrip, store: any WidgetAppGroupKeyValueStore) throws {
        let json = try WidgetJSONValue.encodeJSON(trip)
        store.set(json, forKey: WidgetAppGroup.activeTripKey)
        guard store.string(forKey: WidgetAppGroup.activeTripKey) == json else {
            throw WidgetIntentFailure.writeFailed
        }
    }

    private static func removeTrip(_ store: any WidgetAppGroupKeyValueStore) throws {
        store.removeObject(forKey: WidgetAppGroup.activeTripKey)
        guard store.string(forKey: WidgetAppGroup.activeTripKey) == nil else {
            throw WidgetIntentFailure.writeFailed
        }
    }
}

private extension Result where Failure == WidgetIntentFailure {
    func fold(failure: (WidgetIntentFailure) -> Success) -> Success {
        switch self {
        case .success(let value): return value
        case .failure(let error): return failure(error)
        }
    }
}

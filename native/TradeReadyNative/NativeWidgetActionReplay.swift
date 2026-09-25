import CryptoKit
import Foundation

enum NativeWidgetActionBatchError: Error, Equatable {
    case invalidAccountBinding
    case malformedQueue
    case tooManyActions
    case malformedAction(index: Int)
    case duplicateActionID(String)
    case invalidAction(index: Int, field: String)
}

struct NativeWidgetActionBatch: Equatable {
    static let maximumActionCount = 512
    static let maximumIdentifierLength = WidgetActionFieldRules.maximumIdentifierLength

    enum Kind: Equatable {
        case timerStart
        case timerStop
        case tripLog
        case expenseLog
        case unknown(String)
    }

    struct Action: Equatable {
        let id: String
        let kind: Kind
        let at: String
        let fields: [String: Canonical.JSONValue]
        let digest: String
    }

    let accountBinding: String
    let sourceDigest: String
    let sourceBytes: Data
    /// Only the actions stamped with `hash(accountBinding)` (contract §4.5).
    let actions: [Action]
    /// Task 11.05 (§4.5): entries dropped before type dispatch because their
    /// `ownerTag` is missing or belongs to another owner (or the entry is not
    /// an object, so it carries no owner at all). They are acknowledged with
    /// the claim and never applied. A count only: no ids, no payload.
    var ownerDroppedCount: Int = 0
}

/// Strict, loss-preserving preparation boundary for the untrusted App Group
/// queue. It does not mutate canonical state or acknowledge a durable claim;
/// those operations belong to the replay transaction above this boundary.
enum NativeWidgetActionBatchPlanner {
    static func prepare(
        rawValue: String,
        verifiedAccountBinding: String
    ) throws -> NativeWidgetActionBatch {
        guard isDigest(verifiedAccountBinding) else {
            throw NativeWidgetActionBatchError.invalidAccountBinding
        }
        let source = Data(rawValue.utf8)
        // 11.13 fix round 1 (I2): RN `parsePendingActions` returns [] for ""
        // (and for whitespace, which `JSON.parse` rejects). An empty or
        // whitespace-only queue is an empty batch: the coordinator commits it
        // as a no-op and clears the key. Malformed JSON still quarantines (C8).
        if rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return NativeWidgetActionBatch(
                accountBinding: verifiedAccountBinding,
                sourceDigest: digest(source),
                sourceBytes: source,
                actions: [],
                ownerDroppedCount: 0
            )
        }
        let values: [Canonical.JSONValue]
        do {
            values = try JSONDecoder().decode([Canonical.JSONValue].self, from: source)
        } catch {
            throw NativeWidgetActionBatchError.malformedQueue
        }
        guard values.count <= NativeWidgetActionBatch.maximumActionCount else {
            throw NativeWidgetActionBatchError.tooManyActions
        }

        // Task 11.05 (contract §4.5): the owner check runs BEFORE any field
        // validation or type dispatch. An untagged or foreign entry, of any
        // type (including an unknown one), is dropped and acknowledged; it can
        // neither be applied to this owner nor wedge this owner's batch.
        // `NativeWidgetOwnerTag.matches` is the one tag comparison (a hash of
        // ~90 bytes per entry; at most 512 entries per batch).
        var identifiers = Set<String>()
        var actions: [NativeWidgetActionBatch.Action] = []
        var ownerDropped = 0
        actions.reserveCapacity(values.count)
        for (index, value) in values.enumerated() {
            guard case let .object(fields) = value,
                  NativeWidgetOwnerTag.matches(string("ownerTag", fields), binding: verifiedAccountBinding)
            else {
                ownerDropped += 1
                continue
            }
            guard let id = string("id", fields),
                  let type = string("type", fields),
                  let at = string("at", fields),
                  validIdentifier(id), validIdentifier(type), validInstant(at)
            else { throw NativeWidgetActionBatchError.malformedAction(index: index) }
            guard identifiers.insert(id).inserted else {
                throw NativeWidgetActionBatchError.duplicateActionID(id)
            }

            let kind: NativeWidgetActionBatch.Kind
            switch type {
            case "timer_start":
                guard let jobID = string("jobId", fields), validIdentifier(jobID) else {
                    throw NativeWidgetActionBatchError.invalidAction(index: index, field: "jobId")
                }
                kind = .timerStart
            case "timer_stop":
                if let jobIDValue = fields["jobId"] {
                    guard case let .string(jobID) = jobIDValue, validIdentifier(jobID) else {
                        throw NativeWidgetActionBatchError.invalidAction(index: index, field: "jobId")
                    }
                }
                kind = .timerStop
            case "trip_log":
                try validateDateAndNumbers(
                    fields, index: index,
                    numberFields: ["odometerStart", "odometerEnd"],
                    range: 0...Decimal.greatestFiniteMagnitude
                )
                kind = .tripLog
            case "expense_log":
                try validateDateAndNumbers(
                    fields, index: index,
                    numberFields: ["amount"],
                    range: Decimal(string: "0.0000000000000000001")!...Decimal(1_000_000)
                )
                for optionalString in ["category", "description"] {
                    if let field = fields[optionalString], case .string = field {} else if fields[optionalString] != nil {
                        throw NativeWidgetActionBatchError.invalidAction(index: index, field: optionalString)
                    }
                }
                kind = .expenseLog
            default:
                // Preserve future actions exactly. A later client may know how
                // to replay them after it claims these same source bytes.
                kind = .unknown(type)
            }
            actions.append(.init(
                id: id, kind: kind, at: at, fields: fields,
                digest: digest(try encode(.object(fields)))
            ))
        }

        return NativeWidgetActionBatch(
            accountBinding: verifiedAccountBinding,
            sourceDigest: digest(source),
            sourceBytes: source,
            actions: actions,
            ownerDroppedCount: ownerDropped
        )
    }

    private static func validateDateAndNumbers(
        _ fields: [String: Canonical.JSONValue],
        index: Int,
        numberFields: [String],
        range: ClosedRange<Decimal>
    ) throws {
        guard let date = string("date", fields), validLocalDate(date) else {
            throw NativeWidgetActionBatchError.invalidAction(index: index, field: "date")
        }
        for name in numberFields {
            guard case let .number(value)? = fields[name], range.contains(value) else {
                throw NativeWidgetActionBatchError.invalidAction(index: index, field: name)
            }
        }
    }

    private static func string(
        _ key: String,
        _ fields: [String: Canonical.JSONValue]
    ) -> String? {
        guard case let .string(value)? = fields[key] else { return nil }
        return value
    }

    private static func validIdentifier(_ value: String) -> Bool {
        WidgetActionFieldRules.isValidIdentifier(value)
    }

    private static func validInstant(_ value: String) -> Bool {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) != nil || ISO8601DateFormatter().date(from: value) != nil
    }

    private static func validLocalDate(_ value: String) -> Bool {
        WidgetActionFieldRules.isValidLocalDate(value)
    }

    private static func isDigest(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }

    private static func encode(_ value: Canonical.JSONValue) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

struct NativeWidgetActionReplayResult {
    let snapshot: Canonical.Snapshot
    let changedActionCount: Int
    let ignoredActionCount: Int
    let unsupportedActionIDs: [String]

    var canAcknowledge: Bool { unsupportedActionIDs.isEmpty }
}

/// Applies a claimed batch to all affected canonical families in memory. The
/// caller publishes the returned snapshot once, then acknowledges the claim.
/// Deterministic record IDs and private action markers make a retry idempotent
/// if publication succeeds but acknowledgement is interrupted.
enum NativeWidgetActionReplayer {
    private static let startMarker = "__nativeWidgetStartActionID"
    private static let stopMarker = "__nativeWidgetStopActionID"
    private static let doneStatuses: Set<String> = ["complete", "invoiced", "paid", "declined"]
    private static let expenseCategories: Set<String> = [
        "materials", "tools", "fuel", "labor", "insurance", "software", "marketing", "other"
    ]

    static func apply(
        _ batch: NativeWidgetActionBatch,
        to source: Canonical.Snapshot
    ) throws -> NativeWidgetActionReplayResult {
        var snapshot = source
        var changed = 0
        var ignored = 0
        var unsupported: [String] = []

        for action in batch.actions {
            let didChange: Bool
            switch action.kind {
            case .timerStart:
                didChange = try applyTimerStart(action, snapshot: &snapshot)
            case .timerStop:
                didChange = applyTimerStop(action, snapshot: &snapshot)
            case .tripLog:
                didChange = try applyTrip(action, snapshot: &snapshot)
            case .expenseLog:
                didChange = try applyExpense(action, snapshot: &snapshot)
            case .unknown:
                unsupported.append(action.id)
                continue
            }
            if didChange { changed += 1 } else { ignored += 1 }
        }
        return .init(
            snapshot: snapshot,
            changedActionCount: changed,
            ignoredActionCount: ignored,
            unsupportedActionIDs: unsupported
        )
    }

    private static func applyTimerStart(
        _ action: NativeWidgetActionBatch.Action,
        snapshot: inout Canonical.Snapshot
    ) throws -> Bool {
        guard let jobID = string("jobId", action.fields),
              var jobs = snapshot.payload.jobs,
              let index = jobs.firstIndex(where: { $0.id == jobID })
        else { return false }
        // Task 11.05 (§3.3): a stale widget/Siri snapshot can name a job that
        // was archived since. The exact id is re-resolved here and an
        // archived job fails closed (ignored), matching the projection's own
        // rule that archived work is never offered (RN `!j.archivedAt`).
        guard !hasMarker(action.id, jobs: jobs),
              !doneStatuses.contains(jobs[index].status),
              !isArchived(jobs[index]),
              !hasActiveSession(jobs[index])
        else { return false }

        var session = try decode(
            Canonical.TimeSession.self,
            from: .object(["start": .string(action.at), "end": .null])
        )
        session.preservation.unknownFields[startMarker] = .string(action.id)
        var sessions = jobs[index].timeSessions ?? []
        sessions.append(session)
        jobs[index].timeSessions = sessions
        if jobs[index].status == "scheduled" { jobs[index].status = "in_progress" }
        snapshot.payload.jobs = jobs
        return true
    }

    private static func applyTimerStop(
        _ action: NativeWidgetActionBatch.Action,
        snapshot: inout Canonical.Snapshot
    ) -> Bool {
        guard var jobs = snapshot.payload.jobs, !hasMarker(action.id, jobs: jobs) else { return false }
        let index: Int?
        if let jobID = string("jobId", action.fields) {
            index = jobs.firstIndex { $0.id == jobID }
        } else {
            index = jobs.firstIndex(where: hasActiveSession)
        }
        guard let index, var sessions = jobs[index].timeSessions,
              let last = sessions.indices.last, sessions[last].end == nil
        else { return false }
        sessions[last].end = action.at < sessions[last].start ? sessions[last].start : action.at
        sessions[last].preservation.unknownFields[stopMarker] = .string(action.id)
        jobs[index].timeSessions = sessions
        snapshot.payload.jobs = jobs
        return true
    }

    private static func applyTrip(
        _ action: NativeWidgetActionBatch.Action,
        snapshot: inout Canonical.Snapshot
    ) throws -> Bool {
        let id = "t_siri_\(action.id)"
        var trips = snapshot.payload.trips ?? []
        guard !trips.contains(where: { $0.id == id }),
              let date = string("date", action.fields),
              let start = number("odometerStart", action.fields),
              let end = number("odometerEnd", action.fields)
        else { return false }
        let trip = try decode(Canonical.Trip.self, from: .object([
            "id": .string(id), "date": .string(date),
            "odometerStart": .number(start), "odometerEnd": .number(end),
            "miles": .number(max(0, end - start)),
            "fromJobId": .null, "fromLabel": .string("Home / Shop"),
            "toJobId": .null, "toLabel": .string("Home / Shop"),
            "purpose": .string("Business trip (Siri)"), "createdAt": .string(date)
        ]))
        trips.append(trip)
        snapshot.payload.trips = trips
        return true
    }

    private static func applyExpense(
        _ action: NativeWidgetActionBatch.Action,
        snapshot: inout Canonical.Snapshot
    ) throws -> Bool {
        let id = "e_siri_\(action.id)"
        var expenses = snapshot.payload.expenses ?? []
        guard !expenses.contains(where: { $0.id == id }),
              let date = string("date", action.fields),
              let amount = number("amount", action.fields)
        else { return false }
        let proposedCategory = string("category", action.fields) ?? "other"
        let category = expenseCategories.contains(proposedCategory) ? proposedCategory : "other"
        let proposedDescription = string("description", action.fields) ?? ""
        let description = proposedDescription.isEmpty ? "Logged via Siri" : proposedDescription
        let expense = try decode(Canonical.Expense.self, from: .object([
            "id": .string(id), "createdAt": .string(action.at),
            "description": .string(description), "amount": .number(amount),
            "category": .string(category), "date": .string(date),
            "notes": .string(""), "receiptUri": .null
        ]))
        expenses.append(expense)
        snapshot.payload.expenses = expenses
        return true
    }

    private static func isArchived(_ job: Canonical.Job) -> Bool {
        guard let archivedAt = job.archivedAt else { return false }
        return !archivedAt.isEmpty
    }

    private static func hasActiveSession(_ job: Canonical.Job) -> Bool {
        job.timeSessions?.last?.end == nil && job.timeSessions?.isEmpty == false
    }

    private static func hasMarker(_ actionID: String, jobs: [Canonical.Job]) -> Bool {
        let marker = Canonical.JSONValue.string(actionID)
        for job in jobs {
            for session in job.timeSessions ?? [] {
                if session.preservation.unknownFields[startMarker] == marker
                    || session.preservation.unknownFields[stopMarker] == marker {
                    return true
                }
            }
        }
        return false
    }

    private static func string(
        _ key: String,
        _ fields: [String: Canonical.JSONValue]
    ) -> String? {
        guard case let .string(value)? = fields[key] else { return nil }
        return value
    }

    private static func number(
        _ key: String,
        _ fields: [String: Canonical.JSONValue]
    ) -> Decimal? {
        guard case let .number(value)? = fields[key] else { return nil }
        return value
    }

    private static func decode<T: Decodable>(
        _ type: T.Type,
        from value: Canonical.JSONValue
    ) throws -> T {
        try JSONDecoder().decode(type, from: JSONEncoder().encode(value))
    }
}

protocol NativeWidgetActionQueueBacking {
    func read() throws -> String?
    func write(_ value: String?) throws
}

final class NativeUserDefaultsWidgetActionQueue: NativeWidgetActionQueueBacking {
    /// Task 11.05: the one App Group id and key (`WidgetAppGroup`, §2.1).
    static let key = WidgetAppGroup.actionsKey

    private let defaults: UserDefaults?

    init(defaults: UserDefaults? = WidgetAppGroup.liveDefaults()) {
        self.defaults = defaults
    }

    func read() -> String? { defaults?.string(forKey: Self.key) }

    func write(_ value: String?) {
        if let value {
            defaults?.set(value, forKey: Self.key)
        } else {
            defaults?.removeObject(forKey: Self.key)
        }
    }
}

enum NativeWidgetActionClaimError: Error, Equatable {
    case unavailable
    case lockFailed
    case invalidClaim
    case conflictingClaims
    case writeFailed
    case verificationFailed
}

struct NativeWidgetActionClaim: Codable, Equatable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let accountBinding: String
    let sourceDigest: String
    let sourceBytes: Data

    var rawValue: String? { String(data: sourceBytes, encoding: .utf8) }
}

/// Task 11.05 (decision C8): why a shared queue was set aside. Coarse on
/// purpose: no action id or field value is recorded in the reason.
enum NativeWidgetActionQuarantineReason: String, Codable, Equatable {
    case malformedQueue
    case tooManyActions
    case malformedAction
    case duplicateActionID
    case invalidAction

    /// Every planner rejection of the queue's content quarantines. An invalid
    /// account binding is the caller's error, never the queue's, so it does not.
    init?(_ error: NativeWidgetActionBatchError) {
        switch error {
        case .invalidAccountBinding: return nil
        case .malformedQueue: self = .malformedQueue
        case .tooManyActions: self = .tooManyActions
        case .malformedAction: self = .malformedAction
        case .duplicateActionID: self = .duplicateActionID
        case .invalidAction: self = .invalidAction
        }
    }
}

/// Task 11.05 (C8): the app-private record of a queue that can never be
/// prepared for its owner. Owner-scoped by filename and envelope, like a claim.
struct NativeWidgetActionQuarantine: Codable, Equatable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let accountBinding: String
    let reason: NativeWidgetActionQuarantineReason
    let sourceDigest: String
    let sourceByteCount: Int
    /// The exact bytes, kept only up to `maximumQuarantinedBytes` so a hostile
    /// or runaway queue cannot grow app storage without bound.
    let sourceBytes: Data?
}

/// Cross-process claim transport for the App Group action queue. The app and
/// every extension writer coordinate on the same advisory lock file. The app
/// first publishes and verifies a private write-ahead claim, then removes only
/// the claimed prefix from the shared queue. A crash at any point leaves either
/// the original queue, a recoverable claim, or both.
///
/// Task 11.05: the lock is `WidgetAppGroupLock` on `WidgetAppGroup.lockFileName`,
/// the one implementation the mirror, the scrubber and the extension writers
/// use (§4.2). This type keeps no lock file name or `flock` of its own.
struct NativeWidgetActionClaimTransport {
    static let claimFilePrefix = "claim-"
    static let quarantineFilePrefix = "quarantine-"
    /// C8: at most this many quarantined queues are kept per owner; the oldest
    /// is evicted first.
    static let maximumQuarantineFilesPerOwner = 4
    static let maximumQuarantinedBytes = 1 << 20

    let queue: any NativeWidgetActionQueueBacking
    let claimDirectory: URL
    let lockFile: URL

    static func live(
        fileManager: FileManager = .default,
        queue: any NativeWidgetActionQueueBacking = NativeUserDefaultsWidgetActionQueue()
    ) throws -> NativeWidgetActionClaimTransport {
        guard let lockFile = WidgetAppGroup.liveLockFile() else {
            throw NativeWidgetActionClaimError.unavailable
        }
        guard let support = fileManager.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first else { throw NativeWidgetActionClaimError.unavailable }
        return .init(
            queue: queue,
            claimDirectory: support.appendingPathComponent("WidgetActionClaims", isDirectory: true),
            lockFile: lockFile
        )
    }

    /// Returns the existing unacknowledged claim first. Otherwise it claims the
    /// current shared queue. The verified account binding is part of both the
    /// durable envelope and its filename, preventing cross-account recovery.
    ///
    /// Task 11.05 (old-binding claims): a claim or quarantine file keyed by
    /// any OTHER binding is discarded first, unread. It can only be left over
    /// from a previous account (the account scrub removes this directory) or
    /// from before the replay gate moved to `O`; its actions are stamped for
    /// that other owner, so §4.5 would drop every one of them anyway.
    func claim(verifiedAccountBinding: String) throws -> NativeWidgetActionClaim? {
        try Self.requireBinding(verifiedAccountBinding)
        return try withLock {
            try discardFiles(notOwnedBy: verifiedAccountBinding)
            if let existing = try loadClaim(accountBinding: verifiedAccountBinding) {
                try removeClaimedPrefixFromQueue(existing)
                return existing
            }
            guard let raw = try queue.read() else { return nil }
            let batch = try NativeWidgetActionBatchPlanner.prepare(
                rawValue: raw,
                verifiedAccountBinding: verifiedAccountBinding
            )
            let claim = NativeWidgetActionClaim(
                schemaVersion: NativeWidgetActionClaim.currentSchemaVersion,
                accountBinding: batch.accountBinding,
                sourceDigest: batch.sourceDigest,
                sourceBytes: batch.sourceBytes
            )
            try persist(claim)
            try removeClaimedPrefixFromQueue(claim)
            return claim
        }
    }

    /// Task 11.05 (C8): sets the shared queue aside when, re-read inside this
    /// lock hold, it still cannot be prepared for this owner. The raw bytes
    /// move into an owner-scoped quarantine file (verified) and only then leave
    /// the shared queue, so later actions are no longer wedged behind them.
    /// Returns nil, touching nothing, when the queue is absent or prepares
    /// cleanly now.
    func quarantineUnpreparableQueue(
        verifiedAccountBinding: String
    ) throws -> NativeWidgetActionQuarantineReason? {
        try Self.requireBinding(verifiedAccountBinding)
        return try withLock {
            guard let raw = try queue.read() else { return nil }
            let reason: NativeWidgetActionQuarantineReason
            do {
                _ = try NativeWidgetActionBatchPlanner.prepare(
                    rawValue: raw,
                    verifiedAccountBinding: verifiedAccountBinding
                )
                return nil
            } catch let error as NativeWidgetActionBatchError {
                guard let mapped = NativeWidgetActionQuarantineReason(error) else { throw error }
                reason = mapped
            }
            let source = Data(raw.utf8)
            let record = NativeWidgetActionQuarantine(
                schemaVersion: NativeWidgetActionQuarantine.currentSchemaVersion,
                accountBinding: verifiedAccountBinding,
                reason: reason,
                sourceDigest: Self.digest(source),
                sourceByteCount: source.count,
                sourceBytes: source.count <= Self.maximumQuarantinedBytes ? source : nil
            )
            try persist(record)
            try replaceQueue(with: nil)
            return reason
        }
    }

    /// The quarantine records kept for `accountBinding` (diagnostics/tests).
    func quarantinedQueues(accountBinding: String) throws -> [NativeWidgetActionQuarantine] {
        try Self.requireBinding(accountBinding)
        return try files(prefix: Self.quarantineFilePrefix + accountBinding + "-").map { url in
            do {
                return try JSONDecoder().decode(NativeWidgetActionQuarantine.self, from: Data(contentsOf: url))
            } catch { throw NativeWidgetActionClaimError.invalidClaim }
        }
    }

    /// Task 11.05: the account scrub removes every claim and quarantine file
    /// (they hold the scrubbed account's actions). App-private storage that
    /// only the app's main actor touches (every claim/replay runs from
    /// `AppStore`, which is `@MainActor`), so no App Group lock is needed and
    /// the scrub gains no new dependency on the container. `@MainActor`
    /// makes that single-writer assumption a compile-time rule.
    @MainActor
    func removeAllAccountClaims() throws {
        let manager = FileManager.default
        guard manager.fileExists(atPath: claimDirectory.path) else { return }
        do { try manager.removeItem(at: claimDirectory) } catch { throw NativeWidgetActionClaimError.writeFailed }
        guard !manager.fileExists(atPath: claimDirectory.path) else {
            throw NativeWidgetActionClaimError.verificationFailed
        }
    }

    /// Removes exactly the acknowledged durable claim. Shared bytes appended
    /// after the claim are never touched.
    func acknowledge(_ claim: NativeWidgetActionClaim) throws {
        try withLock {
            guard let stored = try loadClaim(accountBinding: claim.accountBinding), stored == claim
            else { throw NativeWidgetActionClaimError.verificationFailed }
            do {
                let destination = claimURL(claim)
                try FileManager.default.removeItem(at: destination)
                guard !FileManager.default.fileExists(atPath: destination.path) else {
                    throw NativeWidgetActionClaimError.verificationFailed
                }
            } catch let error as NativeWidgetActionClaimError {
                throw error
            } catch {
                throw NativeWidgetActionClaimError.writeFailed
            }
        }
    }

    private func persist(_ claim: NativeWidgetActionClaim) throws {
        try persist(Self.encode(claim), to: claimURL(claim))
    }

    private func persist(_ record: NativeWidgetActionQuarantine) throws {
        let destination = claimDirectory.appendingPathComponent(
            "\(Self.quarantineFilePrefix)\(record.accountBinding)-\(record.sourceDigest).json"
        )
        // Bounded retention: evict this owner's oldest records first.
        let existing = try files(prefix: Self.quarantineFilePrefix + record.accountBinding + "-")
            .filter { $0.lastPathComponent != destination.lastPathComponent }
            .sorted { Self.modificationDate($0) < Self.modificationDate($1) }
        for url in existing.prefix(max(0, existing.count - (Self.maximumQuarantineFilesPerOwner - 1))) {
            do { try FileManager.default.removeItem(at: url) } catch { throw NativeWidgetActionClaimError.writeFailed }
        }
        try persist(Self.encode(record), to: destination)
    }

    private func persist(_ bytes: Data, to destination: URL) throws {
        do {
            try FileManager.default.createDirectory(
                at: claimDirectory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            if FileManager.default.fileExists(atPath: destination.path) {
                guard try Data(contentsOf: destination) == bytes else {
                    throw NativeWidgetActionClaimError.verificationFailed
                }
            } else {
                try bytes.write(to: destination, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            }
            guard try Data(contentsOf: destination) == bytes else {
                throw NativeWidgetActionClaimError.verificationFailed
            }
        } catch let error as NativeWidgetActionClaimError {
            throw error
        } catch {
            throw NativeWidgetActionClaimError.writeFailed
        }
    }

    /// Discards claim and quarantine files keyed by any other binding.
    private func discardFiles(notOwnedBy accountBinding: String) throws {
        let owned = [Self.claimFilePrefix, Self.quarantineFilePrefix].map { $0 + accountBinding + "-" }
        let foreign = try files(prefix: nil).filter { url in
            let name = url.lastPathComponent
            let isTransportFile = name.hasPrefix(Self.claimFilePrefix) || name.hasPrefix(Self.quarantineFilePrefix)
            return isTransportFile && !owned.contains { name.hasPrefix($0) }
        }
        for url in foreign {
            do { try FileManager.default.removeItem(at: url) } catch { throw NativeWidgetActionClaimError.writeFailed }
        }
    }

    private func files(prefix: String?) throws -> [URL] {
        guard FileManager.default.fileExists(atPath: claimDirectory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(
            at: claimDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ).filter { url in
            url.pathExtension == "json" && (prefix.map { url.lastPathComponent.hasPrefix($0) } ?? true)
        }
    }

    private func loadClaim(accountBinding: String) throws -> NativeWidgetActionClaim? {
        try Self.requireBinding(accountBinding)
        let candidates = try files(prefix: Self.claimFilePrefix + accountBinding + "-")
        guard candidates.count <= 1 else { throw NativeWidgetActionClaimError.conflictingClaims }
        guard let candidate = candidates.first else { return nil }
        let claim: NativeWidgetActionClaim
        do {
            claim = try JSONDecoder().decode(
                NativeWidgetActionClaim.self,
                from: Data(contentsOf: candidate)
            )
        } catch { throw NativeWidgetActionClaimError.invalidClaim }
        guard claim.schemaVersion == NativeWidgetActionClaim.currentSchemaVersion,
              claim.accountBinding == accountBinding,
              claim.sourceDigest == Self.digest(claim.sourceBytes),
              claim.rawValue != nil,
              candidate.standardizedFileURL.path == claimURL(claim).standardizedFileURL.path
        else { throw NativeWidgetActionClaimError.invalidClaim }
        // A claim was prepared before it was written, so a planner failure
        // here is claim corruption, never a queue to quarantine (C8).
        do {
            _ = try NativeWidgetActionBatchPlanner.prepare(
                rawValue: claim.rawValue!,
                verifiedAccountBinding: accountBinding
            )
        } catch { throw NativeWidgetActionClaimError.invalidClaim }
        return claim
    }

    /// Handles the narrow crash window after WAL publication but before shared
    /// queue removal. If an extension appended meanwhile, only the exact
    /// already-claimed action prefix is removed and the suffix remains queued.
    private func removeClaimedPrefixFromQueue(_ claim: NativeWidgetActionClaim) throws {
        guard let current = try queue.read() else { return }
        if Data(current.utf8) == claim.sourceBytes {
            try replaceQueue(with: nil)
            return
        }
        guard let claimedRaw = claim.rawValue,
              let claimedValues = try? JSONDecoder().decode([Canonical.JSONValue].self, from: Data(claimedRaw.utf8)),
              let currentValues = try? JSONDecoder().decode([Canonical.JSONValue].self, from: Data(current.utf8)),
              currentValues.count >= claimedValues.count,
              Array(currentValues.prefix(claimedValues.count)) == claimedValues
        else {
            // The queue is independent or malformed. Retain it verbatim.
            return
        }
        let suffix = Array(currentValues.dropFirst(claimedValues.count))
        if suffix.isEmpty {
            try replaceQueue(with: nil)
        } else {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            let bytes = try encoder.encode(suffix)
            guard let raw = String(data: bytes, encoding: .utf8) else {
                throw NativeWidgetActionClaimError.verificationFailed
            }
            try replaceQueue(with: raw)
        }
    }

    private func replaceQueue(with value: String?) throws {
        try queue.write(value)
        guard try queue.read() == value else {
            throw NativeWidgetActionClaimError.verificationFailed
        }
    }

    private func claimURL(_ claim: NativeWidgetActionClaim) -> URL {
        claimDirectory.appendingPathComponent(
            "\(Self.claimFilePrefix)\(claim.accountBinding)-\(claim.sourceDigest).json"
        )
    }

    /// §4.2 through the one shared implementation. Errors thrown by `body`
    /// pass through unchanged; a failure to take the lock is `lockFailed`.
    private func withLock<T>(_ body: () throws -> T) throws -> T {
        do {
            return try WidgetAppGroupLock.withExclusiveLock(at: lockFile, body)
        } catch is WidgetAppGroupLockError {
            throw NativeWidgetActionClaimError.lockFailed
        }
    }

    /// Validated before any filename is built from the binding, so an invalid
    /// value can never match (or discard) another owner's files.
    private static func requireBinding(_ binding: String) throws {
        guard binding.count == 64, binding.allSatisfy({ $0.isHexDigit && !$0.isUppercase })
        else { throw NativeWidgetActionBatchError.invalidAccountBinding }
    }

    private static func modificationDate(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }

    private static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

enum NativeWidgetActionReplayCommitResult {
    case nothingPending
    case retainedUnsupported(actionCount: Int)
    /// `ownerDropped`: untagged or foreign entries acknowledged, never applied (§4.5).
    case committed(snapshot: Canonical.Snapshot, changed: Int, ignored: Int, ownerDropped: Int)
    /// C8: the shared queue could not be prepared and was set aside.
    case quarantined(reason: NativeWidgetActionQuarantineReason)
}

/// Task 11.05 (§4.5, C8): bounded, payload-free replay counters. No action id,
/// field, amount or owner value is ever recorded.
struct NativeWidgetActionReplayDiagnostics: Equatable {
    static let maximumCount = 9_999

    private(set) var ownerDroppedActionCount = 0
    private(set) var quarantinedQueueCount = 0
    /// Task 11.05 fix round 1 (I1): `useAnotherAccount` could not wipe the
    /// App Group (lock or container unavailable). Kept across the account
    /// boundary reset so the failure stays observable.
    private(set) var accountSwitchScrubFailureCount = 0

    mutating func recordOwnerDropped(_ count: Int) {
        guard count > 0 else { return }
        ownerDroppedActionCount = min(Self.maximumCount, ownerDroppedActionCount + min(count, Self.maximumCount))
    }

    mutating func recordQuarantine() {
        quarantinedQueueCount = min(Self.maximumCount, quarantinedQueueCount + 1)
    }

    mutating func recordAccountSwitchScrubFailure() {
        accountSwitchScrubFailureCount = min(Self.maximumCount, accountSwitchScrubFailureCount + 1)
    }

    /// Clears the per-owner counters at an account switch.
    mutating func resetForAccountBoundary() {
        ownerDroppedActionCount = 0
        quarantinedQueueCount = 0
    }
}

/// Owns the commit ordering: durable claim, pure replay, one atomic canonical
/// save, then exact acknowledgement. Unsupported future actions retain their
/// claim and prevent partial application of the batch.
struct NativeWidgetActionReplayCoordinator {
    /// C8: the bounded, payload-free message surfaced after a quarantine.
    static let quarantinedMessage = "Some widget or Siri actions couldn't be read and were set aside."

    let transport: NativeWidgetActionClaimTransport
    let repository: Canonical.SnapshotRepository

    func replayNext(
        snapshot: Canonical.Snapshot,
        verifiedAccountBinding: String
    ) throws -> NativeWidgetActionReplayCommitResult {
        let claimed: NativeWidgetActionClaim?
        do {
            claimed = try transport.claim(verifiedAccountBinding: verifiedAccountBinding)
        } catch let error as NativeWidgetActionBatchError {
            // C8: the queue itself cannot be prepared. Retrying can never
            // succeed and would wedge every later action, so set it aside.
            guard NativeWidgetActionQuarantineReason(error) != nil else { throw error }
            if let reason = try transport.quarantineUnpreparableQueue(
                verifiedAccountBinding: verifiedAccountBinding
            ) {
                return .quarantined(reason: reason)
            }
            // The queue changed between the two lock holds and prepares now.
            claimed = try transport.claim(verifiedAccountBinding: verifiedAccountBinding)
        }
        guard let claim = claimed, let raw = claim.rawValue else { return .nothingPending }
        let batch = try NativeWidgetActionBatchPlanner.prepare(
            rawValue: raw,
            verifiedAccountBinding: verifiedAccountBinding
        )
        let result = try NativeWidgetActionReplayer.apply(batch, to: snapshot)
        guard result.canAcknowledge else {
            return .retainedUnsupported(actionCount: result.unsupportedActionIDs.count)
        }
        if result.changedActionCount > 0 {
            try repository.save(result.snapshot)
        }
        try transport.acknowledge(claim)
        return .committed(
            snapshot: result.snapshot,
            changed: result.changedActionCount,
            ignored: result.ignoredActionCount,
            ownerDropped: batch.ownerDroppedCount
        )
    }
}

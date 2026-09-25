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
    /// Phase 12 12.00b.2-C (L130): owner-matched entries this batch cannot
    /// apply (malformed, invalid, or a different entry reusing an applied id),
    /// in queue order. They never block the valid actions: the transport sets
    /// them aside, exact bytes kept, when it acknowledges the claim (§4.6).
    var rejected: [Rejected] = []

    struct Rejected: Equatable {
        let index: Int
        let error: NativeWidgetActionBatchError
        let value: Canonical.JSONValue
    }
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
        // The transport only ever prepares a `claimablePrefix`, so this is a
        // guard on the batch size, never a reason to set a queue aside.
        guard values.count <= NativeWidgetActionBatch.maximumActionCount else {
            throw NativeWidgetActionBatchError.tooManyActions
        }

        // Task 11.05 (contract §4.5): the owner check runs BEFORE any field
        // validation or type dispatch. An untagged or foreign entry, of any
        // type (including an unknown one), is dropped and acknowledged; it can
        // neither be applied to this owner nor wedge this owner's batch.
        // `NativeWidgetOwnerTag.matches` is the one tag comparison (a hash of
        // ~90 bytes per entry; at most 512 entries per batch).
        //
        // Phase 12 12.00b.2-C (L130, §4.3): a bad owned entry is recorded in
        // `rejected` and skipped; every other entry still applies. Ids are
        // taken by accepted actions only. A later entry with an accepted id is
        // skipped when it is the same action (same canonical digest: the
        // writer's idempotent re-append, which the first entry applies) and
        // set aside when it differs (it can never apply under that id).
        var acceptedDigests: [String: String] = [:]
        var actions: [NativeWidgetActionBatch.Action] = []
        var rejected: [NativeWidgetActionBatch.Rejected] = []
        var ownerDropped = 0
        actions.reserveCapacity(values.count)
        for (index, value) in values.enumerated() {
            guard case let .object(fields) = value,
                  NativeWidgetOwnerTag.matches(string("ownerTag", fields), binding: verifiedAccountBinding)
            else {
                ownerDropped += 1
                continue
            }
            let action: NativeWidgetActionBatch.Action
            do {
                action = try validatedAction(fields, index: index)
            } catch let error as NativeWidgetActionBatchError {
                rejected.append(.init(index: index, error: error, value: value))
                continue
            }
            if let acceptedDigest = acceptedDigests[action.id] {
                if acceptedDigest != action.digest {
                    rejected.append(.init(index: index, error: .duplicateActionID(action.id), value: value))
                }
                continue
            }
            acceptedDigests[action.id] = action.digest
            actions.append(action)
        }

        var batch = NativeWidgetActionBatch(
            accountBinding: verifiedAccountBinding,
            sourceDigest: digest(source),
            sourceBytes: source,
            actions: actions,
            ownerDroppedCount: ownerDropped
        )
        batch.rejected = rejected
        return batch
    }

    /// One owned entry's checks, in the order the batch used to apply them:
    /// id/type/instant (`malformedAction`), then the per-type fields
    /// (`invalidAction`). Unknown types are kept exactly for a later client.
    private static func validatedAction(
        _ fields: [String: Canonical.JSONValue],
        index: Int
    ) throws -> NativeWidgetActionBatch.Action {
        guard let id = string("id", fields),
              let type = string("type", fields),
              let at = string("at", fields),
              validIdentifier(id), validIdentifier(type), validInstant(at)
        else { throw NativeWidgetActionBatchError.malformedAction(index: index) }

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
        return .init(
            id: id, kind: kind, at: at, fields: fields,
            digest: digest(try encode(.object(fields)))
        )
    }

    /// Phase 12 12.00b.2-C (L130): the part of the shared queue one claim
    /// takes. A blank queue or a list of at most `maximumActionCount` entries
    /// is claimed byte for byte. A longer list is claimed as its first
    /// `maximumActionCount` entries, each with its exact bytes; the rest stays
    /// queued for the next claim (`removeClaimedPrefixFromQueue`), in order.
    /// Throws `malformedQueue` when the queue is not a JSON list at all.
    static func claimablePrefix(of rawValue: String) throws -> String {
        if rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return rawValue }
        let source = Data(rawValue.utf8)
        let values: [Canonical.JSONValue]
        do {
            values = try JSONDecoder().decode([Canonical.JSONValue].self, from: source)
        } catch {
            throw NativeWidgetActionBatchError.malformedQueue
        }
        let limit = NativeWidgetActionBatch.maximumActionCount
        guard values.count > limit else { return rawValue }
        let prefix = Array(values.prefix(limit))
        let bytes: Data
        if let entries = exactEntries(of: source, matching: values) {
            bytes = joinedList(entries.prefix(limit))
        } else {
            bytes = try encode(.array(prefix))
        }
        guard (try? JSONDecoder().decode([Canonical.JSONValue].self, from: bytes)) == prefix,
              let claimable = String(data: bytes, encoding: .utf8)
        else { throw NativeWidgetActionBatchError.malformedQueue }
        return claimable
    }

    /// Phase 12 12.00b.2-C (L130): the set-aside entries of `batch` as one JSON
    /// list, each entry with the exact bytes it had in the claimed source
    /// (canonical sorted-key JSON only if those bytes cannot be recovered).
    static func rejectedEntryBytes(of batch: NativeWidgetActionBatch) throws -> Data {
        let values = batch.rejected.map(\.value)
        guard !values.isEmpty else { return Data("[]".utf8) }
        if let all = try? JSONDecoder().decode([Canonical.JSONValue].self, from: batch.sourceBytes),
           let entries = exactEntries(of: batch.sourceBytes, matching: all),
           batch.rejected.allSatisfy({ all.indices.contains($0.index) && all[$0.index] == $0.value }) {
            return joinedList(batch.rejected.map { entries[$0.index] })
        }
        return try encode(.array(values))
    }

    /// The exact bytes of each top-level entry of `source`, but only when
    /// every one of them decodes to the matching entry of `values`.
    static func exactEntries(of source: Data, matching values: [Canonical.JSONValue]) -> [Data]? {
        guard let entries = rawEntries(of: source), entries.count == values.count else { return nil }
        for (entry, value) in zip(entries, values) {
            guard (try? JSONDecoder().decode([Canonical.JSONValue].self, from: joinedList([entry]))) == [value]
            else { return nil }
        }
        return entries
    }

    /// Splits a JSON list into the exact bytes of each top-level entry
    /// (surrounding whitespace trimmed). A syntactic scan only: string escapes
    /// and nesting are tracked, nothing is validated, so callers compare the
    /// result with a real decode (`exactEntries`). Nil when `source` is not
    /// shaped like one list.
    static func rawEntries(of source: Data) -> [Data]? {
        let bytes = [UInt8](source)
        let space: Set<UInt8> = [0x20, 0x09, 0x0A, 0x0D]
        var index = 0
        func skipSpace() { while index < bytes.count, space.contains(bytes[index]) { index += 1 } }
        skipSpace()
        guard index < bytes.count, bytes[index] == UInt8(ascii: "[") else { return nil }
        index += 1
        skipSpace()
        var entries: [Data] = []
        if index < bytes.count, bytes[index] == UInt8(ascii: "]") {
            index += 1
            skipSpace()
            return index == bytes.count ? entries : nil
        }
        while index < bytes.count {
            let start = index
            var depth = 0
            var inString = false
            var escaped = false
            scan: while index < bytes.count {
                let byte = bytes[index]
                if inString {
                    if escaped { escaped = false }
                    else if byte == UInt8(ascii: "\\") { escaped = true }
                    else if byte == UInt8(ascii: "\"") { inString = false }
                } else {
                    switch byte {
                    case UInt8(ascii: "\""): inString = true
                    case UInt8(ascii: "["), UInt8(ascii: "{"): depth += 1
                    case UInt8(ascii: "]"), UInt8(ascii: "}"):
                        if depth == 0 { break scan }
                        depth -= 1
                    case UInt8(ascii: ","):
                        if depth == 0 { break scan }
                    default: break
                    }
                }
                index += 1
            }
            guard index < bytes.count else { return nil }
            var end = index
            while end > start, space.contains(bytes[end - 1]) { end -= 1 }
            guard end > start else { return nil }
            entries.append(Data(bytes[start..<end]))
            if bytes[index] == UInt8(ascii: ",") {
                index += 1
                skipSpace()
                continue
            }
            guard bytes[index] == UInt8(ascii: "]") else { return nil }
            index += 1
            skipSpace()
            return index == bytes.count ? entries : nil
        }
        return nil
    }

    /// `entries` as one JSON list, byte for byte, with no added whitespace.
    static func joinedList<S: Sequence>(_ entries: S) -> Data where S.Element == Data {
        var list = Data("[".utf8)
        for (offset, entry) in entries.enumerated() {
            if offset > 0 { list.append(UInt8(ascii: ",")) }
            list.append(entry)
        }
        list.append(UInt8(ascii: "]"))
        return list
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

/// Final review C1: one canonical record a replayed action wrote, keyed the
/// way the outbound mutation queue keys it (`<table>/<recordId>`).
struct NativeWidgetActionRecordKey: Hashable {
    static let jobsTable = "jobs"
    static let tripsTable = "trips"
    static let expensesTable = "expenses"

    let table: String
    let recordID: String
}

/// Final review C1: why the caller refused to queue a replay's writes. The
/// claim stays unacknowledged and is retried.
enum NativeWidgetActionReplayEnqueueError: Error, Equatable {
    /// The verified owner changed between the commit and the enqueue.
    case ownerChanged
    /// A written record is missing from the committed snapshot.
    case missingRecord
}

struct NativeWidgetActionReplayResult {
    let snapshot: Canonical.Snapshot
    let changedActionCount: Int
    let ignoredActionCount: Int
    let unsupportedActionIDs: [String]
    /// Final review C1: every record this batch's actions wrote, in first-touch
    /// order without duplicates. It includes records an action already wrote
    /// on an earlier, unacknowledged attempt (found by its deterministic id or
    /// session marker), so a retry after an interrupted enqueue re-queues
    /// them; the queue's last-writer-wins dedup makes that idempotent. An
    /// action that matches nothing contributes no record.
    let writtenRecords: [NativeWidgetActionRecordKey]

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

    /// What one action did to the snapshot.
    private enum Outcome {
        /// The action wrote this record now.
        case applied(NativeWidgetActionRecordKey)
        /// The action wrote this record on an earlier attempt (retry).
        case alreadyApplied(NativeWidgetActionRecordKey)
        /// The action matches nothing (unknown or finished job, idle stop).
        case ignored
    }

    static func apply(
        _ batch: NativeWidgetActionBatch,
        to source: Canonical.Snapshot
    ) throws -> NativeWidgetActionReplayResult {
        var snapshot = source
        var changed = 0
        var ignored = 0
        var unsupported: [String] = []
        var written: [NativeWidgetActionRecordKey] = []

        for action in batch.actions {
            let outcome: Outcome
            switch action.kind {
            case .timerStart:
                outcome = try applyTimerStart(action, snapshot: &snapshot)
            case .timerStop:
                outcome = applyTimerStop(action, snapshot: &snapshot)
            case .tripLog:
                outcome = try applyTrip(action, snapshot: &snapshot)
            case .expenseLog:
                outcome = try applyExpense(action, snapshot: &snapshot)
            case .unknown:
                unsupported.append(action.id)
                continue
            }
            switch outcome {
            case .applied(let key):
                changed += 1
                if !written.contains(key) { written.append(key) }
            case .alreadyApplied(let key):
                ignored += 1
                if !written.contains(key) { written.append(key) }
            case .ignored:
                ignored += 1
            }
        }
        return .init(
            snapshot: snapshot,
            changedActionCount: changed,
            ignoredActionCount: ignored,
            unsupportedActionIDs: unsupported,
            writtenRecords: written
        )
    }

    private static func applyTimerStart(
        _ action: NativeWidgetActionBatch.Action,
        snapshot: inout Canonical.Snapshot
    ) throws -> Outcome {
        if let marked = markedJobID(action.id, jobs: snapshot.payload.jobs ?? []) {
            return .alreadyApplied(.init(table: NativeWidgetActionRecordKey.jobsTable, recordID: marked))
        }
        guard let jobID = string("jobId", action.fields),
              var jobs = snapshot.payload.jobs,
              let index = jobs.firstIndex(where: { $0.id == jobID })
        else { return .ignored }
        // Task 11.05 (§3.3): a stale widget/Siri snapshot can name a job that
        // was archived since. The exact id is re-resolved here and an
        // archived job fails closed (ignored), matching the projection's own
        // rule that archived work is never offered (RN `!j.archivedAt`).
        guard !doneStatuses.contains(jobs[index].status),
              !isArchived(jobs[index]),
              !hasActiveSession(jobs[index])
        else { return .ignored }

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
        return .applied(.init(table: NativeWidgetActionRecordKey.jobsTable, recordID: jobID))
    }

    private static func applyTimerStop(
        _ action: NativeWidgetActionBatch.Action,
        snapshot: inout Canonical.Snapshot
    ) -> Outcome {
        guard var jobs = snapshot.payload.jobs else { return .ignored }
        if let marked = markedJobID(action.id, jobs: jobs) {
            return .alreadyApplied(.init(table: NativeWidgetActionRecordKey.jobsTable, recordID: marked))
        }
        let index: Int?
        if let jobID = string("jobId", action.fields) {
            index = jobs.firstIndex { $0.id == jobID }
        } else {
            index = jobs.firstIndex(where: hasActiveSession)
        }
        guard let index, var sessions = jobs[index].timeSessions,
              let last = sessions.indices.last, sessions[last].end == nil
        else { return .ignored }
        sessions[last].end = action.at < sessions[last].start ? sessions[last].start : action.at
        sessions[last].preservation.unknownFields[stopMarker] = .string(action.id)
        jobs[index].timeSessions = sessions
        snapshot.payload.jobs = jobs
        return .applied(.init(table: NativeWidgetActionRecordKey.jobsTable, recordID: jobs[index].id))
    }

    private static func applyTrip(
        _ action: NativeWidgetActionBatch.Action,
        snapshot: inout Canonical.Snapshot
    ) throws -> Outcome {
        let id = "t_siri_\(action.id)"
        let key = NativeWidgetActionRecordKey(table: NativeWidgetActionRecordKey.tripsTable, recordID: id)
        var trips = snapshot.payload.trips ?? []
        guard !trips.contains(where: { $0.id == id }) else { return .alreadyApplied(key) }
        guard let date = string("date", action.fields),
              let start = number("odometerStart", action.fields),
              let end = number("odometerEnd", action.fields)
        else { return .ignored }
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
        return .applied(key)
    }

    private static func applyExpense(
        _ action: NativeWidgetActionBatch.Action,
        snapshot: inout Canonical.Snapshot
    ) throws -> Outcome {
        let id = "e_siri_\(action.id)"
        let key = NativeWidgetActionRecordKey(table: NativeWidgetActionRecordKey.expensesTable, recordID: id)
        var expenses = snapshot.payload.expenses ?? []
        guard !expenses.contains(where: { $0.id == id }) else { return .alreadyApplied(key) }
        guard let date = string("date", action.fields),
              let amount = number("amount", action.fields)
        else { return .ignored }
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
        return .applied(key)
    }

    private static func isArchived(_ job: Canonical.Job) -> Bool {
        guard let archivedAt = job.archivedAt else { return false }
        return !archivedAt.isEmpty
    }

    private static func hasActiveSession(_ job: Canonical.Job) -> Bool {
        job.timeSessions?.last?.end == nil && job.timeSessions?.isEmpty == false
    }

    /// The job holding a session this action already started or stopped.
    private static func markedJobID(_ actionID: String, jobs: [Canonical.Job]) -> String? {
        let marker = Canonical.JSONValue.string(actionID)
        for job in jobs {
            for session in job.timeSessions ?? [] {
                if session.preservation.unknownFields[startMarker] == marker
                    || session.preservation.unknownFields[stopMarker] == marker {
                    return job.id
                }
            }
        }
        return nil
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
    /// 12.00b.2-C fix round 1 (I2b): a claim path that is a regular file
    /// but cannot be read. Its bytes cannot be kept, so it is never removed.
    case unreadableClaim
}

struct NativeWidgetActionClaim: Codable, Equatable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let accountBinding: String
    let sourceDigest: String
    let sourceBytes: Data

    var rawValue: String? { String(data: sourceBytes, encoding: .utf8) }
}

/// Task 11.05 (decision C8): why a shared queue, entry or claim was set
/// aside. Coarse on purpose: no action id or field value is recorded in the
/// reason.
///
/// Phase 12 12.00b.2-C: `malformedQueue` is the one whole-queue reason (the
/// bytes are not a JSON list). `malformedAction`, `invalidAction` and
/// `duplicateActionID` now name single entries (L130), and `invalidClaim` /
/// `conflictingClaims` name claim files set aside so replay continues (L131).
/// `tooManyActions` is no longer written (a long queue is claimed in 512-entry
/// prefixes); it stays decodable for records written by 11.x builds.
enum NativeWidgetActionQuarantineReason: String, Codable, Equatable {
    case malformedQueue
    case tooManyActions
    case malformedAction
    case duplicateActionID
    case invalidAction
    case invalidClaim
    case conflictingClaims

    /// Only a queue that is not a list at all is set aside whole. An invalid
    /// account binding is the caller's error, never the queue's, and the
    /// per-entry errors never fail a batch, so none of them maps.
    init?(_ error: NativeWidgetActionBatchError) {
        switch error {
        case .malformedQueue: self = .malformedQueue
        case .invalidAccountBinding, .tooManyActions, .malformedAction, .duplicateActionID, .invalidAction:
            return nil
        }
    }

    /// L130: the reason recorded for one set-aside entry.
    init(entry error: NativeWidgetActionBatchError) {
        switch error {
        case .duplicateActionID: self = .duplicateActionID
        case .invalidAction: self = .invalidAction
        case .malformedAction, .malformedQueue, .tooManyActions, .invalidAccountBinding: self = .malformedAction
        }
    }

    /// The claim-file reasons (L131), counted apart from queue content.
    var isClaimReason: Bool { self == .invalidClaim || self == .conflictingClaims }
}

/// Task 11.05 (C8): the app-private record of a queue that can never be
/// prepared for its owner. Owner-scoped by filename and envelope, like a claim.
///
/// Phase 12 12.00b.2-C: `sourceBytes` is what was set aside, by `reason`:
/// the whole queue (`malformedQueue`); a JSON list of the set-aside entries
/// with their exact bytes (a per-entry reason, one per entry in
/// `entryReasons`, L130); or the exact claim file (`invalidClaim`,
/// `conflictingClaims`, L131). A claim path that is not a regular file keeps
/// no bytes (`sourceByteCount` 0, fix round 1, I2a).
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
    /// L130: each set-aside entry's reason, in `sourceBytes` order. Nil for
    /// a whole queue or a claim file.
    var entryReasons: [NativeWidgetActionQuarantineReason]? = nil
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
    /// Retention (12.00b.2-C fix round 1, I1). Only set-aside-entry records
    /// (`entryReasons != nil`, L130) are ever evicted: at most this many per
    /// owner, the oldest first. They hold entries that can never apply
    /// (malformed, invalid, or a different entry under an applied id).
    ///
    /// Every other record may be the only copy of valid actions and is never
    /// evicted: a whole queue (`malformedQueue`, and 11.x `tooManyActions`)
    /// and a claim file (`invalidClaim`, `conflictingClaims`). That pool is
    /// bounded without eviction: only the app writes claim files (this
    /// app-private directory, one claim at a time under the §4.2 lock, and a
    /// claim is returned before another is taken), and every native writer
    /// writes a JSON list and refuses to overwrite a queue that is not one
    /// (§4.3, `WidgetIntentEngine`), so each such record needs a file or queue
    /// made outside the protocol, and setting it aside removes that source.
    /// Each record keeps at most `maximumQuarantinedBytes`, and the account
    /// scrub removes the whole directory.
    static let maximumSetAsideEntryRecordsPerOwner = 4
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
            if let (existing, _) = try loadClaim(accountBinding: verifiedAccountBinding) {
                try removeClaimedPrefixFromQueue(existing)
                return existing
            }
            guard let raw = try queue.read() else { return nil }
            // 12.00b.2-C (L130): at most one 512-entry prefix per claim; the
            // rest stays queued. Only a queue that is not a list throws here.
            let batch = try NativeWidgetActionBatchPlanner.prepare(
                rawValue: NativeWidgetActionBatchPlanner.claimablePrefix(of: raw),
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
    ///
    /// Phase 12 12.00b.2-C (L130): only bytes that are not a JSON list reach
    /// this. A bad entry is set aside alone, at acknowledgement, and a long
    /// list is claimed a prefix at a time.
    func quarantineUnpreparableQueue(
        verifiedAccountBinding: String
    ) throws -> NativeWidgetActionQuarantineReason? {
        try Self.requireBinding(verifiedAccountBinding)
        return try withLock {
            guard let raw = try queue.read() else { return nil }
            let reason: NativeWidgetActionQuarantineReason
            do {
                _ = try NativeWidgetActionBatchPlanner.prepare(
                    rawValue: NativeWidgetActionBatchPlanner.claimablePrefix(of: raw),
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

    /// Phase 12 12.00b.2-C (L131): sets aside this owner's claim files that
    /// replay can never use, so later actions are no longer wedged behind
    /// them. Inside one lock hold:
    /// 1. every claim that fails `validatedClaim` is set aside as
    ///    `invalidClaim`;
    /// 2. if more than one valid claim remains, all of them are set aside as
    ///    `conflictingClaims`. The protocol never makes two (one writer under
    ///    this lock, and `claim` returns an existing claim before it takes
    ///    another), so a pair came from outside it (a restore, a copy, a
    ///    version skew). Nothing orders them, and either may already be
    ///    applied, so applying one or both could reorder timers or repeat an
    ///    action. Setting both aside applies nothing twice, and each claim's
    ///    bytes stay in a record that retention never evicts (fix round 1, I1).
    /// Each file is read once; those bytes decide its validity and are what
    /// the record keeps (up to `maximumQuarantinedBytes`). The record is
    /// verified before the claim file is removed.
    ///
    /// Fix round 1 (I2): a claim path that is not a regular file (a
    /// directory, a symbolic link) has no bytes to keep, so it is removed
    /// behind a count-only `invalidClaim` record. A regular file that cannot
    /// be read fails the pass closed (`unreadableClaim`, counted by AppStore)
    /// and nothing is removed: its bytes could not be kept, and the read may
    /// succeed later (data protection).
    /// Returns nil, touching nothing, when the claims load cleanly now.
    func quarantineUnusableClaims(verifiedAccountBinding: String) throws -> NativeWidgetActionQuarantineReason? {
        try Self.requireBinding(verifiedAccountBinding)
        return try withLock {
            try discardFiles(notOwnedBy: verifiedAccountBinding)
            let candidates = try files(prefix: Self.claimFilePrefix + verifiedAccountBinding + "-")
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            var valid: [(url: URL, bytes: Data)] = []
            var invalid: [(url: URL, bytes: Data)] = []
            var notRegular: [URL] = []
            for candidate in candidates {
                guard let kind = try? candidate.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else {
                    throw NativeWidgetActionClaimError.unreadableClaim
                }
                guard kind.isSymbolicLink != true, kind.isRegularFile == true else {
                    notRegular.append(candidate)
                    continue
                }
                let bytes: Data
                do { bytes = try Data(contentsOf: candidate) } catch { throw NativeWidgetActionClaimError.unreadableClaim }
                if (try? validatedClaim(bytes, at: candidate, accountBinding: verifiedAccountBinding)) != nil {
                    valid.append((candidate, bytes))
                } else {
                    invalid.append((candidate, bytes))
                }
            }
            for path in notRegular {
                try setAsideClaimPath(path, accountBinding: verifiedAccountBinding)
            }
            for file in invalid {
                try setAsideClaimFile(file.url, bytes: file.bytes, reason: .invalidClaim, accountBinding: verifiedAccountBinding)
            }
            if valid.count > 1 {
                for file in valid {
                    try setAsideClaimFile(
                        file.url, bytes: file.bytes, reason: .conflictingClaims, accountBinding: verifiedAccountBinding
                    )
                }
                return .conflictingClaims
            }
            return invalid.isEmpty && notRegular.isEmpty ? nil : .invalidClaim
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
    ///
    /// Phase 12 12.00b.2-C (L130): when the claim holds entries the planner
    /// set aside, their record (exact bytes, one reason per entry) is written
    /// and verified BEFORE the claim is removed, in the same lock hold. A
    /// crash in between leaves the claim: the retry re-applies nothing (every
    /// valid action is already recorded) and rewrites the same record.
    func acknowledge(_ claim: NativeWidgetActionClaim) throws {
        try withLock {
            guard let (stored, batch) = try loadClaim(accountBinding: claim.accountBinding), stored == claim
            else { throw NativeWidgetActionClaimError.verificationFailed }
            if !batch.rejected.isEmpty {
                let bytes = try NativeWidgetActionBatchPlanner.rejectedEntryBytes(of: batch)
                try persist(NativeWidgetActionQuarantine(
                    schemaVersion: NativeWidgetActionQuarantine.currentSchemaVersion,
                    accountBinding: claim.accountBinding,
                    reason: NativeWidgetActionQuarantineReason(entry: batch.rejected[0].error),
                    sourceDigest: Self.digest(bytes),
                    sourceByteCount: bytes.count,
                    sourceBytes: bytes.count <= Self.maximumQuarantinedBytes ? bytes : nil,
                    entryReasons: batch.rejected.map { NativeWidgetActionQuarantineReason(entry: $0.error) }
                ))
            }
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
        // Bounded retention (fix round 1, I1): a set-aside-entry record evicts
        // only this owner's oldest set-aside-entry records. Whole-queue and
        // claim-file records are never evicted (`maximumSetAsideEntryRecordsPerOwner`).
        if record.entryReasons != nil {
            let entryRecords = try files(prefix: Self.quarantineFilePrefix + record.accountBinding + "-")
                .filter { $0.lastPathComponent != destination.lastPathComponent && Self.isSetAsideEntryRecord($0) }
                .sorted { (Self.modificationDate($0), $0.lastPathComponent) < (Self.modificationDate($1), $1.lastPathComponent) }
            for url in entryRecords.prefix(max(0, entryRecords.count - (Self.maximumSetAsideEntryRecordsPerOwner - 1))) {
                do { try FileManager.default.removeItem(at: url) } catch { throw NativeWidgetActionClaimError.writeFailed }
            }
        }
        let bytes = try Self.encode(record)
        // 12.00b.2-C: the name is the digest of the bytes set aside, so an
        // existing record under it already keeps those same bytes. One that
        // differs (another reason, or a damaged file) is replaced rather than
        // wedging the acknowledgement behind it.
        if let existing = try? Data(contentsOf: destination), existing != bytes {
            do { try FileManager.default.removeItem(at: destination) } catch { throw NativeWidgetActionClaimError.writeFailed }
        }
        try persist(bytes, to: destination)
    }

    /// L131: records one claim file's `bytes` in an owner-scoped quarantine
    /// record, then removes the file (verified). Called inside the lock.
    private func setAsideClaimFile(
        _ url: URL,
        bytes: Data,
        reason: NativeWidgetActionQuarantineReason,
        accountBinding: String
    ) throws {
        try persist(NativeWidgetActionQuarantine(
            schemaVersion: NativeWidgetActionQuarantine.currentSchemaVersion,
            accountBinding: accountBinding,
            reason: reason,
            sourceDigest: Self.digest(bytes),
            sourceByteCount: bytes.count,
            sourceBytes: bytes.count <= Self.maximumQuarantinedBytes ? bytes : nil
        ))
        do { try FileManager.default.removeItem(at: url) } catch { throw NativeWidgetActionClaimError.writeFailed }
        guard !FileManager.default.fileExists(atPath: url.path) else {
            throw NativeWidgetActionClaimError.verificationFailed
        }
    }

    /// Fix round 1 (I2a): a claim path that is not a regular file has no
    /// bytes to keep. A count-only `invalidClaim` record is written (no bytes,
    /// byte count 0; its digest is of the file name, so a retry rewrites the
    /// same record), then the path itself is removed (a directory with its
    /// contents, a symbolic link but never its target) and verified gone.
    /// Called inside the lock.
    private func setAsideClaimPath(_ url: URL, accountBinding: String) throws {
        try persist(NativeWidgetActionQuarantine(
            schemaVersion: NativeWidgetActionQuarantine.currentSchemaVersion,
            accountBinding: accountBinding,
            reason: .invalidClaim,
            sourceDigest: Self.digest(Data(url.lastPathComponent.utf8)),
            sourceByteCount: 0,
            sourceBytes: nil
        ))
        do { try FileManager.default.removeItem(at: url) } catch { throw NativeWidgetActionClaimError.writeFailed }
        guard (try? FileManager.default.attributesOfItem(atPath: url.path)) == nil else {
            throw NativeWidgetActionClaimError.verificationFailed
        }
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

    /// This owner's one claim and its prepared batch. More than one claim
    /// file is `conflictingClaims`; a bad one is `invalidClaim`. Both are set
    /// aside by `quarantineUnusableClaims` (L131).
    private func loadClaim(
        accountBinding: String
    ) throws -> (claim: NativeWidgetActionClaim, batch: NativeWidgetActionBatch)? {
        try Self.requireBinding(accountBinding)
        let candidates = try files(prefix: Self.claimFilePrefix + accountBinding + "-")
        guard candidates.count <= 1 else { throw NativeWidgetActionClaimError.conflictingClaims }
        guard let candidate = candidates.first else { return nil }
        let bytes: Data
        do { bytes = try Data(contentsOf: candidate) } catch { throw NativeWidgetActionClaimError.invalidClaim }
        return try validatedClaim(bytes, at: candidate, accountBinding: accountBinding)
    }

    /// `bytes` (read from `candidate`) as this owner's claim, or `invalidClaim`.
    private func validatedClaim(
        _ bytes: Data,
        at candidate: URL,
        accountBinding: String
    ) throws -> (claim: NativeWidgetActionClaim, batch: NativeWidgetActionBatch) {
        let claim: NativeWidgetActionClaim
        do {
            claim = try JSONDecoder().decode(NativeWidgetActionClaim.self, from: bytes)
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
            let batch = try NativeWidgetActionBatchPlanner.prepare(
                rawValue: claim.rawValue!,
                verifiedAccountBinding: accountBinding
            )
            return (claim, batch)
        } catch { throw NativeWidgetActionClaimError.invalidClaim }
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
        } else if let entries = NativeWidgetActionBatchPlanner.exactEntries(
            of: Data(current.utf8), matching: currentValues
        ), let raw = String(data: NativeWidgetActionBatchPlanner.joinedList(entries.dropFirst(claimedValues.count)), encoding: .utf8) {
            // 12.00b.2-C (L130): the entries left queued keep their exact
            // bytes, so a later claim sets aside exactly what was written.
            try replaceQueue(with: raw)
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
    ///
    /// Phase 12 12.00b.2-C (Task 6 review M3, R21): a busy lock logs the same
    /// payload-free line as the inbox (`N/NativeAppGroupInbox.swift`), then
    /// fails as before: the queue and claims stay as they are and AppStore
    /// reports the actions as still safely queued.
    private func withLock<T>(_ body: () throws -> T) throws -> T {
        do {
            return try WidgetAppGroupLock.withExclusiveLock(at: lockFile, body)
        } catch WidgetAppGroupLockError.busy {
            print("TradeReadyWidgetLock stage=busy site=replay")
            throw NativeWidgetActionClaimError.lockFailed
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

    /// Fix round 1 (I1): only a record that decodes and lists per-entry
    /// reasons can be evicted. One that cannot be read or decoded is kept.
    private static func isSetAsideEntryRecord(_ url: URL) -> Bool {
        guard let bytes = try? Data(contentsOf: url),
              let record = try? JSONDecoder().decode(NativeWidgetActionQuarantine.self, from: bytes)
        else { return false }
        return record.entryReasons != nil
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
    /// `setAside`: owned entries that could not apply, kept in a quarantine
    /// record written before the claim was acknowledged (12.00b.2-C, L130).
    case committed(snapshot: Canonical.Snapshot, changed: Int, ignored: Int, ownerDropped: Int, setAside: Int)
    /// C8: the shared queue could not be prepared and was set aside, or
    /// (12.00b.2-C, L131) an unusable claim file was.
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
    /// 12.00b.2-C (L130): owned entries set aside while their batch applied.
    /// Counted from `.committed`, which `replayNext` returns only after the
    /// claim is acknowledged, so a retried claim counts its entries once.
    private(set) var setAsideActionCount = 0
    /// 12.00b.2-C (L131): replay results that set aside unusable claim files.
    private(set) var quarantinedClaimCount = 0
    /// 12.00b.2-C fix round 1 (I2b): replay passes that failed closed on a
    /// claim file that is a regular file but cannot be read.
    private(set) var unreadableClaimCount = 0

    mutating func recordOwnerDropped(_ count: Int) {
        guard count > 0 else { return }
        ownerDroppedActionCount = min(Self.maximumCount, ownerDroppedActionCount + min(count, Self.maximumCount))
    }

    /// A whole queue (C8) or, for a claim reason, the claim files (L131).
    mutating func recordQuarantine(_ reason: NativeWidgetActionQuarantineReason) {
        if reason.isClaimReason {
            quarantinedClaimCount = min(Self.maximumCount, quarantinedClaimCount + 1)
        } else {
            quarantinedQueueCount = min(Self.maximumCount, quarantinedQueueCount + 1)
        }
    }

    mutating func recordSetAsideActions(_ count: Int) {
        guard count > 0 else { return }
        setAsideActionCount = min(Self.maximumCount, setAsideActionCount + min(count, Self.maximumCount))
    }

    mutating func recordUnreadableClaim() {
        unreadableClaimCount = min(Self.maximumCount, unreadableClaimCount + 1)
    }

    mutating func recordAccountSwitchScrubFailure() {
        accountSwitchScrubFailureCount = min(Self.maximumCount, accountSwitchScrubFailureCount + 1)
    }

    /// Clears the per-owner counters at an account switch.
    mutating func resetForAccountBoundary() {
        ownerDroppedActionCount = 0
        quarantinedQueueCount = 0
        setAsideActionCount = 0
        quarantinedClaimCount = 0
        unreadableClaimCount = 0
    }
}

/// Owns the commit ordering: durable claim, pure replay, one atomic canonical
/// save, the outbound-sync enqueue of every written record, then exact
/// acknowledgement. Unsupported future actions retain their claim and prevent
/// partial application of the batch.
struct NativeWidgetActionReplayCoordinator {
    /// C8: the bounded, payload-free message surfaced after a quarantine.
    static let quarantinedMessage = "Some widget or Siri actions couldn't be read and were set aside."

    /// 12.00b.2-C: the message for a `.quarantined` result. Bytes that are
    /// not a list, or a claim file that fails validation, "couldn't be read";
    /// conflicting claims were readable but are not applied (L131).
    static func quarantinedMessage(for reason: NativeWidgetActionQuarantineReason) -> String {
        reason == .conflictingClaims
            ? "Some widget or Siri actions couldn't be applied and were set aside."
            : quarantinedMessage
    }

    /// 12.00b.2-C (L130): the message after a pass applied its valid actions
    /// and set `actionCount` owned entries aside. A count only, no content.
    static func setAsideMessage(actionCount: Int) -> String {
        actionCount == 1
            ? "1 widget or Siri action couldn't be applied and was set aside."
            : "\(actionCount) widget or Siri actions couldn't be applied and were set aside."
    }

    /// Final review C1: queues the upserts of `records` (read from the
    /// committed snapshot) for the outbound sync. Called after the canonical
    /// save and BEFORE the claim is acknowledged, only when the batch wrote a
    /// record, on the caller's actor and for the same verified owner the
    /// batch was committed for. A throw leaves the claim unacknowledged: the
    /// retry finds each record already written and queues it again.
    typealias EnqueueWrittenRecords = (
        _ records: [NativeWidgetActionRecordKey],
        _ committed: Canonical.Snapshot
    ) throws -> Void

    let transport: NativeWidgetActionClaimTransport
    let repository: Canonical.SnapshotRepository
    let enqueueWrittenRecords: EnqueueWrittenRecords

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
        } catch NativeWidgetActionClaimError.invalidClaim, NativeWidgetActionClaimError.conflictingClaims {
            // 12.00b.2-C (L131): a claim file replay can never use would
            // otherwise be retried forever, wedging this owner's replay.
            if let reason = try transport.quarantineUnusableClaims(
                verifiedAccountBinding: verifiedAccountBinding
            ) {
                return .quarantined(reason: reason)
            }
            // The claims load cleanly now (a transient read failure).
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
        if !result.writtenRecords.isEmpty {
            try enqueueWrittenRecords(result.writtenRecords, result.snapshot)
        }
        try transport.acknowledge(claim)
        return .committed(
            snapshot: result.snapshot,
            changed: result.changedActionCount,
            ignored: result.ignoredActionCount,
            ownerDropped: batch.ownerDroppedCount,
            setAside: batch.rejected.count
        )
    }
}

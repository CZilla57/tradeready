import CryptoKit
import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

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
    static let maximumIdentifierLength = 128

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
    let actions: [Action]
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
        let values: [Canonical.JSONValue]
        do {
            values = try JSONDecoder().decode([Canonical.JSONValue].self, from: source)
        } catch {
            throw NativeWidgetActionBatchError.malformedQueue
        }
        guard values.count <= NativeWidgetActionBatch.maximumActionCount else {
            throw NativeWidgetActionBatchError.tooManyActions
        }

        var identifiers = Set<String>()
        var actions: [NativeWidgetActionBatch.Action] = []
        actions.reserveCapacity(values.count)
        for (index, value) in values.enumerated() {
            guard case let .object(fields) = value,
                  let id = string("id", fields),
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
            actions: actions
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
        !value.isEmpty
            && value.utf8.count <= NativeWidgetActionBatch.maximumIdentifierLength
            && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }

    private static func validInstant(_ value: String) -> Bool {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) != nil || ISO8601DateFormatter().date(from: value) != nil
    }

    private static func validLocalDate(_ value: String) -> Bool {
        let pieces = value.split(separator: "-", omittingEmptySubsequences: false)
        guard pieces.count == 3, pieces[0].count == 4, pieces[1].count == 2, pieces[2].count == 2,
              let year = Int(pieces[0]), let month = Int(pieces[1]), let day = Int(pieces[2])
        else { return false }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        guard let date = calendar.date(from: DateComponents(year: year, month: month, day: day)) else { return false }
        let rebuilt = calendar.dateComponents([.year, .month, .day], from: date)
        return rebuilt.year == year && rebuilt.month == month && rebuilt.day == day
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
        guard !hasMarker(action.id, jobs: jobs),
              !doneStatuses.contains(jobs[index].status),
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
    static let suiteName = "group.com.gettradereadyapp.tradeready"
    static let key = "widgetActions"

    private let defaults: UserDefaults?

    init(defaults: UserDefaults? = UserDefaults(suiteName: suiteName)) {
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

/// Cross-process claim transport for the App Group action queue. The app and
/// every extension writer coordinate on the same advisory lock file. The app
/// first publishes and verifies a private write-ahead claim, then removes only
/// the claimed prefix from the shared queue. A crash at any point leaves either
/// the original queue, a recoverable claim, or both.
struct NativeWidgetActionClaimTransport {
    static let lockFileName = ".tradeready-widget-actions.lock"

    let queue: any NativeWidgetActionQueueBacking
    let claimDirectory: URL
    let lockFile: URL

    static func live(
        fileManager: FileManager = .default,
        queue: any NativeWidgetActionQueueBacking = NativeUserDefaultsWidgetActionQueue()
    ) throws -> NativeWidgetActionClaimTransport {
        guard let appGroup = fileManager.containerURL(
            forSecurityApplicationGroupIdentifier: NativeUserDefaultsWidgetActionQueue.suiteName
        ) else { throw NativeWidgetActionClaimError.unavailable }
        guard let support = fileManager.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first else { throw NativeWidgetActionClaimError.unavailable }
        return .init(
            queue: queue,
            claimDirectory: support.appendingPathComponent("WidgetActionClaims", isDirectory: true),
            lockFile: appGroup.appendingPathComponent(Self.lockFileName)
        )
    }

    /// Returns the existing unacknowledged claim first. Otherwise it claims the
    /// current shared queue. The verified account binding is part of both the
    /// durable envelope and its filename, preventing cross-account recovery.
    func claim(verifiedAccountBinding: String) throws -> NativeWidgetActionClaim? {
        try withLock {
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
        do {
            try FileManager.default.createDirectory(
                at: claimDirectory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let bytes = try Self.encode(claim)
            let destination = claimURL(claim)
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

    private func loadClaim(accountBinding: String) throws -> NativeWidgetActionClaim? {
        guard accountBinding.count == 64,
              accountBinding.allSatisfy({ $0.isHexDigit && !$0.isUppercase })
        else { throw NativeWidgetActionBatchError.invalidAccountBinding }
        guard FileManager.default.fileExists(atPath: claimDirectory.path) else { return nil }
        let prefix = "claim-\(accountBinding)-"
        let candidates = try FileManager.default.contentsOfDirectory(
            at: claimDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ).filter { $0.lastPathComponent.hasPrefix(prefix) && $0.pathExtension == "json" }
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
        _ = try NativeWidgetActionBatchPlanner.prepare(
            rawValue: claim.rawValue!,
            verifiedAccountBinding: accountBinding
        )
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
            "claim-\(claim.accountBinding)-\(claim.sourceDigest).json"
        )
    }

    private func withLock<T>(_ body: () throws -> T) throws -> T {
        do {
            try FileManager.default.createDirectory(
                at: lockFile.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        } catch { throw NativeWidgetActionClaimError.lockFailed }
        let descriptor = open(lockFile.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw NativeWidgetActionClaimError.lockFailed }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else {
            throw NativeWidgetActionClaimError.lockFailed
        }
        defer { flock(descriptor, LOCK_UN) }
        return try body()
    }

    private static func encode(_ claim: NativeWidgetActionClaim) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(claim)
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

enum NativeWidgetActionReplayCommitResult {
    case nothingPending
    case retainedUnsupported(actionCount: Int)
    case committed(snapshot: Canonical.Snapshot, changed: Int, ignored: Int)
}

/// Owns the commit ordering: durable claim, pure replay, one atomic canonical
/// save, then exact acknowledgement. Unsupported future actions retain their
/// claim and prevent partial application of the batch.
struct NativeWidgetActionReplayCoordinator {
    let transport: NativeWidgetActionClaimTransport
    let repository: Canonical.SnapshotRepository

    func replayNext(
        snapshot: Canonical.Snapshot,
        verifiedAccountBinding: String
    ) throws -> NativeWidgetActionReplayCommitResult {
        guard let claim = try transport.claim(verifiedAccountBinding: verifiedAccountBinding),
              let raw = claim.rawValue
        else { return .nothingPending }
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
            ignored: result.ignoredActionCount
        )
    }
}

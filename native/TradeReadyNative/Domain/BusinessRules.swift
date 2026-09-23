import Foundation

// MARK: - Recurrence

enum RecurrenceCadence: String, Codable, CaseIterable {
    case daily, weekly, monthly, quarterly, annually
}

enum RecurrenceEndCondition: String, Codable {
    case never, count, date
}

struct RecurrenceState: Equatable {
    var endCondition: RecurrenceEndCondition
    var endCount: Int?
    var endDate: String?
    var occurrenceCount: Int
    var nextDueDate: String
}

enum RecurrenceRules {
    /// Matches JavaScript Date setter overflow rather than Calendar's clamping:
    /// 2026-01-31 + one month is 2026-03-03.
    static func nextDate(
        after date: String,
        cadence: RecurrenceCadence,
        calendar inputCalendar: Calendar = .current
    ) -> String {
        guard let parts = dateParts(date) else { return date }
        var calendar = inputCalendar
        calendar.locale = Locale(identifier: "en_US_POSIX")

        var year = parts.year
        var month = parts.month
        let day = parts.day
        switch cadence {
        case .daily, .weekly:
            guard let start = calendar.date(from: DateComponents(
                calendar: calendar, year: year, month: month, day: day
            )), let result = calendar.date(byAdding: .day, value: cadence == .daily ? 1 : 7, to: start)
            else { return date }
            return localDate(result, calendar: calendar)
        case .monthly:
            month += 1
        case .quarterly:
            month += 3
        case .annually:
            year += 1
        }

        // Normalize the target month first, then add day - 1 from its first day.
        // This is equivalent to JS setMonth/setFullYear with an overflowing day.
        let zeroBasedMonth = month - 1
        year += zeroBasedMonth / 12
        month = zeroBasedMonth % 12 + 1
        guard let first = calendar.date(from: DateComponents(
            calendar: calendar, year: year, month: month, day: 1
        )), let result = calendar.date(byAdding: .day, value: day - 1, to: first)
        else { return date }
        return localDate(result, calendar: calendar)
    }

    static func isEndConditionMet(_ state: RecurrenceState) -> Bool {
        switch state.endCondition {
        case .never:
            return false
        case .count:
            // Production records with this condition are required to carry endCount.
            return state.endCount.map { state.occurrenceCount >= $0 } ?? false
        case .date:
            // YYYY-MM-DD lexical order is chronological.
            return state.endDate.map { state.nextDueDate > $0 } ?? false
        }
    }

    /// Resume rule for recurring invoices: elapsed paused periods are skipped and
    /// do not consume occurrenceCount. Already-ended rules remain unchanged.
    static func fastForwardedInvoiceDate(
        _ state: RecurrenceState,
        cadence: RecurrenceCadence,
        through today: String,
        calendar: Calendar = .current
    ) -> String {
        guard !isEndConditionMet(state) else { return state.nextDueDate }
        var next = state.nextDueDate
        while next <= today {
            let advanced = nextDate(after: next, cadence: cadence, calendar: calendar)
            guard advanced > next else { break }
            next = advanced
        }
        return next
    }

    private static func dateParts(_ value: String) -> (year: Int, month: Int, day: Int)? {
        let fields = value.split(separator: "-", omittingEmptySubsequences: false)
        guard fields.count == 3,
              fields[0].count == 4, fields[1].count == 2, fields[2].count == 2,
              let year = Int(fields[0]), let month = Int(fields[1]), let day = Int(fields[2]),
              (1...12).contains(month), (1...31).contains(day)
        else { return nil }
        return (year, month, day)
    }

    private static func localDate(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}

// MARK: - Invoice numbering

struct InvoiceNumberOptions: Equatable {
    var prefix: String?
    var startingNumber: Double?
}

enum InvoiceNumberRules {
    static let defaultPrefix = "INV"

    static func normalizedPrefix(_ candidate: String?) -> String {
        var value = (candidate ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        while let last = value.last, last == "-" || last.isWhitespace {
            value.removeLast()
        }
        return value.isEmpty ? defaultPrefix : value
    }

    static func nextNumber(
        existingNumbers: [String?],
        options: InvoiceNumberOptions = .init()
    ) -> String {
        let prefix = normalizedPrefix(options.prefix)
        let start: Int = {
            guard let raw = options.startingNumber, raw.isFinite, raw >= 1 else { return 1 }
            return Int(raw.rounded(.towardZero))
        }()

        let maximum = existingNumbers.compactMap { number -> Int? in
            var raw = number ?? ""
            if raw.lowercased().hasPrefix(prefix.lowercased()) {
                raw.removeFirst(min(prefix.count, raw.count))
            }
            // JavaScript's /\D/g digit scan is ASCII-only.
            let digits = raw.filter { $0.isASCII && $0.isNumber }
            guard let parsed = Int(digits), parsed != 0 else { return nil }
            return parsed
        }.max()
        let next = max((maximum ?? 0) + 1, start)
        return "\(prefix)-\(String(format: "%04d", next))"
    }
}

// MARK: - Job lifecycle

enum JobLifecycleStatus: String, Codable, CaseIterable {
    case lead
    case estimateSent = "estimate_sent"
    case approved, scheduled
    case inProgress = "in_progress"
    case complete, invoiced, paid, declined

    var next: JobLifecycleStatus? {
        switch self {
        case .lead: return .estimateSent
        case .estimateSent: return .approved
        case .approved: return .scheduled
        case .scheduled: return .inProgress
        case .inProgress: return .complete
        case .complete: return .invoiced
        case .invoiced: return .paid
        case .paid, .declined: return nil
        }
    }
}

enum EstimateDecision { case approved, declined }
enum InvoiceScreenMode { case create, requestDeposit, finalize }

struct JobInvoiceChanges: Equatable {
    var status: JobLifecycleStatus?
    var invoiceID: String
}

struct LifecycleJob: Equatable {
    var id: String
    var status: JobLifecycleStatus
    var invoiceID: String?
}

enum JobLifecycleRules {
    static func statusAfterScheduling(_ status: JobLifecycleStatus, hasSchedule: Bool) -> JobLifecycleStatus {
        hasSchedule && status == .approved ? status.next ?? status : status
    }

    static func canSendEstimate(status: JobLifecycleStatus, estimateTotal: Decimal) -> Bool {
        estimateTotal > 0 && (status == .lead || status == .estimateSent)
    }

    static func statusAfterEstimateDecision(
        _ status: JobLifecycleStatus,
        decision: EstimateDecision
    ) -> JobLifecycleStatus {
        guard status == .lead || status == .estimateSent else { return status }
        return decision == .approved ? (.estimateSent.next ?? status) : .declined
    }

    static func canRequestDeposit(status: JobLifecycleStatus) -> Bool {
        status == .approved || status == .scheduled || status == .inProgress
    }

    static func invoiceScreenMode(status: JobLifecycleStatus, hasInvoice: Bool) -> InvoiceScreenMode? {
        if status == .complete { return hasInvoice ? .finalize : .create }
        if canRequestDeposit(status: status) && !hasInvoice { return .requestDeposit }
        return nil
    }

    static func changesAfterInvoiceSave(
        mode: InvoiceScreenMode,
        invoiceID: String,
        invoicePaid: Bool
    ) -> JobInvoiceChanges {
        JobInvoiceChanges(
            status: mode == .requestDeposit ? nil : (invoicePaid ? .paid : .invoiced),
            invoiceID: invoiceID
        )
    }

    static func isDunningEligible(status: JobLifecycleStatus?) -> Bool {
        guard let status else { return true }
        return status == .complete || status == .invoiced || status == .paid
    }

    static func advancePaidInvoiceJobs(_ jobs: [LifecycleJob], invoices: [LedgerInvoice]) -> [LifecycleJob] {
        let paidIDs = Set(invoices.filter(PaymentLedger.isFullyPaid).map(\.id))
        return jobs.map { job in
            guard job.status == .invoiced,
                  let invoiceID = job.invoiceID,
                  paidIDs.contains(invoiceID)
            else { return job }
            var changed = job
            changed.status = .paid
            return changed
        }
    }
}

// MARK: - Archive

protocol ArchivableRecord {
    var archivedAt: String? { get set }
}

enum ArchiveRules {
    static func isArchived(_ record: some ArchivableRecord) -> Bool {
        !(record.archivedAt ?? "").isEmpty
    }

    static func settingArchive<Record: ArchivableRecord>(
        _ record: Record,
        archived: Bool,
        today: String
    ) -> Record {
        var result = record
        result.archivedAt = archived ? today : nil
        return result
    }

    static func countArchived<Record: ArchivableRecord>(_ records: [Record]) -> Int {
        records.reduce(0) { $0 + (($1.archivedAt ?? "").isEmpty ? 0 : 1) }
    }
}

// MARK: - Local identifiers

/// Formats the timestamp/counter identifiers used by the production client.
/// The clock and random suffix are injectable so golden vectors are deterministic.
final class LocalIDGenerator {
    private let nowMilliseconds: () -> Int64
    private let randomBase36: () -> String
    private var counters: [String: Int] = [:]
    private var lastGeneratedInvoiceMilliseconds: Int64 = 0
    private var lastJobMilliseconds: Int64 = 0
    private var lastManualInvoiceMilliseconds: Int64 = 0
    private var lastMaterialMilliseconds: Int64 = 0
    private var lastJobCostMilliseconds: Int64 = 0
    private let lock = NSLock()

    init(
        nowMilliseconds: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1_000) },
        randomBase36: @escaping () -> String = {
            String(UUID().uuidString.lowercased().filter { $0.isLetter || $0.isNumber }.prefix(8))
        }
    ) {
        self.nowMilliseconds = nowMilliseconds
        self.randomBase36 = randomBase36
    }

    func customerID() -> String { counted(prefix: "c", counterKey: "customer") }
    func paymentID() -> String { counted(prefix: "p", counterKey: "payment") }
    func changeOrderID() -> String { counted(prefix: "co", counterKey: "changeOrder") }
    func importBatchID() -> String { counted(prefix: "imp_", counterKey: "importBatch") }
    func importedJobID() -> String { counted(prefix: "j", counterKey: "importJob") }
    func importedExpenseID() -> String { counted(prefix: "e", counterKey: "importExpense") }

    /// Manual job creation uses `j<Date.now()>` in the production client.
    func jobID() -> String { monotonicTimestamp(prefix: "j", last: &lastJobMilliseconds) }
    func materialID() -> String { monotonicTimestamp(prefix: "m", last: &lastMaterialMilliseconds) }
    func jobCostID() -> String { monotonicTimestamp(prefix: "jc", last: &lastJobCostMilliseconds) }

    /// Manual invoice creation uses the bare millisecond timestamp.
    func manualInvoiceID() -> String { monotonicTimestamp(prefix: "", last: &lastManualInvoiceMilliseconds) }

    func generatedInvoiceID() -> String {
        lock.lock()
        defer { lock.unlock() }
        let current = max(nowMilliseconds(), lastGeneratedInvoiceMilliseconds + 1)
        lastGeneratedInvoiceMilliseconds = current
        return "inv\(current)"
    }

    func recurringJobID(ruleID: String, occurrence: Int) -> String {
        "j\(nowMilliseconds())_\(ruleID)_\(occurrence)"
    }

    func expenseID() -> String { "\(nowMilliseconds())\(suffix(length: 5))" }
    func tripID() -> String { "\(nowMilliseconds())\(suffix(length: 5))" }
    func photoID() -> String { "p\(nowMilliseconds())_\(suffix(length: 32, fallback: "x"))" }

    private func counted(prefix: String, counterKey: String) -> String {
        lock.lock()
        defer { lock.unlock() }
        let next = (counters[counterKey] ?? 0) + 1
        counters[counterKey] = next
        return "\(prefix)\(nowMilliseconds())_\(next)"
    }

    private func monotonicTimestamp(prefix: String, last: inout Int64) -> String {
        lock.lock()
        defer { lock.unlock() }
        let current = max(nowMilliseconds(), last + 1)
        last = current
        return "\(prefix)\(current)"
    }

    private func suffix(length: Int, fallback: String = "") -> String {
        let allowed = randomBase36().lowercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
        let value = String(allowed.prefix(length))
        return value.isEmpty ? fallback : value
    }
}

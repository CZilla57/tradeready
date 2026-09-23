import Foundation

// Task 11.01 (W1): the App Group snapshot schema, compiled into BOTH the app
// (writer) and the TradeReadyWidgets extension (reader).
//
// Contract: docs/native-phase-11-platform-hardening-contract-decisions.md §2.
// This is RN's `BridgeSnapshot` v1 (`targets/widget/Widgets.swift`) plus the
// native `ownerTag` (§2.3):
// - field names and optionality are RN's exactly;
// - decoding is a plain `JSONDecoder` with no key strategy, so unknown keys
//   are ignored and `nextJob.address: null` is rejected (fixture F6);
// - encoding is `.sortedKeys` with explicit `null`s for `nextJob`, `timer`
//   and `scheduledStartTime`, so RN's decoder accepts every native snapshot.
//
// Minimal projection (§2.2): never add a collection, a contact detail other
// than the displayed name and address, notes, an amount other than
// `outstandingTotal`, or any secure value to this type.

struct WidgetSnapshot: Codable, Equatable {
    static let currentVersion = 1

    /// Contract §3.3 (C3): stale iff age > 86,400 s, age < 0, or `updatedAt`
    /// is unparseable. Exactly 86,400 s is fresh.
    static let staleAfterSeconds: TimeInterval = 86_400

    var version: Int
    /// ISO 8601 instant of the mirror write (fractional seconds, `Z`).
    var updatedAt: String
    var nextJob: NextJob?
    var timer: TimerState?
    /// Dollars rounded to 2 dp. RN always writes it; older writers may omit
    /// it (fixture F5), so it decodes as optional.
    var outstandingTotal: Double?
    /// `sha256hex("tradeready.widget.owner.v1:" + binding)` (§2.3). Missing
    /// means "no owner": extension writers refuse (§4.5). RN ignores it.
    var ownerTag: String?

    struct NextJob: Codable, Equatable {
        var id: String
        var customerName: String
        var title: String
        /// Local-frame `yyyy-MM-dd`. Never parse it as UTC (FA-039).
        var scheduledDate: String
        /// `HH:mm`, or nil when the job has a date but no start time.
        var scheduledStartTime: String?
        /// Always a string (`""` when empty). `null` fails the decode (F6).
        var address: String

        private enum CodingKeys: String, CodingKey {
            case id, customerName, title, scheduledDate, scheduledStartTime, address
        }

        init(
            id: String,
            customerName: String,
            title: String,
            scheduledDate: String,
            scheduledStartTime: String?,
            address: String
        ) {
            self.id = id
            self.customerName = customerName
            self.title = title
            self.scheduledDate = scheduledDate
            self.scheduledStartTime = scheduledStartTime
            self.address = address
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(id, forKey: .id)
            try container.encode(customerName, forKey: .customerName)
            try container.encode(title, forKey: .title)
            try container.encode(scheduledDate, forKey: .scheduledDate)
            // Explicit null, never omitted (§2.3).
            try container.encode(scheduledStartTime, forKey: .scheduledStartTime)
            try container.encode(address, forKey: .address)
        }

        /// RN `startDate` (`targets/widget/Widgets.swift:58-70`): the start
        /// instant in the device's local calendar, `en_US_POSIX`, format
        /// `yyyy-MM-dd HH:mm`, else `yyyy-MM-dd`.
        func startDate(timeZone: TimeZone = .current) -> Date? {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = timeZone
            if let time = scheduledStartTime {
                formatter.dateFormat = "yyyy-MM-dd HH:mm"
                return formatter.date(from: "\(scheduledDate) \(time)")
            }
            formatter.dateFormat = "yyyy-MM-dd"
            return formatter.date(from: scheduledDate)
        }
    }

    struct TimerState: Codable, Equatable {
        var jobId: String
        var jobTitle: String
        var customerName: String
        /// ISO 8601 clock-in instant.
        var startedAt: String
    }

    private enum CodingKeys: String, CodingKey {
        case version, updatedAt, nextJob, timer, outstandingTotal, ownerTag
    }

    init(
        version: Int = WidgetSnapshot.currentVersion,
        updatedAt: String,
        nextJob: NextJob?,
        timer: TimerState?,
        outstandingTotal: Double?,
        ownerTag: String? = nil
    ) {
        self.version = version
        self.updatedAt = updatedAt
        self.nextJob = nextJob
        self.timer = timer
        self.outstandingTotal = outstandingTotal
        self.ownerTag = ownerTag
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(updatedAt, forKey: .updatedAt)
        // Explicit nulls, never omitted (§2.3).
        try container.encode(nextJob, forKey: .nextJob)
        try container.encode(timer, forKey: .timer)
        try container.encode(outstandingTotal, forKey: .outstandingTotal)
        try container.encodeIfPresent(ownerTag, forKey: .ownerTag)
    }

    // MARK: JSON

    /// Plain `JSONDecoder`, no key strategy (§2.2). Nil on any failure,
    /// including F6's `address: null`.
    static func decode(json: String) -> WidgetSnapshot? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(WidgetSnapshot.self, from: data)
    }

    /// `.sortedKeys` (§2.3). The result is what the writer stores under
    /// `WidgetAppGroup.snapshotKey`.
    func encodedJSON() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(self)
        guard let json = String(data: data, encoding: .utf8) else {
            throw EncodingError.invalidValue(
                self, .init(codingPath: [], debugDescription: "snapshot JSON was not UTF-8")
            )
        }
        return json
    }

    /// Reads and decodes the mirror. Display-only readers (widget timelines)
    /// may call this without the lock; intent writers must read inside the
    /// same lock hold as their append (§4.5).
    static func load(from defaults: UserDefaults?) -> WidgetSnapshot? {
        guard let json = defaults?.string(forKey: WidgetAppGroup.snapshotKey) else { return nil }
        return decode(json: json)
    }

    // MARK: Dates

    /// `updatedAt` format: `.withInternetDateTime` + `.withFractionalSeconds`,
    /// UTC — byte-compatible with JS `toISOString()`.
    static func isoTimestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    /// Fractional seconds first, then plain (the `siriParseISODate` two-step).
    static func parseISODate(_ text: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: text) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: text)
    }

    var updatedAtDate: Date? { Self.parseISODate(updatedAt) }

    /// Contract §3.3: `age > 86_400 || age < 0 || updatedAt is unparseable`.
    func isStale(now: Date) -> Bool {
        guard let written = updatedAtDate else { return true }
        let age = now.timeIntervalSince(written)
        return age > Self.staleAfterSeconds || age < 0
    }

    /// Equality of everything except `updatedAt` — used by the writer to skip
    /// a redundant rewrite (and timeline reload) of an unchanged, fresh mirror.
    func hasSameContent(as other: WidgetSnapshot) -> Bool {
        version == other.version
            && nextJob == other.nextJob
            && timer == other.timer
            && outstandingTotal == other.outstandingTotal
            && ownerTag == other.ownerTag
    }
}

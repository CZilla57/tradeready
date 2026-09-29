import Foundation

// MARK: - Export + import presentation (task 9.13, requirements X1, X2, I1-I3)
//
// The screen-level half of `screens/ExportDataScreen.tsx` and
// `screens/SettingsImportScreen.tsx`: range choices and their guard, the export
// rows with live counts, the share-file tail, and the import lifecycle copy,
// validation, report, and history projection.
//
// The bytes and the counts come from 9.06/9.07 (`NativeCSVExport`,
// `NativeAccountingPackage`, `NativeCSVImport`, `NativeImportMapping`,
// `NativeImportEngine`). Nothing here writes canonical state.

// MARK: - Export ranges

enum NativeExportRangeChoice: String, CaseIterable, Identifiable {
    case thisMonth = "this_month"
    case thisQuarter = "this_quarter"
    case thisYear = "this_year"
    case lastYear = "last_year"
    case allTime = "all_time"
    case custom

    var id: String { rawValue }

    var label: String {
        switch self {
        case .thisMonth: "This Month"
        case .thisQuarter: "This Quarter"
        case .thisYear: "This Year"
        case .lastYear: "Last Year"
        case .allTime: "All Time"
        case .custom: "Custom"
        }
    }

    var isCustom: Bool { self == .custom }
}

enum NativeExportRange {
    static let invalidTitle = "Check your dates"
    static let invalidMessage = "The start date is after the end date."

    /// The window for a choice. `custom` is the inclusive local-day span of the
    /// two picked dates (`startOfDay` … `endOfDay`), exactly like the RN screen.
    static func range(
        for choice: NativeExportRangeChoice,
        customStart: Date,
        customEnd: Date,
        now: Date = Date(),
        calendar: Calendar = NativeCashBasis.localCalendar
    ) -> NativeDateRange {
        guard choice.isCustom else {
            return NativeCashBasis.exportRange(for: choice.rawValue, now: now)
        }
        return NativeDateRange(
            start: calendar.startOfDay(for: customStart),
            end: endOfDay(customEnd, calendar: calendar)
        )
    }

    /// `startOfDay(customStart) > endOfDay(customEnd)` — only a custom range can
    /// be invalid, and the guard runs before either share action.
    static func isInvalid(
        _ choice: NativeExportRangeChoice,
        customStart: Date,
        customEnd: Date,
        calendar: Calendar = NativeCashBasis.localCalendar
    ) -> Bool {
        guard choice.isCustom else { return false }
        return calendar.startOfDay(for: customStart) > endOfDay(customEnd, calendar: calendar)
    }

    static func endOfDay(_ date: Date, calendar: Calendar = NativeCashBasis.localCalendar) -> Date {
        let start = calendar.startOfDay(for: date)
        return calendar.date(byAdding: DateComponents(hour: 23, minute: 59, second: 59), to: start) ?? start
    }
}

// MARK: - Export rows

enum NativeExportDataset: String, CaseIterable, Identifiable {
    case income, expenses, mileage

    var id: String { rawValue }

    var label: String {
        switch self {
        case .income: "Income"
        case .expenses: "Expenses"
        case .mileage: "Mileage"
        }
    }

    var hint: String {
        switch self {
        case .income: "One row per payment received"
        case .expenses: "One row per expense"
        case .mileage: "One row per logged trip"
        }
    }
}

/// One shareable dataset row: label, live row count, hint, and share filename.
struct NativeExportRow: Equatable {
    var dataset: NativeExportDataset
    var label: String
    var hint: String
    var rowCount: Int
    var filename: String

    var detailText: String { "\(rowCount) rows · \(hint)" }
}

enum NativeExportRows {
    static let packageLabel = "Accountant package (.zip)"
    static let packageHint = "Everything your accountant needs, in one file"
    static let dateRangeHeading = "Date range"
    static let exportHeading = "Export"
    static let footnote = "CSV files open in Excel, Numbers, Google Sheets, and import into accounting software. Amounts are plain numbers; income is listed by payment received."
    static let shareTitle = "Share"

    /// CSV text per dataset for the window (the bytes the share tail sends).
    static func csvs(
        invoices: [Canonical.Invoice],
        expenses: [Canonical.Expense],
        trips: [Canonical.Trip],
        range: NativeDateRange
    ) -> [NativeExportDataset: String] {
        [
            .income: NativeCSVExport.buildIncomeCsv(invoices: invoices, start: range.start, end: range.end),
            .expenses: NativeCSVExport.buildExpensesCsv(expenses: expenses, start: range.start, end: range.end),
            .mileage: NativeCSVExport.buildTripsCsv(trips: trips, start: range.start, end: range.end),
        ]
    }

    /// The three rows in RN's order, with the live row count and the filename
    /// (`csvFilename(dataset, range, choice)`).
    static func rows(
        _ csvs: [NativeExportDataset: String],
        range: NativeDateRange,
        rangeID: String
    ) -> [NativeExportRow] {
        NativeExportDataset.allCases.map { dataset in
            let csv = csvs[dataset] ?? ""
            return NativeExportRow(
                dataset: dataset,
                label: dataset.label,
                hint: dataset.hint,
                rowCount: NativeCSVExport.csvRowCount(csv),
                filename: NativeCSVExport.csvFilename(dataset: dataset.rawValue, range: range, rangeID: rangeID)
            )
        }
    }
}

/// The share tail: write the exact payload where a share sheet can pick it up.
enum NativeExportShare {
    /// Writes `data` to `<directory>/<filename>`, replacing an earlier export of
    /// the same name, and returns the file URL to hand to the activity sheet.
    @discardableResult
    static func write(
        _ data: Data,
        filename: String,
        directory: URL = FileManager.default.temporaryDirectory,
        fileManager: FileManager = .default
    ) throws -> URL {
        let url = directory.appendingPathComponent(filename, isDirectory: false)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: url, options: [.atomic])
        return url
    }
}

// MARK: - Import lifecycle

enum NativeImportStage: Equatable {
    case idle
    case mapping
    case preview
    case report
}

/// The date-format selector's choices ("Auto" + the three explicit formats).
enum NativeImportDateFormatChoice: String, CaseIterable, Identifiable {
    case auto, mdy, dmy, ymd

    var id: String { rawValue }

    var label: String {
        switch self {
        case .auto: "Auto"
        case .mdy: "M-D-Y"
        case .dmy: "D-M-Y"
        case .ymd: "Y-M-D"
        }
    }

    /// The engine format for an explicit choice; nil means "detect it".
    var format: NativeDateFormat? {
        switch self {
        case .auto: nil
        case .mdy: .mdy
        case .dmy: .dmy
        case .ymd: .ymd
        }
    }
}

enum NativeImportCopy {
    static let title = "Import data"
    static let subtitle = "Bring customers, jobs, invoices, or expenses in from a Jobber, Housecall Pro, QuickBooks, or spreadsheet CSV export."
    static let matchColumnsTitle = "Match columns"
    static let dateFormatLabel = "Date format"
    static let ignoreOptionLabel = "Ignore"
    static let chooseFileTitle = "Choose a CSV file"
    static let previewImportTitle = "Preview import"
    static let previewTitle = "Preview"
    static let importNowTitle = "Import now"
    static let importCompleteTitle = "Import complete"
    static let undoTitle = "Undo this import"
    static let importAnotherTitle = "Import another file"
    static let clearSampleTitle = "Clear sample data first"
    static let historyHeading = "Import history"
    static let emptyHistoryText = "No imports on this device yet."

    static let emptyFileTitle = "Empty file"
    static let emptyFileMessage = "That file has no readable rows."
    static let largeFileTitle = "Large file"
    static let largeFileMessage = "Only the first 5,000 rows were read."
    static let alreadyImportedTitle = "Already imported?"
    static let alreadyImportedMessage = "This exact file looks imported already. Import again?"
    static let alreadyImportedConfirm = "Import again"
    static let readFailedTitle = "Could not read file"
    static let readFailedMessage = "Please try a different CSV export."
    static let mapRequiredTitle = "Map required columns"
    static let importFailedTitle = "Import failed"
    static let importFailedMessage = "Nothing was changed. Please try again."
    static let undoFailedTitle = "Undo failed"
    static let undoFailedMessage = "Please try again."
    static let undoTargetMissingMessage = "That import can no longer be undone. Nothing was changed."

    /// RN renders at most this many problem rows, then summarizes the rest.
    static let reportRowCap = 50

    static func entityLabel(_ entity: NativeImportEntity) -> String {
        switch entity {
        case .customers: "Customers"
        case .jobs: "Jobs"
        case .invoices: "Invoices"
        case .expenses: "Expenses"
        }
    }

    /// Required field keys for an entity, in field-definition order.
    static func requiredFields(_ entity: NativeImportEntity) -> [String] {
        (NativeImportMapping.fieldDefs[entity] ?? []).filter(\.required).map(\.key)
    }

    /// The keys that still need a column. Empty means the mapping is complete.
    static func missingRequiredFields(_ entity: NativeImportEntity, mapping: [String?]) -> [String] {
        requiredFields(entity).filter { !mapping.contains($0) }
    }

    static func mapRequiredMessage(_ missing: [String]) -> String {
        "Still need: \(missing.joined(separator: ", "))"
    }

    /// The date-bearing field keys for an entity — what decides whether the date
    /// format selector is shown.
    static func dateFieldKeys(_ entity: NativeImportEntity) -> [String] {
        switch entity {
        case .customers: []
        case .jobs: ["scheduledDate"]
        case .invoices: ["due", "paidAt"]
        case .expenses: ["date"]
        }
    }

    static func mappedDateColumnIndex(_ entity: NativeImportEntity, mapping: [String?]) -> Int? {
        let keys = Set(dateFieldKeys(entity))
        guard let index = mapping.firstIndex(where: { key in
            guard let key else { return false }
            return keys.contains(key)
        }) else { return nil }
        return index
    }

    /// The samples the auto date detector reads (empty when no date column is
    /// mapped, so "Auto" then resolves to nothing and the import falls back to
    /// the engine's own default).
    static func dateSamples(_ entity: NativeImportEntity, mapping: [String?], rows: [[String]]) -> [String] {
        guard let index = mappedDateColumnIndex(entity, mapping: mapping) else { return [] }
        return rows.compactMap { index < $0.count ? $0[index] : nil }
    }

    static func previewLine(_ row: [String]) -> String { row.joined(separator: " · ") }

    static func readyText(rowCount: Int) -> String { "\(rowCount) row(s) ready to import." }

    /// The per-entity report line, exactly as RN words it.
    static func summaryLine(_ entity: NativeImportEntity, counts: NativeImportCounts) -> String {
        switch entity {
        case .customers:
            "\(counts.created) new · \(counts.matched) matched existing · \(counts.skip) skipped"
        case .jobs:
            "\(counts.ok) imported · \(counts.flag) flagged (unrecognized status) · \(counts.skip) skipped"
        case .invoices:
            "\(counts.ok) imported · \(counts.flag) flagged (paid claim, no paid date) · \(counts.skip) skipped"
        case .expenses:
            "\(counts.ok) imported · \(counts.flag) flagged (unrecognized category) · \(counts.skip) skipped"
        }
    }

    static func outcomeText(_ outcome: NativeRowOutcome) -> String {
        let fallback = outcome.status == "flag" ? "Flagged" : "Skipped"
        return "Row \(outcome.rowIndex + 1): \(outcome.reason ?? fallback)"
    }

    /// Problem rows (skips and flags) for the report, capped with an overflow
    /// count.
    static func problemRows(_ outcomes: [NativeRowOutcome]) -> (rows: [NativeRowOutcome], extra: Int) {
        let problems = outcomes.filter { $0.status != "ok" }
        return (Array(problems.prefix(reportRowCap)), max(0, problems.count - reportRowCap))
    }

    static func undoAlert(_ entity: NativeImportEntity) -> (title: String, message: String) {
        ("Import undone", "The imported \(entityLabel(entity).lowercased()) were removed.")
    }

    /// Device-local history rows, newest first (the store returns them in that
    /// order): date, entity, and the same counts line the report uses.
    static func historyText(_ record: NativeImportBatchRecord) -> String {
        let entity = NativeImportEntity(rawValue: record.entity)
        let label = entity.map(entityLabel) ?? record.entity
        let counts = NativeImportCounts(record.counts)
        let detail = entity.map { "\(summaryLine($0, counts: counts))" } ?? "\(counts.ok) imported · \(counts.skip) skipped"
        return "\(record.date) · \(label) · \(detail)"
    }
}

extension NativeImportCounts {
    /// Mirror of the Codable history form.
    init(_ codable: NativeImportCountsCodable) {
        self.init(ok: codable.ok, skip: codable.skip, flag: codable.flag, created: codable.created, matched: codable.matched)
    }
}

import Foundation

// MARK: - Import column mapping + date handling (task 9.07, requirement I1)
//
// Pure port of `utils/importMapping.ts`: deterministic header-vocabulary mapping
// (Jobber / Housecall Pro / QuickBooks + generic synonyms), date-format
// detection, and local-frame date parsing that never uses toISOString.

enum NativeImportEntity: String, CaseIterable {
    case customers, jobs, invoices, expenses
}

struct NativeImportFieldDef: Equatable {
    var key: String
    var label: String
    var required: Bool
}

enum NativeDateFormat: String, Equatable {
    case mdy = "MDY"
    case dmy = "DMY"
    case ymd = "YMD"
}

enum NativeImportMapping {
    static let fieldDefs: [NativeImportEntity: [NativeImportFieldDef]] = [
        .customers: [
            .init(key: "name", label: "Name", required: true),
            .init(key: "email", label: "Email", required: false),
            .init(key: "phone", label: "Phone", required: false),
            .init(key: "address", label: "Address", required: false),
            .init(key: "notes", label: "Notes", required: false),
        ],
        .jobs: [
            .init(key: "title", label: "Job title", required: true),
            .init(key: "customerName", label: "Customer name", required: true),
            .init(key: "status", label: "Status", required: false),
            .init(key: "scheduledDate", label: "Scheduled date", required: false),
            .init(key: "address", label: "Address", required: false),
            .init(key: "description", label: "Description", required: false),
            .init(key: "estimateTotal", label: "Estimate total", required: false),
            .init(key: "notes", label: "Notes", required: false),
        ],
        .invoices: [
            .init(key: "customer", label: "Customer name", required: true),
            .init(key: "amount", label: "Amount", required: true),
            .init(key: "number", label: "Invoice number", required: false),
            .init(key: "due", label: "Due date", required: false),
            .init(key: "paidAt", label: "Paid date", required: false),
            .init(key: "desc", label: "Description", required: false),
            .init(key: "email", label: "Email", required: false),
            .init(key: "phone", label: "Phone", required: false),
        ],
        .expenses: [
            .init(key: "amount", label: "Amount", required: true),
            .init(key: "date", label: "Date", required: true),
            .init(key: "description", label: "Description", required: false),
            .init(key: "category", label: "Category", required: false),
            .init(key: "notes", label: "Notes", required: false),
        ],
    ]

    private static let synonyms: [NativeImportEntity: [String: [String]]] = [
        .customers: [
            "name": ["name", "full name", "customer", "client", "contact", "customer name", "first name", "last name"],
            "email": ["email", "email address", "e-mail"],
            "phone": ["phone", "phone number", "mobile", "cell", "telephone", "mobile phone"],
            "address": ["address", "street address", "billing address", "street", "location"],
            "notes": ["notes", "note", "comments", "description"],
        ],
        .jobs: [
            "title": ["title", "job title", "job name", "service", "job"],
            "customerName": ["customer", "customer name", "client", "client name", "contact"],
            "status": ["status", "stage", "job status"],
            "scheduledDate": ["scheduled date", "date", "start date", "appointment date", "scheduled"],
            "address": ["address", "job address", "service address", "location", "street address"],
            "description": ["description", "details", "scope"],
            "estimateTotal": ["estimate total", "estimate", "quote", "quoted", "total"],
            "notes": ["notes", "note", "comments"],
        ],
        .invoices: [
            "customer": ["customer", "customer name", "client", "client name", "bill to", "contact"],
            "amount": ["amount", "total", "invoice total", "amount due", "balance"],
            "number": ["number", "invoice #", "invoice number", "invoice no", "inv #", "doc number"],
            "due": ["due", "due date", "date due"],
            "paidAt": ["paid on", "paid date", "date paid", "payment date"],
            "desc": ["description", "memo", "details", "line item", "notes"],
            "email": ["email", "email address"],
            "phone": ["phone", "mobile", "cell", "telephone"],
        ],
        .expenses: [
            "amount": ["amount", "total", "cost", "price", "debit"],
            "date": ["date", "transaction date", "posted date", "purchase date"],
            "description": ["description", "memo", "payee", "vendor", "merchant", "details"],
            "category": ["category", "type", "account", "expense category"],
            "notes": ["notes", "note", "comments"],
        ],
    ]

    static func normHeader(_ header: String) -> String {
        header.trimmingCharacters(in: .whitespaces).lowercased()
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: " +", with: " ", options: .regularExpression)
    }

    /// Field key per column, or nil. Longest-phrase-first so multi-word synonyms
    /// beat single words.
    static func detectMapping(entity: NativeImportEntity, headers: [String]) -> [String?] {
        guard let table = synonyms[entity] else { return headers.map { _ in nil } }
        var entries: [(phrase: String, key: String)] = []
        for (key, phrases) in table {
            for phrase in phrases { entries.append((phrase, key)) }
        }
        entries.sort { $0.phrase.count > $1.phrase.count }

        return headers.map { header in
            let normalized = normHeader(header)
            if let exact = entries.first(where: { $0.phrase == normalized }) { return exact.key }
            if let partial = entries.first(where: { normalized.contains($0.phrase) }) { return partial.key }
            return nil
        }
    }

    private static let isoPattern = try! NSRegularExpression(pattern: "^(\\d{4})-(\\d{1,2})-(\\d{1,2})$")
    private static let numericPattern = try! NSRegularExpression(pattern: "^(\\d{1,4})[/\\-.](\\d{1,2})[/\\-.](\\d{1,4})$")

    private static func groups(_ regex: NSRegularExpression, _ value: String) -> [String]? {
        guard let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) else { return nil }
        return (1..<match.numberOfRanges).map { index in
            guard let range = Range(match.range(at: index), in: value) else { return "" }
            return String(value[range])
        }
    }

    static func detectDateFormat(samples: [String]) -> NativeDateFormat? {
        var sawNumeric = false
        var firstSlotOver12 = false
        var secondSlotOver12 = false
        for raw in samples {
            let value = raw.trimmingCharacters(in: .whitespaces)
            if value.isEmpty { continue }
            if groups(isoPattern, value) != nil { return .ymd }
            guard let parts = groups(numericPattern, value), parts.count == 3 else { continue }
            sawNumeric = true
            let first = Int(parts[0]) ?? 0
            let second = Int(parts[1]) ?? 0
            if parts[0].count == 4 { return .ymd }
            if first > 12 { firstSlotOver12 = true }
            if second > 12 { secondSlotOver12 = true }
        }
        if !sawNumeric { return nil }
        if firstSlotOver12 && !secondSlotOver12 { return .dmy }
        return .mdy // US default when ambiguous
    }

    /// Local-frame parse to `YYYY-MM-DD`, or nil. Never uses `toISOString`.
    static func parseImportDate(_ raw: String, format: NativeDateFormat?) -> String? {
        let value = raw.trimmingCharacters(in: .whitespaces)
        if value.isEmpty { return nil }

        var year = 0
        var month = 0
        var day = 0
        if let parts = groups(isoPattern, value), parts.count == 3 {
            year = Int(parts[0]) ?? 0
            month = Int(parts[1]) ?? 0
            day = Int(parts[2]) ?? 0
        } else {
            guard let parts = groups(numericPattern, value), parts.count == 3 else { return nil }
            let p1 = Int(parts[0]) ?? 0
            let p2 = Int(parts[1]) ?? 0
            let p3 = Int(parts[2]) ?? 0
            let resolved = format ?? .mdy
            if resolved == .ymd || parts[0].count == 4 {
                year = p1; month = p2; day = p3
            } else if resolved == .dmy {
                day = p1; month = p2; year = p3
            } else {
                month = p1; day = p2; year = p3
            }
            if year < 100 { year += 2000 }
        }

        guard month >= 1, month <= 12, day >= 1, day <= 31 else { return nil }
        let date = NativeCashBasis.localDate(year: year, month: month - 1, day: day)
        let components = NativeCashBasis.localComponents(date)
        guard components.year == year, components.month == month - 1, components.day == day else { return nil }
        return NativeCashBasis.ymd(date)
    }

    /// `toDateString` for a Date (local `YYYY-MM-DD`).
    static func toDateString(_ date: Date) -> String { NativeCashBasis.ymd(date) }
}

import Foundation

// MARK: - Phase 33: customer tags, the marketing opt-out and the list filter
//
// Spec `docs/superpowers/specs/2026-10-03-campaigns-tags-design.md` §3 and §4.
// Pure rules over `Canonical.Customer`: Foundation and the canonical models
// only, so every runner that compiles a capture point (the editor save plan,
// merge, CSV import) can include this file on its own.

/// Free-form customer labels: at most 10 per customer, 24 characters each,
/// matched case- and diacritic-insensitively (D3). The vocabulary is derived
/// from the customers themselves; there is no settings list.
enum NativeCustomerTags {
    static let maxPerCustomer = 10
    static let maxLength = 24

    /// One vocabulary row: the display spelling, the matching key and how
    /// many customers carry it.
    struct Entry: Equatable, Hashable {
        let display: String
        let key: String
        let count: Int
    }

    /// One label, spec §3.1: control characters stripped, commas and
    /// semicolons (the editor and CSV separators) turned into spaces,
    /// whitespace collapsed and trimmed, leading `#` dropped, cut to 24
    /// characters on a grapheme boundary. Empty is `nil`.
    static func normalize(_ raw: String?) -> String? {
        guard let raw else { return nil }
        var scalars = String.UnicodeScalarView()
        for scalar in raw.unicodeScalars {
            if scalar == "," || scalar == ";" {
                scalars.append(" ")
            } else if scalar.properties.generalCategory == .control {
                // Tabs and newlines are separators; every other C0/C1
                // control is dropped. Format characters (a ZWJ inside an
                // emoji) are kept.
                if CharacterSet.whitespacesAndNewlines.contains(scalar) { scalars.append(" ") }
            } else {
                scalars.append(scalar)
            }
        }
        var cleaned = collapse(String(scalars))
        while cleaned.hasPrefix("#") {
            cleaned = collapse(String(cleaned.dropFirst()))
        }
        // `String.prefix` counts Characters, so the cut never splits a
        // grapheme (an emoji with modifiers stays whole).
        let capped = String(cleaned.prefix(maxLength)).trimmingCharacters(in: .whitespacesAndNewlines)
        return capped.isEmpty ? nil : capped
    }

    /// The matching key: the normalized label folded for case and
    /// diacritics, so "Spring AC", "spring ac" and "Spríng AC" are one tag.
    /// Empty for a label that normalizes to nothing.
    static func key(_ label: String) -> String {
        guard let normalized = normalize(label) else { return "" }
        return normalized
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
    }

    /// The stored form, spec §3.1: each label normalized, de-duplicated by key
    /// (the first spelling wins), the first 10 kept, sorted by key so the wire
    /// order is stable. An empty result is `nil`, so the key is absent.
    static func normalizeList(_ raw: [String]?) -> [String]? {
        guard let raw else { return nil }
        var seen = Set<String>()
        var kept: [(key: String, label: String)] = []
        for value in raw {
            guard kept.count < maxPerCustomer, let label = normalize(value) else { continue }
            let tagKey = key(label)
            guard !tagKey.isEmpty, seen.insert(tagKey).inserted else { continue }
            kept.append((tagKey, label))
        }
        guard !kept.isEmpty else { return nil }
        return kept.sorted { $0.key < $1.key }.map(\.label)
    }

    /// Splits one typed or imported cell on `,`, `;` or `|` and normalizes
    /// the pieces (not capped: `normalizeList` caps the stored form).
    static func split(_ raw: String) -> [String] {
        raw.components(separatedBy: CharacterSet(charactersIn: ",;|")).compactMap(normalize)
    }

    /// Spec §3.1: the tags in use across `customers`. Each key's display
    /// spelling is the one on the most customers (ties alphabetical); rows
    /// are sorted by count descending, then display.
    static func vocabulary(_ customers: [Canonical.Customer]) -> [Entry] {
        var counts: [String: Int] = [:]
        var spellings: [String: [String: Int]] = [:]
        for customer in customers {
            for label in normalizeList(customer.tags) ?? [] {
                let tagKey = key(label)
                counts[tagKey, default: 0] += 1
                spellings[tagKey, default: [:]][label, default: 0] += 1
            }
        }
        let entries: [Entry] = counts.map { tagKey, count in
            let byUse = spellings[tagKey] ?? [:]
            let display = byUse.sorted {
                $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key
            }.first?.key ?? tagKey
            return Entry(display: display, key: tagKey, count: count)
        }
        return entries.sorted {
            if $0.count != $1.count { return $0.count > $1.count }
            let order = $0.display.localizedCaseInsensitiveCompare($1.display)
            if order != .orderedSame { return order == .orderedAscending }
            return $0.key < $1.key
        }
    }

    /// Spec §3.2: a typed tag whose key matches the vocabulary snaps to the
    /// existing spelling, so spellings converge. `nil` when it normalizes to
    /// nothing.
    static func snapped(_ raw: String, vocabulary: [Entry]) -> String? {
        guard let label = normalize(raw) else { return nil }
        let tagKey = key(label)
        return vocabulary.first { $0.key == tagKey }?.display ?? label
    }

    /// Spec §3.2: suggestions under the add field: the vocabulary filtered by
    /// key prefix, without tags already on the customer, top `limit` by count.
    static func suggestions(prefix: String, vocabulary: [Entry], excluding current: [String], limit: Int = 8) -> [Entry] {
        let typed = key(prefix)
        let taken = Set(current.map(key))
        return Array(vocabulary.filter {
            !taken.contains($0.key) && (typed.isEmpty || $0.key.hasPrefix(typed))
        }.prefix(limit))
    }

    /// Spec §4.4: the winner's tags first, then the loser's in key order until
    /// 10; stored sorted by key.
    static func merged(winner: [String]?, loser: [String]?) -> [String]? {
        var combined = normalizeList(winner) ?? []
        var keys = Set(combined.map(key))
        for label in normalizeList(loser) ?? [] where combined.count < maxPerCustomer {
            if keys.insert(key(label)).inserted { combined.append(label) }
        }
        return normalizeList(combined)
    }

    /// Spec §3.3: "AC · VIP · Gate code +2" (up to `limit` tags), or `nil`.
    static func caption(_ tags: [String]?, limit: Int = 3) -> String? {
        let labels = normalizeList(tags) ?? []
        guard !labels.isEmpty else { return nil }
        let shown = labels.prefix(limit).joined(separator: " · ")
        return labels.count > limit ? "\(shown) +\(labels.count - limit)" : shown
    }

    private static func collapse(_ value: String) -> String {
        value.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
    }
}

/// "Do not contact for marketing" (spec §4, D4). A customer is opted out
/// exactly when `marketingOptOutOn` is non-blank (O1). It blocks campaigns
/// and the `maintenance_due` insight; it never blocks invoices, reminders,
/// estimates, appointment messages or review requests.
enum NativeMarketingOptOut {
    enum Via: String, CaseIterable, Equatable {
        case asked
        case textStop = "text_stop"
        case emailReply = "email_reply"
        case imported

        /// The reason picker's choices (an import is never picked by hand).
        static let pickable: [Via] = [.asked, .textStop, .emailReply]

        var displayName: String {
            switch self {
            case .asked: "Asked me"
            case .textStop: "Replied STOP to a text"
            case .emailReply: "Replied to an email"
            case .imported: "Imported"
            }
        }
    }

    /// Lowercased CSV values that set the opt-out on import (spec §3.4).
    static let truthyImportValues: Set<String> = [
        "yes", "y", "true", "1", "x", "unsubscribed", "opted out",
    ]

    static func importValueOptsOut(_ raw: String) -> Bool {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            .components(separatedBy: .whitespaces).filter { !$0.isEmpty }.joined(separator: " ")
        return truthyImportValues.contains(value)
    }

    /// The opt-out day an imported cell sets, or `nil`: a truthy value opts
    /// out on `importDay`; a local `YYYY-MM-DD` (what the accountant package's
    /// `Marketing opt-out` column holds) opts out on that day, so an exported
    /// list round-trips.
    static func importOptOutDay(_ raw: String, importDay: String) -> String? {
        if importValueOptsOut(raw) { return importDay }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = value.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              parts.allSatisfy({ $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }),
              let month = Int(parts[1]), let day = Int(parts[2]), (1...12).contains(month), (1...31).contains(day)
        else { return nil }
        return value
    }

    /// The customer opted out on `day` (local `YYYY-MM-DD`) for `via`. An
    /// existing opt-out is kept as it is (the first date is the record).
    static func optedOut(_ customer: Canonical.Customer, on day: String, via: Via) -> Canonical.Customer {
        guard !customer.isMarketingOptedOut else { return customer }
        var updated = customer
        updated.marketingOptOutOn = day
        updated.marketingOptOutVia = via.rawValue
        return updated
    }

    /// The owner confirmed the customer asked to hear from them again.
    static func cleared(_ customer: Canonical.Customer) -> Canonical.Customer {
        var updated = customer
        updated.marketingOptOutOn = nil
        updated.marketingOptOutVia = nil
        return updated
    }

    /// Spec §4.4 (sticky): if either record is opted out the result is, with
    /// the earlier date and that record's `via`. Equal dates keep the
    /// winner's. Merge never clears an opt-out.
    static func merged(
        winner: (on: String?, via: String?),
        loser: (on: String?, via: String?)
    ) -> (on: String?, via: String?) {
        let winnerOn = blankToNil(winner.on)
        let loserOn = blankToNil(loser.on)
        switch (winnerOn, loserOn) {
        case (nil, nil): return (winner.on, winner.via)
        case (_?, nil): return (winner.on, winner.via)
        case (nil, _?): return (loser.on, loser.via)
        case let (w?, l?): return l < w ? (loser.on, loser.via) : (winner.on, winner.via)
        }
    }

    /// "Asked me · Mar 4, 2026"-style detail line, or `nil` when not opted out.
    static func detail(_ customer: Canonical.Customer) -> String? {
        guard customer.isMarketingOptedOut, let on = customer.marketingOptOutOn else { return nil }
        let reason = customer.marketingOptOutVia.flatMap(Via.init(rawValue:))?.displayName
        return [reason, "since \(on)"].compactMap { $0 }.joined(separator: " · ")
    }

    private static func blankToNil(_ value: String?) -> String? {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return value
    }
}

/// Anything the Customers list can filter: the list's entries conform in the
/// view layer, and the tests use a plain struct.
protocol NativeCustomerListFilterable {
    var id: String { get }
    var phone: String { get }
    var email: String { get }
}

/// The Customers list "Filter" menu (spec §3.3). Per session, never
/// persisted. Kinds combine with AND; tags match any of the selected keys.
struct NativeCustomerListFilter: Equatable {
    var tagKeys: Set<String> = []
    var optedOut = false
    var noContact = false

    var isActive: Bool { !tagKeys.isEmpty || optedOut || noContact }

    /// Filters `entries` (search and "Show archived" are applied by the
    /// caller). An entry with no stored customer (invoice-derived) never
    /// matches a tag or opt-out filter.
    static func apply<Entry: NativeCustomerListFilterable>(
        _ entries: [Entry],
        customers: [Canonical.Customer],
        filter: NativeCustomerListFilter
    ) -> [Entry] {
        guard filter.isActive else { return entries }
        let stored = Dictionary(customers.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return entries.filter { entry in
            let customer = stored[entry.id]
            if !filter.tagKeys.isEmpty {
                guard let customer else { return false }
                let keys = Set((NativeCustomerTags.normalizeList(customer.tags) ?? []).map(NativeCustomerTags.key))
                guard !keys.isDisjoint(with: filter.tagKeys) else { return false }
            }
            if filter.optedOut {
                guard let customer, customer.isMarketingOptedOut else { return false }
            }
            if filter.noContact {
                let hasPhone = entry.phone.contains { $0.isNumber }
                let hasEmail = !entry.email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                guard !hasPhone, !hasEmail else { return false }
            }
            return true
        }
    }
}

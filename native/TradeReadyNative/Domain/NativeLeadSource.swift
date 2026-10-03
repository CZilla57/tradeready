import Foundation

/// Phase 27 (lead source tracking, spec 2026-10-02-lead-source-design.md §2):
/// how a customer first found the business, stored on `Customer.leadSource`
/// as a stable preset key (`referral`, `google`, …) or a custom label.
///
/// Foundation-only and string-in/string-out, so every runner that compiles a
/// capture point (booking intake, CSV import, export, reports) can include it
/// without pulling in the canonical models.
enum NativeLeadSource {
    struct Preset: Equatable {
        /// Stored on the wire; never renamed.
        let key: String
        let displayName: String
        /// Lowercased spellings that normalize to `key` (besides the key and
        /// the display name themselves).
        let aliases: [String]
    }

    /// Presets in picker order.
    static let presets: [Preset] = [
        .init(key: "referral", displayName: "Referral / word of mouth",
              aliases: ["referrals", "referred", "word of mouth", "friend", "friends", "friend or family", "family"]),
        .init(key: "google", displayName: "Google",
              aliases: ["google ads", "google search", "google maps", "gbp", "google business profile",
                        "google business", "google my business", "local services ads", "google lsa"]),
        .init(key: "facebook", displayName: "Facebook",
              aliases: ["fb", "facebook ads", "facebook group", "facebook marketplace"]),
        .init(key: "nextdoor", displayName: "Nextdoor", aliases: ["next door"]),
        .init(key: "yelp", displayName: "Yelp", aliases: []),
        .init(key: "thumbtack_angi", displayName: "Thumbtack / Angi",
              aliases: ["thumbtack", "angi", "angie's list", "angies list", "angie’s list", "homeadvisor", "home advisor"]),
        .init(key: "signage", displayName: "Truck or yard sign",
              aliases: ["truck", "truck sign", "yard sign", "vehicle wrap", "truck wrap", "sign"]),
        .init(key: "website", displayName: "Website", aliases: ["web site", "web", "my website", "our website"]),
        .init(key: "booking_link", displayName: "Online booking link",
              aliases: ["booking link", "online booking", "book online"]),
        .init(key: "mailer", displayName: "Flyer or mailer",
              aliases: ["flyer", "flier", "flyers", "door hanger", "postcard", "direct mail"]),
    ]

    static let bookingLinkKey = "booking_link"
    static let unknownBucketKey = "unknown"
    static let unknownDisplayName = "Unknown"
    static let customLabelMaxLength = 40
    private static let customBucketPrefix = "custom:"

    /// Lowercased values that mean "no source" (spec §2: Unknown is the
    /// absence of a source, never a stored label).
    static let placeholderValues: Set<String> = [
        "unknown", "not set", "none", "n/a", "na", "-", "--", "—", "?",
    ]

    static func preset(key: String) -> Preset? {
        presets.first { $0.key == key }
    }

    /// Spec §2: trims and collapses whitespace and strips control characters;
    /// empty is `nil`. A preset key, display name or alias (any case) becomes
    /// the preset key; anything else is a custom label capped at 40
    /// characters.
    static func normalize(_ raw: String?) -> String? {
        guard let raw else { return nil }
        // Only C0/C1 controls (category Cc), never format characters such as
        // the zero-width joiner inside an emoji; tabs and newlines become
        // spaces below.
        let visible = String(String.UnicodeScalarView(raw.unicodeScalars.filter {
            $0.properties.generalCategory != .control || CharacterSet.whitespacesAndNewlines.contains($0)
        }))
        let cleaned = visible
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !cleaned.isEmpty else { return nil }
        let lowered = cleaned.lowercased()
        // A placeholder ("Unknown", "N/A", "-") from a CSV or a typed label
        // means no source, so it never becomes a second "Unknown" row.
        guard !placeholderValues.contains(lowered) else { return nil }
        if let match = presets.first(where: {
            $0.key == lowered || $0.displayName.lowercased() == lowered || $0.aliases.contains(lowered)
        }) {
            return match.key
        }
        let capped = String(cleaned.prefix(customLabelMaxLength))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return capped.isEmpty ? nil : capped
    }

    /// The report bucket: the preset key, `custom:<lowercased label>` (so
    /// "Home show" and "home show" share a row), or `unknown`.
    static func bucketKey(_ stored: String?) -> String {
        guard let value = normalize(stored) else { return unknownBucketKey }
        if preset(key: value) != nil { return value }
        return customBucketPrefix + value.lowercased()
    }

    /// The preset's display name, a custom label verbatim, or "Unknown".
    static func displayName(_ stored: String?) -> String {
        guard let value = normalize(stored) else { return unknownDisplayName }
        return preset(key: value)?.displayName ?? value
    }

    /// Spec §7, the accountant-package `Lead source` column: the display name
    /// (custom labels verbatim), or empty when unknown, so the value survives
    /// export → re-import through `normalize`.
    static func exportLabel(_ stored: String?) -> String {
        normalize(stored) == nil ? "" : displayName(stored)
    }

    static func isCustom(_ stored: String?) -> Bool {
        guard let value = normalize(stored) else { return false }
        return preset(key: value) == nil
    }

    /// Spec §3 (D2): the custom labels already in use, offered again in the
    /// picker. One spelling per bucket (the first seen), sorted
    /// case-insensitively.
    static func customLabels(in stored: [String?]) -> [String] {
        var seen = Set<String>()
        var labels: [String] = []
        for value in stored {
            guard let label = normalize(value), preset(key: label) == nil,
                  seen.insert(label.lowercased()).inserted
            else { continue }
            labels.append(label)
        }
        return labels.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    /// First touch (spec §1): an existing source is kept; a blank one takes
    /// the candidate. Returns the value to store.
    static func firstTouch(existing: String?, candidate: String?) -> String? {
        normalize(existing) == nil ? normalize(candidate) : existing
    }
}

import Foundation

// MARK: - Phase 33: campaign merge fields, rendering and compliance text
//
// Spec `docs/superpowers/specs/2026-10-03-campaigns-tags-design.md` §6.1 and
// §6.3. Deterministic and pure (Foundation only): the owner's template plus
// one recipient's values render to exactly the text the composer opens with,
// including the opt-out line or the email footer, which are appended here and
// are never editable (D9).

enum NativeCampaignMessage {
    static let nameMaxLength = 60
    static let briefMaxLength = 500
    /// Spec §6.1: a longer text "may arrive as several texts" (a warning).
    static let textWarningLength = 320

    /// The two message kinds a campaign can carry.
    enum Kind: String, CaseIterable, Equatable {
        case text
        case email

        var displayName: String { self == .text ? "Text message" : "Email" }
    }

    /// Spec §6.1 merge fields, in "Insert field" menu order.
    enum Field: String, CaseIterable, Equatable {
        case firstName
        case name
        case businessName
        case ownerName
        case businessPhone
        case lastJob
        case lastServiceMonth
        case bookingLink

        var token: String { "{\(rawValue)}" }

        var displayName: String {
            switch self {
            case .firstName: "First name"
            case .name: "Full name"
            case .businessName: "Business name"
            case .ownerName: "Your name"
            case .businessPhone: "Business phone"
            case .lastJob: "Last job"
            case .lastServiceMonth: "Last service month"
            case .bookingLink: "Booking link"
            }
        }
    }

    /// The owner's business, from Settings.
    struct Business: Equatable {
        var businessName: String
        /// `settings.contactName`.
        var ownerName: String
        var phone: String
        /// `settings.address`: required for email (CAN-SPAM postal address).
        var address: String

        var hasAddress: Bool { !address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        var hasBusinessName: Bool { !businessName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    /// One recipient's values.
    struct Recipient: Equatable {
        var name: String
        var lastJobTitle: String?
        /// Local `YYYY-MM-DD`.
        var lastServiceDate: String?
    }

    struct Rendered: Equatable {
        var subject: String?
        /// The full text the customer receives, compliance text included.
        var body: String
        /// Fields that fell back to their default (the preview flags them).
        var fallbacks: [Field]
        /// A rendered text longer than 320 characters.
        var isLongText: Bool
    }

    enum Issue: Equatable, Hashable {
        case unknownToken(String)
        case emptyBody
        case emptySubject
        /// "Re:", "Fw:" or "Fwd:": a deceptive subject.
        case deceptiveSubject
        case missingBusinessName
        case bookingLinkUnavailable
        case emailNeedsAddress
        /// Warning: the line with `{businessPhone}` is dropped.
        case missingBusinessPhone
        /// Warning: may arrive as several texts.
        case longText(Int)

        var isBlocking: Bool {
            switch self {
            case .missingBusinessPhone, .longText: false
            default: true
            }
        }

        var message: String {
            switch self {
            case let .unknownToken(token): "\(token) isn't a field TradeReady can fill in. Remove it or pick one from Insert field."
            case .emptyBody: "Write the message first."
            case .emptySubject: "Add a subject for the email."
            case .deceptiveSubject: "Subjects can't start with Re:, Fw: or Fwd:. That makes a marketing email look like a reply."
            case .missingBusinessName: "Add your business name in Settings → Business profile before sending."
            case .bookingLinkUnavailable: "Your booking link isn't ready. Turn it on in Settings, or remove {bookingLink}."
            case .emailNeedsAddress:
                "Add your business mailing address in Settings → Business profile to email customers. US law (CAN-SPAM) requires a postal address in marketing emails. A PO box works."
            case .missingBusinessPhone: "Your business phone isn't set, so the line with {businessPhone} is left out."
            case let .longText(count): "This text is \(count) characters, so it may arrive as several texts."
            }
        }
    }

    static let fieldFallbacks: [Field: String] = [
        .firstName: "there",
        .lastJob: "your last service",
        .lastServiceMonth: "a while back",
    ]

    static let textOptOutLine = "Reply STOP to opt out."
    static let disclaimer =
        "TradeReady adds an opt-out line and your address to help you follow anti-spam rules. It isn't legal advice."

    // MARK: Tokens

    /// Every `{…}` in the template, in order (known or not).
    static func tokens(in template: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: #"\{[^{}\n]{1,40}\}"#) else { return [] }
        let range = NSRange(template.startIndex..., in: template)
        return regex.matches(in: template, range: range).compactMap {
            Range($0.range, in: template).map { String(template[$0]) }
        }
    }

    static func field(token: String) -> Field? {
        guard token.hasPrefix("{"), token.hasSuffix("}") else { return nil }
        return Field(rawValue: String(token.dropFirst().dropLast()))
    }

    static func uses(_ field: Field, in template: String?) -> Bool {
        (template ?? "").contains(field.token)
    }

    // MARK: Validation (spec §6.1)

    /// The template's own problems, before any recipient: unknown tokens,
    /// an empty body, a deceptive or empty subject (email), and the length
    /// warning (text, measured with the opt-out line).
    static func validate(kind: Kind, body: String?, subject: String? = nil) -> [Issue] {
        var issues: [Issue] = []
        let text = body ?? ""
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { issues.append(.emptyBody) }
        var seen = Set<String>()
        for token in tokens(in: text) + tokens(in: subject ?? "") where field(token: token) == nil {
            if seen.insert(token).inserted { issues.append(.unknownToken(token)) }
        }
        if kind == .email {
            let trimmed = (subject ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { issues.append(.emptySubject) }
            if isDeceptiveSubject(trimmed) { issues.append(.deceptiveSubject) }
        } else {
            let length = text.count + 2 + textOptOutLine.count
            if length > textWarningLength { issues.append(.longText(length)) }
        }
        return issues
    }

    /// Problems that depend on Settings and the booking link.
    static func contextIssues(
        kind: Kind,
        body: String?,
        subject: String? = nil,
        business: Business,
        bookingLinkReady: Bool
    ) -> [Issue] {
        var issues: [Issue] = []
        let all = (body ?? "") + "\n" + (subject ?? "")
        if !business.hasBusinessName { issues.append(.missingBusinessName) }
        if uses(.bookingLink, in: all), !bookingLinkReady { issues.append(.bookingLinkUnavailable) }
        if kind == .email, !business.hasAddress { issues.append(.emailNeedsAddress) }
        if uses(.businessPhone, in: all), business.phone.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append(.missingBusinessPhone)
        }
        return issues
    }

    static func isDeceptiveSubject(_ subject: String) -> Bool {
        let lowered = subject.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return ["re:", "fw:", "fwd:"].contains { lowered.hasPrefix($0) }
    }

    // MARK: Rendering (spec §6.1, §6.3)

    /// The exact message one recipient receives. The compliance text is
    /// appended (D9); a line holding `{businessPhone}` is dropped when the
    /// phone is blank; `{bookingLink}` renders as `bookingLink` (empty when
    /// it is unavailable, which `contextIssues` blocks).
    static func render(
        kind: Kind,
        body: String,
        subject: String? = nil,
        recipient: Recipient,
        business: Business,
        bookingLink: URL?
    ) -> Rendered {
        var fallbacks: [Field] = []
        let values = fieldValues(recipient: recipient, business: business, bookingLink: bookingLink, fallbacks: &fallbacks)
        let renderedBody = fill(body, values: values, business: business, fallbacks: &fallbacks)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let full = renderedBody + "\n\n" + complianceText(kind: kind, business: business)
        let renderedSubject = kind == .email
            ? fill(subject ?? "", values: values, business: business, fallbacks: &fallbacks)
                .components(separatedBy: .newlines).joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            : nil
        var unique: [Field] = []
        for field in Field.allCases where fallbacks.contains(field) { unique.append(field) }
        return Rendered(
            subject: renderedSubject,
            body: full,
            fallbacks: unique,
            isLongText: kind == .text && full.count > textWarningLength
        )
    }

    /// Spec §6.3: appended to every message, never editable.
    static func complianceText(kind: Kind, business: Business) -> String {
        switch kind {
        case .text:
            return textOptOutLine
        case .email:
            let name = business.businessName.trimmingCharacters(in: .whitespacesAndNewlines)
            let address = business.address
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .joined(separator: ", ")
            return [
                "—",
                "\(name) · \(address)",
                "You're getting this because you're a past customer of \(name).",
                "Reply \"unsubscribe\" and we won't email you about offers again.",
            ].joined(separator: "\n")
        }
    }

    /// Spec §6.1 `{firstName}`: the first word of the name when it is mostly
    /// letters and the name has no business suffix; otherwise "there".
    static func firstName(_ name: String) -> String {
        let words = name.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard let first = words.first else { return fieldFallbacks[.firstName] ?? "there" }
        let suffixes: Set<String> = ["llc", "inc", "co", "corp", "company", "ltd", "corporation", "incorporated"]
        let honorifics: Set<String> = ["mr", "mrs", "ms", "miss", "dr", "mx"]
        let bare = words.map { $0.lowercased().trimmingCharacters(in: .punctuationCharacters) }
        if bare.contains(where: suffixes.contains) { return "there" }
        let cleaned = first.trimmingCharacters(in: CharacterSet(charactersIn: ",.;:"))
        if honorifics.contains(cleaned.lowercased()) { return "there" }
        let letters = cleaned.filter(\.isLetter).count
        let allowed = cleaned.filter { $0.isLetter || $0 == "'" || $0 == "’" || $0 == "-" }.count
        guard letters >= 2, allowed == cleaned.count, Double(letters) / Double(max(cleaned.count, 1)) >= 0.8
        else { return "there" }
        return cleaned
    }

    /// "March 2026" from a local `YYYY-MM-DD`; `nil` when malformed.
    static func monthYear(_ date: String?) -> String? {
        guard let date else { return nil }
        let parts = date.prefix(10).split(separator: "-")
        guard parts.count == 3, let year = Int(parts[0]), let month = Int(parts[1]), (1...12).contains(month)
        else { return nil }
        return "\(monthNames[month - 1]) \(year)"
    }

    /// The `{bookingLink}` URL: the verified booking URL plus `c=<code>`.
    /// `isValidBookingURL` checks only `b`, so it still accepts it.
    static func campaignLink(base: URL, code: String) -> URL? {
        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return nil }
        var items = (components.queryItems ?? []).filter { $0.name != "c" }
        items.append(URLQueryItem(name: "c", value: code))
        components.queryItems = items
        return components.url
    }

    /// Spec §7.4: the `sms:` URL for the URL-scheme fallback (one recipient,
    /// percent-encoded body).
    static func smsURL(phone: String, body: String) -> URL? {
        let digits = phone.filter { $0.isNumber || $0 == "+" }
        guard !digits.isEmpty else { return nil }
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+?#")
        guard let encoded = body.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        return URL(string: "sms:\(digits)&body=\(encoded)")
    }

    /// Spec §7.4: the `mailto:` URL (one recipient, subject and body).
    static func mailtoURL(email: String, subject: String, body: String) -> URL? {
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = email.trimmingCharacters(in: .whitespacesAndNewlines)
        components.queryItems = [URLQueryItem(name: "subject", value: subject), URLQueryItem(name: "body", value: body)]
        return components.url
    }

    // MARK: Private

    private static let monthNames = [
        "January", "February", "March", "April", "May", "June",
        "July", "August", "September", "October", "November", "December",
    ]

    private static func fieldValues(
        recipient: Recipient,
        business: Business,
        bookingLink: URL?,
        fallbacks: inout [Field]
    ) -> [Field: String] {
        let businessName = business.businessName.trimmingCharacters(in: .whitespacesAndNewlines)
        let owner = business.ownerName.trimmingCharacters(in: .whitespacesAndNewlines)
        var values: [Field: String] = [
            .name: recipient.name.trimmingCharacters(in: .whitespacesAndNewlines),
            .businessName: businessName,
            .businessPhone: business.phone.trimmingCharacters(in: .whitespacesAndNewlines),
            .bookingLink: bookingLink?.absoluteString ?? "",
        ]
        let first = firstName(recipient.name)
        values[.firstName] = first
        if first == fieldFallbacks[.firstName] { fallbacks.append(.firstName) }
        if owner.isEmpty { values[.ownerName] = businessName; fallbacks.append(.ownerName) } else { values[.ownerName] = owner }
        if let title = recipient.lastJobTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            values[.lastJob] = title
        } else {
            values[.lastJob] = fieldFallbacks[.lastJob]
            fallbacks.append(.lastJob)
        }
        if let month = monthYear(recipient.lastServiceDate) {
            values[.lastServiceMonth] = month
        } else {
            values[.lastServiceMonth] = fieldFallbacks[.lastServiceMonth]
            fallbacks.append(.lastServiceMonth)
        }
        return values
    }

    private static func fill(
        _ template: String,
        values: [Field: String],
        business: Business,
        fallbacks: inout [Field]
    ) -> String {
        let phoneMissing = (values[.businessPhone] ?? "").isEmpty
        var lines: [String] = []
        for line in template.components(separatedBy: "\n") {
            if phoneMissing, line.contains(Field.businessPhone.token) {
                fallbacks.append(.businessPhone)
                continue
            }
            lines.append(replacingFields(in: line, values: values))
        }
        return lines.joined(separator: "\n")
    }

    /// One left-to-right pass, so a value that itself looks like a field
    /// (a customer named "{name}") is never substituted again. Unknown
    /// tokens stay as typed (`validate` blocks them).
    private static func replacingFields(in line: String, values: [Field: String]) -> String {
        var out = ""
        var rest = Substring(line)
        while let open = rest.firstIndex(of: "{") {
            out += rest[..<open]
            let tail = rest[open...]
            if let close = tail.firstIndex(of: "}"),
               let field = Field(rawValue: String(tail[tail.index(after: open)..<close])) {
                out += values[field] ?? ""
                rest = tail[tail.index(after: close)...]
            } else {
                out.append("{")
                rest = tail.dropFirst()
            }
        }
        return out + rest
    }
}

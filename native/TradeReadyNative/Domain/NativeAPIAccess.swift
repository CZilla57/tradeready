import Foundation

/// Roadmap Phase 23 (read-only open API, spec
/// `docs/superpowers/specs/2026-10-03-open-api-design.md` §2, §9 and the
/// settled manage contract §14.1): the pure rules behind Settings › API
/// access.
///
/// Keys are server authority only (§13 D14): nothing here is stored, cached
/// or synced, and the settings blob gains no field. The raw key travels in a
/// `NativeAPIKeySecret`, which never prints, never reflects and is never
/// `Codable`, so a log line, a crash breadcrumb or a `dump` cannot carry it.
///
/// Foundation only: no app-file dependencies, so the host runners compile it
/// next to their own sources.

// MARK: - Flag (spec §11 stage C)

enum NativeAPIAccessFeature {
    /// Stage C: Settings › API access stays fully hidden until the Worker and
    /// its migration are live. The owner turns it on at ship step 5 (§14.8).
    static let apiAccessEnabled = false

    /// Whether Settings shows the "API access" row. Off means no row and no
    /// way to reach the screen.
    static func showsSettingsEntry(flag: Bool = apiAccessEnabled) -> Bool { flag }
}

// MARK: - Scopes, presets, expiry, grace (§2, §14.1)

enum NativeAPIScope: String, CaseIterable, Identifiable, Sendable {
    // Declaration order is the Worker's canonical order (§14.1).
    case customers = "customers:read"
    case jobs = "jobs:read"
    case invoices = "invoices:read"
    case expenses = "expenses:read"
    case mileage = "mileage:read"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .customers: "Customers"
        case .jobs: "Jobs and estimates"
        case .invoices: "Invoices and payments"
        case .expenses: "Expenses"
        case .mileage: "Mileage"
        }
    }

    var detail: String {
        switch self {
        case .customers: "Names, contact details, addresses and lead sources"
        case .jobs: "Job details, schedules, prices and estimate decisions"
        case .invoices: "Invoices, balances and payment records"
        case .expenses: "Amounts, categories and whether a receipt exists"
        case .mileage: "Trips, miles and odometer readings"
        }
    }

    /// The given scopes in canonical order, without duplicates.
    static func canonical<S: Sequence>(_ scopes: S) -> [NativeAPIScope] where S.Element == NativeAPIScope {
        let wanted = Set(scopes)
        return allCases.filter(wanted.contains)
    }

    /// Server scope strings in canonical order. Unknown strings (a later
    /// additive scope) are skipped rather than failing the whole key.
    static func parse(_ raw: [String]) -> [NativeAPIScope] {
        canonical(raw.compactMap(NativeAPIScope.init(rawValue:)))
    }
}

enum NativeAPIScopePreset: String, CaseIterable, Identifiable, Sendable {
    case everything, bookkeeping, custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .everything: "Everything"
        case .bookkeeping: "Bookkeeping"
        case .custom: "Custom"
        }
    }

    /// The preset's fixed scopes; `nil` for custom.
    var scopes: [NativeAPIScope]? {
        switch self {
        case .everything: NativeAPIScope.allCases
        case .bookkeeping: [.customers, .invoices, .expenses, .mileage]
        case .custom: nil
        }
    }

    /// The preset a scope set equals, else custom.
    static func matching(_ scopes: Set<NativeAPIScope>) -> NativeAPIScopePreset {
        for preset in [NativeAPIScopePreset.everything, .bookkeeping] where Set(preset.scopes ?? []) == scopes {
            return preset
        }
        return .custom
    }
}

enum NativeAPIKeyExpiry: String, CaseIterable, Identifiable, Sendable {
    case oneYear = "1y"
    case ninetyDays = "90d"
    case never = "none"

    /// §2: "default 1 year".
    static let defaultChoice = NativeAPIKeyExpiry.oneYear

    var id: String { rawValue }

    var title: String {
        switch self {
        case .oneYear: "In 1 year"
        case .ninetyDays: "In 90 days"
        case .never: "Never"
        }
    }
}

enum NativeAPIKeyGrace: String, CaseIterable, Sendable {
    case twentyFourHours = "24h"
    case immediate

    /// §13 D3: rotate keeps a 24-hour grace by default.
    static let defaultChoice = NativeAPIKeyGrace.twentyFourHours
}

// MARK: - Keys and activity (KeySummary, §14.1)

enum NativeAPIKeyStatus: String, CaseIterable, Sendable {
    case active, expiring, expired, revoked

    /// The Worker's rule (`keyStatus`): revoked → expired → expiring → active.
    static func derive(revokedAt: Date?, expiresAt: Date?, replacedBy: String?, now: Date) -> NativeAPIKeyStatus {
        if revokedAt != nil { return .revoked }
        if let expiresAt, expiresAt <= now { return .expired }
        if replacedBy != nil { return .expiring }
        return .active
    }
}

struct NativeAPIKeySummary: Equatable, Identifiable, Sendable {
    let id: String
    let name: String
    /// Display prefix, e.g. `trk_Ab3dE9fQ`. Never the key.
    let prefix: String
    let scopes: [NativeAPIScope]
    let createdAt: Date?
    let expiresAt: Date?
    let revokedAt: Date?
    let lastUsedAt: Date?
    let replacedBy: String?
    /// The server's status at response time.
    let status: NativeAPIKeyStatus

    /// The status now: a screen left open past `expiresAt` shows the key as
    /// expired without another request. Revoked and expired never revert.
    func status(at now: Date) -> NativeAPIKeyStatus {
        switch status {
        case .revoked, .expired: return status
        case .active, .expiring:
            if let expiresAt, expiresAt <= now { return .expired }
            return status
        }
    }

    /// Active keys rotate (the Worker refuses a revoked, expired or already
    /// rotated key with `not_found`).
    func canRotate(at now: Date) -> Bool { status(at: now) == .active }

    /// Active keys and old keys still in a rotation grace window revoke.
    func canRevoke(at now: Date) -> Bool {
        let current = status(at: now)
        return current == .active || current == .expiring
    }
}

struct NativeAPIKeyList: Equatable, Sendable {
    let keys: [NativeAPIKeySummary]
    let maxLiveKeys: Int
}

enum NativeAPIActivityKind: Equatable, Sendable {
    case ok, denied, rateLimited, error
    case other(String)

    init(raw: String) {
        switch raw {
        case "ok": self = .ok
        case "denied": self = .denied
        case "rate_limited": self = .rateLimited
        case "error": self = .error
        default: self = .other(raw)
        }
    }

    var title: String {
        switch self {
        case .ok: "Allowed"
        case .denied: "Denied"
        case .rateLimited: "Rate limited"
        case .error: "Error"
        case .other: "Other"
        }
    }
}

struct NativeAPIActivityEvent: Equatable, Identifiable, Sendable {
    /// Position in the newest-first response (log rows carry no id).
    let id: Int
    let at: Date?
    let keyId: String
    let kind: NativeAPIActivityKind
    /// A route template such as `/v1/invoices/:id`, never query values.
    let route: String
    let status: Int
    let ip: String?
}

// MARK: - The secret (§2: shown once, never stored)

/// The raw key from a create or rotate response. It exists to be shown once
/// and copied; it is deliberately not `Codable`, and its description, debug
/// description and mirror hide the value, so string interpolation, `dump`,
/// crash breadcrumbs and analytics can never carry it by accident.
struct NativeAPIKeySecret: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    static let keyPrefix = "trk_"
    /// 107 base64url characters over 80 bytes: key id, owner id, 32 random
    /// bytes and a 128-bit server HMAC tag (§2, 2026-10-12). The app checks
    /// the shape only; the tag is the Worker's to verify.
    static let bodyLength = 107

    private let raw: String

    /// `nil` unless `raw` is `trk_` plus 107 base64url characters (§2).
    init?(_ raw: String) {
        guard Self.isWellFormed(raw) else { return nil }
        self.raw = raw
    }

    /// For the show-once sheet's text and its copy button only.
    var revealedValue: String { raw }

    var description: String { "trk_…(hidden)" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: [], displayStyle: .struct) }

    static func isWellFormed(_ value: String) -> Bool {
        guard value.hasPrefix(keyPrefix) else { return false }
        let body = value.utf8.dropFirst(keyPrefix.utf8.count)
        guard body.count == bodyLength else { return false }
        return body.allSatisfy { byte in
            (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A)
                || (byte >= 0x30 && byte <= 0x39) || byte == 0x2D || byte == 0x5F
        }
    }
}

// MARK: - Create request and its validation (§14.1 field rules)

enum NativeAPIKeyDraftIssue: Error, Equatable, Sendable {
    case nameMissing
    case nameTooLong
    case nameHasControlCharacters
    case noScopes

    var message: String {
        switch self {
        case .nameMissing: "Give the key a name, such as the tool that will use it."
        case .nameTooLong: "Key names can be up to \(NativeAPIKeyName.maxLength) characters."
        case .nameHasControlCharacters: "Key names can't contain line breaks or control characters."
        case .noScopes: "Choose at least one kind of data the key can read."
        }
    }
}

enum NativeAPIKeyName {
    static let maxLength = 40

    /// The Worker's `normalizeName`: trimmed, 1–40 characters (counted in
    /// UTF-16 units, as JavaScript counts), no control characters.
    static func normalize(_ input: String) -> Result<String, NativeAPIKeyDraftIssue> {
        let name = input.trimmingCharacters(in: trimmed)
        if name.isEmpty { return .failure(.nameMissing) }
        if name.utf16.count > maxLength { return .failure(.nameTooLong) }
        if name.unicodeScalars.contains(where: isControl) { return .failure(.nameHasControlCharacters) }
        return .success(name)
    }

    /// Exactly what JavaScript's `trim()` removes: Unicode space separators,
    /// tab, VT, FF, LF, CR, LS, PS and the BOM. Foundation's
    /// `whitespacesAndNewlines` would also trim U+0085, which `trim()` keeps
    /// (and the Worker then refuses as a control character).
    private static let trimmed: CharacterSet = CharacterSet.whitespaces
        .union(CharacterSet(charactersIn: "\u{A}\u{B}\u{C}\u{D}\u{2028}\u{2029}\u{FEFF}"))

    private static func isControl(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x00...0x1F, 0x7F...0x9F, 0x2028, 0x2029: true
        default: false
        }
    }
}

/// A validated `create` request: what the server receives, byte for byte the
/// same on every retry of one operation.
struct NativeAPIKeyCreateRequest: Equatable, Sendable {
    let name: String
    let scopes: [NativeAPIScope]
    let expiry: NativeAPIKeyExpiry

    static func validated(
        name: String,
        scopes: Set<NativeAPIScope>,
        expiry: NativeAPIKeyExpiry
    ) -> Result<NativeAPIKeyCreateRequest, NativeAPIKeyDraftIssue> {
        switch NativeAPIKeyName.normalize(name) {
        case let .failure(issue): return .failure(issue)
        case let .success(normalized):
            guard !scopes.isEmpty else { return .failure(.noScopes) }
            return .success(.init(name: normalized, scopes: NativeAPIScope.canonical(scopes), expiry: expiry))
        }
    }
}

// MARK: - Analytics (§9: scope count only)

/// What the screen reports. Scope count only: never a name, prefix, id or key.
enum NativeAPIAccessAnalyticsEvent: Equatable, Sendable {
    case keyCreated(scopeCount: Int)
    case keyRevoked(scopeCount: Int)
}

// MARK: - Clipboard (§9 show-once sheet)

enum NativeAPIKeyClipboardPolicy {
    /// The copied key stays on this device (no Handoff / Universal Clipboard).
    static let localOnly = true
    /// …and clears itself after two minutes.
    static let lifetime: TimeInterval = 120

    static func expiration(from now: Date) -> Date { now.addingTimeInterval(lifetime) }
}

// MARK: - Rate limiting (Retry-After)

enum NativeAPIRetryAfter {
    /// The manage route's window is one minute (§14.1, 10/min per user). Its
    /// 429 sends no `Retry-After` today, so the app waits the window out.
    static let defaultSeconds: TimeInterval = 60
    static let maximumSeconds: TimeInterval = 3600

    /// `Retry-After` as delta-seconds or an HTTP-date, clamped to 1…3600 s.
    static func seconds(from header: String?, now: Date) -> TimeInterval {
        guard let header = header?.trimmingCharacters(in: .whitespaces), !header.isEmpty else { return defaultSeconds }
        if let value = Int(header) { return clamp(TimeInterval(value)) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        if let date = formatter.date(from: header) { return clamp(date.timeIntervalSince(now)) }
        return defaultSeconds
    }

    private static func clamp(_ value: TimeInterval) -> TimeInterval {
        min(max(value.rounded(.up), 1), maximumSeconds)
    }
}

// MARK: - Presentation (text only; no colour-only meaning)

enum NativeAPIAccessText {
    static let freshnessNote = "Other tools see your data as of your phone's last sync."
    static let showOnceWarning = "TradeReady can't show this key again."
    static let readOnlyNote = "Keys can only read. Internal notes, costs and margins are never shared."
    static let developerDocsURLString = "https://gettradereadyapp.com/developers.html"

    static func statusTitle(_ key: NativeAPIKeySummary, now: Date) -> String {
        switch key.status(at: now) {
        case .active: "Active"
        case .expiring: "Replaced"
        case .expired: "Expired"
        case .revoked: "Revoked"
        }
    }

    static func statusDetail(_ key: NativeAPIKeySummary, now: Date, locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        switch key.status(at: now) {
        case .active:
            guard let expiresAt = key.expiresAt else { return "Never expires" }
            return "Expires \(day(expiresAt, locale: locale, timeZone: timeZone))"
        case .expiring:
            guard let expiresAt = key.expiresAt else { return "Being replaced" }
            return "Keeps working until \(dayAndTime(expiresAt, locale: locale, timeZone: timeZone))"
        case .expired:
            guard let expiresAt = key.expiresAt else { return "Expired" }
            return "Expired \(day(expiresAt, locale: locale, timeZone: timeZone))"
        case .revoked:
            guard let revokedAt = key.revokedAt else { return "Revoked" }
            return "Revoked \(day(revokedAt, locale: locale, timeZone: timeZone))"
        }
    }

    static func lastUsed(_ key: NativeAPIKeySummary, now: Date, locale: Locale = .current) -> String {
        guard let lastUsedAt = key.lastUsedAt else { return "Never used" }
        return "Last used \(relative(lastUsedAt, now: now, locale: locale))"
    }

    static func created(_ key: NativeAPIKeySummary, locale: Locale = .current, timeZone: TimeZone = .current) -> String? {
        key.createdAt.map { "Created \(day($0, locale: locale, timeZone: timeZone))" }
    }

    /// "Everything", "Bookkeeping", or the scope titles in canonical order.
    static func scopeSummary(_ scopes: [NativeAPIScope]) -> String {
        let set = Set(scopes)
        switch NativeAPIScopePreset.matching(set) {
        case .everything: return "Everything"
        case .bookkeeping: return "Bookkeeping (customers, invoices, expenses, mileage)"
        case .custom:
            let titles = NativeAPIScope.canonical(set).map(\.title)
            return titles.isEmpty ? "No access" : titles.joined(separator: ", ")
        }
    }

    /// The prefix as shown in a row: `trk_Ab3dE9fQ…`.
    static func displayPrefix(_ prefix: String) -> String { prefix.isEmpty ? "trk_…" : "\(prefix)…" }

    /// One VoiceOver sentence for a key row.
    static func accessibilitySummary(_ key: NativeAPIKeySummary, now: Date, locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        var parts = [
            key.name.isEmpty ? "Unnamed key" : key.name,
            statusTitle(key, now: now),
            statusDetail(key, now: now, locale: locale, timeZone: timeZone),
            "Key starts with \(key.prefix.isEmpty ? "trk" : key.prefix)",
            "Can read \(scopeSummary(key.scopes))",
        ]
        if let created = created(key, locale: locale, timeZone: timeZone) { parts.append(created) }
        parts.append(lastUsed(key, now: now, locale: locale))
        return parts.joined(separator: ". ")
    }

    /// "Allowed · 200", "Denied · 403", …
    static func activityOutcome(_ event: NativeAPIActivityEvent) -> String {
        "\(event.kind.title) · \(event.status)"
    }

    static func activityAccessibility(
        _ event: NativeAPIActivityEvent,
        keyName: String?,
        now: Date,
        locale: Locale = .current
    ) -> String {
        var parts = [event.route.isEmpty ? "Unknown request" : event.route, "\(event.kind.title), status \(event.status)"]
        if let at = event.at { parts.append(relative(at, now: now, locale: locale)) }
        if let keyName, !keyName.isEmpty { parts.append("Key \(keyName)") }
        if let ip = event.ip, !ip.isEmpty { parts.append("From \(ip)") }
        return parts.joined(separator: ". ")
    }

    /// The reveal sheet's line about the key a rotation replaced.
    static func previousKeyNote(_ previous: NativeAPIKeySummary?, now: Date, locale: Locale = .current, timeZone: TimeZone = .current) -> String? {
        guard let previous else { return nil }
        if let expiresAt = previous.expiresAt, expiresAt > now {
            return "The old key keeps working until \(dayAndTime(expiresAt, locale: locale, timeZone: timeZone)). Update the tool before then."
        }
        return "The old key has stopped working. Update the tool with this key now."
    }

    static func rateLimited(until: Date, now: Date) -> String {
        let seconds = max(1, Int(until.timeIntervalSince(now).rounded(.up)))
        return "Too many requests. Try again in about \(seconds) second\(seconds == 1 ? "" : "s")."
    }

    // MARK: Formatting

    static func day(_ date: Date, locale: Locale, timeZone: TimeZone) -> String {
        date.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted, locale: locale, calendar: calendar(timeZone), timeZone: timeZone))
    }

    static func dayAndTime(_ date: Date, locale: Locale, timeZone: TimeZone) -> String {
        date.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened, locale: locale, calendar: calendar(timeZone), timeZone: timeZone))
    }

    static func relative(_ date: Date, now: Date, locale: Locale) -> String {
        if abs(now.timeIntervalSince(date)) < 60 { return "just now" }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = locale
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: now)
    }

    private static func calendar(_ timeZone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }
}

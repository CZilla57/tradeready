import Foundation

// MARK: - Seam (task 10.12, widened in place by task 11.07; contract §9.6, C16, ruling P6)

/// One analytics property value. The catalog (§9.5) only uses JSON scalars and
/// string arrays, so nothing else can be expressed: no `Data`, no nested
/// objects, no dates. Document bytes are unrepresentable by construction.
enum NativeAnalyticsValue: Equatable, Sendable {
    case bool(Bool)
    case number(Double)
    case string(String)
    case strings([String])

    /// The value handed to the SDK. Integral numbers go out as integers so a
    /// count serializes as `3`, not `3.0` (RN sends JS numbers).
    var jsonObject: Any {
        switch self {
        case .bool(let value): return value
        case .number(let value):
            if value.rounded() == value, abs(value) < 9_007_199_254_740_992 { return Int64(value) }
            return value
        case .string(let value): return value
        case .strings(let value): return value
        }
    }

    /// Lossy string rendering the 10.12/11.06 host-test recording fakes use
    /// for their string assertions: numbers without a trailing `.0`, arrays
    /// comma-joined. Never sent anywhere.
    var legacyStringValue: String {
        switch self {
        case .bool(let value): return value ? "true" : "false"
        case .number(let value):
            if value.rounded() == value, abs(value) < 9_007_199_254_740_992 { return String(Int64(value)) }
            return String(value)
        case .string(let value): return value
        case .strings(let value): return value.joined(separator: ",")
        }
    }
}

extension NativeAnalyticsValue: ExpressibleByStringLiteral, ExpressibleByBooleanLiteral,
    ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral, ExpressibleByArrayLiteral {
    init(stringLiteral value: String) { self = .string(value) }
    init(booleanLiteral value: Bool) { self = .bool(value) }
    init(integerLiteral value: Int) { self = .number(Double(value)) }
    init(floatLiteral value: Double) { self = .number(value) }
    init(arrayLiteral elements: String...) { self = .strings(elements) }
}

/// The analytics seam every call site talks to.
///
/// Task 10.12 created it as `track(_:_: [String: String])` with a no-op
/// default. Task 11.07 widened it in place (contract §9.6) and added
/// `identify`, `reset` and `screen`. Task 11.08 migrated every call site to
/// typed values (`NativeAnalyticsEvent`, `N/NativeAnalyticsEvents.swift`) and
/// removed the `[String: String]` form (review finding m1): the two `track`
/// defaults used to forward to each other, so a conformer that implemented
/// neither recursed forever. The typed `track` is now the only `track`
/// requirement and has no default, so such a conformer fails to compile.
protocol NativeAnalytics {
    func track(_ event: String, _ properties: [String: NativeAnalyticsValue])
    /// The Supabase user id only — never an email, name or trait (§9.4).
    func identify(_ userID: String)
    func reset()
    /// An RN route name (§9.3; the map is `NativeAnalyticsScreenMap`).
    func screen(_ name: String)
}

extension NativeAnalytics {
    /// Convenience for the zero-property call. Forwards to the requirement.
    func track(_ event: String) { track(event, [String: NativeAnalyticsValue]()) }

    /// A typed catalog event (task 11.08). Forwards to the requirement.
    func track(_ event: NativeAnalyticsEvent) { track(event.name, event.properties) }

    func identify(_ userID: String) {}
    func reset() {}
    func screen(_ name: String) {}
}

/// Does nothing. Never throws, never blocks, never touches the network — the
/// `AppStore` default and the transport host tests' control.
struct NativeNoOpAnalytics: NativeAnalytics {
    func track(_ event: String, _ properties: [String: NativeAnalyticsValue]) {}
}

// MARK: - Event catalog (contract §9.5, verbatim fixture)

/// The §9.5 event-catalog fixture, verbatim. The transport's allow-list is
/// parsed from this string; the host test proves it equals the JSON block in
/// `docs/native-phase-11-platform-hardening-contract-decisions.md`.
enum NativeAnalyticsCatalogFixture {
    static let json = #"""
{
  "catalogVersion": 1,
  "enums": {
    "TradeId": ["plumbing","electrical","hvac","carpenter","bricklayer","plasterer","landscaping","cleaning","painting","handyman","other"],
    "PaymentMethod": ["stripe","cash","check","card","other"],
    "JobStatus": ["lead","estimate_sent","approved","scheduled","in_progress","complete","invoiced","paid","declined"],
    "ExpenseCategoryId": ["materials","tools","fuel","labor","insurance","software","marketing","other"],
    "InsightKind": ["labor_overrun","low_margin_estimate","uninvoiced_complete","due_soon","open_slot","unscheduled_approved","maintenance_due","expense_anomaly"]
  },
  "events": {
    "ai_chat_sent": [{"source": "insight_prefill|organic", "provider": "anthropic|groq|backend"}],
    "appointment_confirm_opened": [{}],
    "appointment_confirm_sent": [{}],
    "booking_request_opened": [{}],
    "booking_update_opened": [{}],
    "bulk_invoice_reminders": [{"channel": "email|text", "count": "number"}],
    "bulk_invoices_marked_paid": [{"count": "number"}],
    "change_order_created": [{"amount": "number"}],
    "change_order_decided": [{"decision": "approved|declined", "channel": "manual"}],
    "change_order_sent": [{"amount": "number", "channel": "text|email"}],
    "customer_created": [{"first": "bool"}],
    "customers_merged": [{"jobs": "number", "invoices": "number"}],
    "estimate_follow_up_opened": [{"source": "job_detail|notification"}],
    "estimate_follow_up_sent": [{"channel": "sms|email", "source": "notification|job_detail"}],
    "estimate_sent": [{}],
    "expense_logged": [{"category": "enum:ExpenseCategoryId", "linkedToJob": "bool"}],
    "first_action_tapped": [{"action": "add_customer|create_job"}],
    "insight_coach_opened": [{"kind": "enum:InsightKind"}],
    "insight_dismissed": [{"kind": "enum:InsightKind", "insightId": "string"}],
    "insight_reason_viewed": [{"kind": "enum:InsightKind"}],
    "insight_shown": [{"kinds": "enum[]:InsightKind", "ids": "string[]"}],
    "insight_snoozed": [{"kind": "enum:InsightKind", "insightId": "string", "days": "number"}],
    "insight_tapped": [{"kind": "enum:InsightKind"}],
    "invoice_created": [
      {"source": "from_job", "mode": "create|requestDeposit|finalize"},
      {"source": "manual"},
      {"source": "auto_on_complete", "usedTrackedTime": "bool", "autoEmailQueued": "bool"}
    ],
    "invoice_finalized": [{"source": "from_job"}],
    "invoice_paid": [{"amount": "number"}],
    "job_created": [{"duplicated?": "true", "customerId?": "string", "first": "bool"}],
    "job_status_changed": [{"from": "enum:JobStatus", "to": "enum:JobStatus"}],
    "on_my_way_sent": [{}],
    "onboarding_completed": [{"trade": "enum:TradeId"}],
    "onboarding_start_choice": [{"choice": "sample|fresh"}],
    "onboarding_step_viewed": [{"step": "welcome|business|starting_point"}],
    "overdue_outreach_opened": [{"daysPastDue?": "number"}],
    "payment_link_sent": [{"provider": "string", "deposit": "bool"}],
    "payment_recorded": [{"amount": "number", "method": "enum:PaymentMethod", "balanceRemaining": "number"}],
    "payment_voided": [{"amount": "number", "method": "enum:PaymentMethod"}],
    "pricebook_entry_saved": [{}],
    "pull_to_refresh": [{"screen": "MoneyScreen|JobsScreen"}],
    "receipt_scanned": [{"outcome": "failed"}, {"outcome": "filled|empty", "route": "user_key|backend"}],
    "review_request_sent": [{"channel": "sms|email", "source": "notification|job_detail"}],
    "sample_job_opened": [{}],
    "setup_checklist_dismissed": [{"doneCount": "number"}],
    "setup_checklist_task_opened": [{"task": "notifications|contact|logo|rate|stripe"}],
    "sign_in": [{"method": "password|apple|google"}],
    "sign_up": [{}],
    "sign_up_confirmation_resent": [{}],
    "subscription_paywall_shown": [{"context": "settings|onboarding_gate"}],
    "subscription_purchased": [{}],
    "tax_settings_saved": [{"hasIncomeRate": "bool", "vehicleMethod": "mileage|actual|unset"}],
    "time_tracking_started": [{"jobId": "string"}],
    "trip_logged": [{}],
    "widget_deep_link_opened": [{"type": "job|onmyway"}]
  }
}
"""#
}

/// The parsed §9.5 catalog: event name → allowed property-shape variants.
struct NativeAnalyticsEventCatalog: Equatable {
    enum PropertyType: Equatable {
        case bool
        case number
        case string
        case strings
        case trueLiteral
        /// Inline `a|b|c` (a single token is a fixed literal) or `enum:<Name>`.
        case oneOf(Set<String>)
        /// `enum[]:<Name>`.
        case oneOfArray(Set<String>)
    }

    struct PropertySpec: Equatable {
        let type: PropertyType
        let isOptional: Bool
    }

    typealias Variant = [String: PropertySpec]

    enum ParseError: Error, Equatable {
        case malformed(String)
        case unknownEnum(String)
    }

    let catalogVersion: Int
    let events: [String: [Variant]]

    /// The shipped catalog. `nil` only if the embedded fixture failed to
    /// parse, in which case the transport drops every event (fail closed); the
    /// host test pins that it parses.
    static let standard: NativeAnalyticsEventCatalog? =
        try? NativeAnalyticsEventCatalog(json: Data(NativeAnalyticsCatalogFixture.json.utf8))

    init(json: Data) throws {
        guard let root = try JSONSerialization.jsonObject(with: json) as? [String: Any],
              let version = root["catalogVersion"] as? Int,
              let enumsObject = root["enums"] as? [String: Any],
              let eventsObject = root["events"] as? [String: Any]
        else { throw ParseError.malformed("root") }

        var enums: [String: Set<String>] = [:]
        for (name, values) in enumsObject {
            guard let list = values as? [String], !list.isEmpty else { throw ParseError.malformed("enum \(name)") }
            enums[name] = Set(list)
        }

        var events: [String: [Variant]] = [:]
        for (event, variantsObject) in eventsObject {
            guard let variants = variantsObject as? [[String: Any]], !variants.isEmpty
            else { throw ParseError.malformed("event \(event)") }
            events[event] = try variants.map { variant in
                var parsed: Variant = [:]
                for (rawKey, rawType) in variant {
                    guard let typeString = rawType as? String else { throw ParseError.malformed("\(event).\(rawKey)") }
                    let isOptional = rawKey.hasSuffix("?")
                    let key = isOptional ? String(rawKey.dropLast()) : rawKey
                    parsed[key] = PropertySpec(type: try Self.parseType(typeString, enums: enums), isOptional: isOptional)
                }
                return parsed
            }
        }
        self.catalogVersion = version
        self.events = events
    }

    private static func parseType(_ raw: String, enums: [String: Set<String>]) throws -> PropertyType {
        switch raw {
        case "bool": return .bool
        case "number": return .number
        case "string": return .string
        case "string[]": return .strings
        case "true": return .trueLiteral
        default: break
        }
        if raw.hasPrefix("enum[]:") {
            let name = String(raw.dropFirst("enum[]:".count))
            guard let values = enums[name] else { throw ParseError.unknownEnum(name) }
            return .oneOfArray(values)
        }
        if raw.hasPrefix("enum:") {
            let name = String(raw.dropFirst("enum:".count))
            guard let values = enums[name] else { throw ParseError.unknownEnum(name) }
            return .oneOf(values)
        }
        let tokens = raw.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard !tokens.isEmpty, !tokens.contains(where: \.isEmpty) else { throw ParseError.malformed(raw) }
        return .oneOf(Set(tokens))
    }
}

// MARK: - Diagnostics (bounded; never carries a value)

/// What the choke point reports when it strips or rejects something. It holds
/// an operation, a sanitized event name, and at most `maxIssues` (key, reason)
/// pairs. It never holds a property value, a user id or an error description,
/// so logging it cannot leak what it redacted.
struct NativeAnalyticsDiagnostic: Equatable, Sendable {
    enum Operation: String, Sendable { case setup, track, identify, reset, screen }

    enum Reason: String, Sendable {
        // Event level
        case unknownEvent
        case payloadTooLarge
        case catalogUnavailable
        // Key level (the key is outside every variant of the event)
        case unknownKey
        case secureKey
        case personalDataKey
        case documentKey
        // Value level (the key is in the catalog; the value is not allowed)
        case wrongType
        case notInCatalogEnum
        case nonFiniteNumber
        case oversizeValue
        case secretValue
        case personalDataValue
        case documentValue
        case freeTextValue
        case missingProperty
        // Other operations
        case invalidIdentity
        case invalidScreenName
        case transportFailure
        case disabledDebugBuild
        case disabledMissingKey
        case disabledPlaceholderKey
        case disabledInvalidHost
        case adapterSetupFailed
    }

    struct Issue: Equatable, Sendable {
        let key: String
        let reason: Reason
    }

    static let maxIssues = 8
    static let maxMessageLength = 512
    static let maxNameLength = 40

    let operation: Operation
    let event: String
    let issues: [Issue]
    let omittedIssueCount: Int

    init(operation: Operation, event: String = "", issues: [Issue]) {
        self.operation = operation
        self.event = Self.sanitizedName(event)
        self.issues = Array(issues.prefix(Self.maxIssues)).map {
            Issue(key: Self.sanitizedName($0.key), reason: $0.reason)
        }
        self.omittedIssueCount = max(0, issues.count - Self.maxIssues)
    }

    /// One log line, at most `maxMessageLength` characters.
    var message: String {
        var text = "analytics \(operation.rawValue)"
        if !event.isEmpty { text += " \(event)" }
        if !issues.isEmpty {
            text += ": " + issues.map { $0.key.isEmpty ? $0.reason.rawValue : "\($0.key)=\($0.reason.rawValue)" }
                .joined(separator: ", ")
        }
        if omittedIssueCount > 0 { text += " (+\(omittedIssueCount) more)" }
        return String(text.prefix(Self.maxMessageLength))
    }

    /// Names are code identifiers. Anything that is not a plain identifier of
    /// at most `maxNameLength` characters (an email used as a key, a value
    /// passed as an event name) is replaced rather than echoed.
    ///
    /// Task 11.08 (review finding m3): the result is logged with
    /// `privacy: .public`, and an identifier-shaped credential (`sk_live_…`,
    /// `phc_…`, `AIza…`, a JWT header segment `eyJ…`) passes the character
    /// check. Names are therefore also screened with the value-level
    /// `containsSecret`, and a name carrying a run of 7+ digits (a phone
    /// number or a record id used as a key) is replaced too.
    static func sanitizedName(_ name: String) -> String {
        guard !name.isEmpty else { return "" }
        guard name.utf8.count <= maxNameLength,
              let first = name.unicodeScalars.first,
              first == "_" || first == "$" || NativeAnalyticsPrivacyPolicy.asciiLetters.contains(first),
              name.unicodeScalars.allSatisfy(NativeAnalyticsPrivacyPolicy.nameCharacters.contains),
              !NativeAnalyticsPrivacyPolicy.containsSecret(name),
              !Self.containsLongDigitRun(name)
        else { return "<redacted>" }
        return name
    }

    static let maxNameDigitRun = 6

    private static func containsLongDigitRun(_ name: String) -> Bool {
        var run = 0
        for scalar in name.unicodeScalars {
            if NativeAnalyticsPrivacyPolicy.asciiDigits.contains(scalar) {
                run += 1
                if run > maxNameDigitRun { return true }
            } else {
                run = 0
            }
        }
        return false
    }
}

// MARK: - Privacy policy (the §9.5 allow-list + the §10.1 analytics column)

/// Pure, Foundation-only policy run at the single `track` choke point.
///
/// - An event missing from the catalog is dropped (§9.5).
/// - A key missing from every variant is stripped; the diagnostic classifies
///   it as a secure, personal-data or document key when its name says so.
/// - A catalog key whose value has the wrong type or is outside its enum is
///   stripped; the event still sends (§9.5 rationale).
/// - Free `string`/`string[]` values (internal ids and `provider`) must be
///   plain identifiers: secrets, tokens, emails, phone-like numbers, URLs,
///   data URIs, free text and oversize values are stripped (§10.1).
/// - An event whose sanitized payload exceeds `maxPayloadBytes` is rejected.
struct NativeAnalyticsPrivacyPolicy {
    enum Decision: Equatable {
        case send(event: String, properties: [String: NativeAnalyticsValue])
        case drop
    }

    struct Evaluation: Equatable {
        let decision: Decision
        let diagnostic: NativeAnalyticsDiagnostic?
        /// True when the event name is not in the catalog (Debug asserts).
        let isCatalogViolation: Bool
    }

    static let maxStringBytes = 128
    static let maxArrayCount = 64
    static let maxPayloadBytes = 4_096
    static let maxIdentityBytes = 128
    static let maxScreenNameBytes = 64

    /// Events the PostHog SDK itself generates that may leave the device
    /// (§9.2 lifecycle, §9.3 `$screen`, `identify`'s `$identify`). Everything
    /// else the SDK could produce (autocapture, rage clicks, exceptions, push
    /// opens, deep links, feature-flag calls) is dropped in `beforeSend`.
    static let permittedSDKEvents: Set<String> = [
        "$screen", "$identify",
        "Application Installed", "Application Updated", "Application Opened", "Application Backgrounded",
    ]

    /// Value prefixes of the credential classes in §10.1: Anthropic/OpenAI-style
    /// (`sk-`), Stripe secret/restricted/publishable/webhook, Groq, RevenueCat
    /// (Apple/Google/Amazon/Stripe/web), PostHog, Supabase, Google API keys,
    /// JWTs (Supabase access tokens), GitHub tokens.
    static let secretValuePrefixes: [String] = [
        "sk-", "sk_live_", "sk_test_", "rk_live_", "rk_test_", "pk_live_", "pk_test_", "whsec_",
        "gsk_", "appl_", "goog_", "amzn_", "strp_", "rcb_", "phc_", "phx_",
        "sb_secret_", "sb_publishable_", "AIza", "eyJ", "ghp_", "gho_", "github_pat_",
    ]

    static let secureKeyFragments = [
        "key", "token", "secret", "password", "passwd", "authorization", "bearer", "session",
        "cookie", "credential", "dsn", "jwt", "otp",
    ]
    static let personalDataKeyFragments = [
        "email", "phone", "name", "address", "street", "zip", "postal", "note", "message", "body",
        "text", "review", "comment", "customer", "contact", "sms",
    ]
    static let documentKeyFragments = [
        "pdf", "image", "photo", "picture", "receipt", "bytes", "base64", "data", "csv", "export",
        "file", "attachment", "document", "uri", "url", "blob",
    ]

    static let asciiLetters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ")
    static let asciiDigits = CharacterSet(charactersIn: "0123456789")
    /// Characters a catalog `string` value may contain: internal ids
    /// (`1727190000000k3j9x`, UUIDs, `labor_overrun:<id>`,
    /// `low_margin_estimate:<id>:1234.5`, `open_slot:2026-09-24`).
    static let identifierCharacters = asciiLetters.union(asciiDigits).union(CharacterSet(charactersIn: "_-.:"))
    static let nameCharacters = asciiLetters.union(asciiDigits).union(CharacterSet(charactersIn: "_$"))

    let catalog: NativeAnalyticsEventCatalog?

    static let standard = NativeAnalyticsPrivacyPolicy(catalog: NativeAnalyticsEventCatalog.standard)

    // MARK: track

    func evaluate(event: String, properties: [String: NativeAnalyticsValue]) -> Evaluation {
        guard let catalog else {
            return Evaluation(
                decision: .drop,
                diagnostic: .init(operation: .track, event: event, issues: [.init(key: "", reason: .catalogUnavailable)]),
                isCatalogViolation: false
            )
        }
        guard let variants = catalog.events[event] else {
            return Evaluation(
                decision: .drop,
                diagnostic: .init(operation: .track, event: event, issues: [.init(key: "", reason: .unknownEvent)]),
                isCatalogViolation: true
            )
        }

        // Task 11.08 (review finding m2): a variant whose literal
        // discriminator (`source`, `outcome`) matches the supplied value ranks
        // first. Ranking only by kept-property count let a variant that kept
        // more incidental keys win while stripping the discriminator itself
        // (`invoice_created{source: manual, usedTrackedTime, autoEmailQueued}`
        // used to send without `source`).
        var best: (
            discriminator: Int,
            kept: [String: NativeAnalyticsValue],
            issues: [NativeAnalyticsDiagnostic.Issue],
            missing: Int
        )?
        for variant in variants {
            let result = Self.filter(properties, against: variant)
            let discriminator = Self.discriminatorScore(properties, against: variant)
            if let current = best {
                if discriminator != current.discriminator {
                    if discriminator > current.discriminator {
                        best = (discriminator, result.kept, result.issues, result.missing)
                    }
                } else if result.kept.count > current.kept.count
                    || (result.kept.count == current.kept.count && result.missing < current.missing) {
                    best = (discriminator, result.kept, result.issues, result.missing)
                }
            } else {
                best = (discriminator, result.kept, result.issues, result.missing)
            }
        }
        let chosen: (kept: [String: NativeAnalyticsValue], issues: [NativeAnalyticsDiagnostic.Issue]) =
            best.map { ($0.kept, $0.issues) } ?? ([:], [])

        if Self.encodedSize(of: chosen.kept) > Self.maxPayloadBytes {
            return Evaluation(
                decision: .drop,
                diagnostic: .init(operation: .track, event: event, issues: [.init(key: "", reason: .payloadTooLarge)]),
                isCatalogViolation: false
            )
        }
        return Evaluation(
            decision: .send(event: event, properties: chosen.kept),
            diagnostic: chosen.issues.isEmpty ? nil : .init(operation: .track, event: event, issues: chosen.issues),
            isCatalogViolation: false
        )
    }

    /// +1 for every required single-token literal key (`source: manual`,
    /// `outcome: failed`) whose supplied value equals the literal, −1 for
    /// every one supplied with a different value. Variants without literal
    /// keys score 0, so single-variant events are unaffected.
    static func discriminatorScore(
        _ properties: [String: NativeAnalyticsValue],
        against variant: NativeAnalyticsEventCatalog.Variant
    ) -> Int {
        var score = 0
        for (key, spec) in variant where !spec.isOptional {
            guard case .oneOf(let allowed) = spec.type, allowed.count == 1,
                  let supplied = properties[key]
            else { continue }
            if case .string(let text) = supplied, allowed.contains(text) {
                score += 1
            } else {
                score -= 1
            }
        }
        return score
    }

    private static func filter(
        _ properties: [String: NativeAnalyticsValue],
        against variant: NativeAnalyticsEventCatalog.Variant
    ) -> (kept: [String: NativeAnalyticsValue], issues: [NativeAnalyticsDiagnostic.Issue], missing: Int) {
        var kept: [String: NativeAnalyticsValue] = [:]
        var issues: [NativeAnalyticsDiagnostic.Issue] = []
        for key in properties.keys.sorted() {
            let value = properties[key]!
            guard let spec = variant[key] else {
                issues.append(.init(key: key, reason: classifyUnknownKey(key)))
                continue
            }
            if let reason = rejection(of: value, for: spec.type) {
                issues.append(.init(key: key, reason: reason))
            } else {
                kept[key] = value
            }
        }
        var missing = 0
        for key in variant.keys.sorted() where !variant[key]!.isOptional && kept[key] == nil {
            missing += 1
            if properties[key] == nil { issues.append(.init(key: key, reason: .missingProperty)) }
        }
        return (kept, issues, missing)
    }

    /// `nil` when the value may leave the device under `type`.
    static func rejection(
        of value: NativeAnalyticsValue,
        for type: NativeAnalyticsEventCatalog.PropertyType
    ) -> NativeAnalyticsDiagnostic.Reason? {
        switch (type, value) {
        case (.bool, .bool):
            return nil
        case (.trueLiteral, .bool(let flag)):
            return flag ? nil : .notInCatalogEnum
        case (.number, .number(let number)):
            return number.isFinite ? nil : .nonFiniteNumber
        case (.string, .string(let text)):
            return rejection(ofIdentifier: text)
        case (.strings, .strings(let list)):
            guard list.count <= maxArrayCount else { return .oversizeValue }
            return list.lazy.compactMap { rejection(ofIdentifier: $0) }.first
        case (.oneOf(let allowed), .string(let text)):
            return allowed.contains(text) ? nil : .notInCatalogEnum
        case (.oneOfArray(let allowed), .strings(let list)):
            guard list.count <= maxArrayCount else { return .oversizeValue }
            return list.allSatisfy(allowed.contains) ? nil : .notInCatalogEnum
        default:
            return .wrongType
        }
    }

    /// Screens a free `string` value (an internal id or a provider name).
    static func rejection(ofIdentifier text: String) -> NativeAnalyticsDiagnostic.Reason? {
        if containsSecret(text) { return .secretValue }
        let lowered = text.lowercased()
        if lowered.hasPrefix("data:") || lowered.contains("://") || lowered.contains(";base64,") {
            return .documentValue
        }
        if text.contains("@") || isPhoneLike(text) { return .personalDataValue }
        if text.utf8.count > maxStringBytes { return .oversizeValue }
        guard text.unicodeScalars.allSatisfy(identifierCharacters.contains) else { return .freeTextValue }
        return nil
    }

    static func containsSecret(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if secretValuePrefixes.contains(where: { trimmed.hasPrefix($0) }) { return true }
        let lowered = trimmed.lowercased()
        return lowered.hasPrefix("bearer ") || lowered.contains("authorization:")
            || lowered.contains("access_token") || lowered.contains("refresh_token")
    }

    /// A phone number as a bare value: optional `+`, then 7–15 digits with
    /// phone punctuation and no letters. Pure digit runs of 13+ characters
    /// are allowed because RN record ids start with `Date.now()` (13 digits).
    static func isPhoneLike(_ text: String) -> Bool {
        let scalars = Array(text.unicodeScalars)
        guard !scalars.isEmpty else { return false }
        let punctuation = CharacterSet(charactersIn: "+-. ()")
        guard scalars.allSatisfy({ asciiDigits.contains($0) || punctuation.contains($0) }) else { return false }
        let digitCount = scalars.filter { asciiDigits.contains($0) }.count
        let hasPunctuation = scalars.contains { punctuation.contains($0) }
        if hasPunctuation { return (7...15).contains(digitCount) && !text.contains(":") }
        return (7...12).contains(digitCount)
    }

    static func classifyUnknownKey(_ key: String) -> NativeAnalyticsDiagnostic.Reason {
        let normalized = key.lowercased().filter { $0.isLetter || $0.isNumber }
        if secureKeyFragments.contains(where: normalized.contains) { return .secureKey }
        if personalDataKeyFragments.contains(where: normalized.contains) { return .personalDataKey }
        if documentKeyFragments.contains(where: normalized.contains) { return .documentKey }
        return .unknownKey
    }

    static func encodedSize(of properties: [String: NativeAnalyticsValue]) -> Int {
        let object = properties.mapValues(\.jsonObject)
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        else { return Int.max }
        return data.count
    }

    // MARK: identify / screen

    /// The distinct id is the Supabase user id (a UUID): an identifier of at
    /// most `maxIdentityBytes`, never an email, phone or credential (§9.4).
    static func identityRejection(_ userID: String) -> NativeAnalyticsDiagnostic.Reason? {
        guard !userID.isEmpty, userID.utf8.count <= maxIdentityBytes,
              rejection(ofIdentifier: userID) == nil
        else { return .invalidIdentity }
        return nil
    }

    /// RN route names (`Today`, `JobDetail`): a letter, then letters, digits
    /// or `_`, at most `maxScreenNameBytes`.
    static func screenNameRejection(_ name: String) -> NativeAnalyticsDiagnostic.Reason? {
        guard let first = name.unicodeScalars.first, asciiLetters.contains(first),
              name.utf8.count <= maxScreenNameBytes,
              name.unicodeScalars.allSatisfy({ asciiLetters.contains($0) || asciiDigits.contains($0) || $0 == "_" })
        else { return .invalidScreenName }
        return nil
    }

    /// `beforeSend` gate for anything the SDK is about to enqueue: our own
    /// catalog events (already sanitized by `evaluate`) and the SDK events in
    /// `permittedSDKEvents`. Everything else is dropped.
    func permitsOutgoingEvent(_ name: String) -> Bool {
        if Self.permittedSDKEvents.contains(name) { return true }
        return catalog?.events[name] != nil
    }
}

// MARK: - Transport (the single choke point)

/// The seam to the analytics SDK. Foundation-only so host tests fake it; the
/// PostHog implementation lives in `NativeAnalyticsPostHog.swift` (app target
/// only). Methods may throw; the transport swallows every failure.
protocol NativeAnalyticsSDKAdapter: AnyObject {
    func capture(_ event: String, properties: [String: NativeAnalyticsValue]) throws
    func identify(_ distinctID: String) throws
    func reset() throws
    func screen(_ name: String) throws
}

/// The production `NativeAnalytics`. Every event passes the privacy policy
/// first; only a `.send` decision reaches the adapter, and only when the gate
/// (`NativeAnalyticsGate`) produced one. With no adapter (Debug, a missing or
/// `PLACEHOLDER` key, a failed setup) it emits nothing. Failures are swallowed
/// like RN `utils/analytics.ts`: analytics never crashes the app and never
/// blocks a save.
final class NativeAnalyticsTransport: NativeAnalytics, @unchecked Sendable {
    typealias DiagnosticSink = (NativeAnalyticsDiagnostic) -> Void

    /// Debug builds assert on an event name missing from the catalog (§9.5).
    static let defaultCatalogViolationHandler: (String) -> Void = { message in
        #if DEBUG
        assertionFailure(message)
        #endif
    }

    private let adapter: NativeAnalyticsSDKAdapter?
    private let policy: NativeAnalyticsPrivacyPolicy
    private let diagnostics: DiagnosticSink
    private let catalogViolation: (String) -> Void

    init(
        adapter: NativeAnalyticsSDKAdapter?,
        policy: NativeAnalyticsPrivacyPolicy = .standard,
        diagnostics: @escaping DiagnosticSink = { _ in },
        catalogViolation: @escaping (String) -> Void = NativeAnalyticsTransport.defaultCatalogViolationHandler
    ) {
        self.adapter = adapter
        self.policy = policy
        self.diagnostics = diagnostics
        self.catalogViolation = catalogViolation
    }

    /// True only when a configured SDK adapter is attached.
    var isEmitting: Bool { adapter != nil }

    func track(_ event: String, _ properties: [String: NativeAnalyticsValue]) {
        let evaluation = policy.evaluate(event: event, properties: properties)
        if let diagnostic = evaluation.diagnostic { diagnostics(diagnostic) }
        if evaluation.isCatalogViolation {
            catalogViolation("analytics event outside the §9.5 catalog: \(NativeAnalyticsDiagnostic.sanitizedName(event))")
        }
        guard let adapter, case .send(let name, let sanitized) = evaluation.decision else { return }
        do {
            try adapter.capture(name, properties: sanitized)
        } catch {
            diagnostics(.init(operation: .track, event: name, issues: [.init(key: "", reason: .transportFailure)]))
        }
    }

    func identify(_ userID: String) {
        guard let adapter else { return }
        if let reason = NativeAnalyticsPrivacyPolicy.identityRejection(userID) {
            diagnostics(.init(operation: .identify, issues: [.init(key: "", reason: reason)]))
            return
        }
        do {
            try adapter.identify(userID)
        } catch {
            diagnostics(.init(operation: .identify, issues: [.init(key: "", reason: .transportFailure)]))
        }
    }

    func reset() {
        guard let adapter else { return }
        do {
            try adapter.reset()
        } catch {
            diagnostics(.init(operation: .reset, issues: [.init(key: "", reason: .transportFailure)]))
        }
    }

    func screen(_ name: String) {
        guard let adapter else { return }
        if let reason = NativeAnalyticsPrivacyPolicy.screenNameRejection(name) {
            diagnostics(.init(operation: .screen, issues: [.init(key: "", reason: reason)]))
            return
        }
        do {
            try adapter.screen(name)
        } catch {
            diagnostics(.init(operation: .screen, event: name, issues: [.init(key: "", reason: .transportFailure)]))
        }
    }
}

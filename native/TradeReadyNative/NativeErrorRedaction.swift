import Foundation

// Task 11.09 (contract §10.1–§10.3, C18): the Foundation-only redaction policy
// for crash reports. Host tests compile this file with no SDK; the Sentry
// adapter (`NativeCrashReportingSentry.swift`, app target only) maps SDK
// objects onto the payload types below and back, so every rule here is the
// rule the device runs.

// MARK: - Shared sensitive-data screens (analytics and crash reporting)

/// The value and key screens shared by `NativeAnalyticsPrivacyPolicy` (11.07)
/// and `NativeErrorRedaction` (11.09). There is one list of credential
/// prefixes and one phone rule; `NativeAnalyticsPrivacyPolicy` forwards to
/// these members instead of keeping its own copies.
enum NativeSensitiveData {
    /// Value prefixes of the credential classes in §10.1: Anthropic/OpenAI-style
    /// (`sk-`), Stripe secret/restricted/publishable/webhook, Groq, RevenueCat
    /// (Apple/Google/Amazon/Stripe/web), PostHog, Supabase, Google API keys,
    /// JWTs (Supabase access tokens), GitHub tokens.
    static let secretValuePrefixes: [String] = [
        "sk-", "sk_live_", "sk_test_", "rk_live_", "rk_test_", "pk_live_", "pk_test_", "whsec_",
        "gsk_", "appl_", "goog_", "amzn_", "strp_", "rcb_", "phc_", "phx_",
        "sb_secret_", "sb_publishable_", "AIza", "eyJ", "ghp_", "gho_", "github_pat_",
    ]

    /// Key fragments (lowercased, non-alphanumerics removed) naming secure
    /// fields. Analytics classifies stripped keys with them; the crash
    /// redactor drops any key that contains one.
    static let secureKeyFragments = [
        "key", "token", "secret", "password", "passwd", "authorization", "bearer", "session",
        "cookie", "credential", "dsn", "jwt", "otp",
    ]
    /// Analytics' personal-data key classes (11.07). The crash redactor uses
    /// `NativeErrorRedaction.personalDataKeyFragments`, a narrower list that
    /// keeps `message`, `text` and `name` usable (see there).
    static let personalDataKeyFragments = [
        "email", "phone", "name", "address", "street", "zip", "postal", "note", "message", "body",
        "text", "review", "comment", "customer", "contact", "sms",
    ]
    /// Analytics' document key classes (11.07).
    static let documentKeyFragments = [
        "pdf", "image", "photo", "picture", "receipt", "bytes", "base64", "data", "csv", "export",
        "file", "attachment", "document", "uri", "url", "blob",
    ]

    static let asciiLetters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ")
    static let asciiDigits = CharacterSet(charactersIn: "0123456789")
    /// Characters a plain identifier may contain: internal ids
    /// (`1727190000000k3j9x`, UUIDs, `labor_overrun:<id>`,
    /// `low_margin_estimate:<id>:1234.5`, `open_slot:2026-09-24`). Analytics
    /// forwards to this set for catalog `string` values.
    static let identifierCharacters = asciiLetters.union(asciiDigits).union(CharacterSet(charactersIn: "_-.:"))

    /// A whole value that is (or starts with) a credential.
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

    /// A plain internal identifier (a Supabase user id, a record id): at most
    /// `maxBytes`, identifier characters only, and not a credential, email or
    /// phone number.
    static func isPlainIdentifier(_ text: String, maxBytes: Int = 128) -> Bool {
        guard !text.isEmpty, text.utf8.count <= maxBytes,
              text.unicodeScalars.allSatisfy(identifierCharacters.contains),
              !containsSecret(text), !isPhoneLike(text)
        else { return false }
        return true
    }

    /// Lowercased with every non-alphanumeric removed, so `access_token`,
    /// `Access-Token` and `accessToken` all compare as `accesstoken`.
    static func normalizedKey(_ key: String) -> String {
        String(key.lowercased().unicodeScalars.filter { asciiLetters.contains($0) || asciiDigits.contains($0) })
    }
}

// MARK: - Payloads (Foundation mirrors of the SDK objects)

/// The parts of a crash-reporter event that can carry app data. The Sentry
/// adapter copies an SDK event into this shape, runs `NativeErrorRedaction`,
/// and writes the result back. Anything not modeled here (stack frames,
/// debug images, SDK metadata) holds code addresses and SDK facts only.
struct NativeCrashEventPayload {
    struct Exception {
        var type: String?
        var value: String?
        var mechanismDescription: String?
        var mechanismData: [String: Any]?
    }

    struct Request {
        var url: String?
        var method: String?
        var headers: [String: String]?
        var cookies: String?
        var queryString: String?
        var fragment: String?
        var bodySize: Int?
    }

    struct User {
        var id: String?
        var email: String?
        var username: String?
        var ipAddress: String?
        var name: String?
        var data: [String: Any]?
    }

    var message: String?
    var exceptions: [Exception] = []
    var extras: [String: Any] = [:]
    var tags: [String: String] = [:]
    var contexts: [String: [String: Any]] = [:]
    var breadcrumbs: [NativeCrashBreadcrumbPayload] = []
    var request: Request?
    var user: User?
    var serverName: String?
    var transaction: String?

    /// A JSON view of everything above, for tests and diagnostics.
    var jsonObject: [String: Any] {
        var object: [String: Any] = [:]
        object["message"] = message
        object["exceptions"] = exceptions.map { exception -> [String: Any] in
            var entry: [String: Any] = [:]
            entry["type"] = exception.type
            entry["value"] = exception.value
            entry["mechanismDescription"] = exception.mechanismDescription
            entry["mechanismData"] = exception.mechanismData
            return entry
        }
        object["extras"] = extras
        object["tags"] = tags
        object["contexts"] = contexts
        object["breadcrumbs"] = breadcrumbs.map(\.jsonObject)
        if let request {
            var entry: [String: Any] = [:]
            entry["url"] = request.url
            entry["method"] = request.method
            entry["headers"] = request.headers
            entry["cookies"] = request.cookies
            entry["queryString"] = request.queryString
            entry["fragment"] = request.fragment
            entry["bodySize"] = request.bodySize
            object["request"] = entry
        }
        if let user {
            var entry: [String: Any] = [:]
            entry["id"] = user.id
            entry["email"] = user.email
            entry["username"] = user.username
            entry["ipAddress"] = user.ipAddress
            entry["name"] = user.name
            entry["data"] = user.data
            object["user"] = entry
        }
        object["serverName"] = serverName
        object["transaction"] = transaction
        return object
    }
}

struct NativeCrashBreadcrumbPayload {
    var category: String
    var type: String?
    var message: String?
    var data: [String: Any]?

    var jsonObject: [String: Any] {
        var object: [String: Any] = ["category": category]
        object["type"] = type
        object["message"] = message
        object["data"] = data
        return object
    }
}

// MARK: - The redactor

/// `beforeSend` / `beforeBreadcrumb` / `beforeSendSpan` policy (§10.2):
/// - request bodies, headers, cookies, query strings and fragments are dropped;
/// - URLs keep scheme, host and path, minus token-bearing path segments;
/// - a key in the §10.1 deny table is dropped wherever it appears
///   (case-insensitive, at any depth of nested dictionaries and arrays);
/// - strings are scrubbed of emails, phone numbers, bearer/authorization
///   values, credential-prefixed tokens, JWTs, `key=value` secrets, data URIs
///   and long base64 runs, then capped at `maxStringBytes`;
/// - `Data` values (document bytes) and non-JSON objects are dropped;
/// - extras are allow-listed (§10.3) and `rawError` keeps `{code, message, hint}`;
/// - the user is `{id}` only, and only when the id is a plain identifier.
struct NativeErrorRedaction {
    static let standard = NativeErrorRedaction()

    /// §10.2: each string is capped at 1 KB (UTF-8 bytes, cut on a character
    /// boundary; the cut text ends with `…`).
    static let maxStringBytes = 1_024
    static let maxDepth = 8
    static let maxArrayCount = 100

    static let filtered = "[Filtered]"
    static let filteredEmail = "[email]"
    static let filteredPhone = "[phone]"
    static let filteredDocument = "[document]"
    /// Placeholders a URL path can already hold from an earlier pass
    /// (breadcrumbs pass `beforeBreadcrumb`, then `beforeSend`). They are kept
    /// as is, so redacting twice gives the same text as redacting once.
    static let pathPlaceholders: Set<String> = [filtered, filteredEmail, filteredPhone]

    /// §10.3 native narrowing: the only extra keys that pass.
    static let allowedExtraKeys: Set<String> = [
        "context", "operation", "collection", "status", "code", "count", "jobId", "invoiceId",
        "componentStack", "rawError",
    ]
    /// §10.3: the reduced `rawError` shape.
    static let rawErrorKeys = ["code", "message", "hint"]

    /// Crash-redactor personal-data fragments. Narrower than analytics':
    /// `message` is omitted because `rawError.message` is allowed (§10.3) and
    /// SDK breadcrumbs use it for their own text; `text` would match the
    /// allow-listed `context`; `name` is handled by `personalNameKeys`.
    /// Their values are still pattern-scrubbed.
    static let personalDataKeyFragments = [
        "email", "phone", "mobile", "customer", "contact", "address", "street", "postal", "zipcode",
        "note", "comment", "review", "sms", "body", "payload", "recipient", "signature",
        "firstname", "lastname", "fullname", "username", "displayname", "devicename", "ownername",
        "businessname", "companyname", "latitude", "longitude", "geo",
    ]
    /// Document bytes and exports (§10.1).
    static let documentKeyFragments = [
        "pdf", "image", "photo", "picture", "receipt", "bytes", "base64", "csv", "attachment",
        "document", "blob", "export", "filepath", "filename",
    ]
    /// Money is denied outside the analytics catalog (§10.1 "deny in extras").
    static let moneyKeyFragments = ["amount", "balance", "total", "price", "payment"]
    /// Request parts that carry tokens or bodies.
    static let requestKeyFragments = ["query", "fragment", "header"]
    /// Keys denied only when they are the whole (normalized) key.
    static let exactDenyKeys: Set<String> = ["data", "name", "text", "request", "response"]
    /// SDK contexts whose bare `name` is the platform (`iOS`, `Swift`), not a person.
    static let contextsAllowingBareName: Set<String> = ["os", "runtime", "browser"]

    /// Hosts whose whole path is a payment handle or a payment token
    /// (§10.1 "payment-link URLs with tokens", `providerKeys` handles).
    static let paymentHosts: [String] = [
        "buy.stripe.com", "checkout.stripe.com", "billing.stripe.com", "invoice.stripe.com",
        "pay.stripe.com", "connect.stripe.com", "paypal.me", "paypal.com", "venmo.com", "cash.app",
        "square.link", "squareup.com", "square.site",
    ]
    /// A path segment after one of these is a capability token. For a custom
    /// scheme (`tradeready://portal/<token>`) the host is checked as the first
    /// path segment.
    static let tokenPathMarkers: Set<String> = [
        "portal", "booking", "book", "token", "tokens", "t", "p", "pay", "invite", "reset",
        "reset-password", "verify", "confirm", "approve", "approval", "e", "sign", "s", "r", "l",
        "link", "links", "manage", "respond",
    ]
    /// Schemes whose host is a network host, never a route name.
    static let networkSchemes: Set<String> = ["http", "https", "ws", "wss"]

    // MARK: Keys

    /// True when `key` names a §10.1 deny-table field.
    func isDeniedKey(_ key: String, allowBareName: Bool = false) -> Bool {
        let normalized = NativeSensitiveData.normalizedKey(key)
        guard !normalized.isEmpty else { return false }
        if normalized == "name" { return !allowBareName }
        if Self.exactDenyKeys.contains(normalized) { return true }
        let fragments = NativeSensitiveData.secureKeyFragments + Self.personalDataKeyFragments
            + Self.documentKeyFragments + Self.moneyKeyFragments + Self.requestKeyFragments
        return fragments.contains(where: normalized.contains)
    }

    // MARK: Strings

    func redactString(_ text: String) -> String {
        var result = text
        result = Self.replace(Self.dataURIPattern, in: result) { _ in Self.filteredDocument }
        result = Self.replace(Self.urlPattern, in: result) { redactURL($0) }
        result = Self.replace(Self.bearerPattern, in: result) { _ in "Bearer \(Self.filtered)" }
        result = Self.replace(Self.headerSecretPattern, in: result, template: "$1: \(Self.filtered)")
        result = Self.replace(Self.keyValueSecretPattern, in: result, template: "$1=\(Self.filtered)")
        result = Self.replace(Self.jwtPattern, in: result) { _ in Self.filtered }
        result = Self.replace(Self.secretPrefixPattern, in: result) { _ in Self.filtered }
        result = Self.replace(Self.emailPattern, in: result) { _ in Self.filteredEmail }
        result = Self.replace(Self.base64Pattern, in: result) { _ in Self.filteredDocument }
        result = Self.redactPhones(in: result)
        return Self.capped(result)
    }

    /// Scheme, host and path only: no user info, query or fragment. Payment
    /// hosts lose their whole path; elsewhere a token-bearing segment (after a
    /// capability marker such as `portal`, or token-shaped itself) is filtered.
    /// A custom scheme's host is a route name, so it counts as the segment
    /// before the path (`tradeready://portal/<token>`). Idempotent: a path
    /// placeholder from an earlier pass is kept as is.
    func redactURL(_ text: String) -> String {
        // Placeholders hold `[` and `]`, which are not legal in a URL path;
        // encode them so a second pass parses the same URL the first pass built.
        var parseable = text
        for placeholder in Self.pathPlaceholders {
            let encoded = placeholder.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? placeholder
            parseable = parseable.replacingOccurrences(of: placeholder, with: encoded)
        }
        guard let components = URLComponents(string: parseable), let scheme = components.scheme else {
            return Self.filtered
        }
        let host = (components.host ?? "").lowercased()
        var rebuilt = "\(scheme)://\(host)"
        if let port = components.port { rebuilt += ":\(port)" }
        let segments = components.path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        let isPaymentHost = Self.paymentHosts.contains { host == $0 || host.hasSuffix(".\($0)") }
        if isPaymentHost {
            if components.path.count > 1 { rebuilt += "/\(Self.filtered)" }
            return rebuilt
        }
        var previous = Self.networkSchemes.contains(scheme.lowercased()) ? "" : host
        var path: [String] = []
        for segment in segments {
            if segment.isEmpty { path.append(segment); continue }
            let decoded = segment.removingPercentEncoding ?? segment
            if Self.pathPlaceholders.contains(decoded) {
                path.append(decoded)
            } else if Self.tokenPathMarkers.contains(previous.lowercased()) || Self.isTokenShaped(decoded) {
                path.append(Self.filtered)
            } else {
                path.append(Self.scrubPathSegment(decoded))
            }
            previous = decoded
        }
        rebuilt += path.joined(separator: "/")
        return rebuilt
    }

    /// A capability token in a path: a credential prefix, a JWT, or 20+
    /// URL-safe characters mixing letters and digits that is not a UUID
    /// (record ids are UUIDs or `Date.now()`-prefixed ids, which are allowed).
    static func isTokenShaped(_ segment: String) -> Bool {
        if NativeSensitiveData.containsSecret(segment) { return true }
        let scalars = segment.unicodeScalars
        guard scalars.count >= 20 else { return false }
        let urlSafe = NativeSensitiveData.asciiLetters.union(NativeSensitiveData.asciiDigits)
            .union(CharacterSet(charactersIn: "-_"))
        guard scalars.allSatisfy(urlSafe.contains) else { return false }
        if UUID(uuidString: segment) != nil { return false }
        let hasLetter = scalars.contains { NativeSensitiveData.asciiLetters.contains($0) }
        let hasDigit = scalars.contains { NativeSensitiveData.asciiDigits.contains($0) }
        return hasLetter && hasDigit
    }

    private static func scrubPathSegment(_ segment: String) -> String {
        if segment.contains("@") { return filteredEmail }
        if NativeSensitiveData.isPhoneLike(segment) { return filteredPhone }
        return segment.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? filtered
    }

    // MARK: Values and dictionaries

    /// A redacted JSON-safe value, or nil when the value must be dropped.
    func redactValue(_ value: Any, depth: Int = 0) -> Any? {
        guard depth <= Self.maxDepth else { return nil }
        switch value {
        case let string as String:
            return redactString(string)
        case is Data, is NSData:
            return nil
        case let url as URL:
            return redactString(url.absoluteString)
        case let number as NSNumber:
            // Bool, Int and Double bridge here. Non-finite numbers are not JSON.
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return number.boolValue }
            let double = number.doubleValue
            return double.isFinite ? number : nil
        case let dictionary as [String: Any]:
            return redactDictionary(dictionary, depth: depth + 1)
        case let dictionary as [AnyHashable: Any]:
            var stringKeyed: [String: Any] = [:]
            for (key, item) in dictionary { stringKeyed[String(describing: key.base)] = item }
            return redactDictionary(stringKeyed, depth: depth + 1)
        case let array as [Any]:
            return array.prefix(Self.maxArrayCount).compactMap { redactValue($0, depth: depth + 1) }
        case let date as Date:
            return ISO8601DateFormatter().string(from: date)
        case is NSNull:
            return NSNull()
        default:
            // Arbitrary objects can describe themselves with app data.
            return nil
        }
    }

    func redactDictionary(_ dictionary: [String: Any], depth: Int = 0, allowBareName: Bool = false) -> [String: Any] {
        guard depth <= Self.maxDepth else { return [:] }
        var result: [String: Any] = [:]
        for (key, value) in dictionary {
            if isDeniedKey(key, allowBareName: allowBareName) { continue }
            if let redacted = redactValue(value, depth: depth) {
                result[Self.capped(key)] = redacted
            }
        }
        return result
    }

    // MARK: Events

    /// §10.3: only allow-listed extras pass; `rawError` keeps `{code, message, hint}`.
    func redactExtras(_ extras: [String: Any]) -> [String: Any] {
        var result: [String: Any] = [:]
        for (key, value) in extras where Self.allowedExtraKeys.contains(key) {
            if key == "rawError" {
                if let reduced = reduceRawError(value) { result[key] = reduced }
            } else if let redacted = redactValue(value, depth: 1) {
                result[key] = redacted
            }
        }
        return result
    }

    /// `{code, message, hint}` of a PostgREST-style object, each redacted and
    /// capped. Anything else (details, row data, bytes) is dropped.
    func reduceRawError(_ value: Any) -> [String: Any]? {
        guard let object = Self.stringKeyed(value) else { return nil }
        var reduced: [String: Any] = [:]
        for key in Self.rawErrorKeys {
            switch object[key] {
            case let string as String: reduced[key] = redactString(string)
            case let number as NSNumber where CFGetTypeID(number) != CFBooleanGetTypeID() && number.doubleValue.isFinite:
                reduced[key] = number
            default: break
            }
        }
        return reduced.isEmpty ? nil : reduced
    }

    func redactBreadcrumb(_ breadcrumb: NativeCrashBreadcrumbPayload) -> NativeCrashBreadcrumbPayload {
        var result = breadcrumb
        result.category = redactString(breadcrumb.category)
        result.type = breadcrumb.type.map(redactString)
        result.message = breadcrumb.message.map(redactString)
        result.data = breadcrumb.data.map { redactDictionary($0) }
        return result
    }

    func redactEvent(_ event: NativeCrashEventPayload) -> NativeCrashEventPayload {
        var result = NativeCrashEventPayload()
        result.message = event.message.map(redactString)
        result.exceptions = event.exceptions.map { exception in
            NativeCrashEventPayload.Exception(
                type: exception.type.map(redactString),
                value: exception.value.map(redactString),
                mechanismDescription: exception.mechanismDescription.map(redactString),
                mechanismData: exception.mechanismData.map { redactDictionary($0) }
            )
        }
        result.extras = redactExtras(event.extras)
        for (key, value) in event.tags where !isDeniedKey(key) {
            result.tags[Self.capped(key)] = redactString(value)
        }
        for (name, context) in event.contexts where !isDeniedKey(name) {
            result.contexts[Self.capped(name)] = redactDictionary(
                context,
                depth: 1,
                allowBareName: Self.contextsAllowingBareName.contains(name)
            )
        }
        result.breadcrumbs = event.breadcrumbs.map(redactBreadcrumb)
        if let request = event.request {
            // Bodies, headers (Authorization), cookies, query and fragment never leave.
            result.request = .init(
                url: request.url.map(redactURL),
                method: request.method.map(redactString),
                headers: nil,
                cookies: nil,
                queryString: nil,
                fragment: nil,
                bodySize: request.bodySize
            )
        }
        result.user = event.user.flatMap { redactUser($0) }
        result.serverName = nil // the device name can be a person's name
        result.transaction = event.transaction.map(redactString)
        return result
    }

    /// `{id}` only (§10.2), and only when the id is a plain identifier.
    func redactUser(_ user: NativeCrashEventPayload.User) -> NativeCrashEventPayload.User? {
        guard let id = user.id, NativeSensitiveData.isPlainIdentifier(id) else { return nil }
        return .init(id: id)
    }

    /// A span's description and data (performance traces sample at 0.2, and
    /// the SDK's HTTP spans carry URLs plus `http.query`).
    func redactSpan(description: String?, data: [String: Any]) -> (description: String?, data: [String: Any]) {
        (description.map(redactString), redactDictionary(data))
    }

    // MARK: Helpers

    static func stringKeyed(_ value: Any) -> [String: Any]? {
        if let object = value as? [String: Any] { return object }
        if let object = value as? [AnyHashable: Any] {
            var result: [String: Any] = [:]
            for (key, item) in object { result[String(describing: key.base)] = item }
            return result
        }
        return nil
    }

    /// Cuts `text` to at most `maxStringBytes` UTF-8 bytes on a character
    /// boundary, ending with `…` when cut.
    static func capped(_ text: String) -> String {
        guard text.utf8.count > maxStringBytes else { return text }
        let ellipsis = "…"
        let budget = maxStringBytes - ellipsis.utf8.count
        var result = ""
        var used = 0
        for character in text {
            let size = String(character).utf8.count
            if used + size > budget { break }
            result.append(character)
            used += size
        }
        return result + ellipsis
    }

    private static func regex(_ pattern: String) -> NSRegularExpression {
        // The patterns are constants; a failure is a programming error caught by the host tests.
        try! NSRegularExpression(pattern: pattern, options: [])
    }

    static let dataURIPattern = regex(#"(?i)\bdata:[a-z0-9.+/-]*(?:;[a-z0-9=.+-]*)*,[^\s"'<>]*"#)
    static let urlPattern = regex(#"(?i)\b[a-z][a-z0-9+.-]*://[^\s"'<>]+"#)
    static let bearerPattern = regex(#"(?i)\bbearer\s+[^\s"',;]+"#)
    static let headerSecretPattern = regex(
        #"(?i)\b(authorization|proxy-authorization|x-api-key|api-key|apikey|cookie|set-cookie)\s*[:=]\s*[^\s"',;]+"#
    )
    static let keyValueSecretPattern = regex(
        #"(?i)\b(access_token|refresh_token|id_token|provider_token|token|api_key|apikey|key|secret|client_secret|password|passwd|code|t)=([^&\s"',;]+)"#
    )
    static let jwtPattern = regex(#"\beyJ[A-Za-z0-9_-]{4,}(?:\.[A-Za-z0-9_-]*){0,2}"#)
    static let secretPrefixPattern: NSRegularExpression = {
        let alternatives = NativeSensitiveData.secretValuePrefixes
            .map(NSRegularExpression.escapedPattern(for:))
            .joined(separator: "|")
        return regex("(?<![A-Za-z0-9])(?:\(alternatives))[A-Za-z0-9_\\-]*")
    }()
    static let emailPattern = regex(#"[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}"#)
    static let base64Pattern = regex(#"[A-Za-z0-9+/]{120,}={0,2}"#)
    static let phoneCandidatePattern = regex(#"\+?\(?\d[\d ().-]{5,}\d"#)
    static let isoDatePattern = regex(#"^\d{4}-\d{2}-\d{2}$"#)

    private static func replace(
        _ pattern: NSRegularExpression,
        in text: String,
        template: String
    ) -> String {
        let range = NSRange(text.startIndex..., in: text)
        return pattern.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: template)
    }

    private static func replace(
        _ pattern: NSRegularExpression,
        in text: String,
        with transform: (String) -> String
    ) -> String {
        let nsText = text as NSString
        let matches = pattern.matches(in: text, options: [], range: NSRange(location: 0, length: nsText.length))
        guard !matches.isEmpty else { return text }
        let result = NSMutableString(string: nsText)
        for match in matches.reversed() {
            result.replaceCharacters(in: match.range, with: transform(nsText.substring(with: match.range)))
        }
        return result as String
    }

    /// Phone numbers anywhere in a string. A candidate counts only when it
    /// stands alone: the token around it holds no letter, `_` or `:` (so ids,
    /// UUIDs, times and `Date.now()`-prefixed ids survive), it is not an ISO
    /// date, and it passes the shared `isPhoneLike` rule.
    private static func redactPhones(in text: String) -> String {
        let nsText = text as NSString
        let matches = phoneCandidatePattern.matches(in: text, options: [], range: NSRange(location: 0, length: nsText.length))
        guard !matches.isEmpty else { return text }
        let tokenCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_:./"))
        let blocking = CharacterSet.letters.union(CharacterSet(charactersIn: "_:"))
        let result = NSMutableString(string: nsText)
        for match in matches.reversed() {
            var start = match.range.location
            var end = match.range.location + match.range.length
            while start > 0, let scalar = UnicodeScalar(nsText.character(at: start - 1)), tokenCharacters.contains(scalar) {
                start -= 1
            }
            while end < nsText.length, let scalar = UnicodeScalar(nsText.character(at: end)), tokenCharacters.contains(scalar) {
                end += 1
            }
            let token = nsText.substring(with: NSRange(location: start, length: end - start))
            if token.unicodeScalars.contains(where: blocking.contains) { continue }
            let candidate = nsText.substring(with: match.range).trimmingCharacters(in: .whitespaces)
            let candidateRange = NSRange(candidate.startIndex..., in: candidate)
            if isoDatePattern.firstMatch(in: candidate, options: [], range: candidateRange) != nil { continue }
            guard NativeSensitiveData.isPhoneLike(candidate) else { continue }
            result.replaceCharacters(in: match.range, with: filteredPhone)
        }
        return result as String
    }
}

// MARK: - reportError parity (§10.3; RN `utils/analytics.ts:41-78`)

/// The titled error that wraps a non-`Error` value, so the issue title carries
/// the real message instead of "Object captured as exception". Sentry reads
/// `NSDebugDescriptionErrorKey` into the exception value, and the domain is
/// the exception type.
struct NativeReportedError: Error, CustomNSError, Equatable {
    static let errorDomain = "TradeReady.ReportedError"
    let title: String
    var errorCode: Int { 0 }
    var errorUserInfo: [String: Any] { [NSDebugDescriptionErrorKey: title] }
}

/// One report, ready for the adapter: the error to capture, the allow-listed
/// and redacted extras, and the grouping fingerprint.
struct NativeCrashReport {
    let error: Error
    let extras: [String: Any]
    /// `{{ default }}` plus the `context` value. The adapter captures off the
    /// calling thread (so a slow SDK never blocks a save), which makes every
    /// captured stack look alike; the context keeps call sites apart, like
    /// RN's per-site stacks.
    let fingerprint: [String]

    var title: String? { (error as? NativeReportedError)?.title }
}

enum NativeCrashReportBuilder {
    /// RN `describeNonError`: `"[<code>] <message>"` when `message` is a
    /// non-empty string and `code` a string or number, else `<message>`;
    /// otherwise `JSON.stringify(value)`, else `String(value)`.
    ///
    /// Native narrowing (recorded in contract §10.3): the JSON form is built
    /// from the value *after* `redactValue`, so a denied key (a customer
    /// name, a token, bytes) never reaches the title; and a value that is not
    /// JSON (a struct or class) is described by its type name only, because
    /// Swift's `String(describing:)` prints every stored field, unlike JS's
    /// `"[object Object]"`. The caller redacts the returned string.
    static func describeNonError(_ value: Any?, redaction: NativeErrorRedaction = .standard) -> String {
        if let value, let object = NativeErrorRedaction.stringKeyed(value),
           let message = object["message"] as? String, !message.isEmpty {
            switch object["code"] {
            case let code as String:
                return "[\(code)] \(message)"
            case let code as NSNumber where CFGetTypeID(code) != CFBooleanGetTypeID():
                return "[\(code.stringValue)] \(message)"
            default:
                return message
            }
        }
        guard let value else { return "null" }
        if value is NSNull { return "null" }
        let isJSONShaped = value is String || value is NSNumber
            || NativeErrorRedaction.stringKeyed(value) != nil || value is [Any]
        if isJSONShaped, let reduced = redaction.redactValue(value),
           let data = try? JSONSerialization.data(withJSONObject: reduced, options: [.sortedKeys, .fragmentsAllowed]),
           let json = String(data: data, encoding: .utf8) {
            return json
        }
        return "Non-error value of type \(type(of: value))"
    }

    /// RN `reportError(error, context)`: an `Error` is captured as is;
    /// anything else is wrapped in a titled `NativeReportedError`, with the
    /// original reduced to `rawError` (§10.3). The context becomes extras.
    static func report(
        _ value: Any?,
        context: [String: Any],
        redaction: NativeErrorRedaction = .standard
    ) -> NativeCrashReport {
        var extras = context
        let error: Error
        if let thrown = value as? Error {
            error = thrown
        } else {
            error = NativeReportedError(title: redaction.redactString(describeNonError(value, redaction: redaction)))
            if let value, !(value is NSNull) { extras["rawError"] = value }
        }
        let redacted = redaction.redactExtras(extras)
        let site = (redacted["context"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "unspecified"
        return NativeCrashReport(error: error, extras: redacted, fingerprint: ["{{ default }}", site])
    }
}

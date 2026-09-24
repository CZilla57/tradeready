import Foundation

// Task 11.09 (contract §10.2–§10.3, C12, C18): crash reporting behind a
// Foundation-only seam. The Sentry SDK is imported only by
// `NativeCrashReportingSentry.swift` (app target only); host tests drive
// `NativeCrashReporter` through a fake `NativeCrashReportingSDKAdapter`.

// MARK: - Options (§10.2)

/// Every Sentry option §10.2 fixes. The adapter copies these onto the SDK's
/// `Options` one to one; host tests assert them on the fake adapter.
struct NativeCrashReportingOptions: Equatable, Sendable {
    let dsn: String
    let environment: String
    let releaseName: String
    /// RN `tracesSampleRate: 0.2` (`App.tsx:108-113`): performance traces.
    var tracesSampleRate: Double = 0.2
    /// Release health (sessions). A separate setting from traces; the Phase 12
    /// crash-free-sessions metric depends on it.
    var enableAutoSessionTracking = true
    var sendDefaultPii = false
    var attachScreenshot = false
    var attachViewHierarchy = false
    var sessionReplaySessionSampleRate: Float = 0
    var sessionReplayOnErrorSampleRate: Float = 0
    /// Failed-request events carry URLs that can hold portal/booking tokens.
    var enableCaptureFailedRequests = false
    var debug = false
}

// MARK: - Gate (§10.2)

/// Crash reporting is enabled iff all hold (RN `App.tsx:103-114`):
/// 1. a non-Debug build (RN `enabled: !__DEV__`);
/// 2. `TradeReadySentryDSN` (Info.plist, from `TRADEREADY_SENTRY_DSN`) is
///    non-empty after trimming and is not an unexpanded `$(...)` reference;
/// 3. the DSN does not start with `PLACEHOLDER`;
/// 4. the DSN is an `https` URL with a public key and a project path (a
///    malformed DSN disables reporting rather than failing inside the SDK).
///
/// Neither committed build configuration sets `TRADEREADY_SENTRY_DSN`; the RN
/// DSN (`app.json:100`) is not copied, so both builds report nothing until a
/// release supplies one at build time.
enum NativeCrashReportingGate {
    enum DisabledReason: String, Equatable, Sendable {
        case debugBuild = "disabled_debug_build"
        case missingDSN = "disabled_missing_dsn"
        case placeholderDSN = "disabled_placeholder_dsn"
        case invalidDSN = "disabled_invalid_dsn"
        case adapterSetupFailed = "adapter_setup_failed"
    }

    enum Resolution: Equatable, Sendable {
        case enabled(NativeCrashReportingOptions)
        case disabled(DisabledReason)
    }

    static let dsnInfoKey = "TradeReadySentryDSN"
    static let placeholderPrefix = "PLACEHOLDER"

    static var isDebugBuild: Bool {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }

    /// `<bundle id>@<CFBundleShortVersionString>+<CFBundleVersion>` (§10.2),
    /// the same shape the SDK derives by default.
    static func releaseName(bundleID: String?, shortVersion: String?, build: String?) -> String {
        func part(_ value: String?) -> String {
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return trimmed.isEmpty || trimmed.hasPrefix("$(") ? "unknown" : trimmed
        }
        return "\(part(bundleID))@\(part(shortVersion))+\(part(build))"
    }

    static func resolve(
        isDebugBuild: Bool,
        dsn: String?,
        environment: String,
        releaseName: String
    ) -> Resolution {
        if isDebugBuild { return .disabled(.debugBuild) }
        guard let trimmed = dsn?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty, !trimmed.hasPrefix("$(")
        else { return .disabled(.missingDSN) }
        if trimmed.hasPrefix(placeholderPrefix) { return .disabled(.placeholderDSN) }
        guard isWellFormedDSN(trimmed) else { return .disabled(.invalidDSN) }
        return .enabled(NativeCrashReportingOptions(dsn: trimmed, environment: environment, releaseName: releaseName))
    }

    static func isWellFormedDSN(_ dsn: String) -> Bool {
        guard let components = URLComponents(string: dsn),
              components.scheme?.lowercased() == "https",
              let host = components.host, !host.isEmpty,
              let publicKey = components.user, !publicKey.isEmpty,
              components.query == nil, components.fragment == nil,
              components.path.count > 1
        else { return false }
        return true
    }

    /// Only an `.enabled` resolution builds and starts an SDK adapter. A
    /// disabled gate or a failed start yields a reporter that sends nothing;
    /// either way one bounded setup diagnostic is reported and nothing crashes.
    static func makeReporter(
        resolution: Resolution,
        makeAdapter: () throws -> NativeCrashReportingSDKAdapter,
        redaction: NativeErrorRedaction = .standard,
        diagnostics: @escaping NativeCrashReporter.DiagnosticSink = { _ in },
        queue: DispatchQueue = NativeCrashReporter.makeQueue()
    ) -> NativeCrashReporter {
        var adapter: NativeCrashReportingSDKAdapter?
        switch resolution {
        case .disabled(let reason):
            diagnostics(reason.rawValue)
        case .enabled(let options):
            do {
                let candidate = try makeAdapter()
                try candidate.start(options: options, redaction: redaction)
                adapter = candidate
            } catch {
                diagnostics(DisabledReason.adapterSetupFailed.rawValue)
            }
        }
        return NativeCrashReporter(adapter: adapter, redaction: redaction, diagnostics: diagnostics, queue: queue)
    }
}

// MARK: - Seams

/// The seam to the crash-reporting SDK. Foundation-only so host tests fake
/// it. Methods may throw; the reporter swallows every failure.
protocol NativeCrashReportingSDKAdapter: AnyObject {
    /// Starts the SDK with exactly `options`, installing `redaction` as the
    /// `beforeSend`, `beforeBreadcrumb` and `beforeSendSpan` hooks.
    func start(options: NativeCrashReportingOptions, redaction: NativeErrorRedaction) throws
    func capture(_ report: NativeCrashReport) throws
    /// `{id}` only, or nil to clear (§9.4, §10.2).
    func setUser(id: String?) throws
}

/// What `AppStore` (and later call sites) see. Never throws, never blocks.
protocol NativeCrashReporting: AnyObject {
    /// RN `reportError(error, context)` (§10.3): an `Error` is captured as is;
    /// any other value is wrapped in a titled `NativeReportedError`.
    func reportError(_ value: Any?, context: [String: Any])
    /// RN `Sentry.setUser({id})` / `Sentry.setUser(null)` (§9.4).
    func setUser(id: String?)
}

extension NativeCrashReporting {
    func reportError(_ value: Any?, context: String) {
        reportError(value, context: ["context": context])
    }
}

/// The default for every `AppStore` that is not the app's: reports nothing.
final class NativeNoOpCrashReporting: NativeCrashReporting {
    func reportError(_ value: Any?, context: [String: Any]) {}
    func setUser(id: String?) {}
}

// MARK: - Reporter

/// The production `NativeCrashReporting`. Reports are built (wrapped, allow-
/// listed, redacted) and handed to the adapter on a private serial queue, so
/// neither a throwing nor a slow SDK can block or roll back a save; order
/// between `setUser` and `reportError` is kept, so a reset always lands
/// before the next owner's first report. With no adapter (Debug, a missing,
/// `PLACEHOLDER` or malformed DSN, a failed start) it does nothing at all.
final class NativeCrashReporter: NativeCrashReporting, @unchecked Sendable {
    typealias DiagnosticSink = (String) -> Void

    private let adapter: NativeCrashReportingSDKAdapter?
    private let redaction: NativeErrorRedaction
    private let diagnostics: DiagnosticSink
    private let queue: DispatchQueue

    static func makeQueue() -> DispatchQueue {
        DispatchQueue(label: "com.tradeready.native.crash-reporting", qos: .utility)
    }

    init(
        adapter: NativeCrashReportingSDKAdapter?,
        redaction: NativeErrorRedaction = .standard,
        diagnostics: @escaping DiagnosticSink = { _ in },
        queue: DispatchQueue = NativeCrashReporter.makeQueue()
    ) {
        self.adapter = adapter
        self.redaction = redaction
        self.diagnostics = diagnostics
        self.queue = queue
    }

    /// True only when a started SDK adapter is attached.
    var isReporting: Bool { adapter != nil }

    func reportError(_ value: Any?, context: [String: Any]) {
        guard let adapter else { return }
        let redaction = redaction
        let diagnostics = diagnostics
        let box = UncheckedBox((value, context))
        queue.async {
            let report = NativeCrashReportBuilder.report(box.value.0, context: box.value.1, redaction: redaction)
            do {
                try adapter.capture(report)
            } catch {
                diagnostics("capture_failed")
            }
        }
    }

    func setUser(id: String?) {
        guard let adapter else { return }
        // Only a plain identifier is ever sent; anything else clears the user.
        let sanitized = id.flatMap { NativeSensitiveData.isPlainIdentifier($0) ? $0 : nil }
        if id != nil, sanitized == nil { diagnostics("invalid_user_id") }
        let diagnostics = diagnostics
        queue.async {
            do {
                try adapter.setUser(id: sanitized)
            } catch {
                diagnostics("set_user_failed")
            }
        }
    }

    /// Blocks until every queued adapter call has run (tests; never on a save path).
    func waitUntilIdle() {
        queue.sync {}
    }
}

/// Carries the caller's `Any` values onto the reporting queue. The reporter
/// only reads them there.
private struct UncheckedBox<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}

import Foundation
import os
#if canImport(Sentry)
import Sentry
#endif

// Task 11.09 (contract §7, §10.2): the only file that imports the Sentry SDK.
// App target only — the widget extension compiles nothing from this folder's
// root and links no crash-reporting SDK. Host tests never compile this file;
// they drive `NativeCrashReporter` through a fake adapter and test every
// redaction rule on `NativeCrashEventPayload`, which this adapter maps the
// SDK's objects onto and back.

#if canImport(Sentry)
/// Sentry Cocoa (SPM `exactVersion` 9.29.0) behind `NativeCrashReportingSDKAdapter`.
final class NativeSentryCrashReportingAdapter: NativeCrashReportingSDKAdapter {
    struct StartFailed: Error {}

    func start(options configuration: NativeCrashReportingOptions, redaction: NativeErrorRedaction) throws {
        SentrySDK.start { options in
            options.dsn = configuration.dsn
            options.debug = configuration.debug
            options.environment = configuration.environment
            options.releaseName = configuration.releaseName
            // Performance traces (RN `tracesSampleRate: 0.2`).
            options.tracesSampleRate = NSNumber(value: configuration.tracesSampleRate)
            // Release health, a separate setting (Phase 12 crash-free sessions).
            options.enableAutoSessionTracking = configuration.enableAutoSessionTracking
            options.sendDefaultPii = configuration.sendDefaultPii
            options.attachScreenshot = configuration.attachScreenshot
            options.attachViewHierarchy = configuration.attachViewHierarchy
            options.sessionReplay.sessionSampleRate = configuration.sessionReplaySessionSampleRate
            options.sessionReplay.onErrorSampleRate = configuration.sessionReplayOnErrorSampleRate
            options.enableCaptureFailedRequests = configuration.enableCaptureFailedRequests
            options.beforeSend = { event in
                Self.redact(event, with: redaction)
                return event
            }
            options.beforeBreadcrumb = { breadcrumb in
                Self.redact(breadcrumb, with: redaction)
                return breadcrumb
            }
            options.beforeSendSpan = { span in
                let redacted = redaction.redactSpan(description: span.spanDescription, data: span.data)
                span.spanDescription = redacted.description
                for key in span.data.keys where redacted.data[key] == nil {
                    span.removeData(key: key)
                }
                for (key, value) in redacted.data {
                    span.setData(value: value, key: key)
                }
                return span
            }
        }
        guard SentrySDK.isEnabled else { throw StartFailed() }
    }

    func capture(_ report: NativeCrashReport) throws {
        SentrySDK.capture(error: report.error) { scope in
            scope.setExtras(report.extras)
            scope.setFingerprint(report.fingerprint)
        }
    }

    func setUser(id: String?) throws {
        // `{id}` only: no email, username, IP address or name (§10.2).
        SentrySDK.setUser(id.map { User(userId: $0) })
    }

    // MARK: SDK object ↔ payload

    static func redact(_ event: Event, with redaction: NativeErrorRedaction) {
        var payload = NativeCrashEventPayload()
        payload.message = event.message?.formatted
        payload.exceptions = (event.exceptions ?? []).map { exception in
            NativeCrashEventPayload.Exception(
                type: exception.type,
                value: exception.value,
                mechanismDescription: exception.mechanism?.desc,
                mechanismData: exception.mechanism?.data
            )
        }
        payload.extras = event.extra ?? [:]
        payload.tags = event.tags ?? [:]
        payload.contexts = event.context ?? [:]
        payload.breadcrumbs = (event.breadcrumbs ?? []).map(Self.payload)
        if let request = event.request {
            payload.request = .init(
                url: request.url,
                method: request.method,
                headers: request.headers,
                cookies: nil,
                queryString: request.queryString,
                fragment: request.fragment,
                bodySize: request.bodySize?.intValue
            )
        }
        if let user = event.user {
            payload.user = .init(
                id: user.userId,
                email: user.email,
                username: user.username,
                ipAddress: user.ipAddress,
                name: user.name,
                data: user.data
            )
        }
        payload.serverName = event.serverName
        payload.transaction = event.transaction

        let redacted = redaction.redactEvent(payload)

        event.message = redacted.message.map { SentryMessage(formatted: $0) }
        if let exceptions = event.exceptions {
            for (exception, clean) in zip(exceptions, redacted.exceptions) {
                exception.type = clean.type
                exception.value = clean.value
                exception.mechanism?.desc = clean.mechanismDescription
                exception.mechanism?.data = clean.mechanismData
            }
        }
        event.extra = redacted.extras
        event.tags = redacted.tags
        event.context = redacted.contexts
        if let breadcrumbs = event.breadcrumbs {
            for (breadcrumb, clean) in zip(breadcrumbs, redacted.breadcrumbs) {
                Self.apply(clean, to: breadcrumb)
            }
        }
        if let request = event.request, let clean = redacted.request {
            request.url = clean.url
            request.method = clean.method
            request.headers = nil
            request.cookies = nil
            request.queryString = nil
            request.fragment = nil
        }
        event.user = redacted.user?.id.map { User(userId: $0) }
        event.serverName = nil
        event.transaction = redacted.transaction
    }

    static func redact(_ breadcrumb: Breadcrumb, with redaction: NativeErrorRedaction) {
        apply(redaction.redactBreadcrumb(payload(breadcrumb)), to: breadcrumb)
    }

    private static func payload(_ breadcrumb: Breadcrumb) -> NativeCrashBreadcrumbPayload {
        NativeCrashBreadcrumbPayload(
            category: breadcrumb.category,
            type: breadcrumb.type,
            message: breadcrumb.message,
            data: breadcrumb.data
        )
    }

    private static func apply(_ clean: NativeCrashBreadcrumbPayload, to breadcrumb: Breadcrumb) {
        breadcrumb.category = clean.category
        breadcrumb.type = clean.type
        breadcrumb.message = clean.message
        // `setData(value:key:)` replaces the deprecated `data` setter; nil removes a key.
        for key in breadcrumb.data?.keys.map({ $0 }) ?? [] where clean.data?[key] == nil {
            breadcrumb.setData(value: nil, key: key)
        }
        for (key, value) in clean.data ?? [:] {
            breadcrumb.setData(value: value, key: key)
        }
    }
}
#endif

extension NativeCrashReporter {
    private static let logger = Logger(subsystem: "com.tradeready.native", category: "crash-reporting")

    /// The app's reporter: the §10.2 gate over the Info.plist DSN, the Sentry
    /// adapter when enabled, and bounded diagnostics (a fixed reason code,
    /// never a value, user id or error description) to `os.Logger`.
    static func live() -> NativeCrashReporter {
        let info = Bundle.main.infoDictionary ?? [:]
        let resolution = NativeCrashReportingGate.resolve(
            isDebugBuild: NativeCrashReportingGate.isDebugBuild,
            dsn: BuildEnvironment.sentryDSN,
            environment: BuildEnvironment.environment.rawValue,
            releaseName: NativeCrashReportingGate.releaseName(
                bundleID: Bundle.main.bundleIdentifier,
                shortVersion: info["CFBundleShortVersionString"] as? String,
                build: info["CFBundleVersion"] as? String
            )
        )
        return NativeCrashReportingGate.makeReporter(
            resolution: resolution,
            makeAdapter: {
                #if canImport(Sentry)
                return NativeSentryCrashReportingAdapter()
                #else
                throw NativeCrashReportingSDKUnavailable()
                #endif
            },
            diagnostics: { reason in
                logger.debug("crash reporting: \(reason, privacy: .public)")
            }
        )
    }
}

/// Thrown by `live()` when the app was built without the Sentry package; the
/// gate then yields a reporter that sends nothing.
struct NativeCrashReportingSDKUnavailable: Error {}

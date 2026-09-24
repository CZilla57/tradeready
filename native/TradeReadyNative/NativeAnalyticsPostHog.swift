import Foundation
import os
#if canImport(PostHog)
import PostHog
#endif

// Task 11.07 (contract §7, §9.2): the only file that imports the PostHog SDK.
// App target only — the widget extension compiles nothing from this folder's
// root and links no analytics SDK. Host tests never compile this file; they
// drive `NativeAnalyticsTransport` through a fake `NativeAnalyticsSDKAdapter`.

#if canImport(PostHog)
/// PostHog iOS (SPM `exactVersion` 3.81.0) behind `NativeAnalyticsSDKAdapter`.
/// Every call it receives has already passed `NativeAnalyticsPrivacyPolicy`.
final class NativePostHogAnalyticsAdapter: NativeAnalyticsSDKAdapter {
    private let sdk: PostHogSDK

    init(configuration: NativeAnalyticsConfiguration, policy: NativeAnalyticsPrivacyPolicy) {
        let config = PostHogConfig(projectToken: configuration.apiKey, host: configuration.host.absoluteString)
        // §9.2 options (chosen).
        config.captureApplicationLifecycleEvents = true // RN parity
        config.captureScreenViews = false // screens are sent explicitly (§9.3)
        config.captureElementInteractions = false // element-interaction autocapture off
        config.captureSwiftUIElementInteractions = false
        config.rageClickConfig.enabled = false // `$rageclick` is element-interaction autocapture
        config.sessionReplay = false
        config.surveys = false
        config.errorTrackingConfig.autoCapture = false // Sentry (11.09) is the only crash reporter
        // Recorded 11.07 additions (plan §7): nothing below is used by the
        // app, and each would send data the §9.5 catalog does not declare.
        config.capturePushNotificationSubscriptions = false // no APNs token upload
        config.capturePushNotificationOpened = false // no `$push_notification_opened`
        config.preloadFeatureFlags = false // no feature flags in the app
        config.sendFeatureFlagEvent = false
        config.debug = false
        // Defense in depth: only catalog events (already sanitized by the
        // transport) and the SDK events in `permittedSDKEvents` may be queued.
        config.setBeforeSend { event in
            policy.permitsOutgoingEvent(event.event) ? event : nil
        }
        // Flush on background stays the SDK default (§9.2).
        PostHogSDK.shared.setup(config)
        sdk = PostHogSDK.shared
    }

    func capture(_ event: String, properties: [String: NativeAnalyticsValue]) throws {
        // RN sends `undefined` or `{}` for property-less events (§9.5).
        sdk.capture(event, properties: properties.isEmpty ? nil : properties.mapValues(\.jsonObject))
    }

    func identify(_ distinctID: String) throws {
        sdk.identify(distinctID) // the id only: no traits (§9.4)
    }

    func reset() throws {
        sdk.reset()
    }

    func screen(_ name: String) throws {
        sdk.screen(name)
    }
}
#endif

extension NativeAnalyticsTransport {
    private static let logger = Logger(subsystem: "com.tradeready.native", category: "analytics")

    /// The app's transport: the §9.2 gate over the Info.plist values, the
    /// PostHog adapter when enabled, and bounded diagnostics to `os.Logger`
    /// (debug level; the message never holds a property value or user id).
    static func live() -> NativeAnalyticsTransport {
        let policy = NativeAnalyticsPrivacyPolicy.standard
        let resolution = NativeAnalyticsGate.resolve(
            isDebugBuild: NativeAnalyticsGate.isDebugBuild,
            apiKey: BuildEnvironment.postHogAPIKey,
            host: BuildEnvironment.postHogHost
        )
        return NativeAnalyticsGate.makeTransport(
            resolution: resolution,
            makeAdapter: { configuration in
                #if canImport(PostHog)
                return NativePostHogAnalyticsAdapter(configuration: configuration, policy: policy)
                #else
                throw NativeAnalyticsSDKUnavailable()
                #endif
            },
            policy: policy,
            diagnostics: { diagnostic in
                logger.debug("\(diagnostic.message, privacy: .public)")
            }
        )
    }
}

/// Thrown by `live()` when the app was built without the PostHog package; the
/// gate then yields a transport that emits nothing.
struct NativeAnalyticsSDKUnavailable: Error {}

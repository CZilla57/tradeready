import Foundation

/// Phase 18 (Tap to Pay on iPhone, spec §4.1): the reader seam. Everything in
/// the payment flow talks to `NativeCardReader`; only
/// `NativeStripeTerminalCardReader` (stage B, behind
/// `#if canImport(StripeTerminal)`, not yet written) will import the SDK.
/// Until then Release carries only `NativeUnavailableCardReader`.
enum NativeCardReaderState: Equatable {
    case unsupported
    case notConfigured
    case preparing(progress: Double)
    case ready
    case busy
}

enum NativeCardCollectResult: Equatable {
    /// The card was charged. `amountCents` is what Stripe says it collected.
    case succeeded(paymentIntentID: String, amountCents: Int)
    case declined(reason: String)
    case canceled
    case timedOut
}

/// A reader failure that is not a card outcome (SDK or hardware error).
struct NativeCardReaderError: Error, Equatable {
    var message: String
}

@MainActor
protocol NativeCardReader: AnyObject {
    var state: NativeCardReaderState { get }
    /// Connects the on-device reader for `locationId`. First configuration can
    /// take minutes; `state` reports progress while it runs.
    func prepare(locationId: String, merchantName: String) async throws
    /// Presents the system tap UI for the PaymentIntent behind `clientSecret`.
    func collect(clientSecret: String) async throws -> NativeCardCollectResult
    /// Whether this Stripe account has accepted Apple's Tap to Pay terms.
    /// `nil` = unknown. Never stored locally.
    func isAccountLinked() async -> Bool?
}

/// The only reader compiled into Release before stage B: it reports
/// `unsupported` and refuses to collect.
@MainActor
final class NativeUnavailableCardReader: NativeCardReader {
    var state: NativeCardReaderState { .unsupported }
    func prepare(locationId: String, merchantName: String) async throws {
        throw NativeCardReaderError(message: "Tap to Pay on iPhone isn't available in this build.")
    }
    func collect(clientSecret: String) async throws -> NativeCardCollectResult {
        throw NativeCardReaderError(message: "Tap to Pay on iPhone isn't available in this build.")
    }
    func isAccountLinked() async -> Bool? { nil }
}

/// The owner's per-device opt-in (Settings ▸ Payments ▸ Tap to Pay). Per
/// device on purpose: the location permission it leads to is per device too.
struct NativeTapToPayPreference {
    static let key = "tradeready.tapToPay.ownerEnabled"
    var defaults: UserDefaults = .standard
    var isEnabled: Bool {
        get { defaults.bool(forKey: Self.key) }
        nonmutating set { defaults.set(newValue, forKey: Self.key) }
    }
}

/// True only when ALL four hold (spec §4.1). Off by default: no committed
/// configuration sets the Info.plist key, and without the SDK there is no
/// supported device.
struct NativeTapToPayCapability: Equatable {
    /// Info.plist `TradeReadyTapToPayEnabled` (YES).
    var buildFlagEnabled: Bool
    /// `#if canImport(StripeTerminal)` held for this build.
    var sdkLinked: Bool
    /// The runtime device and OS check passed (the reader says so).
    var deviceSupported: Bool
    /// The owner turned Tap to Pay on in Settings.
    var ownerEnabled: Bool

    var isAvailable: Bool { buildFlagEnabled && sdkLinked && deviceSupported && ownerEnabled }
    /// The build and device can do it, whether or not the owner turned it on:
    /// the Settings page (where they turn it on) shows from here.
    var isSupportedHere: Bool { buildFlagEnabled && sdkLinked && deviceSupported }

    static let infoPlistKey = "TradeReadyTapToPayEnabled"

    static var sdkLinkedInThisBuild: Bool {
        #if canImport(StripeTerminal)
        true
        #else
        false
        #endif
    }

    /// The Info.plist value may be a boolean or a build-setting string.
    static func buildFlag(infoDictionary: [String: Any]?) -> Bool {
        switch infoDictionary?[infoPlistKey] {
        case let flag as Bool: return flag
        case let text as String: return ["yes", "true", "1"].contains(text.lowercased())
        default: return false
        }
    }

    @MainActor
    static func current(
        reader: any NativeCardReader,
        preference: NativeTapToPayPreference = NativeTapToPayPreference(),
        infoDictionary: [String: Any]? = Bundle.main.infoDictionary
    ) -> NativeTapToPayCapability {
        NativeTapToPayCapability(
            buildFlagEnabled: buildFlag(infoDictionary: infoDictionary),
            sdkLinked: sdkLinkedInThisBuild,
            deviceSupported: reader.state != .unsupported,
            ownerEnabled: preference.isEnabled)
    }
}

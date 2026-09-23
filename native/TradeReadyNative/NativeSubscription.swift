import Foundation
#if canImport(RevenueCat)
import RevenueCat
#endif

enum NativeSubscriptionPeriod: String, Equatable, Sendable {
    case monthly
    case annual
}

struct NativeSubscriptionTrial: Equatable, Sendable {
    enum Unit: String, Equatable, Sendable {
        case day, week, month, year
    }

    let value: Int
    let unit: Unit

    var badge: String {
        "\(value)-\(unit.rawValue) free trial — no charge until it ends"
    }

    var detail: String {
        let noun = value == 1 ? unit.rawValue : "\(unit.rawValue)s"
        return "No charge for \(value) \(noun). Cancel anytime."
    }
}

struct NativeSubscriptionPackage: Identifiable, Equatable, Sendable {
    let id: String
    let productIdentifier: String
    let period: NativeSubscriptionPeriod
    let localizedPrice: String
    let trial: NativeSubscriptionTrial?
}

struct NativeSubscriptionOffering: Equatable, Sendable {
    let packages: [NativeSubscriptionPackage]

    var preferredPackageID: String? {
        packages.first(where: { $0.period == .annual })?.id ?? packages.first?.id
    }
}

struct NativeSubscriptionEntitlement: Equatable, Sendable {
    let isActive: Bool
    let isTrialing: Bool
}

struct NativeSubscriptionPurchaseResult: Equatable, Sendable {
    let entitlement: NativeSubscriptionEntitlement
    let userCancelled: Bool
}

enum NativeSubscriptionError: LocalizedError, Equatable {
    case invalidConfiguration
    case unavailable
    case unknownPackage

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration:
            "Subscriptions are not configured for this build."
        case .unavailable:
            "Subscription options aren't available right now. This is usually temporary — please try again in a moment."
        case .unknownPackage:
            "That subscription option is no longer available. Refresh the plans and try again."
        }
    }
}

enum NativeSubscriptionGateResolution: Equatable {
    /// Continue to the post-subscription destination. A failed or absent SDK
    /// configuration deliberately uses this path to preserve the React Native
    /// app's existing fail-open behavior for already-paying customers.
    case advance(isTrialing: Bool)
    case paywall(NativeSubscriptionOffering)
    case paywallError(message: String)
}

@MainActor
protocol NativeSubscriptionServing: AnyObject {
    func prepare(appUserID: String, apiKey: String, entitlementID: String) async throws -> NativeSubscriptionEntitlement
    func loadOffering() async throws -> NativeSubscriptionOffering
    func purchase(packageID: String) async throws -> NativeSubscriptionPurchaseResult
    func restore() async throws -> NativeSubscriptionEntitlement
    func logOut() async
}

/// Resolve the subscription boundary without owning any app navigation state.
/// Keeping the policy here makes the fail-open behavior and paywall failure
/// states testable without configuring RevenueCat or touching a real receipt.
@MainActor
func resolveNativeSubscriptionGate(
    appUserID: String,
    apiKey: String?,
    entitlementID: String?,
    service: NativeSubscriptionServing
) async -> NativeSubscriptionGateResolution {
    guard let apiKey, let entitlementID else {
        return .advance(isTrialing: false)
    }

    let entitlement: NativeSubscriptionEntitlement
    do {
        entitlement = try await service.prepare(
            appUserID: appUserID,
            apiKey: apiKey,
            entitlementID: entitlementID
        )
    } catch {
        return .advance(isTrialing: false)
    }

    if entitlement.isActive {
        return .advance(isTrialing: entitlement.isTrialing)
    }
    do {
        return .paywall(try await service.loadOffering())
    } catch {
        return .paywallError(message: nativeSubscriptionMessage(for: error))
    }
}

/// Third-party errors can contain store/account diagnostics that do not belong
/// in UI copy. Only errors defined by our closed boundary are user-displayable.
func nativeSubscriptionMessage(for error: Error) -> String {
    if let error = error as? NativeSubscriptionError {
        return error.localizedDescription
    }
    return NativeSubscriptionError.unavailable.localizedDescription
}

/// RevenueCat is configured only after Supabase independently verifies the
/// account. The Supabase UUID intentionally remains the RevenueCat App User ID:
/// the existing webhook keys subscription rows by that exact stable value.
@MainActor
final class NativeRevenueCatSubscriptionService: NativeSubscriptionServing {
    private var entitlementID: String?

    #if canImport(RevenueCat)
    private var packagesByID: [String: Package] = [:]
    #endif

    func prepare(
        appUserID: String,
        apiKey: String,
        entitlementID: String
    ) async throws -> NativeSubscriptionEntitlement {
        guard !appUserID.isEmpty,
              apiKey.hasPrefix("appl_"),
              !entitlementID.isEmpty
        else { throw NativeSubscriptionError.invalidConfiguration }
        self.entitlementID = entitlementID

        #if canImport(RevenueCat)
        if !Purchases.isConfigured {
            Purchases.configure(withAPIKey: apiKey, appUserID: appUserID)
        } else if Purchases.shared.appUserID != appUserID {
            _ = try await Purchases.shared.logIn(appUserID)
        }
        return entitlement(from: try await Purchases.shared.customerInfo())
        #else
        throw NativeSubscriptionError.unavailable
        #endif
    }

    func loadOffering() async throws -> NativeSubscriptionOffering {
        #if canImport(RevenueCat)
        guard entitlementID != nil else { throw NativeSubscriptionError.invalidConfiguration }
        let offerings = try await Purchases.shared.offerings()
        guard let available = offerings.current?.availablePackages else {
            packagesByID = [:]
            return .init(packages: [])
        }
        let eligible = await Purchases.shared.checkTrialOrIntroDiscountEligibility(
            packages: available
        )
        packagesByID = Dictionary(uniqueKeysWithValues: available.map { ($0.identifier, $0) })
        let packages = available.compactMap { package -> NativeSubscriptionPackage? in
            let period: NativeSubscriptionPeriod
            switch package.packageType {
            case .annual: period = .annual
            case .monthly: period = .monthly
            default: return nil
            }
            let eligibility = eligible[package]?.status
            let canShowTrial = eligibility != .ineligible
            return .init(
                id: package.identifier,
                productIdentifier: package.storeProduct.productIdentifier,
                period: period,
                localizedPrice: package.storeProduct.localizedPriceString,
                trial: canShowTrial ? trial(from: package.storeProduct.introductoryDiscount) : nil
            )
        }
        .sorted { left, right in left.period == .annual && right.period != .annual }
        return .init(packages: packages)
        #else
        throw NativeSubscriptionError.unavailable
        #endif
    }

    func purchase(packageID: String) async throws -> NativeSubscriptionPurchaseResult {
        #if canImport(RevenueCat)
        guard let package = packagesByID[packageID] else {
            throw NativeSubscriptionError.unknownPackage
        }
        let result = try await Purchases.shared.purchase(package: package)
        return .init(
            entitlement: entitlement(from: result.customerInfo),
            userCancelled: result.userCancelled
        )
        #else
        throw NativeSubscriptionError.unavailable
        #endif
    }

    func restore() async throws -> NativeSubscriptionEntitlement {
        #if canImport(RevenueCat)
        return entitlement(from: try await Purchases.shared.restorePurchases())
        #else
        throw NativeSubscriptionError.unavailable
        #endif
    }

    func logOut() async {
        #if canImport(RevenueCat)
        guard Purchases.isConfigured else { return }
        _ = try? await Purchases.shared.logOut()
        packagesByID = [:]
        entitlementID = nil
        #endif
    }

    #if canImport(RevenueCat)
    private func entitlement(from customerInfo: CustomerInfo) -> NativeSubscriptionEntitlement {
        guard let entitlementID,
              let active = customerInfo.entitlements.active[entitlementID]
        else { return .init(isActive: false, isTrialing: false) }
        return .init(isActive: true, isTrialing: active.periodType == .trial)
    }

    private func trial(from discount: StoreProductDiscount?) -> NativeSubscriptionTrial? {
        guard let discount, discount.paymentMode == .freeTrial else { return nil }
        let unit: NativeSubscriptionTrial.Unit
        switch discount.subscriptionPeriod.unit {
        case .day: unit = .day
        case .week: unit = .week
        case .month: unit = .month
        case .year: unit = .year
        @unknown default: return nil
        }
        let total = discount.subscriptionPeriod.value * discount.numberOfPeriods
        guard total > 0 else { return nil }
        return .init(value: total, unit: unit)
    }
    #endif
}

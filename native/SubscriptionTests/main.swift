import Foundation

private enum LeakyStoreError: LocalizedError {
    case failed

    var errorDescription: String? { "private store diagnostic" }
}

@MainActor
private final class SubscriptionServiceStub: NativeSubscriptionServing {
    var preparedUserID: String?
    var preparedAPIKey: String?
    var preparedEntitlementID: String?
    var prepareResult = Result<NativeSubscriptionEntitlement, Error>.success(
        .init(isActive: false, isTrialing: false)
    )
    var offeringResult = Result<NativeSubscriptionOffering, Error>.success(
        .init(packages: [])
    )
    var prepareCallCount = 0
    var offeringCallCount = 0

    func prepare(
        appUserID: String,
        apiKey: String,
        entitlementID: String
    ) async throws -> NativeSubscriptionEntitlement {
        prepareCallCount += 1
        preparedUserID = appUserID
        preparedAPIKey = apiKey
        preparedEntitlementID = entitlementID
        return try prepareResult.get()
    }

    func loadOffering() async throws -> NativeSubscriptionOffering {
        offeringCallCount += 1
        return try offeringResult.get()
    }

    func purchase(packageID: String) async throws -> NativeSubscriptionPurchaseResult {
        throw NativeSubscriptionError.unavailable
    }

    func restore() async throws -> NativeSubscriptionEntitlement {
        throw NativeSubscriptionError.unavailable
    }

    func logOut() async {}
}

@main
struct SubscriptionTests {
    @MainActor
    static func main() async throws {
        var failures = 0
        func expect(_ condition: @autoclosure () -> Bool, _ label: String) {
            if !condition() { failures += 1; print("FAIL: \(label)") }
        }

        let monthly = NativeSubscriptionPackage(
            id: "$rc_monthly",
            productIdentifier: "tradeready.monthly",
            period: .monthly,
            localizedPrice: "$14.99",
            trial: .init(value: 1, unit: .week)
        )
        let annual = NativeSubscriptionPackage(
            id: "$rc_annual",
            productIdentifier: "tradeready.annual",
            period: .annual,
            localizedPrice: "$149.99",
            trial: .init(value: 7, unit: .day)
        )
        let offering = NativeSubscriptionOffering(packages: [monthly, annual])
        expect(offering.preferredPackageID == annual.id,
               "annual package is selected before monthly when both are offered")
        expect(monthly.trial?.badge == "1-week free trial — no charge until it ends"
               && monthly.trial?.detail == "No charge for 1 week. Cancel anytime.",
               "single-period trial copy stays grammatical")
        expect(annual.trial?.detail == "No charge for 7 days. Cancel anytime.",
               "multi-period trial copy stays grammatical")

        let unconfigured = SubscriptionServiceStub()
        let unconfiguredResolution = await resolveNativeSubscriptionGate(
            appUserID: "owner-a",
            apiKey: nil,
            entitlementID: "TradeReady Pro",
            service: unconfigured
        )
        expect(unconfiguredResolution == .advance(isTrialing: false)
               && unconfigured.prepareCallCount == 0,
               "missing client configuration fails open without touching the SDK")

        let unavailable = SubscriptionServiceStub()
        unavailable.prepareResult = .failure(LeakyStoreError.failed)
        let unavailableResolution = await resolveNativeSubscriptionGate(
            appUserID: "owner-a",
            apiKey: "appl_public",
            entitlementID: "TradeReady Pro",
            service: unavailable
        )
        expect(unavailableResolution == .advance(isTrialing: false),
               "entitlement refresh failure preserves established fail-open access")

        let active = SubscriptionServiceStub()
        active.prepareResult = .success(.init(isActive: true, isTrialing: true))
        let activeResolution = await resolveNativeSubscriptionGate(
            appUserID: "owner-b",
            apiKey: "appl_public",
            entitlementID: "TradeReady Pro",
            service: active
        )
        expect(activeResolution == .advance(isTrialing: true)
               && active.offeringCallCount == 0,
               "active trial advances without loading a paywall")
        expect(active.preparedUserID == "owner-b"
               && active.preparedAPIKey == "appl_public"
               && active.preparedEntitlementID == "TradeReady Pro",
               "verified Supabase subject and exact RevenueCat identifiers cross the boundary")

        let inactive = SubscriptionServiceStub()
        inactive.offeringResult = .success(offering)
        let inactiveResolution = await resolveNativeSubscriptionGate(
            appUserID: "owner-c",
            apiKey: "appl_public",
            entitlementID: "TradeReady Pro",
            service: inactive
        )
        expect(inactiveResolution == .paywall(offering)
               && inactive.offeringCallCount == 1,
               "inactive entitlement loads the current offering and blocks on the paywall")

        let brokenOffering = SubscriptionServiceStub()
        brokenOffering.offeringResult = .failure(LeakyStoreError.failed)
        let brokenOfferingResolution = await resolveNativeSubscriptionGate(
            appUserID: "owner-d",
            apiKey: "appl_public",
            entitlementID: "TradeReady Pro",
            service: brokenOffering
        )
        expect(brokenOfferingResolution == .paywallError(
            message: NativeSubscriptionError.unavailable.localizedDescription
        ), "offering failures stay on a retryable paywall with bounded copy")
        expect(!nativeSubscriptionMessage(for: LeakyStoreError.failed).contains("private"),
               "third-party diagnostics are never rendered as paywall copy")

        do {
            _ = try await NativeRevenueCatSubscriptionService().prepare(
                appUserID: "owner-e",
                apiKey: "wrong-key",
                entitlementID: "TradeReady Pro"
            )
            expect(false, "invalid SDK keys fail before configuration")
        } catch NativeSubscriptionError.invalidConfiguration {}

        if failures > 0 {
            print("FAILED: native subscription tests (\(failures) failure(s))")
            Foundation.exit(1)
        }
        print("PASS: native subscription gate tests")
    }
}

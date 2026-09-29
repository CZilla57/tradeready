import Foundation

@main
struct BuildEnvironmentTests {
    static func main() {
        var failures = 0
        func expect(_ condition: @autoclosure () -> Bool, _ label: String) {
            if !condition() { failures += 1; print("FAIL: \(label)") }
        }

        let production = URL(string: "https://production.supabase.co")!
        let staging = URL(string: "https://isolated-staging.supabase.co")!
        let productionKey = "sb_publishable_production"
        let stagingKey = "sb_publishable_staging"

        func permits(
            _ environment: TradeReadyEnvironment,
            _ configuredURL: URL?,
            productionURL: URL? = production,
            configuredKey: String? = stagingKey,
            productionKey: String? = productionKey,
            enabled: Bool = false
        ) -> Bool {
            BuildEnvironment.permitsSupabaseDataWrites(
                environment: environment,
                configuredURL: configuredURL,
                productionURL: productionURL,
                configuredPublishableKey: configuredKey,
                productionPublishableKey: productionKey,
                productionWritesEnabled: enabled
            )
        }

        expect(!permits(.development, production, configuredKey: productionKey),
               "development cannot write to the production Supabase origin")
        expect(!permits(.staging, production, configuredKey: productionKey),
               "staging cannot write to the production Supabase origin")
        expect(!permits(.staging, URL(string: "https://production.supabase.co:443"), configuredKey: productionKey),
               "an explicit default HTTPS port cannot disguise the production origin")
        expect(!permits(.staging, URL(string: "https://production.supabase.co."), configuredKey: productionKey),
               "a trailing DNS dot cannot disguise the production origin")
        expect(permits(.staging, staging),
               "staging can write to a distinct isolated Supabase origin")
        expect(!permits(.staging, staging, configuredKey: productionKey),
               "staging cannot reuse the production publishable key")
        expect(!permits(.production, production, configuredKey: productionKey),
               "production requires the explicit production-write switch")
        expect(permits(.production, production, configuredKey: productionKey, enabled: true),
               "production can write only to its matching origin when explicitly enabled")
        expect(!permits(.production, staging, configuredKey: productionKey, enabled: true),
               "production cannot write to an origin that disagrees with its production reference")
        expect(!permits(.production, production, configuredKey: stagingKey, enabled: true),
               "production cannot write with a key that disagrees with its production reference")
        expect(!permits(.staging, staging, productionURL: nil),
               "a missing production reference fails closed")
        expect(!permits(.staging, staging, productionKey: nil),
               "a missing production publishable-key reference fails closed")
        expect(!permits(.staging, staging, configuredKey: "legacy-or-malformed"),
               "a malformed configured publishable key fails closed")
        expect(!permits(.staging, URL(string: "http://isolated-staging.supabase.co")),
               "a non-HTTPS configured origin fails closed")
        expect(!permits(.staging, URL(string: "https://isolated-staging.supabase.co/rest/v1")),
               "a configured origin with a path fails closed")
        expect(!permits(.staging, staging, productionURL: URL(string: "not a URL")),
               "an invalid production reference fails closed")

        if failures == 0 { print("PASS: build environment tests") }
        else { exit(1) }
    }
}

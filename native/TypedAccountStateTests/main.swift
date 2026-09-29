import CryptoKit
import Foundation

private func framed(_ values: [Data]) -> Data {
    var result = Data()
    for value in values {
        var length = UInt64(value.count).bigEndian
        withUnsafeBytes(of: &length) { result.append(contentsOf: $0) }
        result.append(value)
    }
    return result
}

private func digest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private struct TypedStateBindingProvider: NativeAuxiliaryAccountBindingProviding {
    func keyedBinding(for opaqueSubject: String) throws -> Data {
        Data("typed-state-test:\(opaqueSubject)".utf8)
    }
}

@main
struct TypedAccountStateTests {
    static func main() async throws {
        var failures = 0
        func expect(_ condition: @autoclosure () -> Bool, _ label: String) {
            if !condition() { failures += 1; print("FAIL: \(label)") }
        }

        let owner = "typed-owner"
        let values: [String: Data] = [
            "__dataOwner": try JSONEncoder().encode(owner),
            "onboardingComplete": Data("true".utf8),
            "onboardingStage": Data("personalized".utf8),
            "onboardingDraft": Data(#"{"businessName":"Acme","contactName":"Lee","trade":"hvac","step":2}"#.utf8),
            "setupChecklistState": Data(#"{"dismissed":false,"done":{"rate":true,"stripe":false},"sampleTourDone":true}"#.utf8),
            "review_requests": Data(#"[{"jobId":"j1","customerId":"c1","customerName":"Pat","customerPhone":"555","customerEmail":"p@example.com","scheduledAt":"2026-09-01T00:00:00.000Z","sentAt":null}]"#.utf8),
            "dismissed_duplicate_pairs": Data(#"["a|b","c|d"]"#.utf8),
            "insightMutes": Data(#"[{"id":"overdue-j1","mutedAt":"2026-09-01T00:00:00.000Z"},{"id":"legacy-id-only"}]"#.utf8),
            "invoiceReminderPromptShown": Data("false".utf8),
            "__syncQueue": Data(#"[{"recordId":"must-not-surface"}]"#.utf8),
            "__lastSyncedAt": Data(#""2099-01-01T00:00:00Z""#.utf8)
        ]
        let artifactBytes = try NativeAuxiliaryStateStore.encode(.init(values: values))
        let identity = try NativeVerifiedAuxiliaryIdentity(opaqueSubject: owner)
        let plan = try NativeAuxiliaryActivationPlanner.plan(
            sourceArtifactBytes: artifactBytes,
            identity: identity,
            accountBindingProvider: TypedStateBindingProvider()
        )
        let account = plan.transactions.first { $0.scope == .account }!
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tradeready-typed-state-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try await NativeAuxiliaryActivationStore(rootURL: root).stage(plan)
        let binding = account.accountBinding!
        let envelopeURL = root.appendingPathComponent("Accounts", isDirectory: true)
            .appendingPathComponent("\(binding).json")
        let bytes = try Data(contentsOf: envelopeURL)

        let state = try NativeTypedAccountStateConsumer.decode(
            envelopeBytes: bytes,
            expectedAccountBinding: binding
        )
        expect(state.onboardingComplete == true, "raw onboarding boolean decodes")
        expect(state.onboardingStage == .personalized, "raw onboarding stage decodes")
        expect(state.onboardingDraft?.businessName == "Acme"
               && state.onboardingDraft?.trade == .hvac
               && state.onboardingDraft?.step == 2,
               "onboarding draft decodes to constrained types")
        expect(state.setupChecklistState?.done?.rate == true
               && state.setupChecklistState?.done?.stripe == false
               && state.setupChecklistState?.sampleTourDone == true,
               "setup checklist decodes to explicit task fields")
        expect(state.reviewRequests?.first?.jobId == "j1"
               && state.reviewRequests?.first?.sentAt == nil,
               "review requests preserve pending records")
        expect(state.dismissedDuplicatePairs == ["a|b", "c|d"],
               "dismissed duplicate pairs decode")
        expect(state.insightMutes?.count == 2
               && state.insightMutes?.last?.mutedAt == nil,
               "insight mutes admit the legacy id-only shape")
        expect(state.invoiceReminderPromptShown == false,
               "raw reminder prompt boolean preserves false")

        let loaded = try NativeTypedAccountStateConsumer.load(
            activationRootURL: root,
            accountBinding: binding
        )
        expect(loaded == state, "file consumer reads only the bound account envelope")

        let wrongBinding = String(repeating: "a", count: 64)
        do {
            _ = try NativeTypedAccountStateConsumer.decode(
                envelopeBytes: bytes,
                expectedAccountBinding: wrongBinding
            )
            expect(false, "wrong account binding is rejected")
        } catch NativeTypedAccountStateError.accountBindingMismatch {}

        var envelope = try JSONSerialization.jsonObject(with: bytes) as! [String: Any]
        var entries = envelope["entries"] as! [[String: Any]]
        let completeIndex = entries.firstIndex { $0["key"] as? String == "onboardingComplete" }!
        entries[completeIndex]["value"] = Data("not-a-bool".utf8).base64EncodedString()
        envelope["entries"] = entries
        let tamperedBytes = try JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys])
        do {
            _ = try NativeTypedAccountStateConsumer.decode(
                envelopeBytes: tamperedBytes,
                expectedAccountBinding: binding
            )
            expect(false, "tampered entry bytes are rejected before decoding")
        } catch NativeTypedAccountStateError.invalidEntryDigest {}

        var invalidValues = values
        invalidValues["onboardingStage"] = Data("future-stage".utf8)
        let invalidPlan = try NativeAuxiliaryActivationPlanner.plan(
            sourceArtifactBytes: NativeAuxiliaryStateStore.encode(.init(values: invalidValues)),
            identity: identity,
            accountBindingProvider: TypedStateBindingProvider()
        )
        let invalidRoot = root.appendingPathComponent("invalid", isDirectory: true)
        _ = try await NativeAuxiliaryActivationStore(rootURL: invalidRoot).stage(invalidPlan)
        let invalidBinding = invalidPlan.transactions.first { $0.scope == .account }!.accountBinding!
        let invalidBytes = try Data(contentsOf: invalidRoot
            .appendingPathComponent("Accounts", isDirectory: true)
            .appendingPathComponent("\(invalidBinding).json"))
        do {
            _ = try NativeTypedAccountStateConsumer.decode(
                envelopeBytes: invalidBytes,
                expectedAccountBinding: invalidBinding
            )
            expect(false, "invalid known value fails the complete typed read")
        } catch NativeTypedAccountStateError.invalidValue(let key) {
            expect(key == "onboardingStage", "invalid-value error identifies only the key")
        }

        // The planner keeps sync keys out of activation.
        var syncOnlyValues = values
        for key in [
            "onboardingComplete", "onboardingStage", "onboardingDraft",
            "setupChecklistState", "review_requests", "dismissed_duplicate_pairs",
            "insightMutes", "invoiceReminderPromptShown"
        ] { syncOnlyValues.removeValue(forKey: key) }
        let syncOnlyPlan = try NativeAuxiliaryActivationPlanner.plan(
            sourceArtifactBytes: NativeAuxiliaryStateStore.encode(.init(values: syncOnlyValues)),
            identity: identity,
            accountBindingProvider: TypedStateBindingProvider()
        )
        expect(syncOnlyPlan.transactions.allSatisfy { $0.scope != .account },
               "sync reconciliation keys never enter a staged account envelope")

        // Also authenticate a synthetic future envelope containing a sync key.
        // It must not alter or appear in the typed result.
        var futureEnvelope = try JSONSerialization.jsonObject(with: bytes) as! [String: Any]
        var futureEntries = futureEnvelope["entries"] as! [[String: Any]]
        let syncKey = "__syncQueue"
        let syncValue = Data(#"[{"recordId":"must-not-surface"}]"#.utf8)
        let syncDigest = digest(framed([
            Data("tradeready-aux-entry-v1".utf8), Data(syncKey.utf8), syncValue,
            Data("account".utf8), Data("activateAfterIdentity".utf8)
        ]))
        futureEntries.append([
            "key": syncKey,
            "value": syncValue.base64EncodedString(),
            "digest": syncDigest
        ])
        futureEnvelope["entries"] = futureEntries
        let sourceDigest = futureEnvelope["sourceArtifactSHA256"] as! String
        futureEnvelope["transactionID"] = digest(framed([
            Data("tradeready-aux-transaction-v1".utf8), Data(sourceDigest.utf8),
            Data("account".utf8), Data(binding.utf8)
        ] + futureEntries.map { Data(($0["digest"] as! String).utf8) }))
        let futureBytes = try JSONSerialization.data(withJSONObject: futureEnvelope, options: [.sortedKeys])
        let futureState = try NativeTypedAccountStateConsumer.decode(
            envelopeBytes: futureBytes,
            expectedAccountBinding: binding
        )
        expect(futureState == state,
               "authenticated sync and unknown entries remain unavailable to typed consumers")

        do {
            _ = try NativeTypedAccountStateConsumer.load(
                activationRootURL: root,
                accountBinding: String(repeating: "b", count: 64)
            )
            expect(false, "missing account envelope fails closed")
        } catch NativeTypedAccountStateError.missingEnvelope {}

        if failures > 0 {
            print("FAILED: Typed account-state tests (\(failures) failure(s))")
            Foundation.exit(1)
        }
        print("PASS: Typed account-state tests")
    }
}

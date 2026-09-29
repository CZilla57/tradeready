import Foundation

private struct TestBindingProvider: NativeAuxiliaryAccountBindingProviding {
    let prefix: String
    func keyedBinding(for opaqueSubject: String) throws -> Data {
        Data("\(prefix):\(opaqueSubject)".utf8)
    }
}

private struct EmptyBindingProvider: NativeAuxiliaryAccountBindingProviding {
    func keyedBinding(for opaqueSubject: String) throws -> Data { Data() }
}

@main
struct AuxiliaryActivationTests {
    static func main() async throws {
        var failures = 0
        func expect(_ condition: @autoclosure () -> Bool, _ label: String) {
            if !condition() { failures += 1; print("FAIL: \(label)") }
        }

        let identity = try NativeVerifiedAuxiliaryIdentity(opaqueSubject: "User-A")
        expect(identity.opaqueSubject == "User-A", "identity remains byte-for-byte opaque")
        do {
            _ = try NativeVerifiedAuxiliaryIdentity(opaqueSubject: "")
            expect(false, "empty identity is rejected")
        } catch NativeAuxiliaryActivationError.invalidIdentity {}
        do {
            _ = try NativeVerifiedAuxiliaryIdentity(opaqueSubject: "user\nA")
            expect(false, "control characters are rejected")
        } catch NativeAuxiliaryActivationError.invalidIdentity {}
        let spaced = try NativeVerifiedAuxiliaryIdentity(opaqueSubject: " User-A ")
        expect(spaced.opaqueSubject == " User-A ", "identity is not trimmed")

        var values: [String: Data] = [
            "__themePreference": Data("dark".utf8),
            "onboardingComplete": Data("true".utf8),
            "insightMutes": Data("{\"job-1\":true}".utf8),
            "__syncQueue": Data("[{\"recordId\":\"secret-record\"}]".utf8),
            "__lastSyncedAt": Data("\"2099-01-01\"".utf8),
            "__dataOwner": try JSONEncoder().encode("User-A"),
            "__initDone_User-A": Data("true".utf8),
            "opaque": Data([0xff, 0x00])
        ]
        let artifact = NativeAuxiliaryStateArtifact(values: values)
        let sourceBytes = try NativeAuxiliaryStateStore.encode(artifact)
        let sourceCopy = sourceBytes
        let provider = TestBindingProvider(prefix: "key-one")
        let plan = try NativeAuxiliaryActivationPlanner.plan(
            sourceArtifactBytes: sourceBytes,
            identity: identity,
            accountBindingProvider: provider
        )
        expect(sourceBytes == sourceCopy, "planning leaves exact source artifact bytes unchanged")
        expect(plan.accountDisposition == .staged && plan.transactions.count == 2,
               "valid owner stages device and account transactions")
        let stagedKeys = Set(plan.transactions.flatMap { $0.entries.map(\.key) })
        expect(stagedKeys.contains("__themePreference")
               && stagedKeys.contains("onboardingComplete")
               && stagedKeys.contains("insightMutes"),
               "validated generic entries are staged")
        expect(!stagedKeys.contains("__syncQueue")
               && !stagedKeys.contains("__lastSyncedAt")
               && !stagedKeys.contains("__dataOwner")
               && !stagedKeys.contains("__initDone_User-A")
               && !stagedKeys.contains("opaque"),
               "sync, owner, per-user, and unknown state are excluded")

        let repeatedPlan = try NativeAuxiliaryActivationPlanner.plan(
            sourceArtifactBytes: sourceBytes,
            identity: identity,
            accountBindingProvider: provider
        )
        expect(plan == repeatedPlan, "digests and transaction IDs are deterministic")
        let differentBindingPlan = try NativeAuxiliaryActivationPlanner.plan(
            sourceArtifactBytes: sourceBytes,
            identity: identity,
            accountBindingProvider: TestBindingProvider(prefix: "key-two")
        )
        expect(plan.transactions.first(where: { $0.scope == .account })?.accountBinding
               != differentBindingPlan.transactions.first(where: { $0.scope == .account })?.accountBinding,
               "account namespace depends on injected keyed binding")
        do {
            _ = try NativeAuxiliaryActivationPlanner.plan(
                sourceArtifactBytes: sourceBytes,
                identity: identity,
                accountBindingProvider: EmptyBindingProvider()
            )
            expect(false, "empty keyed binding is rejected")
        } catch NativeAuxiliaryActivationError.invalidAccountBinding {}

        for badOwner in [nil, Data("123".utf8), Data("\"user-a\"".utf8), Data("\"\"".utf8)] {
            var badValues = values
            if let badOwner { badValues["__dataOwner"] = badOwner }
            else { badValues.removeValue(forKey: "__dataOwner") }
            let badBytes = try NativeAuxiliaryStateStore.encode(.init(values: badValues))
            let blocked = try NativeAuxiliaryActivationPlanner.plan(
                sourceArtifactBytes: badBytes,
                identity: identity,
                accountBindingProvider: provider
            )
            expect(blocked.accountDisposition == .identityNotProven
                   && blocked.transactions.allSatisfy { $0.scope == .device },
                   "missing, malformed, empty, or mismatched owner blocks all account entries")
        }

        values["__themePreference"] = Data(" DARK ".utf8)
        let invalidThemePlan = try NativeAuxiliaryActivationPlanner.plan(
            sourceArtifactBytes: NativeAuxiliaryStateStore.encode(.init(values: values)),
            identity: identity,
            accountBindingProvider: provider
        )
        expect(invalidThemePlan.transactions.allSatisfy { $0.scope != .device },
               "theme permits only exact light, dark, or system")

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tradeready-aux-activation-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixedDate = Date(timeIntervalSince1970: 1_800_000_000)
        let store = NativeAuxiliaryActivationStore(rootURL: root, now: { fixedDate })
        let firstOutcome = try await store.stage(plan)
        expect(firstOutcome.newlyStagedCount == 2 && firstOutcome.alreadyStagedCount == 0,
               "first staging atomically publishes both envelopes")
        let receiptURL = root.appendingPathComponent(NativeAuxiliaryActivationStore.receiptFilename)
        let firstReceiptBytes = try Data(contentsOf: receiptURL)
        let receipt = try await store.loadReceipt()
        expect(receipt?.transactions.count == 2
               && receipt?.transactions.allSatisfy { $0.stagedAt == fixedDate } == true,
               "receipt records deterministic staged transactions")
        let receiptText = String(decoding: firstReceiptBytes, as: UTF8.self)
        expect(!receiptText.contains("User-A")
               && !receiptText.contains("secret-record")
               && !receiptText.contains("insightMutes")
               && !receiptText.contains("job-1"),
               "receipt excludes raw account IDs, values, and legacy keys")
        let secondOutcome = try await store.stage(plan)
        let secondReceiptBytes = try Data(contentsOf: receiptURL)
        expect(secondOutcome.newlyStagedCount == 0 && secondOutcome.alreadyStagedCount == 2
               && secondReceiptBytes == firstReceiptBytes,
               "identical retry is a byte-preserving no-op")
        expect(sourceBytes == sourceCopy, "staging also leaves source artifact bytes unchanged")

        let concurrentRoot = root.appendingPathComponent("concurrent", isDirectory: true)
        let concurrentStore = NativeAuxiliaryActivationStore(
            rootURL: concurrentRoot,
            now: { fixedDate }
        )
        async let concurrentFirst = concurrentStore.stage(plan)
        async let concurrentSecond = concurrentStore.stage(plan)
        let concurrentOutcomes = try await [concurrentFirst, concurrentSecond]
        expect(concurrentOutcomes.reduce(0) { $0 + $1.newlyStagedCount } == 2
               && concurrentOutcomes.reduce(0) { $0 + $1.alreadyStagedCount } == 2,
               "actor serialization makes concurrent identical staging idempotent")
        let concurrentReceipt = try await concurrentStore.loadReceipt()
        expect(concurrentReceipt?.transactions.count == 2,
               "concurrent staging cannot lose receipt transactions")

        let conflictPlan = try NativeAuxiliaryActivationPlanner.plan(
            sourceArtifactBytes: NativeAuxiliaryStateStore.encode(.init(values: [
                "__themePreference": Data("light".utf8)
            ])),
            identity: nil,
            accountBindingProvider: provider
        )
        do {
            _ = try await store.stage(conflictPlan)
            expect(false, "different source artifact cannot replace receipt/envelope")
        } catch NativeAuxiliaryActivationError.conflictingReceipt {}
        let receiptBytesAfterConflict = try Data(contentsOf: receiptURL)
        expect(receiptBytesAfterConflict == firstReceiptBytes,
               "conflict leaves existing receipt unchanged")

        let corruptRoot = root.appendingPathComponent("corrupt", isDirectory: true)
        try FileManager.default.createDirectory(at: corruptRoot, withIntermediateDirectories: true)
        try Data("not-json".utf8).write(
            to: corruptRoot.appendingPathComponent(NativeAuxiliaryActivationStore.receiptFilename)
        )
        let corruptStore = NativeAuxiliaryActivationStore(rootURL: corruptRoot)
        do {
            _ = try await corruptStore.stage(plan)
            expect(false, "corrupt receipt fails closed")
        } catch NativeAuxiliaryActivationError.corruptReceipt {}

        let envelopeConflictRoot = root.appendingPathComponent("envelope-conflict", isDirectory: true)
        let accountTransaction = plan.transactions.first { $0.scope == .account }!
        let conflictingAccountURL = envelopeConflictRoot
            .appendingPathComponent("Accounts", isDirectory: true)
            .appendingPathComponent("\(accountTransaction.accountBinding!).json")
        try FileManager.default.createDirectory(
            at: conflictingAccountURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let conflictingBytes = Data("conflicting-envelope".utf8)
        try conflictingBytes.write(to: conflictingAccountURL)
        let envelopeConflictStore = NativeAuxiliaryActivationStore(rootURL: envelopeConflictRoot)
        do {
            _ = try await envelopeConflictStore.stage(plan)
            expect(false, "different existing envelope fails closed")
        } catch NativeAuxiliaryActivationError.conflictingEnvelope {}
        let deviceURL = envelopeConflictRoot
            .appendingPathComponent("auxiliary-activation-device.json")
        let accountBytesAfterConflict = try Data(contentsOf: conflictingAccountURL)
        expect(!FileManager.default.fileExists(atPath: deviceURL.path)
               && accountBytesAfterConflict == conflictingBytes,
               "all envelope conflicts are preflighted before any mutation")

        if failures > 0 {
            print("FAILED: Auxiliary activation tests (\(failures) failure(s))")
            Foundation.exit(1)
        }
        print("PASS: Auxiliary activation tests")
    }
}

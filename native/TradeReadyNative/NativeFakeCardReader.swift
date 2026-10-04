import Foundation

#if DEBUG
/// Phase 18: the scriptable reader for host tests and DEBUG previews (spec
/// §4.1). Compiled out of Release. Every outcome is queued ahead of time;
/// with an empty queue `collect` approves exactly the amount it was told to.
@MainActor
final class NativeFakeCardReader: NativeCardReader {
    enum Outcome {
        case result(NativeCardCollectResult)
        case failure(NativeCardReaderError)
    }

    var state: NativeCardReaderState
    var linked: Bool?
    var prepareFailure: NativeCardReaderError?
    var outcomes: [Outcome] = []
    /// Set before `collect` so the fake can approve the amount the test wants
    /// (the real reader learns it from Stripe).
    var approveAmountCents = 0
    var approvePaymentIntentID = "pi_3Fake000000000001"

    private(set) var prepareCalls: [(locationId: String, merchantName: String)] = []
    private(set) var collectedSecrets: [String] = []

    init(state: NativeCardReaderState = .ready, linked: Bool? = true) {
        self.state = state
        self.linked = linked
    }

    func prepare(locationId: String, merchantName: String) async throws {
        prepareCalls.append((locationId, merchantName))
        if let prepareFailure { throw prepareFailure }
        state = .ready
    }

    func collect(clientSecret: String) async throws -> NativeCardCollectResult {
        collectedSecrets.append(clientSecret)
        if outcomes.isEmpty {
            return .succeeded(paymentIntentID: approvePaymentIntentID, amountCents: approveAmountCents)
        }
        switch outcomes.removeFirst() {
        case .result(let result): return result
        case .failure(let error): throw error
        }
    }

    func isAccountLinked() async -> Bool? { linked }
}
#endif

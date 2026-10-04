import Combine
import Foundation

/// Phase 18 (Tap to Pay, spec §4.2, §4.3): the invoice sheet's state machine,
/// independent of SwiftUI so the host tests drive it with
/// `NativeFakeCardReader` and a fake `NativeTerminalServicing`.
///
/// ONE CHARGE PER OPERATION. The operation id, the amount and the local day
/// are minted together on the first `start` and reused by every retry (so
/// Stripe's idempotency returns the same PaymentIntent). Changing the amount
/// mints a new operation: the Worker rejects one id reused with new details.
/// An approved flow is terminal: `start` does nothing after it, so a double
/// tap cannot charge twice.
@MainActor
final class NativeTapToPayFlow: ObservableObject {
    enum Failure: Equatable {
        case readerUnavailable
        case readerNotReady
        case invoiceMissing
        case amountNotPositive
        case amountExceedsBalance(balanceCents: Int)
        case amountTooLarge
        /// Nothing was charged: the balance fell below the amount while the
        /// PaymentIntent was being created (e.g. the webhook's copy arrived).
        case balanceChanged(balanceCents: Int)
        /// The Worker answered with an amount other than the one asked for.
        case amountMismatch
        case notSynced
        case stripeNotConnected
        case sessionExpired
        case network
        case server
        case reader(String)
    }

    struct Approval: Equatable {
        var paymentIntentID: String
        var amountCents: Int
        /// The device's ledger copy was saved. False means the card WAS
        /// charged but the local save failed; the Worker webhook records it
        /// and the next sync brings it down, or `retryRecording()` saves it.
        var recorded: Bool
        /// The reader reported a different amount than requested (recorded as
        /// charged, never as requested).
        var amountDiffersFromRequest: Bool
    }

    enum Phase: Equatable {
        case idle
        /// Creating the PaymentIntent on the Worker.
        case preparing
        /// The system tap UI is up.
        case collecting
        case approved(Approval)
        case declined(reason: String)
        case canceled
        case timedOut
        case failed(Failure)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var requestedAmountCents = 0

    let invoiceID: String
    private let service: any NativeTerminalServicing
    private let reader: any NativeCardReader
    /// The invoice's live balance in cents, read at the start and again right
    /// before the card is read. nil = the invoice is gone.
    private let balanceCents: @MainActor () -> Int?
    /// Saves the device's ledger entry (`AppStore.recordCardPresentPayment`);
    /// true when saved (or already present).
    private let record: @MainActor (Canonical.Payment) -> Bool
    private let today: () -> String
    private let makeOperationID: () -> String

    private struct Operation {
        var id: String
        var amountCents: Int
        var localDate: String
    }
    private var operation: Operation?
    private var pendingEntry: Canonical.Payment?

    init(
        invoiceID: String,
        service: any NativeTerminalServicing,
        reader: any NativeCardReader,
        balanceCents: @escaping @MainActor () -> Int?,
        record: @escaping @MainActor (Canonical.Payment) -> Bool,
        today: @escaping () -> String = { NativeCardPresentPayment.localDate(.now) },
        makeOperationID: @escaping () -> String = NativeCardPresentPayment.newOperationID
    ) {
        self.invoiceID = invoiceID
        self.service = service
        self.reader = reader
        self.balanceCents = balanceCents
        self.record = record
        self.today = today
        self.makeOperationID = makeOperationID
    }

    /// The operation id in use (nil before the first start). For tests.
    var currentOperationID: String? { operation?.id }

    var isBusy: Bool { phase == .preparing || phase == .collecting }
    var isFinished: Bool { if case .approved = phase { return true } else { return false } }

    /// Starts, or retries after a decline, timeout, cancel or failure.
    func start(amountCents: Int) async {
        guard !isBusy, !isFinished else { return }
        requestedAmountCents = amountCents

        switch reader.state {
        case .unsupported: phase = .failed(.readerUnavailable); return
        case .notConfigured, .preparing, .busy: phase = .failed(.readerNotReady); return
        case .ready: break
        }
        guard let balance = balanceCents() else { phase = .failed(.invoiceMissing); return }
        switch NativeCardPresentPayment.validate(amountCents: amountCents, balanceCents: balance) {
        case .ok: break
        case .notPositive: phase = .failed(.amountNotPositive); return
        case .exceedsBalance(let cents): phase = .failed(.amountExceedsBalance(balanceCents: cents)); return
        case .tooLarge: phase = .failed(.amountTooLarge); return
        }

        if operation?.amountCents != amountCents {
            operation = Operation(id: makeOperationID(), amountCents: amountCents, localDate: today())
        }
        guard let operation else { return }

        phase = .preparing
        let intent: NativeTerminalPaymentIntent
        do {
            intent = try await service.createPaymentIntent(
                invoiceID: invoiceID, amountCents: amountCents,
                localDate: operation.localDate, operationID: operation.id)
        } catch let error as NativeTerminalError {
            phase = .failed(Self.failure(for: error))
            return
        } catch {
            phase = .failed(.network)
            return
        }
        guard intent.amountCents == amountCents else { phase = .failed(.amountMismatch); return }

        // The balance may have moved while the PaymentIntent was created.
        guard let liveBalance = balanceCents() else { phase = .failed(.invoiceMissing); return }
        guard amountCents <= liveBalance else { phase = .failed(.balanceChanged(balanceCents: liveBalance)); return }

        phase = .collecting
        let result: NativeCardCollectResult
        do {
            result = try await reader.collect(clientSecret: intent.clientSecret)
        } catch let error as NativeCardReaderError {
            phase = .failed(.reader(error.message))
            return
        } catch {
            phase = .failed(.reader("The card reader stopped. Try again."))
            return
        }

        switch result {
        case .declined(let reason): phase = .declined(reason: reason)
        case .canceled: phase = .canceled
        case .timedOut: phase = .timedOut
        case .succeeded(let paymentIntentID, let collectedCents):
            approve(paymentIntentID: paymentIntentID, collectedCents: collectedCents, requestedCents: amountCents, localDate: operation.localDate)
        }
    }

    /// Saves the ledger entry again after an approved charge whose first save
    /// failed. Idempotent by ledger id.
    func retryRecording() {
        guard case .approved(var approval) = phase, !approval.recorded, let entry = pendingEntry else { return }
        if record(entry) {
            approval.recorded = true
            phase = .approved(approval)
        }
    }

    private func approve(paymentIntentID: String, collectedCents: Int, requestedCents: Int, localDate: String) {
        // The card was charged for `collectedCents`: that is what is booked.
        var approval = Approval(
            paymentIntentID: paymentIntentID, amountCents: collectedCents,
            recorded: false, amountDiffersFromRequest: collectedCents != requestedCents)
        if let entry = try? NativeCardPresentPayment.ledgerEntry(
            paymentIntentId: paymentIntentID, amountCents: collectedCents, localDate: localDate) {
            pendingEntry = entry
            approval.recorded = record(entry)
        }
        phase = .approved(approval)
    }

    static func failure(for error: NativeTerminalError) -> Failure {
        switch error {
        case .notSynced: .notSynced
        case .rejectedSession, .malformedSession: .sessionExpired
        case .amountExceedsBalance(let cents): .amountExceedsBalance(balanceCents: cents ?? 0)
        case .unavailable, .invalidConfiguration, .rateLimited: .network
        case .amountMismatch: .amountMismatch
        case .noConnectedAccount: .stripeNotConnected
        case .invalidResponse, .notFound, .invalidRequest, .operationConflict, .stripeRejected, .serverError: .server
        }
    }
}

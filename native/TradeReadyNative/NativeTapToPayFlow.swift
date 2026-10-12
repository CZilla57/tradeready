import Combine
import Foundation

/// Phase 18 (Tap to Pay, spec §4.2, §4.3): the invoice sheet's state machine,
/// independent of SwiftUI so the host tests drive it with
/// `NativeFakeCardReader` and a fake `NativeTerminalServicing`.
///
/// ONE CHARGE PER OPERATION. The operation id, the amount, the local day and
/// the invoice number (the PaymentIntent description) are minted together on
/// the first `start` and reused by every retry, so Stripe's idempotency
/// returns the same PaymentIntent. An approved flow is terminal: `start` does
/// nothing after it, so a double tap cannot charge twice.
///
/// THE AMOUNT AND THE OPERATION LOCK once a collect attempt starts, until that
/// PaymentIntent's outcome is known. A clear card outcome (declined, canceled,
/// timed out) unlocks. A reader error does NOT: the confirm may have reached
/// Stripe, so the flow asks `reader.status(of:)` first:
///   succeeded             -> book it exactly once;
///   canceled              -> the intent is dead: unlock and mint a new
///                            operation on the next start;
///   requires_payment_method -> not charged, but still open: retry allowed
///                            with the SAME amount and operation (a late
///                            confirm would land on the same intent), amount
///                            stays locked;
///   unknown               -> locked in `.paymentUnconfirmed` ("Checking
///                            payment"); only `checkAgain()` moves on, and
///                            never to a new charge.
/// A reader that reports another PaymentIntent's id is never booked: the flow
/// locks for good (`identityMismatch`) and only a `succeeded` status for the
/// intent it created can end it.
@MainActor
final class NativeTapToPayFlow: ObservableObject {
    enum Failure: Equatable {
        case readerUnavailable
        case readerNotReady
        case invoiceMissing
        case amountNotPositive
        case amountExceedsBalance(balanceCents: Int)
        /// Under Stripe's minimum charge: too small to take by card.
        case belowMinimum
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
        /// The reader stopped and Stripe confirmed the card was NOT charged.
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
        /// The ledger entry could not even be built (e.g. a zero collected
        /// amount), so "Save" cannot succeed and must not be offered. Only the
        /// Worker's webhook copy can book it.
        var entryUnbuildable = false
    }

    enum Phase: Equatable {
        case idle
        /// Creating the PaymentIntent on the Worker.
        case preparing
        /// The system tap UI is up.
        case collecting
        /// Asking Stripe whether the card was charged after an ambiguous stop.
        case checkingPayment
        /// The outcome could not be read. Locked: "Checking payment" and
        /// `checkAgain()`; never a new charge.
        case paymentUnconfirmed
        case approved(Approval)
        case declined(reason: String)
        case canceled
        case timedOut
        case failed(Failure)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var requestedAmountCents = 0
    /// Non-nil from the moment a collect attempt starts until its outcome is
    /// known: every `start` uses this amount whatever it is passed.
    @Published private(set) var lockedAmountCents: Int?

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
    /// The invoice number as shown now; read ONCE per operation.
    private let invoiceNumber: @MainActor () -> String?

    private struct Operation {
        var id: String
        var amountCents: Int
        var localDate: String
        /// Frozen with the operation: the PaymentIntent description is part of
        /// Stripe's idempotency parameters.
        var invoiceNumber: String?
        var intent: NativeTerminalPaymentIntent?
    }
    private var operation: Operation?
    /// What to book when the first save failed (the entry is rebuilt on retry).
    private var pendingBooking: (paymentIntentID: String, cents: Int, localDate: String)?
    /// The intent whose outcome is unknown.
    private var unresolved: NativeTerminalPaymentIntent?
    private var identityMismatch = false
    /// The sheet is gone: nothing may start a collection.
    private var closed = false

    init(
        invoiceID: String,
        service: any NativeTerminalServicing,
        reader: any NativeCardReader,
        balanceCents: @escaping @MainActor () -> Int?,
        record: @escaping @MainActor (Canonical.Payment) -> Bool,
        invoiceNumber: @escaping @MainActor () -> String? = { nil },
        today: @escaping () -> String = { NativeCardPresentPayment.localDate(.now) },
        makeOperationID: @escaping () -> String = NativeCardPresentPayment.newOperationID
    ) {
        self.invoiceID = invoiceID
        self.service = service
        self.reader = reader
        self.balanceCents = balanceCents
        self.record = record
        self.invoiceNumber = invoiceNumber
        self.today = today
        self.makeOperationID = makeOperationID
    }

    /// The operation id in use (nil before the first start). For tests.
    var currentOperationID: String? { operation?.id }

    var isBusy: Bool { phase == .preparing || phase == .collecting || phase == .checkingPayment }
    var isFinished: Bool { if case .approved = phase { return true } else { return false } }
    /// The amount field must not be editable.
    var isAmountLocked: Bool { isBusy || isFinished || lockedAmountCents != nil || phase == .paymentUnconfirmed }
    /// The sheet is gone (or going): any pending start stops before the reader.
    func close() { closed = true }

    /// Starts, or retries after a decline, timeout, cancel or failure. While a
    /// PaymentIntent's outcome is unknown it only re-checks.
    func start(amountCents requested: Int) async {
        guard !isBusy, !isFinished, !closed else { return }
        if unresolved != nil { await checkAgain(); return }
        let amountCents = lockedAmountCents ?? requested
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
        case .belowMinimum: phase = .failed(.belowMinimum); return
        case .tooLarge: phase = .failed(.amountTooLarge); return
        }

        if operation?.amountCents != amountCents {
            operation = Operation(
                id: makeOperationID(), amountCents: amountCents, localDate: today(),
                invoiceNumber: NativeCardPresentPayment.cleanInvoiceNumber(invoiceNumber()))
        }
        guard let operation else { return }

        phase = .preparing
        let intent: NativeTerminalPaymentIntent
        do {
            intent = try await service.createPaymentIntent(
                invoiceID: invoiceID, amountCents: amountCents,
                localDate: operation.localDate, operationID: operation.id,
                invoiceNumber: operation.invoiceNumber)
        } catch let error as NativeTerminalError {
            phase = .failed(Self.failure(for: error))
            return
        } catch {
            phase = .failed(.network)
            return
        }
        guard intent.amountCents == amountCents else { phase = .failed(.amountMismatch); return }
        self.operation?.intent = intent

        // The sheet may have been dismissed while the intent was created: a
        // gone sheet never starts a collection.
        guard !closed, !Task.isCancelled else { phase = .canceled; return }

        // The balance may have moved while the PaymentIntent was created.
        guard let liveBalance = balanceCents() else { phase = .failed(.invoiceMissing); return }
        guard amountCents <= liveBalance else { phase = .failed(.balanceChanged(balanceCents: liveBalance)); return }

        // From here the amount and the operation are locked until this
        // intent's outcome is known.
        lockedAmountCents = amountCents
        phase = .collecting
        let result: NativeCardCollectResult
        do {
            result = try await reader.collect(clientSecret: intent.clientSecret)
        } catch let error as NativeCardReaderError {
            await resolveOutcome(of: intent, readerMessage: error.message)
            return
        } catch {
            await resolveOutcome(of: intent, readerMessage: "The card reader stopped. Try again.")
            return
        }

        switch result {
        case .declined(let reason): lockedAmountCents = nil; phase = .declined(reason: reason)
        case .canceled: lockedAmountCents = nil; phase = .canceled
        case .timedOut: lockedAmountCents = nil; phase = .timedOut
        case .succeeded(let paymentIntentID, let collectedCents):
            guard paymentIntentID == intent.paymentIntentID else {
                // A charge for another intent: book nothing, stay locked.
                identityMismatch = true
                unresolved = intent
                phase = .paymentUnconfirmed
                return
            }
            approve(paymentIntentID: paymentIntentID, collectedCents: collectedCents, requestedCents: amountCents, localDate: operation.localDate)
        }
    }

    /// Re-reads the outcome of the intent whose result is unknown. Never
    /// starts a charge.
    func checkAgain() async {
        guard phase == .paymentUnconfirmed, let intent = unresolved else { return }
        await resolveOutcome(of: intent, readerMessage: "The card reader stopped. Try again.")
    }

    private func resolveOutcome(of intent: NativeTerminalPaymentIntent, readerMessage: String) async {
        phase = .checkingPayment
        let status = await reader.status(of: intent)
        let operationAmount = operation?.amountCents ?? intent.amountCents
        let localDate = operation?.localDate ?? today()
        switch status {
        case .succeeded(let cents):
            // It WAS charged: book exactly this intent, exactly once.
            approve(paymentIntentID: intent.paymentIntentID, collectedCents: cents, requestedCents: operationAmount, localDate: localDate)
        case .canceled where !identityMismatch:
            // Dead: the next start mints a new operation.
            unresolved = nil
            lockedAmountCents = nil
            operation = nil
            phase = .failed(.reader(readerMessage))
        case .requiresPaymentMethod where !identityMismatch:
            // Not charged, still open: same amount and operation on retry.
            unresolved = nil
            phase = .failed(.reader(readerMessage))
        case .canceled, .requiresPaymentMethod, .unknown:
            unresolved = intent
            phase = .paymentUnconfirmed
        }
    }

    /// Saves the ledger entry again after an approved charge whose first save
    /// failed. Idempotent by ledger id.
    func retryRecording() {
        guard case .approved(var approval) = phase, !approval.recorded, let booking = pendingBooking else { return }
        guard let entry = try? NativeCardPresentPayment.ledgerEntry(
            paymentIntentId: booking.paymentIntentID, amountCents: booking.cents, localDate: booking.localDate)
        else { return }
        if record(entry) {
            approval.recorded = true
            approval.entryUnbuildable = false
            phase = .approved(approval)
        }
    }

    private func approve(paymentIntentID: String, collectedCents: Int, requestedCents: Int, localDate: String) {
        // The card was charged for `collectedCents`: that is what is booked.
        unresolved = nil
        identityMismatch = false
        var approval = Approval(
            paymentIntentID: paymentIntentID, amountCents: collectedCents,
            recorded: false, amountDiffersFromRequest: collectedCents != requestedCents)
        pendingBooking = (paymentIntentID, collectedCents, localDate)
        do {
            let entry = try NativeCardPresentPayment.ledgerEntry(
                paymentIntentId: paymentIntentID, amountCents: collectedCents, localDate: localDate)
            approval.recorded = record(entry)
        } catch {
            // Charged, but there is nothing valid to save: say so, and do not
            // offer a Save button that cannot work.
            approval.entryUnbuildable = true
        }
        phase = .approved(approval)
    }

    static func failure(for error: NativeTerminalError) -> Failure {
        switch error {
        case .notSynced: .notSynced
        case .rejectedSession, .malformedSession: .sessionExpired
        case .amountExceedsBalance(let cents): .amountExceedsBalance(balanceCents: cents ?? 0)
        case .belowMinimum: .belowMinimum
        case .unavailable, .invalidConfiguration, .rateLimited: .network
        case .amountMismatch: .amountMismatch
        case .noConnectedAccount: .stripeNotConnected
        case .invalidResponse, .notFound, .invalidRequest, .operationConflict, .stripeRejected, .serverError: .server
        }
    }
}

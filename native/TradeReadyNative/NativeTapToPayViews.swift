import SwiftUI

/// Phase 18 (Tap to Pay on iPhone, spec §4.2): the invoice button and sheet
/// and the Settings checklist. Everything here is HIDDEN until
/// `NativeTapToPayEnvironment.resources` is installed (stage B, with the SDK
/// reader and a credentialed `NativeTerminalService`) AND the capability gate
/// passes, so stage A ships no visible change.
@MainActor
enum NativeTapToPayEnvironment {
    struct Resources {
        let service: any NativeTerminalServicing
        let reader: any NativeCardReader
    }
    /// Stage B installs the credentialed service and the Stripe Terminal
    /// reader here at launch. nil in stage A, so no view below renders.
    static var resources: Resources?
}

extension Invoice {
    /// The balance in whole cents; 0 when the balance is not a whole number of
    /// cents (never guess a charge).
    var balanceCents: Int { NativeCardPresentPayment.cents(fromDollars: balance) ?? 0 }
}

// MARK: - Invoice detail

/// A row at the top of the Payments section (never hidden behind scrolling,
/// per Apple's checklist). Renders nothing unless Tap to Pay is available and
/// the invoice has a balance.
struct NativeTapToPayInvoiceRow: View {
    @EnvironmentObject private var store: AppStore
    let invoice: Invoice
    let onSendReceipt: () -> Void
    @State private var presenting = false

    var body: some View {
        if let resources = NativeTapToPayEnvironment.resources,
           NativeTapToPayCapability.current(reader: resources.reader).isAvailable,
           NativeCardPresentPayment.ineligibility(
               capabilityAvailable: true, status: store.stripeConnectStatus,
               invoiceBalanceCents: invoice.balanceCents) == nil {
            Button { presenting = true } label: {
                Label("Tap to Pay on iPhone", systemImage: "wave.3.right.circle.fill")
            }
            .sheet(isPresented: $presenting) {
                NativeTapToPaySheet(invoiceID: invoice.id, store: store, resources: resources, onSendReceipt: onSendReceipt)
            }
        }
    }
}

struct NativeTapToPaySheet: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var flow: NativeTapToPayFlow
    @State private var amountText: String
    let onSendReceipt: () -> Void

    init(invoiceID: String, store: AppStore, resources: NativeTapToPayEnvironment.Resources, onSendReceipt: @escaping () -> Void) {
        let balance = store.invoices.first { $0.id == invoiceID }?.balanceCents ?? 0
        _amountText = State(initialValue: String(format: "%.2f", NativeCardPresentPayment.dollars(fromCents: balance)))
        self.onSendReceipt = onSendReceipt
        _flow = StateObject(wrappedValue: NativeTapToPayFlow(
            invoiceID: invoiceID, service: resources.service, reader: resources.reader,
            balanceCents: { [weak store] in store?.invoices.first { $0.id == invoiceID }?.balanceCents },
            record: { [weak store] entry in
                guard let store else { return false }
                if case .success = store.recordCardPresentPayment(invoiceID: invoiceID, entry: entry) { return true }
                return false
            },
            invoiceNumber: { [weak store] in store?.invoices.first { $0.id == invoiceID }?.number }))
    }

    private var amountCents: Int? {
        Double(amountText.trimmingCharacters(in: .whitespaces)).flatMap(NativeCardPresentPayment.cents(fromDollars:))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Amount") {
                    TextField("Amount", text: $amountText)
                        .keyboardType(.decimalPad)
                        .disabled(flow.isAmountLocked)
                    if amountCents == nil {
                        Text("Enter an amount in dollars and cents.").font(.caption).foregroundStyle(Color.tradeWarningText)
                    }
                }
                Section { status }
                if !flow.isFinished && flow.phase != .paymentUnconfirmed { Section { chargeButton } }
            }
            .nativeContentColumn(.list)
            .navigationTitle("Tap to Pay on iPhone")
            .navigationBarTitleDisplayMode(.inline)
            .nativeKeyboardDoneBar()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(flow.isFinished ? "Done" : "Close") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                        .disabled(flow.isBusy)
                }
            }
        }
        .interactiveDismissDisabled(flow.isBusy)
        // A dismissed sheet must never start a collection (the start task
        // outlives the view).
        .onDisappear { flow.close() }
        // While the amount is locked the field shows the amount being charged.
        .onChange(of: flow.lockedAmountCents) { _, locked in
            if let locked { amountText = String(format: "%.2f", NativeCardPresentPayment.dollars(fromCents: locked)) }
        }
    }

    @ViewBuilder private var status: some View {
        switch flow.phase {
        case .idle:
            Text("Enter the amount, then hold the customer's card or phone near the top of your iPhone.")
                .font(.callout).foregroundStyle(.secondary)
        case .preparing:
            HStack { ProgressView(); Text("Preparing…") }
        case .collecting:
            HStack { ProgressView(); Text("Hold the card or phone near your iPhone.") }
        case .checkingPayment:
            HStack { ProgressView(); Text("Checking payment") }
        case .paymentUnconfirmed:
            Label("Checking payment", systemImage: "questionmark.circle").foregroundStyle(Color.tradeWarningText)
            Text("We couldn't confirm whether the card was charged. Don't take the payment again yet. Check again, or look in your Stripe dashboard. If it was charged, it will appear on this invoice after the next sync.")
                .font(.caption).foregroundStyle(.secondary)
            Button("Check again") { Task { await flow.checkAgain() } }
        case .approved(let approval):
            Label("Approved: \(NativeCardPresentPayment.dollars(fromCents: approval.amountCents).currency)", systemImage: "checkmark.circle.fill")
                .foregroundStyle(Color.tradeSuccessText).fontWeight(.semibold)
            if approval.amountDiffersFromRequest {
                Text("The card was charged a different amount than you entered. The invoice shows what was charged.")
                    .font(.caption).foregroundStyle(Color.tradeWarningText)
            }
            if approval.recorded {
                Button("Send receipt") {
                    dismiss()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { onSendReceipt() }
                }
            } else if approval.entryUnbuildable {
                Text("The card was charged, but this payment couldn't be saved on this invoice from here (reference \(approval.paymentIntentID)). It will appear after the next sync. Check your Stripe dashboard if it doesn't.")
                    .font(.caption).foregroundStyle(Color.tradeDangerText)
            } else {
                Text("The card was charged, but this payment hasn't been saved on this invoice yet. It will appear after the next sync, or save it now.")
                    .font(.caption).foregroundStyle(Color.tradeWarningText)
                Button("Save to this invoice") { flow.retryRecording() }
            }
        case .declined(let reason):
            Label("Declined", systemImage: "xmark.circle.fill").foregroundStyle(Color.tradeDangerText)
            Text(reason.isEmpty ? "The card was declined. Nothing was charged." : "The card was declined (\(reason)). Nothing was charged.")
                .font(.caption).foregroundStyle(.secondary)
        case .timedOut:
            Label("Timed out", systemImage: "clock.badge.exclamationmark").foregroundStyle(Color.tradeWarningText)
            Text("No card was read. Nothing was charged.").font(.caption).foregroundStyle(.secondary)
        case .canceled:
            Label("Canceled", systemImage: "xmark.circle").foregroundStyle(.secondary)
            Text("Nothing was charged.").font(.caption).foregroundStyle(.secondary)
        case .failed(let failure):
            Text(Self.message(for: failure)).font(.callout).foregroundStyle(Color.tradeDangerText)
        }
    }

    @ViewBuilder private var chargeButton: some View {
        let retrying = flow.phase != .idle
        Button {
            if let cents = amountCents { Task { await flow.start(amountCents: cents) } }
        } label: {
            Label(retrying ? "Try again" : "Charge \(amountCents.map { NativeCardPresentPayment.dollars(fromCents: $0).currency } ?? "")",
                  systemImage: "wave.3.right.circle.fill")
        }
        .disabled(flow.isBusy || amountCents == nil)
    }

    static func message(for failure: NativeTapToPayFlow.Failure) -> String {
        switch failure {
        case .readerUnavailable: "Tap to Pay on iPhone isn't available on this device."
        case .readerNotReady: "Getting ready. Try again in a moment."
        case .invoiceMissing: "This invoice is no longer available."
        case .amountNotPositive: "Enter an amount greater than zero."
        case .amountExceedsBalance(let cents): "That's more than the balance of \(NativeCardPresentPayment.dollars(fromCents: cents).currency)."
        case .belowMinimum: NativeCardPresentPayment.belowMinimumMessage
        case .amountTooLarge: "That amount is too large for one card payment."
        case .balanceChanged(let cents): "The balance changed to \(NativeCardPresentPayment.dollars(fromCents: cents).currency). Nothing was charged."
        case .amountMismatch: "The amount didn't match. Nothing was charged. Try again."
        case .notSynced: "This invoice hasn't synced yet. Open the app while online, wait for it to sync, and try again."
        case .stripeNotConnected: "Connect your Stripe account in Settings first."
        case .sessionExpired: "Your session expired. Sign in again."
        case .network: "Couldn't reach the server. Nothing was charged. Try again."
        case .server: "Something went wrong. Nothing was charged. Try again."
        case .reader(let message): "\(message)\nThe card was not charged. You can try again."
        }
    }
}

// MARK: - Settings checklist

/// Settings ▸ Payments ▸ "Tap to Pay on iPhone": the setup checklist (spec
/// §4.2). Shows only where the build and device support it. Steps 3, 5 and 6
/// (location prompt, ProximityReaderDiscovery education, configuration
/// progress) are driven by the SDK reader and arrive with stage B.
struct NativeTapToPaySettingsSection: View {
    @EnvironmentObject private var store: AppStore
    @State private var ownerEnabled = NativeTapToPayPreference().isEnabled
    @State private var locationID: String?
    @State private var locationChecked = false
    @State private var linked: Bool?
    @State private var displayName = ""
    @State private var line1 = ""
    @State private var city = ""
    @State private var state = ""
    @State private var postalCode = ""
    @State private var busy = false
    @State private var errorText: String?

    var body: some View {
        if let resources = NativeTapToPayEnvironment.resources,
           NativeTapToPayCapability.current(reader: resources.reader).isSupportedHere {
            Section("TAP TO PAY ON IPHONE") {
                Toggle("Take card payments in person", isOn: $ownerEnabled)
                    .onChange(of: ownerEnabled) { _, value in NativeTapToPayPreference().isEnabled = value }
                Text("Stripe's in-person card rates apply. Fees are taken by Stripe from each payment.")
                    .font(.caption).foregroundStyle(.secondary)
                if ownerEnabled { checklist(resources) }
            }
        }
    }

    @ViewBuilder private func checklist(_ resources: NativeTapToPayEnvironment.Resources) -> some View {
        let status = store.stripeConnectStatus
        let stripeReady = NativeCardPresentPayment.ineligibility(capabilityAvailable: true, status: status, invoiceBalanceCents: 1) == nil
        row("1. Stripe account ready for card payments", done: stripeReady)
        if !stripeReady { Text("Complete Stripe setup above first.").font(.caption).foregroundStyle(.secondary) }
        row("2. Business address for card payments", done: locationID != nil)
        if stripeReady && locationChecked && locationID == nil {
            TextField("Business name", text: $displayName)
            TextField("Street address", text: $line1)
            TextField("City", text: $city)
            TextField("State (2 letters)", text: $state).textInputAutocapitalization(.characters)
            TextField("ZIP code", text: $postalCode).keyboardType(.numbersAndPunctuation)
            Button { Task { await ensureLocation(resources) } } label: {
                HStack { Text("Save address"); if busy { Spacer(); ProgressView() } }
            }.disabled(busy)
        }
        row("3. Location access", done: nil)
        row("4. Apple's Tap to Pay terms", done: linked)
        row("5. How to tap", done: nil)
        if case .preparing = resources.reader.state {
            HStack { ProgressView(); Text("Getting ready…") }
        }
        if let errorText { Text(errorText).font(.caption).foregroundStyle(Color.tradeDangerText) }
        Color.clear.frame(height: 0)
            .task {
                if displayName.isEmpty { displayName = store.settings.businessName }
                if stripeReady, !locationChecked {
                    locationID = (try? await resources.service.locationStatus())?.locationID
                    locationChecked = true
                }
                linked = await resources.reader.isAccountLinked()
            }
    }

    private func row(_ title: String, done: Bool?) -> some View {
        HStack {
            Text(title)
            Spacer()
            if let done {
                Image(systemName: done ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(done ? Color.tradeSuccessText : Color.secondary)
            }
        }
    }

    private func ensureLocation(_ resources: NativeTapToPayEnvironment.Resources) async {
        busy = true
        defer { busy = false }
        do {
            let result = try await resources.service.ensureLocation(
                displayName: displayName,
                address: NativeTerminalAddress(line1: line1, line2: nil, city: city, state: state, postalCode: postalCode))
            locationID = result.locationID
            errorText = nil
        } catch {
            errorText = "Couldn't save the address. Check it and try again."
        }
    }
}

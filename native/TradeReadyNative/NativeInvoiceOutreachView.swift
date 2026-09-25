import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Reviewed invoice outreach (`screens/OutreachScreen.tsx` parity). The owner
/// picks a channel, deposit ask and provider, reviews an editable deterministic
/// message, and continues into Apple's Mail/Messages composer. Nothing sends
/// automatically; only an explicit `.sent` result supersedes a pending
/// automatic request.
struct NativeInvoiceOutreachView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss

    let invoiceID: String

    private enum Channel: String, CaseIterable, Identifiable {
        case email = "Email", text = "Text"
        var id: String { rawValue }
    }

    private enum DepositMode: String, CaseIterable, Identifiable {
        case full = "Full balance", half = "50% deposit", custom = "Custom"
        var id: String { rawValue }
    }

    @State private var channel: Channel = .email
    @State private var depositMode: DepositMode = .full
    @State private var customValue = "50"
    @State private var customIsPercent = true
    @State private var providerID: String = ""
    @State private var paymentLink = ""
    @State private var generatingLink = false
    @State private var linkError: String?
    @State private var planEnabled = false
    @State private var installments = "3"
    @State private var frequency = "Bi-weekly"
    @State private var emailSubject = ""
    @State private var emailBody = ""
    @State private var smsBody = ""
    @State private var attachPDF = true
    @State private var copied = false
    @State private var showingComposer = false
    @State private var composerUnavailable = false
    @State private var outcomeNotice: String?

    private static let providerLabels = [
        "stripe": "Stripe", "square": "Square", "paypal": "PayPal.Me",
        "venmo": "Venmo", "custom": "Custom URL",
    ]

    private var invoice: Invoice? { store.invoices.first { $0.id == invoiceID } }

    private var configuredProviders: [(id: String, label: String)] {
        let active = providerID.isEmpty ? store.settings.paymentProvider : providerID
        var ids = [active]
        for id in ["square", "paypal", "venmo", "custom"] where id != active {
            if !store.settings.providerKey(for: id).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                ids.append(id)
            }
        }
        return ids.compactMap { id in Self.providerLabels[id].map { (id, $0) } }
    }

    private var nativeDepositMode: NativeDepositMode {
        switch depositMode {
        case .full: return NativeDepositMode.full
        case .half: return NativeDepositMode.half
        case .custom:
            let parsed = Double(customValue.trimmingCharacters(in: .whitespacesAndNewlines)) ?? .nan
            return customIsPercent ? .customPercent(parsed) : .customFixed(parsed)
        }
    }

    private var requestedAmount: Double {
        guard let invoice else { return 0 }
        return NativeInvoicePaymentLinks.requestedAmount(total: invoice.amount, balance: invoice.balance, mode: nativeDepositMode)
    }

    private var depositAsk: NativeDepositAsk? {
        guard let invoice else { return nil }
        return NativeInvoicePaymentLinks.depositAsk(total: invoice.amount, balance: invoice.balance, mode: nativeDepositMode)
    }

    var body: some View {
        NavigationStack {
            Group {
                if let invoice {
                    Form {
                        Section("Channel") {
                            Picker("Channel", selection: $channel) {
                                ForEach(Channel.allCases) { Text($0.rawValue).tag($0) }
                            }.pickerStyle(.segmented)
                        }
                        if !invoice.isPaid {
                            Section("Request") {
                                Picker("Amount", selection: $depositMode) {
                                    ForEach(DepositMode.allCases) { Text($0.rawValue).tag($0) }
                                }.pickerStyle(.segmented)
                                if depositMode == .custom {
                                    HStack {
                                        TextField(customIsPercent ? "Percent of total" : "Amount ($)", text: $customValue)
                                            .keyboardType(.decimalPad)
                                        Picker("Unit", selection: $customIsPercent) {
                                            Text("%").tag(true)
                                            Text("$").tag(false)
                                        }.pickerStyle(.segmented).frame(width: 110)
                                    }
                                }
                                if let ask = depositAsk {
                                    Text("Requesting \(NativeInvoiceOutreach.formatMoney(ask.amount)) of the \(NativeInvoiceOutreach.formatMoney((invoice.balance * 100).rounded() / 100)) balance")
                                        .font(.caption).foregroundStyle(.secondary)
                                } else if depositMode == .custom && requestedAmount <= 0 {
                                    Text("Enter an amount greater than zero.").font(.caption).foregroundStyle(Color.tradeWarningText)
                                }
                            }
                            Section("Pay via") {
                                ScrollView(.horizontal, showsIndicators: false) {
                                    HStack {
                                        ForEach(configuredProviders, id: \.id) { provider in
                                            Button {
                                                selectProvider(provider.id)
                                            } label: {
                                                Text(provider.label)
                                                    .padding(.horizontal, 12).padding(.vertical, 6)
                                                    .background(provider.id == providerID ? Color.tradeReady.opacity(0.12) : Color.clear)
                                                    .clipShape(Capsule())
                                            }
                                            .buttonStyle(.plain)
                                            .overlay(Capsule().stroke(provider.id == providerID ? Color.tradeReady : Color.secondary.opacity(0.3)))
                                        }
                                    }
                                }
                                if paymentLink.isEmpty {
                                    Button {
                                        Task { await generateLink(explicit: true) }
                                    } label: {
                                        HStack {
                                            Text("Generate payment link")
                                            if generatingLink { Spacer(); ProgressView() }
                                        }
                                    }.disabled(generatingLink || requestedAmount <= 0)
                                } else {
                                    Text(paymentLink).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                                }
                                if let linkError {
                                    Text(linkError).font(.caption).foregroundStyle(Color.tradeDangerText)
                                }
                            }
                            Section("Payment plan") {
                                Toggle("Offer a payment plan", isOn: $planEnabled)
                                if planEnabled {
                                    HStack {
                                        TextField("Installments", text: $installments).keyboardType(.numberPad)
                                        TextField("Frequency", text: $frequency)
                                    }
                                }
                            }
                        }
                        Section(channel == .email ? "Email" : "Text message") {
                            if channel == .email {
                                TextField("Subject", text: $emailSubject)
                                TextEditor(text: $emailBody).frame(minHeight: 200)
                                Toggle("Attach invoice PDF", isOn: $attachPDF)
                            } else {
                                TextEditor(text: $smsBody).frame(minHeight: 160)
                            }
                            HStack {
                                Button {
                                    regenerate()
                                } label: { Label("Regenerate", systemImage: "arrow.clockwise") }
                                Spacer()
                                Button {
                                    copyMessage()
                                } label: { Label(copied ? "Copied" : "Copy", systemImage: "doc.on.doc") }
                            }.buttonStyle(.borderless)
                        }
                        if let outcomeNotice {
                            Section { Text(outcomeNotice).font(.caption).foregroundStyle(.secondary) }
                        }
                        Section {
                            Button {
                                continueToComposer()
                            } label: {
                                Label(
                                    channel == .email ? "Continue to Mail" : "Continue to Messages",
                                    systemImage: channel == .email ? "envelope" : "message"
                                ).frame(maxWidth: .infinity)
                            }
                            .tradeReadyProminentButtonStyle()
                            .disabled(!canSend)
                        } footer: {
                            Text("Nothing is sent until you review it again and tap Send in the system composer.")
                        }
                    }
                    .nativeContentColumn(.list)
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "doc.text.magnifyingglass").font(.largeTitle).foregroundStyle(.secondary)
                        Text("Invoice not available").font(.headline)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .navigationTitle("Request payment")
            .navigationBarTitleDisplayMode(.inline)
            .nativeKeyboardDoneBar()
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction) } }
            .onAppear {
                if providerID.isEmpty { providerID = store.settings.paymentProvider }
                restoreCachedLink()
                regenerate()
            }
            .onChange(of: channel) { regenerate() }
            .onChange(of: depositMode) { handleDepositChange() }
            .onChange(of: customIsPercent) { handleDepositChange() }
            .onChange(of: planEnabled) { regenerate() }
            .onChange(of: installments) { regenerate() }
            .onChange(of: frequency) { regenerate() }
            .sheet(isPresented: $showingComposer) {
                if let draft = composerDraft {
                    NativeMessageComposer(draft: draft, onFinish: handleComposerOutcome)
                        .ignoresSafeArea()
                }
            }
            .alert("Composer unavailable", isPresented: $composerUnavailable) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(channel == .email
                     ? "Set up a Mail account on this device and try again."
                     : "Messages is not available on this device.")
            }
        }
        .nativeAnalyticsScreen(.outreach)
    }

    // MARK: - Message state

    private var canSend: Bool {
        guard let invoice, !invoice.isPaid else { return false }
        if channel == .email { return !invoice.email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return !invoice.phone.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func outreachInvoice(_ invoice: Invoice) -> NativeInvoiceOutreachInvoice {
        NativeInvoiceOutreachInvoice(
            customer: invoice.customer,
            number: invoice.number,
            description: invoice.description,
            total: invoice.amount,
            balance: invoice.balance,
            isPartlyPaid: invoice.isPartlyPaid,
            daysPastDue: NativeInvoiceList.daysPastDue(
                due: NativeInvoiceEditing.dayString(invoice.due), now: .now) ?? 0)
    }

    private func outreachBusiness() -> NativeInvoiceOutreachBusiness {
        NativeInvoiceOutreachBusiness(
            businessName: store.settings.businessName,
            contactName: store.settings.contactName,
            phone: store.settings.phone,
            paymentNotes: store.settings.paymentNotes)
    }

    private func outreachPlan() -> NativeInvoiceOutreachPlan? {
        guard planEnabled else { return nil }
        return NativeInvoiceOutreachPlan(installments: installments, frequency: frequency)
    }

    private func regenerate() {
        guard let invoice else { return }
        let raw = NativeInvoiceOutreach.message(
            invoice: outreachInvoice(invoice),
            channel: channel == .email ? .email : .text,
            business: outreachBusiness(),
            paymentLink: paymentLink.isEmpty ? nil : paymentLink,
            plan: outreachPlan(),
            deposit: depositAsk)
        if channel == .email {
            let split = NativeInvoiceOutreach.splitEmailSubject(
                raw, fallbackSubject: NativeInvoiceOutreach.fallbackSubject(invoiceNumber: invoice.number))
            emailSubject = split.subject
            emailBody = split.body
        } else {
            smsBody = raw
        }
        copied = false
    }

    private func handleDepositChange() {
        // The visible link was minted for the previous amount.
        paymentLink = ""
        linkError = nil
        regenerate()
    }

    private func selectProvider(_ id: String) {
        guard id != providerID else { return }
        providerID = id
        paymentLink = ""
        linkError = nil
        Task { await generateLink(explicit: false) }
    }

    private func restoreCachedLink() {
        guard let invoice, requestedAmount > 0,
              let cached = store.cachedInvoicePaymentLink(
                  invoiceID: invoice.id,
                  amount: Decimal(requestedAmount))
        else { return }
        paymentLink = cached
    }

    private func generateLink(explicit: Bool) async {
        guard let invoice,
              let provider = NativePaymentProvider(rawValue: providerID),
              requestedAmount > 0
        else { return }
        generatingLink = true
        defer { generatingLink = false }
        do {
            let url = try await store.generateInvoicePaymentLink(
                invoiceID: invoice.id,
                amount: Decimal(requestedAmount),
                provider: provider)
            paymentLink = url.absoluteString
            linkError = nil
            // Task 11.08: RN `OutreachScreen.tsx:211` — explicit generation only.
            if explicit { store.recordPaymentLinkSent(provider: provider, deposit: depositAsk != nil) }
            regenerate()
        } catch {
            // Best-effort downgrade: the message still asks the customer to
            // contact the owner directly to arrange payment.
            paymentLink = ""
            linkError = explicit ? "Could not generate a payment link. The message below asks the customer to contact you directly." : nil
            if explicit { regenerate() }
        }
    }

    private func copyMessage() {
        #if canImport(UIKit)
        let full = channel == .email && !emailSubject.isEmpty
            ? "Subject: \(emailSubject)\n\n\(emailBody)" : (channel == .email ? emailBody : smsBody)
        UIPasteboard.general.string = full
        copied = true
        #endif
    }

    // MARK: - Composer

    private var composerDraft: NativeAppointmentMessageDraft? {
        guard let invoice, canSend else { return nil }
        let channelValue: NativeAppointmentMessageChannel = channel == .email ? .email : .sms
        let recipient = channel == .email ? invoice.email : invoice.phone
        let attachments: [NativeMessageAttachment]
        if channel == .email, attachPDF,
           let document = store.invoicePDFDocument(invoiceID: invoice.id),
           let data = try? NativeInvoicePDFRenderer.data(
               for: document, logoReference: store.invoicePDFLogoReference()) {
            attachments = [NativeMessageAttachment(data: data, mimeType: "application/pdf", fileName: document.filename)]
        } else {
            attachments = []
        }
        return NativeAppointmentMessageDraft(
            channel: channelValue,
            recipient: recipient,
            subject: channel == .email ? emailSubject : nil,
            body: channel == .email ? emailBody : smsBody,
            attachments: attachments)
    }

    private var pdfWasAttached: Bool { composerDraft?.attachments.isEmpty == false }

    private func continueToComposer() {
        guard composerDraft != nil else { return }
        if NativeMessageComposer.canPresent(channel == .email ? .email : .sms) {
            showingComposer = true
        } else {
            composerUnavailable = true
        }
    }

    private func handleComposerOutcome(_ outcome: NativeMessageComposeOutcome) {
        showingComposer = false
        let missingPDF = channel == .email && attachPDF && !pdfWasAttached
        switch NativeInvoiceOutreach.resolution(for: outcome) {
        case .recordSent:
            store.clearInvoiceAutoEmailRequest(invoiceID: invoiceID)
            if missingPDF {
                outcomeNotice = "Couldn't attach the invoice PDF, so the draft didn't include it."
            } else {
                dismiss()
            }
        case .keepDraft:
            outcomeNotice = missingPDF ? "Couldn't attach the invoice PDF, so the draft didn't include it." : nil
        case .keepDraftWithSavedNotice:
            outcomeNotice = "Saved as a draft in Mail. It was not sent."
        case .keepDraftWithFailureNotice:
            outcomeNotice = "The composer reported a failure. Your message was kept — try again."
        }
    }
}

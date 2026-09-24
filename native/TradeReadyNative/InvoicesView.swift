import SwiftUI

private enum InvoiceFilter: String, CaseIterable, Identifiable {
    case all = "All", unpaid = "Unpaid", overdue = "Overdue", paid = "Paid"
    var id: String { rawValue }
}

/// One stable settlement submission: the payment ID is minted when the dialog
/// opens so retries reuse it and the ledger dedupes a double submit.
private struct InvoiceSettleRequest: Identifiable {
    let invoice: Invoice
    let paymentID: String
    var id: String { invoice.id }
}

/// One reviewed bulk reminder in a sequential chain.
private struct BulkOutreachItem: Identifiable {
    let id: String
}

struct InvoicesView: View {
    @EnvironmentObject private var store: AppStore
    @State private var search = ""
    @State private var filter: InvoiceFilter = .all
    @State private var showingEditor = false
    @State private var settleRequest: InvoiceSettleRequest?
    @State private var mutationError: String?
    @State private var path: [String] = []
    @State private var confirmationRequest: NativeConfirmationRequest?
    @State private var selecting = false
    @State private var selectedIDs: Set<String> = []
    @State private var confirmingBulkSettle = false
    @State private var showingBulkChannel = false
    @State private var bulkNotice: String?
    @State private var bulkQueue: [String] = []
    @State private var bulkChannel: NativeBulkRemindChannel?
    @State private var bulkIndex = 0
    @State private var bulkCurrent: BulkOutreachItem?
    @State private var bulkSkipped = 0
    @State private var bulkChannelName = "email"

    private var invoices: [Invoice] {
        store.invoices.filter { invoice in
            let matchesSearch = search.isEmpty || invoice.customer.localizedCaseInsensitiveContains(search) || invoice.number.localizedCaseInsensitiveContains(search)
            let matchesFilter = switch filter { case .all: true; case .unpaid: !invoice.isPaid; case .overdue: invoice.isOverdue; case .paid: invoice.isPaid }
            return matchesSearch && matchesFilter
        }.sorted { $0.due < $1.due }
    }

    private var contentState: NativeContentState {
        NativeContentState.collection(
            visibleCount: invoices.count,
            totalCount: store.invoices.count,
            query: search,
            isFiltering: filter != .all
        )
    }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Section {
                    NativeAccessibilityAdaptiveRow(alignment: .center, spacing: 10) {
                        Button { toggleStatFilter(.unpaid) } label: {
                            MetricCard(title: "Outstanding", value: store.invoices.reduce(0) { $0 + $1.balance }.currency)
                        }.buttonStyle(.plain)
                        Button { toggleStatFilter(.overdue) } label: {
                            MetricCard(title: "Overdue", value: "\(store.invoices.filter(\.isOverdue).count)", color: .orange)
                        }.buttonStyle(.plain)
                        Button { toggleStatFilter(.paid) } label: {
                            MetricCard(title: "Collected", value: store.invoices.reduce(0) { $0 + $1.amountPaid }.currency, color: .green)
                        }.buttonStyle(.plain)
                    }.listRowInsets(EdgeInsets()).listRowBackground(Color.clear)
                }
                Section {
                    Picker("Status", selection: $filter) { ForEach(InvoiceFilter.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented)
                    NavigationLink {
                        NativeRecurringInvoicesView()
                    } label: {
                        HStack {
                            Label("Maintenance plans", systemImage: "arrow.triangle.2.circlepath")
                            Spacer()
                            Text("\(store.recurringInvoiceRules.filter(\.isActive).count) active")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                ForEach(invoices) { invoice in
                    if selecting {
                        Button { toggleSelected(invoice.id) } label: {
                            HStack {
                                Image(systemName: selectedIDs.contains(invoice.id) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(selectedIDs.contains(invoice.id) ? Color.tradeReady : .secondary)
                                InvoiceRow(invoice: invoice)
                            }
                        }.buttonStyle(.plain)
                    } else {
                        NavigationLink(value: invoice.id) { InvoiceRow(invoice: invoice) }
                            .swipeActions {
                                Button(role: .destructive) {
                                    confirmationRequest = .deleteInvoice(
                                        id: invoice.id,
                                        number: invoice.number,
                                        customer: invoice.customer
                                    )
                                } label: { Label("Delete", systemImage: "trash") }
                                if !invoice.isPaid {
                                    Button { settleRequest = InvoiceSettleRequest(invoice: invoice, paymentID: Payment().id) } label: {
                                        Label("Paid", systemImage: "checkmark.circle")
                                    }
                                    .tint(.green)
                                }
                            }
                    }
                }
            }
            .tradeReadyListStyle()
            .overlay {
                NativeContentStateView(
                    state: contentState,
                    emptyTitle: "No invoices",
                    emptyMessage: "Create an invoice to start tracking payment.",
                    symbol: "doc.text",
                    resetAction: { search = ""; filter = .all }
                )
            }
            .refreshable { await store.performPullToRefresh() }
            .navigationTitle("Invoices")
            .searchable(text: $search, prompt: "Customer or invoice number")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(selecting ? "Done" : "Select") { selecting ? exitSelectMode() : (selecting = true) }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showingEditor = true } label: { Image(systemName: "plus") }
                        .accessibilityLabel(NativeAccessibilityAudit.Label.addInvoice)
                }
            }
            .safeAreaInset(edge: .bottom) {
                if selecting {
                    HStack {
                        Text("\(selectedIDs.count) selected").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Remind") { showingBulkChannel = true }.disabled(selectedIDs.isEmpty)
                        Button("Mark paid") { confirmingBulkSettle = true }.disabled(selectedIDs.isEmpty)
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 10)
                    .background(.bar)
                }
            }
            .navigationDestination(for: String.self) { InvoiceDetailView(invoiceID: $0) }
            .sheet(isPresented: $showingEditor) { InvoiceEditor(invoice: Invoice(number: store.nextInvoiceNumber(), due: Calendar.current.date(byAdding: .day, value: 30, to: .now) ?? .now), isNew: true) }
            .onChange(of: store.deepLinkedInvoiceID) { _, id in
                openRequestedInvoice(id)
            }
            .onAppear {
                openRequestedInvoice(store.deepLinkedInvoiceID)
            }
            .confirmationDialog(
                "Mark as paid?",
                isPresented: Binding(
                    get: { settleRequest != nil },
                    set: { if !$0 { settleRequest = nil } }
                ),
                titleVisibility: .visible,
                presenting: settleRequest
            ) { request in
                Button(request.invoice.isPartlyPaid ? "Mark rest paid" : "Mark paid") {
                    switch store.settleInvoice(invoiceID: request.invoice.id, paymentID: request.paymentID) {
                    case .success:
                        settleRequest = nil
                    case .failure:
                        settleRequest = nil
                        mutationError = "Could not mark the invoice paid. Existing data was preserved."
                    }
                }
                Button("Cancel", role: .cancel) { settleRequest = nil }
            } message: { _ in
                Text("This records the remaining balance as collected.")
            }
            .alert("Couldn't save", isPresented: Binding(
                get: { mutationError != nil },
                set: { if !$0 { mutationError = nil } }
            )) {
                Button("OK", role: .cancel) { mutationError = nil }
            } message: {
                Text(mutationError ?? "Existing data was preserved.")
            }
            .nativeConfirmation($confirmationRequest) { intent in
                guard case .deleteInvoice(let recordID) = intent else { return }
                store.deleteInvoice(id: recordID)
            }
            .confirmationDialog("Send reminders", isPresented: $showingBulkChannel, titleVisibility: .visible) {
                Button("Email") { startBulkRemind(channel: .email, name: "email address") }
                Button("Text") { startBulkRemind(channel: .text, name: "phone number") }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The composer opens once per invoice — review and send each.")
            }
            .alert("Mark \(selectedIDs.count) invoice(s) paid?", isPresented: $confirmingBulkSettle) {
                Button("Mark paid") { runBulkSettle() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Each invoice's remaining balance is recorded as collected today.")
            }
            .sheet(item: $bulkCurrent, onDismiss: advanceBulkQueue) { item in
                NativeInvoiceOutreachView(invoiceID: item.id)
            }
            .alert("Bulk update", isPresented: Binding(
                get: { bulkNotice != nil },
                set: { if !$0 { bulkNotice = nil } }
            )) {
                Button("OK", role: .cancel) { bulkNotice = nil }
            } message: {
                Text(bulkNotice ?? "")
            }
            // On the stack's root content, not the stack, so a pop back re-sends it.
            .nativeAnalyticsScreen(.invoiceList)
        }
    }

    private func openRequestedInvoice(_ id: String?) {
        guard let id, store.invoices.contains(where: { $0.id == id }) else { return }
        filter = .all
        path = [id]
        store.deepLinkedInvoiceID = nil
    }

    /// Stat taps drive the filter; tapping the active one clears back to All.
    private func toggleStatFilter(_ target: InvoiceFilter) {
        filter = (filter == target) ? .all : target
    }

    private func toggleSelected(_ id: String) {
        if selectedIDs.contains(id) { selectedIDs.remove(id) } else { selectedIDs.insert(id) }
    }

    private func exitSelectMode() {
        selecting = false
        selectedIDs = []
        bulkQueue = []
        bulkCurrent = nil
    }

    private func runBulkSettle() {
        let ids = Array(selectedIDs)
        let result = store.commitBulkSettleInvoices(ids: ids)
        if result.settled.isEmpty {
            bulkNotice = "Nothing to settle — the selected invoices are already paid."
        } else if result.skipped > 0 {
            bulkNotice = "Marked \(result.settled.count) paid. \(result.skipped) skipped (already paid)."
        }
        exitSelectMode()
    }

    private func startBulkRemind(channel: NativeBulkRemindChannel, name: String) {
        bulkChannelName = name
        let items = store.invoices.map {
            NativeBulkRemindableItem(id: $0.id, isPaid: $0.isPaid, email: $0.email, phone: $0.phone)
        }
        let split = NativeInvoiceBulk.splitRemindable(items, selectedIDs: selectedIDs, channel: channel)
        bulkSkipped = split.skippedNoContact.count
        if split.eligible.isEmpty {
            bulkNotice = channel == .email
                ? "None of the selected unpaid invoices have an email address."
                : "None of the selected unpaid invoices have a phone number."
            return
        }
        bulkQueue = split.eligible.map(\.id)
        bulkChannel = channel
        bulkIndex = 0
        advanceBulkQueue()
    }

    private func advanceBulkQueue() {
        guard bulkIndex < bulkQueue.count else {
            // Chain complete: report it, summarize skips, then leave
            // selection mode. `bulkIndex` is the sheets presented.
            if let bulkChannel {
                store.recordBulkInvoiceReminderRunCompleted(channel: bulkChannel, presentedCount: bulkIndex)
            }
            bulkChannel = nil
            if bulkSkipped > 0 {
                bulkNotice = "\(bulkSkipped) selected invoice(s) have no \(bulkChannelName) on file and were skipped."
            }
            exitSelectMode()
            return
        }
        bulkCurrent = BulkOutreachItem(id: bulkQueue[bulkIndex])
        bulkIndex += 1
    }
}

struct InvoiceRow: View {
    let invoice: Invoice
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack { Text(invoice.customer).font(.headline); Spacer(); Text(invoice.balance.currency).fontWeight(.semibold) }
            HStack {
                Text("\(invoice.number) · Due \(invoice.due.shortDate)").font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                Text(invoice.isPaid ? "Paid" : invoice.isOverdue ? "Overdue" : invoice.isPartlyPaid ? "Partial" : "Open")
                    .font(.caption.weight(.semibold)).foregroundStyle(invoice.isPaid ? .green : invoice.isOverdue ? .orange : .blue)
            }
        }.padding(.vertical, 4)
    }
}

/// One frozen PDF share: the temp file lives through the share sheet and is
/// removed on dismissal.
private struct InvoicePDFShare: Identifiable {
    let url: URL
    var id: String { url.path }
}

struct InvoiceDetailView: View {
    @EnvironmentObject private var store: AppStore
    let invoiceID: String
    @State private var editing = false
    @State private var recordingPayment = false
    @State private var confirmingSettlement = false
    @State private var settlePaymentID = Payment().id
    @State private var paymentToVoid: Payment?
    @State private var mutationError: String?
    @State private var pdfShare: InvoicePDFShare?
    @State private var pdfCleanupURL: URL?
    @State private var pdfError: String?
    @State private var showingOutreach = false
    private var invoice: Invoice? { store.invoices.first { $0.id == invoiceID } }

    var body: some View {
        Group {
            if let invoice {
                List {
                    Section {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack(alignment: .firstTextBaseline) { Text(invoice.balance.currency).font(.largeTitle.bold()); Spacer(); Text(invoice.isPaid ? "Paid" : invoice.isOverdue ? "Overdue" : "Open").foregroundStyle(invoice.isPaid ? .green : invoice.isOverdue ? .orange : .secondary) }
                            Text("of \(invoice.amount.currency) · due \(invoice.due.shortDate)").foregroundStyle(.secondary)
                            ContactButtons(phone: invoice.phone, email: invoice.email)
                        }.padding(.vertical, 5)
                    }
                    Section("Invoice") { LabeledContent("Number", value: invoice.number); LabeledContent("Customer", value: invoice.customer); if !invoice.description.isEmpty { Text(invoice.description) } }
                    Section("Document") {
                        Button { sharePDF() } label: { Label("Save or share PDF", systemImage: "doc.richtext") }
                        if !invoice.isPaid {
                            Button { showingOutreach = true } label: { Label("Request payment", systemImage: "envelope") }
                        }
                    }
                    if let job = store.jobs.first(where: { $0.invoiceId == invoice.id && ($0.archivedAt ?? "").isEmpty }) {
                        Section("Linked job") {
                            Button {
                                store.routeToGlobalSearchResult(.job(job.id))
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(job.title).font(.headline)
                                        Text(job.customerName).font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    Section("Payments") {
                        if invoice.effectivePayments.isEmpty { Text("No payments recorded yet.").foregroundStyle(.secondary) }
                        ForEach(invoice.effectivePayments) { payment in
                            VStack(alignment: .leading, spacing: 3) {
                                HStack {
                                    Text(payment.amount.currency).fontWeight(.semibold)
                                    Spacer()
                                    Text("\(payment.date.shortDate) · \(payment.method)")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                if payment.id.hasPrefix("legacy_") {
                                    Text("Recorded before itemized history").font(.caption).italic().foregroundStyle(.secondary)
                                } else if !payment.note.isEmpty {
                                    Text(payment.note).font(.caption).italic().foregroundStyle(.secondary)
                                }
                                if let voidedAt = payment.voidedAt {
                                    Text("Voided \(voidedAt.shortDate)").font(.caption).foregroundStyle(.orange)
                                }
                            }
                            .foregroundStyle(payment.voidedAt == nil ? .primary : .secondary)
                            .strikethrough(payment.voidedAt != nil)
                            .accessibilityElement(children: .combine)
                            .accessibilityHint(payment.voidedAt == nil ? "Swipe to void this payment" : "")
                            .swipeActions {
                                if payment.voidedAt == nil {
                                    Button(role: .destructive) { paymentToVoid = payment } label: {
                                        Label("Void", systemImage: "xmark.circle")
                                    }
                                }
                            }
                        }
                        if invoice.overpaidAmount > 0 {
                            LabeledContent("Overpaid", value: invoice.overpaidAmount.currency)
                                .foregroundStyle(.orange)
                        }
                        if !invoice.isPaid {
                            Button { recordingPayment = true } label: { Label("Record payment", systemImage: "plus.circle.fill") }
                            Button {
                                // Stable per dialog: a retry after a failed save reuses the ID.
                                settlePaymentID = Payment().id
                                confirmingSettlement = true
                            } label: {
                                Label(invoice.isPartlyPaid ? "Mark rest paid" : "Mark paid", systemImage: "checkmark.circle")
                            }
                        }
                    }
                }
                .tradeReadyListStyle()
                .navigationTitle(invoice.number)
                .toolbar { Button("Edit") { editing = true } }
                .onAppear {
                    if store.consumeOutreachDeepLink(invoiceID: invoiceID) {
                        showingOutreach = true
                    }
                }
                .sheet(isPresented: $editing) { InvoiceEditor(invoice: invoice) }
                .sheet(isPresented: $recordingPayment) { PaymentEditor(invoice: invoice) }
                .sheet(isPresented: $showingOutreach) { NativeInvoiceOutreachView(invoiceID: invoiceID) }
                .sheet(item: $pdfShare, onDismiss: cleanupPDFShare) { share in
                    NativeActivitySheet(items: [share.url])
                        .ignoresSafeArea()
                }
                .alert("Couldn't create PDF", isPresented: Binding(
                    get: { pdfError != nil },
                    set: { if !$0 { pdfError = nil } }
                )) {
                    Button("OK", role: .cancel) { pdfError = nil }
                } message: {
                    Text(pdfError ?? "Your invoice was not changed.")
                }
                .alert("Mark as paid?", isPresented: $confirmingSettlement) {
                    Button(invoice.isPartlyPaid ? "Mark rest paid" : "Mark paid") {
                        if case .failure = store.settleInvoice(invoiceID: invoiceID, paymentID: settlePaymentID) {
                            mutationError = "Could not mark the invoice paid. Existing data was preserved."
                        }
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("This records the remaining balance as collected.")
                }
                .alert("Couldn't save", isPresented: Binding(
                    get: { mutationError != nil },
                    set: { if !$0 { mutationError = nil } }
                )) {
                    Button("OK", role: .cancel) { mutationError = nil }
                } message: {
                    Text(mutationError ?? "Existing data was preserved.")
                }
                .alert(
                    "Void this payment?",
                    isPresented: Binding(
                        get: { paymentToVoid != nil },
                        set: { if !$0 { paymentToVoid = nil } }
                    ),
                    presenting: paymentToVoid
                ) { payment in
                    Button("Void payment", role: .destructive) {
                        if case .failure = store.voidPayment(invoiceID: invoiceID, paymentID: payment.id) {
                            mutationError = "Could not void the payment. Existing data was preserved."
                        }
                        paymentToVoid = nil
                    }
                    Button("Cancel", role: .cancel) { paymentToVoid = nil }
                } message: { payment in
                    let restored = invoice.voidingPayment(id: payment.id, on: .now).balance
                    Text("This can't be undone. \(invoice.number) will go back to \(restored.currency) due. To correct a mistake, record a new payment.")
                }
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "doc.text.magnifyingglass").font(.largeTitle).foregroundStyle(.secondary)
                    Text("Invoice not available").font(.headline)
                    Text("It may have been deleted on another device.").font(.subheadline).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .navigationTitle("Invoice")
            }
        }
    }

    /// Renders the frozen canonical document into a temp file kept alive
    /// through the share sheet. Exporting never mutates invoice state.
    private func sharePDF() {
        guard let document = store.invoicePDFDocument(invoiceID: invoiceID) else {
            pdfError = "This invoice is no longer available. Your invoice was not changed."
            return
        }
        do {
            let url = try NativeInvoicePDFRenderer.temporaryFile(for: document)
            pdfCleanupURL = url
            pdfShare = InvoicePDFShare(url: url)
        } catch {
            pdfError = "The invoice PDF could not be created. Your invoice was not changed."
        }
    }

    private func cleanupPDFShare() {
        pdfShare = nil
        guard let url = pdfCleanupURL else { return }
        pdfCleanupURL = nil
        try? FileManager.default.removeItem(at: url)
    }
}

struct InvoiceEditor: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State var invoice: Invoice
    let isNew: Bool
    private let opened: Invoice?
    @State private var saveError: String?

    init(invoice: Invoice, isNew: Bool = false) {
        _invoice = State(initialValue: invoice)
        self.isNew = isNew
        self.opened = isNew ? nil : invoice
    }

    var body: some View {
        NavigationStack {
            Form {
                if let saveError {
                    Section {
                        Text(saveError).foregroundStyle(.red)
                    }
                }
                Section("Customer") {
                    Picker("Customer", selection: $invoice.customerId) {
                        Text("Choose a customer").tag("")
                        ForEach(store.customers) { Text($0.name).tag($0.id) }
                    }
                    .onChange(of: invoice.customerId) { _, id in if let c = store.customers.first(where: { $0.id == id }) { invoice.customer = c.name; invoice.email = c.email; invoice.phone = c.phone } }
                }
                Section("Details") { TextField("Invoice number", text: $invoice.number); CurrencyField(title: "Amount", value: $invoice.amount); DatePicker("Due", selection: $invoice.due, displayedComponents: .date); TextField("Description of work", text: $invoice.description, axis: .vertical) }
                Section("Contact") { TextField("Email", text: $invoice.email).keyboardType(.emailAddress).textInputAutocapitalization(.never); TextField("Phone", text: $invoice.phone).keyboardType(.phonePad) }
            }
            .scrollContentBackground(.hidden).background(Color.tradeCanvas)
            .navigationTitle(invoice.customer.isEmpty ? "New Invoice" : "Edit Invoice")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                DismissableFormToolbar(title: invoice.number) {
                    let draft = NativeInvoiceDraft(
                        customer: invoice.customer,
                        customerId: invoice.customerId,
                        number: invoice.number,
                        amount: invoice.amount,
                        due: NativeInvoiceEditing.dayString(invoice.due),
                        email: invoice.email,
                        phone: invoice.phone,
                        description: invoice.description
                    )
                    switch store.commitInvoiceEdit(id: isNew ? nil : invoice.id, opened: opened, draft: draft) {
                    case .success:
                        dismiss()
                    case .failure(let refusal):
                        // The draft stays visible; existing data is preserved.
                        saveError = switch refusal {
                        case .missingRecord:
                            "This invoice no longer exists. Your edits were kept — go back and recreate it if needed."
                        case .conflictingRecord:
                            "This invoice changed elsewhere. Your edits were kept — reopen it to review the latest version before saving."
                        case .persistenceUnavailable:
                            "Could not save right now. Your edits were kept and existing data was preserved."
                        case .invalidDraft:
                            "Enter a customer name and an amount greater than zero."
                        }
                    }
                }
            }
        }
        .nativeAnalyticsScreen(.invoiceEditor)
    }
}

struct PaymentEditor: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let invoice: Invoice
    @State private var amount: Double
    @State private var date = Date.now
    @State private var method = "Cash"
    @State private var note = ""
    /// Minted once per sheet: retries reuse the same ID and the ledger
    /// dedupes, so a double submit records exactly one payment.
    @State private var paymentID: String = Payment().id
    @State private var saveError: String?

    init(invoice: Invoice) { self.invoice = invoice; _amount = State(initialValue: invoice.balance) }

    var body: some View {
        NavigationStack {
            Form {
                if let saveError {
                    Section {
                        Text(saveError).foregroundStyle(.red)
                    }
                }
                Section {
                    CurrencyField(title: "Amount", value: $amount)
                    if amount > invoice.balance {
                        Text("More than the \(invoice.balance.currency) balance — that's okay; the invoice will show as fully paid.")
                            .font(.caption).foregroundStyle(.orange)
                    } else if amount <= 0 {
                        Text("Enter an amount greater than zero.").font(.caption).foregroundStyle(.orange)
                    }
                    DatePicker("Date", selection: $date, displayedComponents: .date)
                    Picker("Method", selection: $method) { ForEach(["Cash", "Cheque", "Card", "Other"], id: \.self) { Text($0) } }
                    TextField("Note", text: $note)
                }
            }
            .scrollContentBackground(.hidden).background(Color.tradeCanvas)
            .navigationTitle("Record Payment")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                DismissableFormToolbar(title: "Payment") {
                    guard amount > 0 else { return }
                    let payment = Payment(id: paymentID, amount: amount, date: date, method: method, note: note)
                    switch store.recordPayment(invoiceID: invoice.id, payment: payment) {
                    case .success:
                        dismiss()
                    case .failure:
                        saveError = "Could not record the payment. Your entry was kept and existing data was preserved."
                    }
                }
            }
        }
    }
}

import SwiftUI

private struct NativeCustomerRoute: Hashable {
    let id: String
    let name: String
}

struct CustomersView: View {
    @ScaledMetric(relativeTo: .subheadline) private var initialsSize: CGFloat = 42
    @EnvironmentObject private var store: AppStore
    @State private var search = ""
    @State private var showingEditor = false
    @State private var showingArchived = false
    @State private var path: [NativeCustomerRoute] = []
    @State private var isRootVisible = true

    /// Task 11.11 fix round 1: anything this screen presents over itself.
    private var isPresentingAnything: Bool { showingEditor }

    /// ⌘N (new customer) only while the list is on top: never under the
    /// editor sheet, nor under a pushed customer.
    private var newShortcut: KeyboardShortcut? {
        isPresentingAnything || !path.isEmpty || !isRootVisible ? nil : KeyboardShortcut("n", modifiers: .command)
    }

    private var allCustomers: [NativeCustomerListEntry] {
        NativeCustomerIdentity.buildList(invoices: store.invoices, customers: store.customers)
    }

    private var customers: [NativeCustomerListEntry] {
        allCustomers.filter { customer in
            customer.isArchived == showingArchived
                && (search.isEmpty
                    || customer.name.localizedCaseInsensitiveContains(search)
                    || customer.email.localizedCaseInsensitiveContains(search)
                    || customer.phone.localizedCaseInsensitiveContains(search))
        }
    }

    private var activeCustomers: [NativeCustomerListEntry] {
        allCustomers.filter { !$0.isArchived }
    }

    private var customersInSelectedScope: [NativeCustomerListEntry] {
        allCustomers.filter { $0.isArchived == showingArchived }
    }

    private var contentState: NativeContentState {
        NativeContentState.collection(
            visibleCount: customers.count,
            totalCount: customersInSelectedScope.count,
            query: search
        )
    }

    private var duplicatePairs: [NativeCustomerDuplicatePair] {
        NativeCustomerIdentity.filterUndismissed(
            NativeCustomerIdentity.duplicatePairs(in: store.customers),
            dismissedKeys: store.dismissedCustomerDuplicatePairKeys
        )
    }

    private var duplicateReviewRoute: NativeCustomerRoute? {
        guard let pair = duplicatePairs.first,
              let candidate = NativeCustomerIdentity.reviewCandidate(for: pair, entries: allCustomers)
        else { return nil }
        return .init(id: candidate.id, name: candidate.name)
    }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Section {
                    LabeledContent("Active customers", value: "\(activeCustomers.count)")
                    LabeledContent(
                        "Total collected",
                        value: activeCustomers.reduce(0) { $0 + $1.totalSpent }.currency
                    )
                    Toggle("Show archived", isOn: $showingArchived)
                }

                if !showingArchived,
                   let pair = duplicatePairs.first,
                   let reviewRoute = duplicateReviewRoute {
                    Section {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(duplicatePairs.count > 1
                                ? "Possible duplicates (\(duplicatePairs.count))"
                                : "Possible duplicate")
                                .font(.headline)
                            Text(duplicateMessage(pair))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            HStack {
                                Button("Dismiss") {
                                    store.dismissCustomerDuplicatePair(pair.key)
                                }
                                Spacer()
                                NavigationLink(value: reviewRoute) {
                                    Label("Review", systemImage: "person.2")
                                }
                                .tradeReadyProminentButtonStyle()
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }

                Section(showingArchived ? "Archived" : "Customers") {
                    if contentState == .content {
                        ForEach(customers) { customer in
                            NavigationLink(value: NativeCustomerRoute(id: customer.id, name: customer.name)) {
                                customerRow(customer)
                            }
                            .swipeActions {
                                if customer.isManual {
                                    Button {
                                        store.setCustomerArchived(
                                            id: customer.id,
                                            archived: !customer.isArchived
                                        )
                                    } label: {
                                        Label(
                                            customer.isArchived ? "Restore" : "Archive",
                                            systemImage: customer.isArchived ? "arrow.uturn.backward" : "archivebox"
                                        )
                                    }
                                    .tint(customer.isArchived ? Color.tradeReadyFill : Color.tradeWarningFill)
                                }
                            }
                        }
                    } else {
                        NativeContentStateView(
                            state: contentState,
                            emptyTitle: showingArchived ? "No archived customers" : "No customers yet",
                            emptyMessage: showingArchived
                                ? "Archived customers will appear here."
                                : "Add a customer or create an invoice to get started.",
                            symbol: showingArchived ? "archivebox" : "person.2",
                            resetAction: { search = "" }
                        )
                        .listRowBackground(Color.clear)
                    }
                }
            }
            .nativeContentColumn(.list)
            .tradeReadyListStyle()
            .refreshable { await store.performPullToRefresh() }
            .navigationTitle("Customers")
            .searchable(text: $search)
            .toolbar {
                Button {
                    guard !isPresentingAnything else { return }
                    showingEditor = true
                } label: { Label(NativeAccessibilityAudit.Label.addCustomer, systemImage: "plus") }
                .labelStyle(.iconOnly)
                .accessibilityLabel(NativeAccessibilityAudit.Label.addCustomer)
                .keyboardShortcut(newShortcut)
            }
            .navigationDestination(for: NativeCustomerRoute.self) {
                CustomerDetailView(customerID: $0.id, fallbackName: $0.name)
            }
            .sheet(isPresented: $showingEditor) {
                CustomerEditor(customer: Customer(), mode: .create)
            }
            .onChange(of: store.deepLinkedCustomerID) { _, id in
                openRequestedCustomer(id)
            }
            .onDisappear { isRootVisible = false }
            .onAppear {
                isRootVisible = true
                openRequestedCustomer(store.deepLinkedCustomerID)
            }
            // On the stack's root content, not the stack, so a pop back re-sends it.
            .nativeAnalyticsScreen(.customerList)
        }
    }

    private func openRequestedCustomer(_ id: String?) {
        guard let id,
              let customer = store.customers.first(where: { $0.id == id && !NativeCustomerIdentity.isArchived($0) })
        else { return }
        showingArchived = false
        path = [.init(id: customer.id, name: customer.name)]
        store.deepLinkedCustomerID = nil
    }

    @ViewBuilder
    private func customerRow(_ customer: NativeCustomerListEntry) -> some View {
        HStack(spacing: 13) {
            Text(initials(for: customer.name))
                .font(.subheadline.bold())
                .foregroundStyle(Color.tradeReady)
                .frame(width: initialsSize, height: initialsSize)
                .background(Color.tradeReady.opacity(0.12), in: Circle())
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(customer.name).font(.headline)
                    if !customer.isManual {
                        Text("From invoices")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                Text(customerSummary(customer))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
    }

    private func customerSummary(_ customer: NativeCustomerListEntry) -> String {
        let invoiceCount = customer.invoices.count
        if customer.totalOwed > 0 {
            return "\(invoiceCount) invoice\(invoiceCount == 1 ? "" : "s") · \(customer.totalOwed.currency) owed"
        }
        if customer.totalSpent > 0 {
            return "\(invoiceCount) invoice\(invoiceCount == 1 ? "" : "s") · \(customer.totalSpent.currency) paid"
        }
        return invoiceCount == 0 ? "No invoices yet" : "\(invoiceCount) invoice\(invoiceCount == 1 ? "" : "s")"
    }

    private func duplicateMessage(_ pair: NativeCustomerDuplicatePair) -> String {
        let sharedValue = switch pair.reason {
        case .name: "name"
        case .phone: "phone number"
        case .email: "email"
        }
        return "“\(pair.a.name)” and “\(pair.b.name)” share the same \(sharedValue)."
    }

    private func initials(for name: String) -> String {
        let value = name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined().uppercased()
        return value.isEmpty ? "?" : value
    }
}

struct CustomerDetailView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let customerID: String
    let fallbackName: String
    @State private var editorCustomer: Customer?
    @State private var invoiceDraft: Invoice?
    @State private var showingMergePicker = false
    @State private var confirmationRequest: NativeConfirmationRequest?
    @State private var notesDraft = ""
    @State private var notesBaseline = ""
    @State private var notesSaveFailed = false

    init(customerID: String, fallbackName: String = "") {
        self.customerID = customerID
        self.fallbackName = fallbackName
    }

    private var customer: NativeCustomerListEntry? {
        let customers = NativeCustomerIdentity.buildList(invoices: store.invoices, customers: store.customers)
        if let exact = customers.first(where: { $0.id == customerID }) { return exact }
        let name = NativeCustomerIdentity.normalizedName(fallbackName)
        return customers.first { NativeCustomerIdentity.normalizedName($0.name) == name }
    }

    private var storedCustomer: Customer? {
        if let exact = store.customers.first(where: { $0.id == customer?.id }) { return exact }
        return NativeCustomerIdentity.resolve(
            customers: store.customers,
            customerID: nil,
            customerName: customer?.name ?? fallbackName
        )
    }

    private var jobs: [Job] {
        guard let customer else { return [] }
        let name = NativeCustomerIdentity.normalizedName(customer.name)
        return store.jobs
            .filter {
                $0.customerId == customer.id
                    || NativeCustomerIdentity.normalizedName($0.customerName) == name
            }
            .sorted {
                let left = $0.scheduledAt ?? .distantPast
                let right = $1.scheduledAt ?? .distantPast
                if left != right { return left > right }
                return $0.id < $1.id
            }
    }

    private var invoices: [Invoice] {
        (customer?.invoices ?? []).sorted {
            if $0.due != $1.due { return $0.due > $1.due }
            return $0.id < $1.id
        }
    }

    private var currentNotes: String {
        storedCustomer?.notes ?? customer?.notes ?? ""
    }

    var body: some View {
        Group {
            if let customer {
                List {
                    Section {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Text(customer.name).font(.title2.bold())
                                if customer.isArchived {
                                    Text("Archived")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                }
                            }
                            HStack {
                                ContactButtons(phone: customer.phone, email: customer.email)
                                Spacer()
                                Button {
                                    invoiceDraft = NativeCustomerDetailActions.invoiceDraft(
                                        for: customer,
                                        storedCustomer: storedCustomer,
                                        number: store.nextInvoiceNumber(),
                                        due: Calendar.current.date(byAdding: .day, value: 30, to: .now) ?? .now
                                    )
                                } label: {
                                    Label("New invoice", systemImage: "doc.badge.plus")
                                }
                                .buttonStyle(.bordered)
                                .accessibilityLabel("New invoice for \(customer.name)")
                            }
                        }
                        .padding(.vertical, 5)
                    }

                    Section("Overview") {
                        LabeledContent("Invoices", value: "\(invoices.count)")
                        LabeledContent("Collected", value: customer.totalSpent.currency)
                        LabeledContent("Outstanding", value: customer.totalOwed.currency)
                    }

                    if !customer.phone.isEmpty || !customer.email.isEmpty || !(storedCustomer?.address ?? "").isEmpty {
                        Section("Contact") {
                            if !customer.phone.isEmpty { LabeledContent("Phone", value: customer.phone) }
                            if !customer.email.isEmpty { LabeledContent("Email", value: customer.email) }
                            if let address = storedCustomer?.address, !address.isEmpty { Text(address) }
                        }
                    }

                    // Customer Portal section
                    Section("Customer Portal") {
                        NavigationLink {
                            NativeCustomerPortalView(
                                customerID: customer.id,
                                customerName: customer.name
                            )
                        } label: {
                            HStack {
                                Label("Manage portal link", systemImage: "person.crop.circle.badge.checkmark")
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .accessibilityHint("Opens portal link administration for \(customer.name)")
                    }

                    Section("Jobs") {
                        if jobs.isEmpty { Text("No jobs").foregroundStyle(.secondary) }
                        ForEach(jobs) { JobRow(job: $0) }
                    }

                    Section("Invoices") {
                        if invoices.isEmpty { Text("No invoices").foregroundStyle(.secondary) }
                        ForEach(invoices) { invoice in
                            Button {
                                store.routeToGlobalSearchResult(.invoice(invoice.id))
                            } label: {
                                InvoiceRow(invoice: invoice)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Open invoice \(invoice.number) for \(invoice.customer)")
                        }
                    }

                    Section {
                        TextField(
                            "Preferred contact times, access details, parking information…",
                            text: $notesDraft,
                            axis: .vertical
                        )
                        .lineLimit(3...8)
                        .accessibilityLabel("Customer notes")

                        if notesDraft != notesBaseline {
                            Button("Save notes", systemImage: "checkmark.circle") {
                                let record = NativeCustomerDetailActions.customerSavingNotes(
                                    notesDraft,
                                    for: customer,
                                    storedCustomer: storedCustomer
                                )
                                if store.upsert(record) {
                                    notesBaseline = notesDraft
                                } else {
                                    notesSaveFailed = true
                                }
                            }
                        }
                    } header: {
                        Text("Notes")
                    } footer: {
                        if !customer.isManual {
                            Text("Saving notes also creates a saved customer record for this invoice-derived customer.")
                        }
                    }

                    if let storedCustomer, store.customers.contains(where: { $0.id != storedCustomer.id }) {
                        Section {
                            Button("Merge into another customer", systemImage: "person.2") {
                                showingMergePicker = true
                            }
                            .foregroundStyle(Color.tradeDangerText)
                        } header: {
                            Text("Customer record")
                        } footer: {
                            Text("Jobs, invoices, and recurring plans will move to the customer you keep.")
                        }
                    }

                    if let storedCustomer {
                        Section {
                            Button(role: .destructive) {
                                confirmationRequest = .deleteCustomer(
                                    id: storedCustomer.id,
                                    name: storedCustomer.name
                                )
                            } label: {
                                Label("Delete customer", systemImage: "trash").nativeDestructiveText()
                            }
                        } footer: {
                            Text("Their jobs and invoices will remain in your records.")
                        }
                    }

                    if !customer.isManual {
                        Section {
                            Button("Save customer details", systemImage: "person.crop.circle.badge.plus") {
                                editorCustomer = Customer(
                                    name: customer.name,
                                    email: customer.email,
                                    phone: customer.phone
                                )
                            }
                        } footer: {
                            Text("This invoice-derived customer has not been added to your customer records yet.")
                        }
                    }
                }
                .nativeContentColumn(.list)
                .tradeReadyListStyle()
                .refreshable { await store.performPullToRefresh() }
                .navigationTitle("Customer")
                .navigationBarTitleDisplayMode(.inline)
                .nativeKeyboardDoneBar()
                .toolbar {
                    if let storedCustomer {
                        Button("Edit", systemImage: "pencil") {
                            editorCustomer = storedCustomer
                        }
                        Button(
                            NativeCustomerIdentity.isArchived(storedCustomer) ? "Restore" : "Archive",
                            systemImage: NativeCustomerIdentity.isArchived(storedCustomer) ? "arrow.uturn.backward" : "archivebox"
                        ) {
                            store.setCustomerArchived(
                                id: storedCustomer.id,
                                archived: !NativeCustomerIdentity.isArchived(storedCustomer)
                            )
                        }
                    }
                }
                .sheet(item: $editorCustomer) {
                    CustomerEditor(customer: $0, mode: .editOrPromote)
                }
                .sheet(item: $invoiceDraft) {
                    InvoiceEditor(invoice: $0)
                }
                .sheet(isPresented: $showingMergePicker) {
                    if let storedCustomer {
                        NativeCustomerMergePicker(loser: storedCustomer) {
                            dismiss()
                        }
                    }
                }
                .nativeConfirmation($confirmationRequest) { intent in
                    guard case .deleteCustomer(let recordID) = intent else { return }
                    if store.deleteCustomer(id: recordID) {
                        dismiss()
                    }
                }
                .alert("Notes not saved", isPresented: $notesSaveFailed) {
                    Button("OK", role: .cancel) {}
                } message: {
                    Text("Your existing customer data was preserved. Try saving again.")
                }
                .onAppear {
                    notesDraft = currentNotes
                    notesBaseline = currentNotes
                }
                .onChange(of: currentNotes) { _, updatedNotes in
                    guard notesDraft == notesBaseline else { return }
                    notesDraft = updatedNotes
                    notesBaseline = updatedNotes
                }
            } else {
                EmptyContent(
                    title: "Customer unavailable",
                    message: "This customer is no longer present in local records.",
                    symbol: "person.crop.circle.badge.questionmark"
                )
            }
        }
        .nativeAnalyticsScreen(.customerDetail)
    }
}

private struct NativeCustomerMergePicker: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let loser: Customer
    let onMerged: () -> Void
    @State private var search = ""
    @State private var confirmationRequest: NativeConfirmationRequest?

    private var candidates: [Customer] {
        store.customers
            .filter {
                $0.id != loser.id
                    && (search.isEmpty
                        || $0.name.localizedCaseInsensitiveContains(search)
                        || $0.email.localizedCaseInsensitiveContains(search)
                        || $0.phone.localizedCaseInsensitiveContains(search))
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Choose the customer to keep. Blank contact details will be filled from \(loser.name).")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Section("Keep customer") {
                    if candidates.isEmpty {
                        Text("No matching customers")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(candidates) { candidate in
                            Button {
                                confirmationRequest = .mergeCustomer(
                                    loserID: loser.id,
                                    loserName: loser.name,
                                    winnerID: candidate.id,
                                    winnerName: candidate.name,
                                    warnsAboutPortalLink: store.customerHasPortalLink(id: loser.id)
                                )
                            } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(candidate.name).foregroundStyle(.primary)
                                    if !candidate.email.isEmpty || !candidate.phone.isEmpty {
                                        Text([candidate.email, candidate.phone].filter { !$0.isEmpty }.joined(separator: " · "))
                                            .font(.subheadline)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .nativeContentColumn(.list)
            .tradeReadyListStyle()
            .navigationTitle("Merge \(loser.name)")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $search)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                }
            }
            .nativeConfirmation($confirmationRequest) { intent in
                guard case let .mergeCustomer(loserID, winnerID) = intent else { return }
                if store.mergeCustomer(loserID: loserID, into: winnerID) {
                    dismiss()
                    onMerged()
                }
            }
        }
    }
}

struct CustomerEditor: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State var customer: Customer
    let mode: NativeCustomerEditorMode
    @State private var saveIssue: NativeCustomerEditorSaveIssue?
    @StateObject private var addressLookup = NativeAddressLookupModel()

    var body: some View {
        NavigationStack {
            Form {
                Section("Customer") {
                    TextField("Name", text: $customer.name)
                    TextField("Phone", text: $customer.phone).keyboardType(.phonePad)
                    TextField("Email", text: $customer.email)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                }
                Section("Location") {
                    TextField("Address", text: Binding(
                        get: { customer.address },
                        set: {
                            customer.address = $0
                            addressLookup.update(query: $0)
                        }
                    ), axis: .vertical)
                    .textContentType(.fullStreetAddress)
                    .accessibilityLabel("Address")

                    if addressLookup.state == .searching {
                        HStack(spacing: 10) {
                            ProgressView().controlSize(.small)
                            Text("Finding addresses…")
                                .foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .combine)
                    }

                    ForEach(addressLookup.suggestions) { suggestion in
                        Button {
                            customer.address = addressLookup.select(suggestion)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(suggestion.title)
                                    .foregroundStyle(.primary)
                                if !suggestion.subtitle.isEmpty {
                                    Text(suggestion.subtitle)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .accessibilityLabel("Use address \(suggestion.address)")
                    }

                    if addressLookup.state == .selected {
                        Label("Address selected", systemImage: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(Color.tradeSuccessText)
                    } else if addressLookup.state == .noResults {
                        Text("No matching address found. You can still save what you entered.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if addressLookup.state == .unavailable {
                        Text("Address lookup is unavailable. You can still save what you entered.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Section("Notes") {
                    TextField("Access details, preferences…", text: $customer.notes, axis: .vertical)
                        .lineLimit(3...8)
                }
            }
            .nativeContentColumn(.list)
            .scrollContentBackground(.hidden)
            .background(Color.tradeCanvas)
            .navigationTitle(customer.name.isEmpty ? "New Customer" : "Edit Customer")
            .navigationBarTitleDisplayMode(.inline)
            .nativeKeyboardDoneBar()
            .toolbar {
                DismissableFormToolbar(title: "Customer") {
                    let plan = NativeCustomerIdentity.editorSavePlan(
                        for: customer,
                        existingCustomers: store.customers,
                        mode: mode
                    )
                    guard plan.canSave else {
                        saveIssue = plan.issue
                        return
                    }
                    if store.upsert(plan.customer) {
                        dismiss()
                    } else {
                        saveIssue = .persistenceFailed
                    }
                }
            }
            .alert(item: $saveIssue) { issue in
                switch issue {
                case .nameRequired:
                    Alert(
                        title: Text("Name required"),
                        message: Text("Please enter the customer's name."),
                        dismissButton: .default(Text("OK"))
                    )
                case .duplicateName(_, let existingName):
                    Alert(
                        title: Text("Customer already exists"),
                        message: Text("\"\(existingName)\" is already in your customer list."),
                        dismissButton: .default(Text("OK"))
                    )
                case .persistenceFailed:
                    Alert(
                        title: Text("Customer not saved"),
                        message: Text("Your existing customer data was preserved. Try saving again."),
                        dismissButton: .default(Text("OK"))
                    )
                }
            }
        }
        .nativeAnalyticsScreen(.customerEditor)
    }
}

extension NativeCustomerEditorSaveIssue: Identifiable {
    var id: String {
        switch self {
        case .nameRequired: "name-required"
        case .duplicateName(let existingID, _): "duplicate-name:\(existingID)"
        case .persistenceFailed: "persistence-failed"
        }
    }
}

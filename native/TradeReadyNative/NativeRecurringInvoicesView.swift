import SwiftUI

/// Maintenance-plan (recurring invoice) manager
/// (`screens/RecurringInvoicesScreen.tsx` +
/// `screens/AddRecurringInvoiceScreen.tsx` parity). Generation itself runs on
/// foreground after sync; this screen manages rules. Invoices a plan already
/// generated are real receivables and are never touched by rule edits.
struct NativeRecurringInvoicesView: View {
    @EnvironmentObject private var store: AppStore
    @State private var editorTarget: PlanEditorTarget?
    @State private var actionRule: Canonical.RecurringInvoice?
    @State private var confirmingDelete = false
    @State private var confirmingCancel = false
    @State private var saveError: String?

    /// The open plan editor. One `sheet(item:)` carries the plan with the
    /// presentation (Task 11.11 fix round 1): the old `sheet(isPresented:)`
    /// read a separate `editingRule`, which the "+" action (or ⌘N under the
    /// sheet) set to nil, turning an open edit into a create on Save.
    private enum PlanEditorTarget: Identifiable {
        case new
        case edit(Canonical.RecurringInvoice)

        var id: String {
            switch self {
            case .new: "new"
            case .edit(let rule): "edit-\(rule.id)"
            }
        }

        var rule: Canonical.RecurringInvoice? {
            if case .edit(let rule) = self { rule } else { nil }
        }
    }

    /// Task 11.11 fix round 1: anything this screen presents over itself.
    private var isPresentingAnything: Bool {
        editorTarget != nil || actionRule != nil || confirmingCancel || confirmingDelete
    }

    /// ⌘N (new plan) never fires under the editor, the plan actions or their alerts.
    private var newShortcut: KeyboardShortcut? {
        isPresentingAnything ? nil : KeyboardShortcut("n", modifiers: .command)
    }

    private static let cadenceLabels: [(RecurrenceCadence, String)] = [
        (.daily, "Daily"), (.weekly, "Weekly"), (.monthly, "Monthly"),
        (.quarterly, "Quarterly"), (.annually, "Annually"),
    ]

    var body: some View {
        List {
            Section {
                Toggle("Automatic email", isOn: Binding(
                    get: { store.settings.autoSendRecurringInvoicesEnabled },
                    set: { store.settings.autoSendRecurringInvoicesEnabled = $0 }))
                Text("When on, newly generated plan invoices can be emailed automatically. Each plan still opts in individually, and only the newest invoice ever sends.")
                    .font(.caption).foregroundStyle(.secondary)
            } footer: {
                Text("Turning this on never emails pre-existing invoices.")
            }
            if let saveError {
                Section { Text(saveError).foregroundStyle(Color.tradeDangerText) }
            }
            Section("Plans") {
                if store.recurringInvoiceRules.isEmpty {
                    Text("No maintenance plans yet.").foregroundStyle(.secondary)
                }
                ForEach(store.recurringInvoiceRules, id: \.id) { rule in
                    Button { actionRule = rule } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(rule.customerName).font(.headline)
                                Text("\(cadenceLabel(rule.cadence)) · \(rule.amount.currency) · \(endText(rule))")
                                    .font(.subheadline).foregroundStyle(.secondary)
                                Text("\(rule.occurrenceCount) generated · Next \(rule.nextDueDate)")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(rule.isActive ? "Active" : "Paused")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(rule.isActive ? .green : .orange)
                        }
                    }.buttonStyle(.plain)
                }
            }
        }
        .nativeContentColumn(.list)
        .tradeReadyListStyle()
        .navigationTitle("Maintenance plans")
        .toolbar {
            Button {
                guard !isPresentingAnything else { return }
                editorTarget = .new
            } label: { Label(NativeAccessibilityAudit.Label.addMaintenancePlan, systemImage: "plus") }
                .labelStyle(.iconOnly)
                .accessibilityLabel(NativeAccessibilityAudit.Label.addMaintenancePlan)
                .keyboardShortcut(newShortcut)
        }
        .sheet(item: $editorTarget) { target in
            NativeRecurringInvoiceEditor(rule: target.rule)
        }
        .confirmationDialog(
            actionRule?.customerName ?? "Plan",
            isPresented: Binding(get: { actionRule != nil }, set: { if !$0 { actionRule = nil } }),
            titleVisibility: .visible,
            presenting: actionRule
        ) { rule in
            Button(rule.isActive ? "Pause plan" : "Resume plan") {
                if !store.setRecurringInvoiceActive(id: rule.id, isActive: !rule.isActive) {
                    saveError = "The plan could not be updated. Nothing was changed."
                }
                actionRule = nil
            }
            Button("Edit plan") {
                editorTarget = .edit(rule)
                actionRule = nil
            }
            Button("Cancel plan", role: .destructive) {
                confirmingCancel = true
            }
            Button("Delete plan", role: .destructive) {
                confirmingDelete = true
            }
            Button("Dismiss", role: .cancel) { actionRule = nil }
        }
        .alert("Cancel maintenance plan?", isPresented: $confirmingCancel) {
            Button("Cancel plan", role: .destructive) {
                if let rule = actionRule, !store.setRecurringInvoiceActive(id: rule.id, isActive: false) {
                    saveError = "The plan could not be paused. Nothing was changed."
                }
                actionRule = nil
            }
            Button("Keep plan", role: .cancel) { confirmingCancel = false }
        } message: {
            Text("No more invoices will be generated. The plan stays in your list, paused. Invoices already created are not affected.")
        }
        .alert("Delete maintenance plan?", isPresented: $confirmingDelete) {
            Button("Delete", role: .destructive) {
                if let rule = actionRule, !store.deleteRecurringInvoice(id: rule.id) {
                    saveError = "The plan could not be deleted. Nothing was changed."
                }
                actionRule = nil
            }
            Button("Keep plan", role: .cancel) { confirmingDelete = false }
        } message: {
            Text("This removes the plan permanently. Invoices it already generated are not affected.")
        }
        .nativeAnalyticsScreen(.recurringInvoices)
    }

    private func cadenceLabel(_ raw: String) -> String {
        Self.cadenceLabels.first(where: { $0.0.rawValue == raw })?.1 ?? raw
    }

    private func endText(_ rule: Canonical.RecurringInvoice) -> String {
        switch rule.endCondition {
        case "count": "Ends after \(rule.endCount ?? 0) invoices"
        case "date": "Ends \(rule.endDate ?? "")"
        default: "No end date"
        }
    }
}

private struct NativeRecurringInvoiceEditor: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let rule: Canonical.RecurringInvoice?

    @State private var customerId = ""
    @State private var customerName = ""
    @State private var description = ""
    @State private var amount = ""
    @State private var dueDays = "30"
    @State private var cadence = RecurrenceCadence.monthly
    @State private var startDate = Date.now
    @State private var endCondition = RecurrenceEndCondition.never
    @State private var endCount = ""
    @State private var endDate = Date.now
    @State private var autoSend = false
    @State private var confirmingAutoSend = false
    @State private var saveError: String?

    private var isEditing: Bool { rule != nil }

    var body: some View {
        NavigationStack {
            Form {
                if let saveError {
                    Section { Text(saveError).foregroundStyle(Color.tradeDangerText) }
                }
                Section("Customer") {
                    Picker("Customer", selection: $customerId) {
                        Text("Choose a customer").tag("")
                        ForEach(store.customers) { Text($0.name).tag($0.id) }
                    }
                    .onChange(of: customerId) { _, id in
                        if let c = store.customers.first(where: { $0.id == id }) {
                            customerName = c.name
                        }
                    }
                    if customerId.isEmpty {
                        TextField("Customer name", text: $customerName)
                    }
                }
                Section("Plan") {
                    TextField("Description", text: $description)
                    CurrencyField(title: "Amount per invoice", value: amountBinding)
                    HStack {
                        TextField("Due (days)", text: $dueDays).keyboardType(.numberPad)
                        Picker("Repeats", selection: $cadence) {
                            ForEach(RecurrenceCadence.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                        }
                    }
                    if !isEditing {
                        DatePicker("Starts", selection: $startDate, displayedComponents: .date)
                    }
                }
                Section("Ends") {
                    Picker("End", selection: $endCondition) {
                        Text("Never").tag(RecurrenceEndCondition.never)
                        Text("After a count").tag(RecurrenceEndCondition.count)
                        Text("On a date").tag(RecurrenceEndCondition.date)
                    }.pickerStyle(.segmented)
                    if endCondition == .count {
                        TextField("Number of invoices", text: $endCount).keyboardType(.numberPad)
                    } else if endCondition == .date {
                        DatePicker("End date", selection: $endDate, displayedComponents: .date)
                    }
                }
                Section("Delivery") {
                    Toggle("Email invoices automatically", isOn: Binding(
                        get: { autoSend },
                        set: { value in
                            if value && !autoSend { confirmingAutoSend = true } else { autoSend = value }
                        }))
                    Text("Only the newest generated invoice ever sends, and only when automatic email is also on. Enabling this never emails pre-existing invoices.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .nativeContentColumn(.list)
            .scrollContentBackground(.hidden).background(Color.tradeCanvas)
            .navigationTitle(isEditing ? "Edit plan" : "New plan")
            .navigationBarTitleDisplayMode(.inline)
            .nativeKeyboardDoneBar()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction) }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { save() }.keyboardShortcut("s", modifiers: .command) }
            }
            .onAppear(perform: hydrate)
            .confirmationDialog("Email invoices automatically?", isPresented: $confirmingAutoSend, titleVisibility: .visible) {
                Button("Enable auto-email") { autoSend = true }
                Button("Keep off", role: .cancel) {}
            } message: {
                Text("New invoices from this plan can be emailed automatically once generated. Invoices it already created are never emailed retroactively.")
            }
        }
        .nativeAnalyticsScreen(.recurringInvoiceEditor)
    }

    private var amountBinding: Binding<Double> {
        Binding(
            get: { Double(amount) ?? 0 },
            set: { amount = $0 == 0 ? "" : String($0) })
    }

    private func hydrate() {
        guard let rule else { return }
        customerId = rule.customerId
        customerName = rule.customerName
        description = rule.description
        amount = String(describing: rule.amount)
        dueDays = String(rule.dueDays)
        cadence = RecurrenceCadence(rawValue: rule.cadence) ?? .monthly
        endCondition = RecurrenceEndCondition(rawValue: rule.endCondition) ?? .never
        endCount = rule.endCount.map(String.init) ?? ""
        autoSend = rule.autoSendEnabled ?? false
    }

    private func save() {
        let name = customerName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { saveError = "Choose or enter a customer."; return }
        guard let parsedAmount = Double(amount), parsedAmount > 0 else {
            saveError = "Enter an amount greater than zero."; return
        }
        guard let parsedDueDays = Int(dueDays.trimmingCharacters(in: .whitespacesAndNewlines)),
              parsedDueDays >= 0
        else { saveError = "Due days must be zero or more."; return }
        if endCondition == .count {
            guard let count = Int(endCount.trimmingCharacters(in: .whitespacesAndNewlines)), count >= 1 else {
                saveError = "Enter how many invoices the plan should generate."; return
            }
        }
        if autoSend {
            let email = store.customers.first(where: { $0.id == customerId })?.email ?? ""
            if !NativeRecurringInvoices.isPlausibleEmail(email.isEmpty ? nil : email) {
                saveError = "Automatic email needs a valid customer email on file."
                return
            }
        }
        let start = NativeRecurringJobs.todayString(from: startDate)
        if isEditing, let rule {
            let updated = Canonical.RecurringInvoice(
                id: rule.id, customerId: customerId, customerName: name,
                description: description.trimmingCharacters(in: .whitespacesAndNewlines),
                amount: Decimal(parsedAmount), dueDays: parsedDueDays,
                cadence: cadence.rawValue, endCondition: endCondition.rawValue,
                endCount: endCondition == .count ? Int(endCount) : rule.endCount,
                endDate: endCondition == .date ? NativeRecurringJobs.todayString(from: endDate) : rule.endDate,
                occurrenceCount: rule.occurrenceCount, lastGeneratedDate: rule.lastGeneratedDate,
                nextDueDate: rule.nextDueDate, isActive: rule.isActive,
                createdAt: rule.createdAt, autoSendEnabled: autoSend,
                preservation: rule.preservation)
            if store.updateRecurringInvoice(updated) { dismiss() }
            else { saveError = "The plan could not be saved. Nothing was changed." }
        } else {
            let created = Canonical.RecurringInvoice(
                id: "rinv_\(Int(Date.now.timeIntervalSince1970 * 1000))",
                customerId: customerId, customerName: name,
                description: description.trimmingCharacters(in: .whitespacesAndNewlines),
                amount: Decimal(parsedAmount), dueDays: parsedDueDays,
                cadence: cadence.rawValue, endCondition: endCondition.rawValue,
                endCount: endCondition == .count ? Int(endCount) : nil,
                endDate: endCondition == .date ? NativeRecurringJobs.todayString(from: endDate) : nil,
                occurrenceCount: 0, lastGeneratedDate: nil, nextDueDate: start,
                isActive: true, createdAt: start, autoSendEnabled: autoSend)
            if store.createRecurringInvoice(created) { dismiss() }
            else { saveError = "The plan could not be saved. Nothing was changed." }
        }
    }
}

private extension Decimal {
    var currency: String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "USD"
        return formatter.string(from: NSDecimalNumber(decimal: self)) ?? "\(self)"
    }
}

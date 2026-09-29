import SwiftUI

/// The create/requestDeposit/finalize sheet, ported from
/// `CreateInvoiceFromJobScreen.tsx`. Simpler than the estimate-review sheet —
/// no composer hand-off, just a `Form` in the style of `InvoiceEditor`. Saving
/// calls `AppStore.commitInvoiceFromJob`, which re-derives line items from the
/// job's current record rather than anything computed here.
struct NativeCreateInvoiceFromJobView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State var draft: NativeInvoiceFromJobDraft

    private var copy: (title: String, cta: String) {
        switch draft.mode {
        case .create: ("Create Invoice", "Create invoice")
        case .requestDeposit: ("Request Deposit", "Request deposit")
        case .finalize: ("Finalize Invoice", "Finalize invoice")
        }
    }

    private var canSave: Bool {
        !draft.customer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && draft.amount > 0
    }

    private var amount: Binding<Double> {
        Binding(
            get: { NSDecimalNumber(decimal: draft.amount).doubleValue },
            set: { draft.amount = Decimal(string: String($0)) ?? 0 }
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                if draft.mode != .finalize, draft.prefillReferenceAmount > 0 {
                    let prefill = NSDecimalNumber(decimal: draft.prefillReferenceAmount).doubleValue
                    Section {
                        Text("Pre-filled from job estimate (\(prefill.currency)). Review and adjust if needed.")
                            .font(.footnote).foregroundStyle(Color.accentColor)
                    }
                }
                if draft.mode == .finalize, draft.finalizeChangeOrderDelta != 0 {
                    let delta = NSDecimalNumber(decimal: draft.finalizeChangeOrderDelta).doubleValue
                    Section {
                        Text("Amount updated to include approved change orders (\(delta > 0 ? "+" : "")\(delta.currency)). Review and adjust if needed.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                if draft.billedFromTracked {
                    Section {
                        Text("⏱ Billed from tracked time. Amount updated to match hours worked.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                Section("Customer") { TextField("Customer name", text: $draft.customer) }
                Section("Details") {
                    TextField("Invoice number", text: $draft.number)
                    CurrencyField(title: "Amount", value: amount)
                    DatePicker("Due", selection: $draft.due, displayedComponents: .date)
                    TextField("Description of work", text: $draft.desc, axis: .vertical)
                }
                Section("Contact") {
                    TextField("Email", text: $draft.email).keyboardType(.emailAddress).textInputAutocapitalization(.never)
                    TextField("Phone", text: $draft.phone).keyboardType(.phonePad)
                }
            }
            .nativeContentColumn(.list)
            .scrollContentBackground(.hidden).background(Color.tradeCanvas)
            .navigationTitle(copy.title)
            .navigationBarTitleDisplayMode(.inline)
            .nativeKeyboardDoneBar()
            .toolbar {
                DismissableFormToolbar(title: copy.cta) {
                    guard canSave else { return }
                    if store.commitInvoiceFromJob(draft) { dismiss() }
                }
            }
        }
        .nativeAnalyticsScreen(.createInvoiceFromJob)
    }
}

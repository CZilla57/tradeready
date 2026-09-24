import PhotosUI
import SwiftUI
import UIKit

// MARK: - Expense editor (task 9.10, requirements E1, E2)
//
// Port of `components/money/AddExpenseModal.tsx`: create/edit/delete with the
// canonical `ExpenseDraft` field set, the 8-category picker, the optional job
// link, and receipt capture. The receipt photo is persisted to the deterministic
// native path first (`AppStore.persistReceipt`), then the 9.04 OCR transport
// pre-fills the form for REVIEW ONLY.
//
// Policy lives in `NativeExpenseComposer`; this view only binds fields and moves
// the scan lifecycle. Nothing here is committed automatically: the scan writes
// draft text, and only an explicit Save reaches `commitExpenseEdit`. A failed or
// unavailable scan leaves manual entry exactly as the user left it.

/// Which expense the sheet is editing. `Identifiable` so the Money screen can
/// present it with `.sheet(item:)` without a second boolean.
enum NativeExpenseEditorTarget: Identifiable, Equatable {
    case create
    case edit(String)

    var id: String {
        switch self {
        case .create: "create"
        case .edit(let id): "edit-\(id)"
        }
    }
}

struct NativeExpenseEditor: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss

    let target: NativeExpenseEditorTarget
    /// The record as the user opened it, used both to seed the form and as the
    /// stale-copy baseline for the field-scoped commit.
    let opened: Expense?
    /// Pre-linked job (the "add expense to this job" path).
    let defaultJobId: String?

    @State private var draft: NativeExpenseEditorDraft
    @State private var touched = NativeExpenseTouchedFields()
    @State private var scanState: NativeExpenseScanState = .idle
    @State private var scanBlurry = false
    /// Monotonic scan id: a result from a photo the user already removed or
    /// replaced is discarded (RN keeps the same guard in `scanIdRef`).
    @State private var scanID = 0
    @State private var pickerItem: PhotosPickerItem?
    @State private var showingLibrary = false
    @State private var showingCamera = false
    @State private var showingReceiptSource = false
    /// One alert slot: the modal form has both a validation guard and a write
    /// failure, and a single presentation avoids two `.alert` modifiers racing
    /// on the same view.
    @State private var alert: NativeExpenseAlert?
    @State private var showingDeleteConfirmation = false

    init(target: NativeExpenseEditorTarget, opened: Expense? = nil, defaultJobId: String? = nil) {
        self.target = target
        self.opened = opened
        self.defaultJobId = defaultJobId
        if let opened {
            var draft = NativeExpenseEditorDraft()
            draft.merchant = opened.merchant
            draft.amountText = NativeExpenseComposer.amountText(Decimal(opened.amount))
            draft.date = opened.date
            draft.categoryID = opened.category.rawValue
            draft.notes = opened.notes
            draft.receiptUri = opened.receiptUri
            draft.jobId = opened.jobId
            _draft = State(initialValue: draft)
        } else {
            var draft = NativeExpenseEditorDraft.newExpense()
            draft.jobId = defaultJobId
            _draft = State(initialValue: draft)
        }
    }

    private var isEditing: Bool { if case .edit = target { return true }; return false }
    private var title: String { isEditing ? "Edit Expense" : "Log Expense" }

    /// Linkable job candidates, newest first. A pre-linked job is always kept in
    /// the list even when its status would otherwise filter it out.
    private var linkableJobs: [Canonical.Job] {
        NativeExpenseComposer.linkableJobs(store.canonicalJobs, alwaysIncludeID: draft.jobId ?? defaultJobId)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledField(label: "What was it?") {
                        TextField("e.g. PVC fittings from Home Depot", text: merchantBinding)
                    }
                    LabeledField(label: "Amount") {
                        TextField("0.00", text: amountBinding)
                            .keyboardType(.decimalPad)
                    }
                    DatePicker("Date", selection: dateBinding, displayedComponents: .date)
                }

                Section("Category") { categoryChips }

                if !linkableJobs.isEmpty {
                    Section("Link to job (optional)") { jobChips }
                }

                Section {
                    LabeledField(label: "Notes (optional)") {
                        TextField("Job number, vendor, receipt #...", text: $draft.notes, axis: .vertical)
                    }
                }

                Section("Receipt photo (optional)") { receiptSection }

                if isEditing {
                    Section {
                        Button(role: .destructive) { showingDeleteConfirmation = true } label: {
                            Label("Delete Expense", systemImage: "trash")
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.tradeCanvas)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }.fontWeight(.semibold)
                }
            }
            .alert(alert?.title ?? "", isPresented: showingAlert, presenting: alert) { _ in
                Button("OK", role: .cancel) { alert = nil }
            } message: { value in
                Text(value.message)
            }
            .confirmationDialog("Add Receipt Photo", isPresented: $showingReceiptSource, titleVisibility: .visible) {
                // A device without a camera (or a disabled one) is offered the
                // library only, rather than a button that cannot work.
                if UIImagePickerController.isSourceTypeAvailable(.camera) {
                    Button("Take Photo") { showingCamera = true }
                }
                Button("Choose from Library") { showingLibrary = true }
                Button("Cancel", role: .cancel) {}
            }
            .photosPicker(isPresented: $showingLibrary, selection: $pickerItem, matching: .images)
            .onChange(of: pickerItem) { _, item in importPickerItem(item) }
            .sheet(isPresented: $showingCamera) {
                NativeJobCamera { data, _, _ in
                    showingCamera = false
                    attachReceipt(sourceData: data)
                }
                .ignoresSafeArea()
            }
            .confirmationDialog(
                "Delete Expense",
                isPresented: $showingDeleteConfirmation,
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) { delete() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Remove \"\(draft.merchant)\"?")
            }
        }
    }

    // MARK: Fields

    /// Every user-owned binding marks its field as touched, which is what stops a
    /// later scan from overwriting what they typed.
    private var merchantBinding: Binding<String> {
        Binding(
            get: { draft.merchant },
            set: { touched.merchant = true; draft.merchant = $0 }
        )
    }

    private var amountBinding: Binding<String> {
        Binding(
            get: { draft.amountText },
            set: { touched.amount = true; draft.amountText = $0 }
        )
    }

    private var dateBinding: Binding<Date> {
        Binding(
            get: { draft.date },
            set: { touched.date = true; draft.date = $0 }
        )
    }

    private var categoryChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(NativeExpenseCategories.all, id: \.id) { category in
                    let selected = draft.categoryID == category.id
                    Button {
                        touched.category = true
                        draft.categoryID = category.id
                    } label: {
                        Label(category.label, systemImage: NativeMoneyCategorySymbol.symbol(for: category.id))
                            .font(.footnote.weight(.semibold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(selected ? Color.tradeReady : Color.tradeInk.opacity(0.06), in: Capsule())
                            .foregroundStyle(selected ? Color.white : Color.primary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selected ? [.isSelected] : [])
                    .accessibilityLabel(category.label)
                }
            }
            .padding(.vertical, 2)
        }
    }

    private var jobChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Button {
                    draft.jobId = nil
                } label: {
                    chipLabel("None", selected: draft.jobId == nil)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("No job link")

                ForEach(linkableJobs, id: \.id) { job in
                    let selected = draft.jobId == job.id
                    Button {
                        draft.jobId = job.id
                    } label: {
                        chipLabel(job.title, selected: selected)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Link to job \(job.title)")
                }
            }
            .padding(.vertical, 2)
        }
    }

    private func chipLabel(_ text: String, selected: Bool) -> some View {
        Text(text)
            .font(.footnote.weight(.semibold))
            .lineLimit(1)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(selected ? Color.tradeReady : Color.tradeInk.opacity(0.06), in: Capsule())
            .foregroundStyle(selected ? Color.white : Color.primary)
    }

    // MARK: Receipt

    @ViewBuilder
    private var receiptSection: some View {
        if let receiptUri = draft.receiptUri {
            if let image = localImage(receiptUri) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(height: 160)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            } else {
                Label("Receipt attached", systemImage: "photo")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            if let banner = NativeExpenseComposer.scanBanner(scanState, blurry: scanBlurry) {
                HStack(spacing: 6) {
                    if scanState == .reading {
                        ProgressView().controlSize(.small)
                    } else if scanState == .filled {
                        Image(systemName: "sparkles").foregroundStyle(Color.tradeReady)
                    }
                    Text(banner)
                        .font(.caption)
                        .foregroundStyle(scanState == .filled ? Color.tradeReady : Color.secondary)
                }
                .accessibilityElement(children: .combine)
            }

            Button(role: .destructive) { removeReceipt() } label: {
                Label("Remove photo", systemImage: "xmark")
            }
        } else {
            Button { showingReceiptSource = true } label: {
                Label("Add receipt photo", systemImage: "camera")
            }
        }

    }

    private func localImage(_ receiptUri: String) -> UIImage? {
        let url = URL(string: receiptUri).flatMap { $0.isFileURL ? $0 : nil }
            ?? URL(fileURLWithPath: receiptUri)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return UIImage(data: data)
    }

    private func importPickerItem(_ item: PhotosPickerItem?) {
        guard let item else { return }
        pickerItem = nil
        Task {
            guard let data = try? await item.loadTransferable(type: Data.self) else {
                await MainActor.run {
                    alert = .failure(
                        title: "Couldn't Add Receipt",
                        message: "That photo couldn't be read. Try another image."
                    )
                }
                return
            }
            await MainActor.run { attachReceipt(sourceData: data) }
        }
    }

    /// Persist, then scan. The photo is attached and visible even when the scan
    /// fails or is unavailable — the receipt is the user's record either way.
    private func attachReceipt(sourceData: Data) {
        scanID += 1
        let currentScan = scanID
        guard let receiptUri = store.persistReceipt(sourceData: sourceData) else {
            alert = .failure(
                title: "Couldn't Add Receipt",
                message: "That image couldn't be used for a receipt. Try another photo."
            )
            return
        }
        draft.receiptUri = receiptUri
        scanBlurry = false
        scanState = .reading

        Task {
            let result = await store.scanReceipt(receiptUri: receiptUri)
            guard currentScan == scanID else { return }
            guard let result else {
                scanBlurry = false
                scanState = .failed
                store.recordReceiptScan(nil, state: .failed)
                return
            }
            let application = NativeExpenseComposer.applyingScan(
                result.extraction, to: &draft, touched: touched
            )
            scanBlurry = application.blurry
            scanState = application.state
            // Task 11.08: RN `AddExpenseModal.tsx:183`, after the fields apply.
            store.recordReceiptScan(result, state: application.state)
        }
    }

    private func removeReceipt() {
        scanID += 1
        draft.receiptUri = nil
        scanState = .idle
        scanBlurry = false
    }

    // MARK: Save / delete

    private func save() {
        if let validation = NativeExpenseComposer.validation(draft) {
            alert = .validation(validation.message)
            return
        }
        guard let amount = NativeExpenseComposer.amountValue(draft.amountText) else {
            alert = .validation(NativeExpenseValidation.invalidAmount.message)
            return
        }
        var expense = opened ?? Expense()
        expense.merchant = draft.merchant.trimmingCharacters(in: .whitespacesAndNewlines)
        expense.amount = amount
        expense.date = draft.date
        expense.category = ExpenseCategory(rawValue: draft.categoryID) ?? .other
        expense.notes = draft.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        expense.receiptUri = draft.receiptUri
        expense.jobId = draft.jobId

        switch store.commitExpenseEdit(id: opened?.id, opened: opened, draft: expense) {
        case .success:
            dismiss()
        case .failure(let refusal):
            alert = .failure(title: "Couldn't Save", message: Self.refusalCopy(refusal))
        }
    }

    private func delete() {
        guard case .edit(let id) = target else { return }
        if store.deleteExpenseRecord(id: id) {
            dismiss()
        } else {
            alert = .failure(
                title: "Couldn't Delete",
                message: "That expense couldn't be deleted. Nothing was changed."
            )
        }
    }

    static func refusalCopy(_ refusal: NativeMoneyRecordRefusal) -> String {
        switch refusal {
        case .persistenceUnavailable: "Your expense couldn't be saved. Nothing was changed."
        case .missingRecord: "That expense is no longer available. Reopen the list."
        case .staleEditorCopy: "This expense changed on another device. Reopen it and try again."
        case .conflictingRecord: "That expense already exists."
        case .invalidDraft(let message): message
        }
    }

    private var showingAlert: Binding<Bool> {
        Binding(
            get: { alert != nil },
            set: { if !$0 { alert = nil } }
        )
    }
}

/// RN's `Alert.alert` cases the modal can raise, in one slot.
private enum NativeExpenseAlert: Equatable {
    /// `Missing Info` — "Please enter a description." / "Please enter a valid amount."
    case validation(String)
    /// A write, capture, or read failure with its own headline.
    case failure(title: String, message: String)

    var title: String {
        switch self {
        case .validation: "Missing Info"
        case .failure(let title, _): title
        }
    }

    var message: String {
        switch self {
        case .validation(let message): message
        case .failure(_, let message): message
        }
    }
}

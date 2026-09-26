import SwiftUI

// MARK: - Tax set-aside settings (12.00b.3, Phase 11 carry G2)
//
// Port of `components/money/TaxSettingsModal.tsx`, opened from the Money tax
// card the way RN's `TaxSetAsideCard` opens it. As in RN there is no Settings
// entry: the card is the feature's one home. `NativeTaxSettingsEditor` holds
// the sheet's state and rules and is seeded from the live settings on each
// open. Save validates there, then commits through
// `AppStore.commitTaxSettings`, which writes only the two tax fields, enqueues
// the settings sync and emits `tax_settings_saved` (RN `TaxSetAsideCard.tsx:53-65`).
// Cancel and a swipe down close without saving (RN Cancel, backdrop tap and
// `onRequestClose`). RN shows the modal without a screen event, so this sheet
// sends none either.

struct NativeTaxSettingsView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss

    @State private var editor: NativeTaxSettingsEditor
    @State private var showingRateAlert = false
    @State private var showingSaveFailure = false

    init(editor: NativeTaxSettingsEditor) {
        _editor = State(initialValue: editor)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(NativeTaxBreakdownCopy.ratePlaceholder, text: $editor.rateText)
                        .keyboardType(.decimalPad)
                        .accessibilityLabel(NativeAccessibilityAudit.Label.taxIncomeRate)
                } header: {
                    Text(NativeTaxBreakdownCopy.rateLabel)
                } footer: {
                    Text(NativeTaxBreakdownCopy.settingsHelp)
                }

                Section {
                    methodRow(.mileage, title: NativeTaxBreakdownCopy.standardMileageLabel, systemImage: "car")
                    methodRow(
                        .actual,
                        title: NativeTaxBreakdownCopy.actualFuelLabel,
                        systemImage: "gauge.with.dots.needle.33percent"
                    )
                    if editor.showsMethodUnsetNote {
                        Text(NativeTaxBreakdownCopy.methodUnsetNote)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text(NativeTaxBreakdownCopy.vehicleLabel)
                } footer: {
                    Text(NativeTaxBreakdownCopy.vehicleHelp(
                        mileageRateText: NativeMoneyFormat.money(editor.mileageRate)
                    ))
                }

                Section {
                    Text(NativeTaxBreakdownCopy.settingsDisclaimer)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .nativeContentColumn(.list)
            .scrollContentBackground(.hidden)
            .background(Color.tradeCanvas)
            .navigationTitle(NativeTaxBreakdownCopy.settingsTitle)
            .navigationBarTitleDisplayMode(.inline)
            .nativeKeyboardDoneBar()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .fontWeight(.semibold)
                        .keyboardShortcut("s", modifiers: .command)
                        .accessibilityLabel(NativeAccessibilityAudit.Label.saveTaxSettings)
                }
            }
            .alert(NativeTaxBreakdownCopy.rateValidationTitle, isPresented: $showingRateAlert) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(NativeTaxBreakdownCopy.rateValidationMessage)
            }
            .alert("Couldn't Save", isPresented: $showingSaveFailure) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Your tax settings couldn't be saved. Nothing was changed.")
            }
        }
    }

    /// One of RN's two radio chips (:118-151): the election is chosen by tapping
    /// it, and nothing un-chooses it.
    private func methodRow(_ method: VehicleDeductionMethod, title: String, systemImage: String) -> some View {
        let isSelected = editor.selectedMethod == method
        return Button {
            editor.select(method)
        } label: {
            HStack(spacing: 12) {
                Label(title, systemImage: systemImage)
                    .foregroundStyle(.primary)
                Spacer(minLength: 8)
                if isSelected {
                    Image(systemName: "checkmark")
                        .fontWeight(.semibold)
                        .foregroundStyle(Color.tradeReady)
                        .accessibilityHidden(true)
                }
            }
        }
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    // MARK: Save

    /// RN `handleSave` (:65-81), then the card's `handleSaveSettings`. A refused
    /// rate raises "Check the rate" and saves nothing; the sheet closes only
    /// once the commit is durable.
    private func save() {
        switch editor.save() {
        case .failure:
            showingRateAlert = true
        case .success(let draft):
            if store.commitTaxSettings(draft) {
                dismiss()
            } else {
                showingSaveFailure = true
            }
        }
    }
}

import SwiftUI

/// Phase 34 (referrals, spec 2026-10-03-referral-program-design.md §5.6):
/// customer detail › a referral row › "Record thank-you". The owner's record
/// of how they thanked the referrer for this one referral. TradeReady keeps
/// the record only: it never sends gifts, credits or money. A credit becomes
/// an invoice line only when the owner turns it on while creating the
/// referrer's next invoice from a job.
struct NativeReferralRewardSheet: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let referredCustomerID: String
    let referredName: String
    let referrerName: String

    @State private var kind: NativeReferrals.RewardKind = .thankYou
    @State private var amount: Double = 0
    @State private var note = ""
    @State private var date = Date()
    @State private var hasExisting = false
    @State private var loaded = false
    @State private var errorMessage: String?
    @State private var confirmingRemove = false
    @State private var expensePrefill: Expense?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Thanking \(referrerName) for referring \(referredName).")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Section {
                    Picker("Kind", selection: $kind) {
                        ForEach(NativeReferrals.RewardKind.allCases) { option in
                            Text(option.displayName).tag(option)
                        }
                    }
                    if kind.takesAmount {
                        CurrencyField(title: kind.requiresAmount ? "Credit amount" : "Amount (optional)", value: $amount)
                    }
                    DatePicker("Date", selection: $date, displayedComponents: .date)
                } header: {
                    Text("How you thanked them")
                } footer: {
                    Text("TradeReady only keeps a record. It never sends gifts, credits or money.")
                }
                Section {
                    TextField("Coffee card, handwritten card…", text: Binding(
                        get: { note },
                        set: { note = String($0.prefix(NativeReferrals.rewardNoteMaxLength)) }
                    ), axis: .vertical)
                    .lineLimit(2...5)
                    .accessibilityLabel("Note")
                } header: {
                    Text("Note (optional)")
                } footer: {
                    Text("Up to \(NativeReferrals.rewardNoteMaxLength) characters.")
                }
                if kind == .invoiceCredit {
                    Section {
                        Text("When you create \(referrerName)'s next invoice from a job, you can apply this credit as a \u{201C}Referral credit\u{201D} line.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                if (kind == .giftCard || kind == .other), amount > 0 {
                    Section {
                        Button("Log as a Marketing expense", systemImage: "receipt") {
                            expensePrefill = Expense(
                                merchant: kind == .giftCard ? "Referral gift card" : "Referral thank-you",
                                amount: amount,
                                category: .marketing,
                                notes: "Referral thank-you for \(referrerName)"
                            )
                        }
                    } footer: {
                        Text("Opens a new expense to review. It's saved only when you tap Save there.")
                    }
                }
                if hasExisting {
                    Section {
                        Button(role: .destructive) {
                            confirmingRemove = true
                        } label: {
                            Label("Remove record", systemImage: "trash").nativeDestructiveText()
                        }
                    }
                }
            }
            .nativeContentColumn(.list)
            .scrollContentBackground(.hidden)
            .background(Color.tradeCanvas)
            .navigationTitle("Record thank-you")
            .navigationBarTitleDisplayMode(.inline)
            .nativeKeyboardDoneBar()
            .toolbar {
                DismissableFormToolbar(title: "Thank-you") { save() }
            }
            .onAppear(perform: load)
            .confirmationDialog(
                "Remove this thank-you record?",
                isPresented: $confirmingRemove,
                titleVisibility: .visible
            ) {
                Button("Remove record", role: .destructive) {
                    if store.removeReferralReward(referredCustomerID: referredCustomerID) {
                        dismiss()
                    } else {
                        errorMessage = "The record could not be removed. Nothing was changed."
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Any credit already on an invoice stays there.")
            }
            .alert("Thank-you not saved", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
            .sheet(item: $expensePrefill) { prefill in
                NativeExpenseEditor(target: .create, prefill: prefill)
            }
        }
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        guard let reward = store.referralReward(referredCustomerID: referredCustomerID) else { return }
        hasExisting = true
        kind = NativeReferrals.RewardKind(rawValue: reward.kind) ?? .other
        amount = reward.amount.map { NSDecimalNumber(decimal: $0).doubleValue } ?? 0
        note = reward.note ?? ""
        if let parsed = NativeCashBasis.parseLocalDate(reward.recordedOn) { date = parsed }
    }

    private func save() {
        let cents = Decimal(string: String(format: "%.2f", amount)) ?? 0
        do {
            let reward = try NativeReferrals.makeReward(
                kind: kind, amount: kind.takesAmount ? cents : nil, note: note,
                recordedOn: NativeCashBasis.ymd(date)
            )
            if store.recordReferralReward(referredCustomerID: referredCustomerID, reward: reward) {
                dismiss()
            } else {
                errorMessage = "Your existing records were preserved. Check that this customer still has a referrer, then try again."
            }
        } catch NativeReferrals.RewardIssue.amountRequired {
            errorMessage = "Enter the credit amount."
        } catch NativeReferrals.RewardIssue.invalidAmount {
            errorMessage = "Enter an amount greater than zero."
        } catch {
            errorMessage = "Check the date and try again."
        }
    }
}

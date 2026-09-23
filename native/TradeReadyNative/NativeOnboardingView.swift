import SwiftUI

struct NativeOnboardingView: View {
    @EnvironmentObject private var store: AppStore
    @State private var draft: NativeOnboardingDocument.Draft
    @State private var showErrors = false
    @State private var errorMessage: String?
    @State private var isSaving = false

    init(draft: NativeOnboardingDocument.Draft) {
        _draft = State(initialValue: draft)
    }

    var body: some View {
        VStack(spacing: 0) {
            Text("Step \(draft.step + 1) of 3 · \(draft.step == 0 ? "Welcome" : "Your business")")
                .font(.caption.monospaced().weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .padding(.vertical, 16)

            ScrollView {
                Group {
                    if draft.step == 0 { welcome }
                    else { business }
                }
                .frame(maxWidth: 560)
                .padding(24)
                .frame(maxWidth: .infinity)
            }

            HStack {
                if draft.step > 0 {
                    Button("Back") { persist(step: 0) }
                        .buttonStyle(.bordered)
                }
                Button(draft.step == 0 ? "Let’s get started" : "Continue") {
                    continueFlow()
                }
                .buttonStyle(.borderedProminent)
                .frame(maxWidth: .infinity)
                .disabled(isSaving)
            }
            .padding(20)
            .background(.background)
        }
        .background(Color.tradeCanvas)
    }

    private var welcome: some View {
        VStack(spacing: 24) {
            VStack(spacing: 8) {
                Text("TradeReady").font(.system(size: 42, weight: .bold, design: .rounded))
                Text("Built to work. Ready to grow.").foregroundStyle(.secondary)
                Text("Manage jobs, invoices, and customers—all in one place.")
                    .multilineTextAlignment(.center)
            }
            VStack(alignment: .leading, spacing: 16) {
                feature("calendar", "Today", "Your schedule and earnings at a glance")
                feature("hammer", "Jobs", "From lead to invoice in seconds")
                feature("doc.text", "Invoices", "Send, track, and get paid faster")
                feature("sparkles", "Coach", "Practical help for your business")
            }
            .padding(20)
            .background(.background, in: RoundedRectangle(cornerRadius: 20))
            VStack(alignment: .leading, spacing: 10) {
                Label("Setup takes about a minute—just your name, business, and trade.", systemImage: "clock")
                Label("TradeReady is a subscription with a free trial. Plans and pricing come next.", systemImage: "creditcard")
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
    }

    private var business: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Your business").font(.largeTitle.bold())
            Text("Just the basics—you can add contact details, your logo, and rates later.")
                .foregroundStyle(.secondary)
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.circle.fill")
                    .foregroundStyle(.red)
            }
            TextField("Business name", text: binding(\.businessName))
                .textContentType(.organizationName)
            if showErrors && draft.businessName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("Business name is required.").font(.caption).foregroundStyle(.red)
            }
            TextField("Your name", text: binding(\.contactName))
                .textContentType(.name)
            if showErrors && draft.contactName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("Your name is required.").font(.caption).foregroundStyle(.red)
            }
            Text("Your trade").font(.headline)
            Text("Used to tailor sample jobs and future pricing guidance.")
                .font(.caption).foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 120))], spacing: 10) {
                ForEach(NativeTypedAccountState.Trade.allCases, id: \.self) { trade in
                    Button(trade.displayName) {
                        draft.trade = trade
                        persist()
                    }
                    .buttonStyle(.bordered)
                    .tint(draft.trade == trade ? .tradeReady : .secondary)
                    .accessibilityAddTraits(draft.trade == trade ? .isSelected : [])
                }
            }
        }
        .textFieldStyle(.roundedBorder)
    }

    private func feature(_ icon: String, _ title: String, _ detail: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon).frame(width: 26).foregroundStyle(.tint)
            VStack(alignment: .leading) {
                Text(title).font(.headline)
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }

    private func binding(_ keyPath: WritableKeyPath<NativeOnboardingDocument.Draft, String>) -> Binding<String> {
        Binding {
            draft[keyPath: keyPath]
        } set: { value in
            draft[keyPath: keyPath] = String(value.prefix(120))
            persist()
        }
    }

    private func persist(step: Int? = nil) {
        if let step { draft.step = step }
        do { try store.saveOnboardingDraft(draft) }
        catch { errorMessage = error.localizedDescription }
    }

    private func continueFlow() {
        errorMessage = nil
        if draft.step == 0 {
            persist(step: 1)
            return
        }
        guard !draft.businessName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !draft.contactName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            showErrors = true
            return
        }
        isSaving = true
        defer { isSaving = false }
        do { try store.completeOnboardingPersonalization(draft) }
        catch { errorMessage = error.localizedDescription }
    }
}

struct NativeStartingPointView: View {
    @EnvironmentObject private var store: AppStore
    let trade: NativeTypedAccountState.Trade
    @State private var isChoosing = false
    @State private var errorMessage: String?

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                Text("Step 3 of 3 · Starting point")
                    .font(.caption.monospaced().weight(.semibold))
                    .foregroundStyle(.secondary).textCase(.uppercase)
                Text("How do you want to start?").font(.largeTitle.bold())
                Text("One last choice and you’re working.").foregroundStyle(.secondary)
                if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
                choiceCard(
                    .sample,
                    icon: "chart.bar.doc.horizontal",
                    title: "Explore with sample data",
                    detail: "See an example \(trade.displayName.lowercased()) job, invoice, customer, and expense. Your existing records are never replaced.",
                    action: "Explore the app"
                )
                choiceCard(
                    .fresh,
                    icon: "sparkles",
                    title: "Start with my business",
                    detail: "Begin with a clean slate. Any real records already on this device remain untouched.",
                    action: "Start fresh"
                )
            }
            .frame(maxWidth: 560)
            .padding(24)
            .frame(maxWidth: .infinity)
        }
        .background(Color.tradeCanvas)
    }

    private func choiceCard(
        _ choice: NativeStartingPointChoice,
        icon: String,
        title: String,
        detail: String,
        action: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(title, systemImage: icon).font(.title3.bold())
            Text(detail).foregroundStyle(.secondary)
            Button(action) { choose(choice) }
                .buttonStyle(.borderedProminent)
                .frame(maxWidth: .infinity)
                .disabled(isChoosing)
        }
        .padding(20)
        .background(.background, in: RoundedRectangle(cornerRadius: 20))
    }

    private func choose(_ choice: NativeStartingPointChoice) {
        guard !isChoosing else { return }
        isChoosing = true
        errorMessage = nil
        defer { isChoosing = false }
        do { try store.completeStartingPoint(choice) }
        catch { errorMessage = error.localizedDescription }
    }
}

private extension NativeTypedAccountState.Trade {
    var displayName: String {
        self == .hvac ? "HVAC" : rawValue.capitalized
    }
}

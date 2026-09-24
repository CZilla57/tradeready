import SwiftUI

private struct NativeRecurringRuleDraft: Identifiable {
    let rule: Canonical.RecurringJob
    var id: String { rule.id }
}

struct NativeRecurringJobsView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var editingRule: NativeRecurringRuleDraft?

    var body: some View {
        NavigationStack {
            List {
                if store.recurringJobRules.isEmpty {
                    ContentUnavailableView("No recurring jobs", systemImage: "repeat", description: Text("Open a job and choose Set up repeat to create a series."))
                } else {
                    ForEach(store.recurringJobRules, id: \.id) { rule in
                        Section {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    VStack(alignment: .leading) {
                                        Text(rule.title).font(.headline)
                                        Text(rule.customerName).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Label(rule.isActive ? "Active" : "Paused", systemImage: rule.isActive ? "play.circle.fill" : "pause.circle.fill")
                                        .font(.caption).foregroundStyle(rule.isActive ? .green : .secondary)
                                }
                                Text("\(cadenceLabel(rule.cadence)) · \(rule.occurrenceCount) generated · next \(rule.nextDueDate)")
                                    .font(.caption).foregroundStyle(.secondary)
                                Text(endLabel(rule)).font(.caption).foregroundStyle(.secondary)
                                HStack {
                                    Button(rule.isActive ? "Pause" : "Resume", systemImage: rule.isActive ? "pause.fill" : "play.fill") {
                                        if rule.isActive { _ = store.pauseRecurringJob(id: rule.id) } else { _ = store.resumeRecurringJob(id: rule.id) }
                                    }
                                    Button("Edit", systemImage: "pencil") { editingRule = NativeRecurringRuleDraft(rule: rule) }
                                    if let occurrence = store.latestGeneratedJob(forRecurringID: rule.id) {
                                        Button("View occurrence", systemImage: "arrow.up.right") {
                                            store.selectedTab = .jobs
                                            store.deepLinkedJobID = occurrence.id
                                            dismiss()
                                        }
                                    }
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
            }
            .nativeContentColumn(.list)
            .tradeReadyListStyle()
            .navigationTitle("Recurring jobs")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() }.keyboardShortcut(.cancelAction) } }
            .sheet(item: $editingRule) { draft in NativeRecurringJobEditor(rule: draft.rule) }
        }
        .nativeAnalyticsScreen(.recurringJobs)
    }

    private func cadenceLabel(_ value: String) -> String {
        RecurrenceCadence(rawValue: value)?.rawValue.capitalized ?? value.capitalized
    }

    private func endLabel(_ rule: Canonical.RecurringJob) -> String {
        switch RecurrenceEndCondition(rawValue: rule.endCondition) ?? .never {
        case .never: return "No end date"
        case .count: return "Ends after \(rule.endCount ?? 0) jobs"
        case .date: return "Ends \(rule.endDate ?? "")"
        }
    }
}

struct NativeRecurringJobEditor: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var rule: Canonical.RecurringJob
    @State private var endCount = ""
    @State private var endDate = Date()

    init(rule: Canonical.RecurringJob) {
        _rule = State(initialValue: rule)
        _endCount = State(initialValue: rule.endCount.map(String.init) ?? "")
        _endDate = State(initialValue: Self.date(from: rule.endDate) ?? .now)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Repeat") {
                    Picker("Cadence", selection: $rule.cadence) {
                        ForEach(RecurrenceCadence.allCases, id: \.rawValue) { Text($0.rawValue.capitalized).tag($0.rawValue) }
                    }
                    Picker("Ends", selection: $rule.endCondition) {
                        Text("Never").tag(RecurrenceEndCondition.never.rawValue)
                        Text("After a number of jobs").tag(RecurrenceEndCondition.count.rawValue)
                        Text("On a date").tag(RecurrenceEndCondition.date.rawValue)
                    }
                    if rule.endCondition == RecurrenceEndCondition.count.rawValue {
                        TextField("Number of jobs", text: $endCount).keyboardType(.numberPad)
                    } else if rule.endCondition == RecurrenceEndCondition.date.rawValue {
                        DatePicker("End date", selection: $endDate, displayedComponents: .date)
                    }
                }
                Section("Series") {
                    Text(rule.isActive ? "Series is active" : "Series is paused")
                    LabeledContent("Generated", value: String(rule.occurrenceCount))
                    LabeledContent("Next due", value: rule.nextDueDate)
                }
            }
            .nativeContentColumn(.list)
            .navigationTitle("Repeat \(rule.title)")
            .toolbar {
                DismissableFormToolbar(title: "Save") {
                    rule.endCount = rule.endCondition == RecurrenceEndCondition.count.rawValue ? max(Int(endCount) ?? 1, rule.occurrenceCount) : nil
                    rule.endDate = rule.endCondition == RecurrenceEndCondition.date.rawValue ? endDate.dateOnlyString : nil
                    if store.updateRecurringJob(rule) { dismiss() }
                }
            }
        }
    }

    private static func date(from value: String?) -> Date? {
        guard let value else { return nil }
        let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd"; formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.date(from: value)
    }
}

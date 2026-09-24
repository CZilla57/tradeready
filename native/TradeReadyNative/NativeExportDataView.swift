import SwiftUI
import UIKit

// MARK: - Accounting export (task 9.13, requirements X1, X2)
//
// Port of `screens/ExportDataScreen.tsx`: the range chips (with the custom
// start/end pickers and the "Check your dates" guard), the accountant-package
// row, the three CSV rows with live row counts, the footnote, and the share
// tail. Every byte comes from 9.06's builders; this screen only picks a window
// and hands the payload to the system share sheet.

struct NativeExportDataView: View {
    @EnvironmentObject private var store: AppStore

    @State private var choice: NativeExportRangeChoice = .thisYear
    @State private var customStart: Date
    @State private var customEnd: Date
    @State private var shareItem: NativeShareItem?
    @State private var alert: NativeExportAlert?

    init(now: Date = Date(), calendar: Calendar = NativeCashBasis.localCalendar) {
        let start = calendar.date(from: DateComponents(
            year: calendar.component(.year, from: now), month: 1, day: 1
        )) ?? now
        _customStart = State(initialValue: start)
        _customEnd = State(initialValue: now)
    }

    private var range: NativeDateRange {
        NativeExportRange.range(
            for: choice, customStart: customStart, customEnd: customEnd, now: Date()
        )
    }

    private var csvs: [NativeExportDataset: String] {
        NativeExportRows.csvs(
            invoices: store.canonicalInvoices,
            expenses: store.canonicalExpenses,
            trips: store.canonicalTrips,
            range: range
        )
    }

    private var rows: [NativeExportRow] {
        NativeExportRows.rows(csvs, range: range, rangeID: choice.rawValue)
    }

    var body: some View {
        List {
            Section(NativeExportRows.dateRangeHeading) {
                rangeChips
                if choice.isCustom { customDatePickers }
            }

            Section(NativeExportRows.footnote) {
                exportRow(
                    label: NativeExportRows.packageLabel,
                    detail: NativeExportRows.packageHint,
                    action: sharePackage
                )
                ForEach(rows, id: \.dataset) { row in
                    exportRow(label: row.label, detail: row.detailText) { share(row) }
                }
            }
        }
        .tradeReadyListStyle()
        .navigationTitle("Export data")
        .navigationBarTitleDisplayMode(.inline)
        .alert(alert?.title ?? "", isPresented: showingAlert, presenting: alert) { _ in
            Button("OK", role: .cancel) { alert = nil }
        } message: { value in
            Text(value.message)
        }
        .sheet(item: $shareItem) { item in
            NativeShareSheet(url: item.url)
        }
        .nativeAnalyticsScreen(.exportData)
    }

    // MARK: Pieces

    private var rangeChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(NativeExportRangeChoice.allCases) { option in
                    Button { choice = option } label: {
                        Text(option.label)
                            .font(.footnote.weight(.semibold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(
                                choice == option ? Color.tradeReadyFill : Color.tradeInk.opacity(0.06),
                                in: Capsule()
                            )
                            .foregroundStyle(choice == option ? Color.white : Color.primary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(choice == option ? [.isSelected] : [])
                    .accessibilityLabel("Range: \(option.label)")
                }
            }
            .padding(.vertical, 2)
        }
    }

    private var customDatePickers: some View {
        Group {
            DatePicker("From", selection: $customStart, displayedComponents: .date)
            DatePicker("To", selection: $customEnd, displayedComponents: .date)
        }
    }

    private func exportRow(label: String, detail: String, action: @escaping () -> Void) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(.subheadline.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button(NativeExportRows.shareTitle, action: action)
                .buttonStyle(.bordered)
                .accessibilityLabel("Share \(label)")
        }
    }

    // MARK: Share

    private func share(_ row: NativeExportRow) {
        guard checkDates() else { return }
        let csv = csvs[row.dataset] ?? ""
        stageShare(NativeCSVExport.sharePayload(csv: csv), filename: row.filename)
    }

    private func sharePackage() {
        guard checkDates() else { return }
        let package = NativeAccountingPackage.buildAccountingPackage(
            NativePackageInput(
                invoices: store.canonicalInvoices,
                expenses: store.canonicalExpenses,
                trips: store.canonicalTrips,
                customers: store.canonicalCustomers,
                jobNameById: Dictionary(
                    uniqueKeysWithValues: store.canonicalJobs.map { ($0.id, $0.title) }
                )
            ),
            start: range.start,
            end: range.end
        )
        stageShare(NativeCSVExport.sharePayload(zipBytes: package.bytes), filename: package.filename)
    }

    /// RN's guard: a custom range whose start is after its end never shares.
    private func checkDates() -> Bool {
        guard NativeExportRange.isInvalid(choice, customStart: customStart, customEnd: customEnd) else {
            return true
        }
        alert = .failure(title: NativeExportRange.invalidTitle, message: NativeExportRange.invalidMessage)
        return false
    }

    private func stageShare(_ data: Data, filename: String) {
        do {
            let url = try NativeExportShare.write(data, filename: filename)
            shareItem = NativeShareItem(url: url)
        } catch {
            alert = .failure(title: "Couldn't prepare the file", message: "Nothing was shared. Please try again.")
        }
    }

    private var showingAlert: Binding<Bool> {
        Binding(
            get: { alert != nil },
            set: { if !$0 { alert = nil } }
        )
    }
}

private enum NativeExportAlert: Equatable {
    case failure(title: String, message: String)
    var title: String { if case .failure(let title, _) = self { return title }; return "" }
    var message: String { if case .failure(_, let message) = self { return message }; return "" }
}

/// A written export file, identified for `.sheet(item:)`.
struct NativeShareItem: Identifiable, Equatable {
    let url: URL
    var id: String { url.absoluteString }
}

/// Thin `UIActivityViewController` wrapper for a single file URL.
struct NativeShareSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

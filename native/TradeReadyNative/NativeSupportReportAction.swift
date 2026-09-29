import SwiftUI

/// Phase 12 (12.02): the one "Prepare support report" action. Settings ›
/// Import Data › Migration support shows it, and so do both blocked screens in
/// `RootView` (migration paused, cleanup paused), whose owner cannot reach
/// Settings. It only asks the store for the report
/// (`AppStore.createPersistenceSupportReport`), which reads diagnostics and
/// writes `tradeready-support-report.json` beside the store: no owner record
/// is written, so it works while owner writes are blocked. Once prepared, the
/// same row shares the file; nothing leaves the device until the owner picks
/// where to send it.
struct NativeSupportReportAction: View {
    @EnvironmentObject private var store: AppStore
    @State private var reportURL: URL?
    @State private var errorMessage: String?

    var body: some View {
        if let reportURL {
            ShareLink(item: reportURL) {
                Label("Share support report", systemImage: "square.and.arrow.up")
            }
        } else {
            Button {
                do {
                    reportURL = try store.createPersistenceSupportReport()
                    errorMessage = nil
                } catch {
                    errorMessage = "The support report could not be created."
                }
            } label: {
                Label("Prepare support report", systemImage: "wrench.and.screwdriver")
            }
        }
        Text("Includes only app version and build, data counts, backup, migration, cleanup and sync status, and error codes. It never includes customer records, names, contact details or credentials.")
            .font(.caption).foregroundStyle(.secondary)
        if let errorMessage {
            Text(errorMessage).font(.caption).foregroundStyle(Color.tradeDangerText)
        }
    }
}

import SwiftUI
import UniformTypeIdentifiers

// MARK: - CSV import (task 9.13, requirements I1-I3)
//
// Port of `screens/SettingsImportScreen.tsx`: pick a CSV, map columns against
// the detected vocabulary, choose a date format, preview, commit explicitly,
// read the per-row report, and undo. Parse/map/validate/commit all live in
// 9.07 + `AppStore.commitImport`; this screen is orchestration and copy.
//
// Nothing is auto-committed: the durable write happens only on "Import now",
// history is device-local, and undo strips only that batch's own records.

struct NativeImportView: View {
    @EnvironmentObject private var store: AppStore

    @State private var entity: NativeImportEntity = .customers
    @State private var stage: NativeImportStage = .idle
    @State private var headers: [String] = []
    @State private var rows: [[String]] = []
    @State private var mapping: [String?] = []
    @State private var fileHash = ""
    @State private var fileWasTruncated = false
    @State private var dateFormatChoice: NativeImportDateFormatChoice = .auto
    @State private var report: AppStore.NativeImportCommitReport?
    @State private var pendingImport: NativePendingImport?
    @State private var showingFileImporter = false
    @State private var alert: NativeImportAlert?

    var body: some View {
        List {
            Section {
                Text(NativeImportCopy.subtitle)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                entityChips
            }

            switch stage {
            case .idle:
                idleSection
                historySection
            case .mapping:
                mappingSection
            case .preview:
                previewSection
            case .report:
                reportSection
            }
        }
        .tradeReadyListStyle()
        .navigationTitle(NativeImportCopy.title)
        .navigationBarTitleDisplayMode(.inline)
        .fileImporter(
            isPresented: $showingFileImporter,
            allowedContentTypes: [.commaSeparatedText, .plainText, .text, .data],
            allowsMultipleSelection: false
        ) { result in
            handlePickedFile(result)
        }
        .alert(alert?.title ?? "", isPresented: showingAlert, presenting: alert) { value in
            switch value {
            case .confirmation:
                Button(NativeImportCopy.alreadyImportedConfirm) { runPendingImport() }
                Button("Cancel", role: .cancel) { pendingImport = nil; alert = nil }
            default:
                Button("OK", role: .cancel) { alert = nil }
            }
        } message: { value in
            Text(value.message)
        }
    }

    // MARK: Header + stages

    private var entityChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(NativeImportEntity.allCases, id: \.rawValue) { option in
                    Button { selectEntity(option) } label: {
                        Text(NativeImportCopy.entityLabel(option))
                            .font(.footnote.weight(.semibold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(
                                entity == option ? Color.tradeReadyFill : Color.tradeInk.opacity(0.06),
                                in: Capsule()
                            )
                            .foregroundStyle(entity == option ? Color.white : Color.primary)
                    }
                    .buttonStyle(.plain)
                    .disabled(stage != .idle)
                    .opacity(stage == .idle || entity == option ? 1 : 0.5)
                    .accessibilityAddTraits(entity == option ? [.isSelected] : [])
                    .accessibilityLabel("Import \(NativeImportCopy.entityLabel(option))")
                }
            }
            .padding(.vertical, 2)
        }
    }

    private var idleSection: some View {
        Section {
            Button(NativeImportCopy.chooseFileTitle) { showingFileImporter = true }
        }
    }

    private var mappingSection: some View {
        Section {
            ForEach(Array(headers.enumerated()), id: \.offset) { index, header in
                VStack(alignment: .leading, spacing: 4) {
                    Text(header).font(.caption.monospaced()).foregroundStyle(.secondary)
                    Picker(header, selection: mappingBinding(index)) {
                        Text(NativeImportCopy.ignoreOptionLabel).tag(String?.none)
                        ForEach(NativeImportMapping.fieldDefs[entity] ?? [], id: \.key) { field in
                            Text(field.label).tag(String?.some(field.key))
                        }
                    }
                    .labelsHidden()
                    .accessibilityLabel("Map \(header)")
                }
            }

            if NativeImportCopy.mappedDateColumnIndex(entity, mapping: mapping) != nil {
                VStack(alignment: .leading, spacing: 6) {
                    Text(NativeImportCopy.dateFormatLabel).font(.caption).foregroundStyle(.secondary)
                    Picker(NativeImportCopy.dateFormatLabel, selection: $dateFormatChoice) {
                        ForEach(NativeImportDateFormatChoice.allCases, id: \.rawValue) { option in
                            Text(option.label).tag(option)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
            }

            Button(NativeImportCopy.previewImportTitle) { validateAndPreview() }
        } header: {
            Text(NativeImportCopy.matchColumnsTitle)
        }
    }

    private var previewSection: some View {
        Section {
            ForEach(Array(rows.prefix(5).enumerated()), id: \.offset) { _, row in
                Text(NativeImportCopy.previewLine(row))
                    .font(.caption.monospaced())
                    .lineLimit(2)
            }
            Text(NativeImportCopy.readyText(rowCount: rows.count))
                .font(.footnote)
                .foregroundStyle(.secondary)
            Button(NativeImportCopy.importNowTitle) { commit() }
        } header: {
            Text(NativeImportCopy.previewTitle)
        }
    }

    private var reportSection: some View {
        Section {
            if let report {
                Text(NativeImportCopy.summaryLine(entity, counts: report.counts))
                    .font(.subheadline)

                let problems = NativeImportCopy.problemRows(report.outcomes)
                ForEach(problems.rows, id: \.rowIndex) { outcome in
                    Text(NativeImportCopy.outcomeText(outcome))
                        .font(.caption.monospaced())
                        .foregroundStyle(outcome.status == "flag" ? .orange : .secondary)
                }
                if problems.extra > 0 {
                    Text("+\(problems.extra) more").font(.footnote).foregroundStyle(.secondary)
                }
            }

            Button(NativeImportCopy.undoTitle) { undo() }
            Button(NativeImportCopy.importAnotherTitle) { selectEntity(entity) }
        } header: {
            Text(NativeImportCopy.importCompleteTitle)
        }
    }

    private var historySection: some View {
        Section {
            let history = store.importHistory
            if history.isEmpty {
                Text(NativeImportCopy.emptyHistoryText).font(.footnote).foregroundStyle(.secondary)
            } else {
                ForEach(history.prefix(5), id: \.batchId) { record in
                    Text(NativeImportCopy.historyText(record))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text(NativeImportCopy.historyHeading)
        }
    }

    // MARK: Actions

    private func mappingBinding(_ index: Int) -> Binding<String?> {
        Binding(
            get: { index < mapping.count ? mapping[index] : nil },
            set: { newValue in
                guard index < mapping.count else { return }
                mapping[index] = newValue
            }
        )
    }

    private func selectEntity(_ next: NativeImportEntity) {
        entity = next
        stage = .idle
        headers = []
        rows = []
        mapping = []
        fileHash = ""
        fileWasTruncated = false
        dateFormatChoice = .auto
        report = nil
        pendingImport = nil
    }

    private func handlePickedFile(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result, let url = urls.first else { return }
        let needsScope = url.startAccessingSecurityScopedResource()
        defer { if needsScope { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8)
        else {
            alert = .failure(
                title: NativeImportCopy.readFailedTitle,
                message: NativeImportCopy.readFailedMessage
            )
            return
        }
        let parsed = NativeCSVImport.parseCsv(text)
        guard !parsed.headers.isEmpty else {
            alert = .failure(
                title: NativeImportCopy.emptyFileTitle,
                message: NativeImportCopy.emptyFileMessage
            )
            return
        }
        let hash = NativeCSVImport.hashCsv(text)
        let prior = store.importBatch(entity: entity, fileHash: hash)
        pendingImport = NativePendingImport(
            headers: parsed.headers, rows: parsed.rows, hash: hash, truncated: parsed.truncated
        )
        if prior != nil {
            alert = .confirmation(
                title: NativeImportCopy.alreadyImportedTitle,
                message: NativeImportCopy.alreadyImportedMessage
            )
        } else {
            runPendingImport()
        }
    }

    /// Loads the pending file into the mapping stage. Runs either straight after
    /// picking or after the "already imported?" confirmation.
    private func runPendingImport() {
        guard let pending = pendingImport else { return }
        pendingImport = nil
        alert = nil
        headers = pending.headers
        rows = pending.rows
        fileHash = pending.hash
        fileWasTruncated = pending.truncated
        mapping = NativeImportMapping.detectMapping(entity: entity, headers: pending.headers)
        dateFormatChoice = .auto
        stage = .mapping
        if pending.truncated {
            alert = .note(title: NativeImportCopy.largeFileTitle, message: NativeImportCopy.largeFileMessage)
        }
    }

    private func validateAndPreview() {
        let missing = NativeImportCopy.missingRequiredFields(entity, mapping: mapping)
        guard missing.isEmpty else {
            alert = .failure(
                title: NativeImportCopy.mapRequiredTitle,
                message: NativeImportCopy.mapRequiredMessage(missing)
            )
            return
        }
        stage = .preview
    }

    private func commit() {
        let format = resolvedDateFormat()
        let result = store.commitImport(
            entity: entity,
            rows: rows,
            mapping: mapping,
            dateFormat: format,
            fileHash: fileHash,
            truncated: fileWasTruncated
        )
        switch result {
        case .success(let report):
            self.report = report
            stage = .report
        case .failure:
            alert = .failure(
                title: NativeImportCopy.importFailedTitle,
                message: NativeImportCopy.importFailedMessage
            )
        }
    }

    /// "Auto" resolves through the detector over the mapped date column; an
    /// explicit choice is used as-is.
    private func resolvedDateFormat() -> NativeDateFormat? {
        if let explicit = dateFormatChoice.format { return explicit }
        return NativeImportMapping.detectDateFormat(
            samples: NativeImportCopy.dateSamples(entity, mapping: mapping, rows: rows)
        )
    }

    private func undo() {
        guard let report else { return }
        if store.undoImport(batchID: report.batchID) {
            let copy = NativeImportCopy.undoAlert(entity)
            self.report = nil
            selectEntity(entity)
            alert = .note(title: copy.title, message: copy.message)
        } else {
            alert = .failure(
                title: NativeImportCopy.undoFailedTitle,
                message: NativeImportCopy.undoTargetMissingMessage
            )
        }
    }

    private var showingAlert: Binding<Bool> {
        Binding(
            get: { alert != nil },
            set: { if !$0 { alert = nil } }
        )
    }
}

/// A parsed, not-yet-mapped file waiting on the re-import confirmation.
private struct NativePendingImport {
    var headers: [String]
    var rows: [[String]]
    var hash: String
    var truncated: Bool
}

/// The screen's alert slots: a plain note, a failure, or the re-import question.
private enum NativeImportAlert: Equatable {
    case note(title: String, message: String)
    case failure(title: String, message: String)
    case confirmation(title: String, message: String)

    var title: String {
        switch self {
        case .note(let title, _), .failure(let title, _), .confirmation(let title, _): title
        }
    }

    var message: String {
        switch self {
        case .note(_, let message), .failure(_, let message), .confirmation(_, let message): message
        }
    }
}

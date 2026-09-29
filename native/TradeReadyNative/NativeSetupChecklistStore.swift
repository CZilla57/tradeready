import Foundation

enum NativeSetupChecklistStoreError: Error, Equatable {
    case invalidAccountBinding
    case accountBindingMismatch
    case unreadableStore
    case unsupportedSchema
}

/// Exact-owner-bound store for the setup-checklist state (task 10.03, D4/D5).
///
/// Same durability contract as `NativeReviewRequestStore`: one versioned
/// document per verified account binding, last-known-good backup, atomic writes,
/// fail-closed reads. The state is device-local and never syncs; sign-out wipes
/// it so the next account does not inherit a dismissal or a "used once" flag.
struct NativeSetupChecklistStore {
    private struct Document: Codable {
        static let currentSchemaVersion = 1

        let schemaVersion: Int
        let accountBinding: String
        let state: NativeSetupChecklistState
    }

    let fileURL: URL
    private let fileManager: FileManager

    init(fileURL: URL, fileManager: FileManager = .default) {
        self.fileURL = fileURL
        self.fileManager = fileManager
    }

    var backupURL: URL { fileURL.appendingPathExtension("backup") }

    func load(for accountBinding: String) throws -> NativeSetupChecklistState {
        try validateAccountBinding(accountBinding)
        if fileManager.fileExists(atPath: fileURL.path) {
            return try decode(Data(contentsOf: fileURL), accountBinding: accountBinding)
        }
        if fileManager.fileExists(atPath: backupURL.path) {
            return try decode(Data(contentsOf: backupURL), accountBinding: accountBinding)
        }
        return NativeSetupChecklistState()
    }

    func save(_ state: NativeSetupChecklistState, for accountBinding: String) throws {
        try validateAccountBinding(accountBinding)
        if fileManager.fileExists(atPath: fileURL.path) {
            let current = try Data(contentsOf: fileURL)
            _ = try decode(current, accountBinding: accountBinding)
            try atomicWrite(current, to: backupURL)
        }
        let document = Document(
            schemaVersion: Document.currentSchemaVersion,
            accountBinding: accountBinding,
            state: state
        )
        try atomicWrite(try JSONEncoder().encode(document), to: fileURL)
    }

    /// Records one completed task. An already-recorded task is a no-op that does
    /// not write, mirroring `markSetupTaskDone`.
    @discardableResult
    func markTaskDone(_ task: NativeSetupTaskID, for accountBinding: String) throws -> NativeSetupChecklistState {
        let current = try load(for: accountBinding)
        if current.isDone(task) { return current }
        let updated = NativeSetupChecklist.markingDone(task, in: current)
        try save(updated, for: accountBinding)
        return updated
    }

    /// `dismissSetupChecklist` — always writes, keeping recorded completions.
    @discardableResult
    func dismiss(for accountBinding: String) throws -> NativeSetupChecklistState {
        let updated = NativeSetupChecklist.dismissing(try load(for: accountBinding))
        try save(updated, for: accountBinding)
        return updated
    }

    /// `markSampleTourDone` — the hero shows at most once; already-set is a no-op.
    @discardableResult
    func markSampleTourDone(for accountBinding: String) throws -> NativeSetupChecklistState {
        let current = try load(for: accountBinding)
        if current.sampleTourDone == true { return current }
        let updated = NativeSetupChecklist.markingSampleTourDone(current)
        try save(updated, for: accountBinding)
        return updated
    }

    /// Adopts the migrated `setupChecklistState` once at activation; existing
    /// owner state wins. Returns the state that should be published.
    @discardableResult
    func mergeSeeded(
        _ seed: NativeSetupChecklistState,
        for accountBinding: String
    ) throws -> NativeSetupChecklistState {
        let stored = try load(for: accountBinding)
        let merged = NativeSetupChecklist.mergingSeed(seed, into: stored)
        guard merged != stored else { return stored }
        try save(merged, for: accountBinding)
        return merged
    }

    func removeAll() throws {
        for url in [fileURL, backupURL] where fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
    }

    private func decode(_ data: Data, accountBinding: String) throws -> NativeSetupChecklistState {
        let document: Document
        do { document = try JSONDecoder().decode(Document.self, from: data) }
        catch { throw NativeSetupChecklistStoreError.unreadableStore }
        guard document.schemaVersion == Document.currentSchemaVersion else {
            throw NativeSetupChecklistStoreError.unsupportedSchema
        }
        guard document.accountBinding == accountBinding else {
            throw NativeSetupChecklistStoreError.accountBindingMismatch
        }
        return document.state
    }

    private func validateAccountBinding(_ value: String) throws {
        guard value.count == 64, value.utf8.allSatisfy({
            (48...57).contains($0) || (97...102).contains($0)
        }) else { throw NativeSetupChecklistStoreError.invalidAccountBinding }
    }

    private func atomicWrite(_ data: Data, to url: URL) throws {
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
    }
}

/// The one-shot contextual invoice-reminder prompt flag (`REMINDER_PROMPT_KEY`,
/// `utils/notifications.ts`), modelled as its own owner-bound value so a stale
/// "already asked" flag can never leak into the next account. The flag is stamped
/// BEFORE the alert is shown, so a dismissed prompt never repeats.
struct NativeReminderPromptStore {
    private struct Document: Codable {
        static let currentSchemaVersion = 1

        let schemaVersion: Int
        let accountBinding: String
        let shown: Bool
    }

    let fileURL: URL
    private let fileManager: FileManager

    init(fileURL: URL, fileManager: FileManager = .default) {
        self.fileURL = fileURL
        self.fileManager = fileManager
    }

    var backupURL: URL { fileURL.appendingPathExtension("backup") }

    func wasShown(for accountBinding: String) throws -> Bool {
        try validateAccountBinding(accountBinding)
        guard fileManager.fileExists(atPath: fileURL.path) else { return false }
        let document: Document
        do { document = try JSONDecoder().decode(Document.self, from: Data(contentsOf: fileURL)) }
        catch { throw NativeSetupChecklistStoreError.unreadableStore }
        guard document.schemaVersion == Document.currentSchemaVersion else {
            throw NativeSetupChecklistStoreError.unsupportedSchema
        }
        guard document.accountBinding == accountBinding else {
            throw NativeSetupChecklistStoreError.accountBindingMismatch
        }
        return document.shown
    }

    /// Stamps the flag. Once true it stays true (a re-stamp is a no-op write).
    @discardableResult
    func markShown(for accountBinding: String) throws -> Bool {
        if try wasShown(for: accountBinding) { return true }
        let document = Document(
            schemaVersion: Document.currentSchemaVersion,
            accountBinding: accountBinding,
            shown: true
        )
        try atomicWrite(try JSONEncoder().encode(document), to: fileURL)
        return true
    }

    /// Adopts the migrated `invoiceReminderPromptShown` seed; a live owner flag
    /// always wins, and a seed can only ever set it to true.
    @discardableResult
    func mergeSeeded(_ shown: Bool, for accountBinding: String) throws -> Bool {
        guard shown else { return try wasShown(for: accountBinding) }
        return try markShown(for: accountBinding)
    }

    func removeAll() throws {
        for url in [fileURL, backupURL] where fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
    }

    private func validateAccountBinding(_ value: String) throws {
        guard value.count == 64, value.utf8.allSatisfy({
            (48...57).contains($0) || (97...102).contains($0)
        }) else { throw NativeSetupChecklistStoreError.invalidAccountBinding }
    }

    private func atomicWrite(_ data: Data, to url: URL) throws {
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
    }
}

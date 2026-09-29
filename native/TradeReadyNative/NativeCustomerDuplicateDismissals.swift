import Foundation

enum NativeCustomerDuplicateDismissalStoreError: Error, Equatable {
    case invalidAccountBinding
    case accountBindingMismatch
    case invalidPairKey
    case unreadableStore
    case unsupportedSchema
}

/// Owner-bound local state for customer duplicate suggestions the user has
/// dismissed. This is deliberately separate from the canonical business-data
/// snapshot and sync queue: dismissing a suggestion must never rewrite customer
/// identity or propagate device-local UI state to Supabase.
struct NativeCustomerDuplicateDismissalStore {
    private struct Document: Codable {
        static let currentSchemaVersion = 1

        let schemaVersion: Int
        let accountBinding: String
        let pairKeys: [String]
    }

    let fileURL: URL
    private let fileManager: FileManager

    init(fileURL: URL, fileManager: FileManager = .default) {
        self.fileURL = fileURL
        self.fileManager = fileManager
    }

    var backupURL: URL { fileURL.appendingPathExtension("backup") }

    func load(for accountBinding: String) throws -> [String] {
        try validateAccountBinding(accountBinding)
        if fileManager.fileExists(atPath: fileURL.path) {
            return try decode(Data(contentsOf: fileURL), accountBinding: accountBinding)
        }
        if fileManager.fileExists(atPath: backupURL.path) {
            return try decode(Data(contentsOf: backupURL), accountBinding: accountBinding)
        }
        return []
    }

    func save(_ pairKeys: some Sequence<String>, for accountBinding: String) throws {
        try validateAccountBinding(accountBinding)
        let normalized = try normalize(pairKeys)

        if fileManager.fileExists(atPath: fileURL.path) {
            let current = try Data(contentsOf: fileURL)
            _ = try decode(current, accountBinding: accountBinding)
            try atomicWrite(current, to: backupURL)
        }

        let document = Document(
            schemaVersion: Document.currentSchemaVersion,
            accountBinding: accountBinding,
            pairKeys: normalized
        )
        try atomicWrite(try JSONEncoder().encode(document), to: fileURL)
    }

    func removeAll() throws {
        for url in [fileURL, backupURL] where fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
    }

    private func decode(_ data: Data, accountBinding: String) throws -> [String] {
        let document: Document
        do { document = try JSONDecoder().decode(Document.self, from: data) }
        catch { throw NativeCustomerDuplicateDismissalStoreError.unreadableStore }
        guard document.schemaVersion == Document.currentSchemaVersion else {
            throw NativeCustomerDuplicateDismissalStoreError.unsupportedSchema
        }
        guard document.accountBinding == accountBinding else {
            throw NativeCustomerDuplicateDismissalStoreError.accountBindingMismatch
        }
        return try normalize(document.pairKeys)
    }

    private func normalize(_ pairKeys: some Sequence<String>) throws -> [String] {
        var result: Set<String> = []
        for key in pairKeys {
            let parts = key.split(separator: "|", omittingEmptySubsequences: false)
            guard key.utf8.count <= 512,
                  parts.count == 2,
                  !parts[0].isEmpty,
                  !parts[1].isEmpty,
                  parts[0] < parts[1],
                  key.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) })
            else { throw NativeCustomerDuplicateDismissalStoreError.invalidPairKey }
            result.insert(key)
        }
        return result.sorted()
    }

    private func validateAccountBinding(_ value: String) throws {
        guard value.count == 64, value.utf8.allSatisfy({
            (48...57).contains($0) || (97...102).contains($0)
        }) else { throw NativeCustomerDuplicateDismissalStoreError.invalidAccountBinding }
    }

    private func atomicWrite(_ data: Data, to url: URL) throws {
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
    }
}

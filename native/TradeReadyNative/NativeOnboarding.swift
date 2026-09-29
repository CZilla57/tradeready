import Foundation

enum NativeOnboardingError: LocalizedError, Equatable {
    case invalidAccountBinding
    case accountMismatch
    case corruptState
    case invalidDraft

    var errorDescription: String? {
        switch self {
        case .invalidAccountBinding, .accountMismatch:
            "This device contains data from another account."
        case .corruptState:
            "Your setup progress could not be read. Your saved business data was left unchanged."
        case .invalidDraft:
            "Enter your business name and your name to continue."
        }
    }
}

enum NativeStartingPointChoice: String, Codable, Equatable, Sendable {
    case sample
    case fresh
}

struct NativeOnboardingDocument: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    enum Stage: String, Codable, Equatable, Sendable {
        case drafting
        case personalizationCommit
        case personalized
        case sampleCommit
        case freshCommit
        case done
    }

    struct Draft: Codable, Equatable, Sendable {
        var businessName: String
        var contactName: String
        var trade: NativeTypedAccountState.Trade
        var step: Int

        func validated() throws -> Draft {
            let business = businessName.trimmingCharacters(in: .whitespacesAndNewlines)
            let contact = contactName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !business.isEmpty, !contact.isEmpty,
                  business.count <= 120, contact.count <= 120, (0...1).contains(step)
            else { throw NativeOnboardingError.invalidDraft }
            return .init(businessName: business, contactName: contact, trade: trade, step: step)
        }
    }

    let schemaVersion: Int
    let accountBinding: String
    var stage: Stage
    var draft: Draft
    var sampleNamespace: String?
    var sampleAnchor: Date?

    init(
        accountBinding: String,
        stage: Stage,
        draft: Draft,
        sampleNamespace: String? = nil,
        sampleAnchor: Date? = nil
    ) {
        schemaVersion = Self.currentSchemaVersion
        self.accountBinding = accountBinding
        self.stage = stage
        self.draft = draft
        self.sampleNamespace = sampleNamespace
        self.sampleAnchor = sampleAnchor
    }
}

struct NativeOnboardingStore {
    static let filename = "native-account-workspace.json"

    let primaryURL: URL
    let backupURL: URL
    private let fileManager: FileManager

    init(snapshotURL: URL, fileManager: FileManager = .default) {
        primaryURL = snapshotURL.deletingLastPathComponent().appendingPathComponent(Self.filename)
        backupURL = primaryURL.appendingPathExtension("backup")
        self.fileManager = fileManager
    }

    func load() throws -> NativeOnboardingDocument? {
        if fileManager.fileExists(atPath: primaryURL.path) {
            do { return try decode(Data(contentsOf: primaryURL)) }
            catch {
                guard fileManager.fileExists(atPath: backupURL.path) else { throw error }
                let backup = try Data(contentsOf: backupURL)
                let recovered = try decode(backup)
                try atomicWrite(backup, to: primaryURL)
                return recovered
            }
        }
        guard fileManager.fileExists(atPath: backupURL.path) else { return nil }
        let backup = try Data(contentsOf: backupURL)
        let recovered = try decode(backup)
        try atomicWrite(backup, to: primaryURL)
        return recovered
    }

    func establish(
        accountBinding: String,
        imported: NativeTypedAccountState?,
        hasPersonalizedSettings: Bool,
        allowCreation: Bool = true
    ) throws -> NativeOnboardingDocument {
        guard Self.isBinding(accountBinding) else { throw NativeOnboardingError.invalidAccountBinding }
        if let current = try load() {
            guard current.accountBinding == accountBinding else { throw NativeOnboardingError.accountMismatch }
            return current
        }
        guard allowCreation else { throw NativeOnboardingError.accountMismatch }

        let importedDraft = imported?.onboardingDraft
        let draft = NativeOnboardingDocument.Draft(
            businessName: importedDraft?.businessName ?? "",
            contactName: importedDraft?.contactName ?? "",
            trade: importedDraft?.trade ?? .plumbing,
            step: importedDraft?.step == 1 ? 1 : 0
        )
        let stage: NativeOnboardingDocument.Stage
        if imported?.onboardingStage == .personalized {
            stage = .personalized
        } else if imported?.onboardingStage == .done || imported?.onboardingComplete == true {
            stage = .done
        } else if imported?.onboardingComplete == false {
            stage = .drafting
        } else {
            // Pre-onboarding accounts already carrying personalized settings
            // are returning users; do not ask them to seed sample data again.
            stage = hasPersonalizedSettings ? .done : .drafting
        }
        let created = NativeOnboardingDocument(
            accountBinding: accountBinding,
            stage: stage,
            draft: draft
        )
        try save(created)
        return created
    }

    func save(_ document: NativeOnboardingDocument) throws {
        guard Self.isBinding(document.accountBinding),
              document.schemaVersion == NativeOnboardingDocument.currentSchemaVersion,
              (0...1).contains(document.draft.step)
        else { throw NativeOnboardingError.corruptState }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let bytes = try encoder.encode(document)
        try fileManager.createDirectory(
            at: primaryURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        if fileManager.fileExists(atPath: primaryURL.path),
           let current = try? Data(contentsOf: primaryURL),
           (try? decode(current)) != nil
        {
            try atomicWrite(current, to: backupURL)
        }
        try atomicWrite(bytes, to: primaryURL)
        guard try decode(Data(contentsOf: primaryURL)) == document else {
            throw NativeOnboardingError.corruptState
        }
    }

    private func decode(_ data: Data) throws -> NativeOnboardingDocument {
        guard let document = try? JSONDecoder().decode(NativeOnboardingDocument.self, from: data),
              document.schemaVersion == NativeOnboardingDocument.currentSchemaVersion,
              Self.isBinding(document.accountBinding),
              (0...1).contains(document.draft.step)
        else { throw NativeOnboardingError.corruptState }
        return document
    }

    private func atomicWrite(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
    }

    private static func isBinding(_ value: String) -> Bool {
        value.count == 64 && value.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }
}

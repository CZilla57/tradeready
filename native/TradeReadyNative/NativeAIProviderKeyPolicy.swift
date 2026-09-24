import Foundation

// Task 11.15 (contract §11, C19): the Foundation-only policy for Settings ›
// AI Assistant "Advanced" key entry (RN `screens/SettingsAIScreen.tsx`).
// Copy, trim and shape validation, the save/clear outcome, the masked saved
// state, and provider precedence live here; the view only renders them and
// `AppStore` only applies them to the existing secure store
// (`NativeAIProviderKeyStore.swift`). Nothing here logs, persists or reports.

/// The two user-supplied provider keys, in RN's render order (the Groq card,
/// then the Anthropic card).
enum NativeAIProviderKeyKind: String, CaseIterable, Sendable {
    case groq
    case anthropic

    /// The Keychain account under `NativeKeychainSecureSettingsStore`: RN's
    /// `SECURE_FIELDS` names, the accounts migrated keys use, which
    /// `clearAccountValues()` removes and the canonical codec strips.
    var secureAccount: String {
        switch self {
        case .groq: return "groqKey"
        case .anthropic: return "anthropicKey"
        }
    }

    var providerName: String {
        switch self {
        case .groq: return "Groq"
        case .anthropic: return "Anthropic"
        }
    }

    /// The prefix every real key of this provider carries. It is also a
    /// credential prefix in `NativeSensitiveData.secretValuePrefixes`, so the
    /// shared analytics and crash screens recognize any key this policy
    /// accepts (`sk-ant-` is matched by `sk-`).
    var requiredPrefix: String {
        switch self {
        case .groq: return "gsk_"
        case .anthropic: return "sk-ant-"
        }
    }

    /// RN hint text, verbatim.
    var hint: String {
        switch self {
        case .groq:
            return "Groq API key — powers the AI chat tab (estimates, advice, invoice messages). Get a free key at console.groq.com — no billing required."
        case .anthropic:
            return "Anthropic (Claude) API key — used for AI-generated invoice outreach messages. Get one at console.anthropic.com."
        }
    }

    /// RN placeholder, verbatim.
    var placeholder: String {
        switch self {
        case .groq: return "gsk_..."
        case .anthropic: return "sk-ant-..."
        }
    }

    /// RN `accessibilityLabel`, verbatim.
    var accessibilityLabel: String { "\(providerName) API key" }
}

/// What a save or remove did, for the page's feedback line. Messages name the
/// provider only and never echo the entry.
enum NativeAIProviderKeyChange: Equatable, Sendable {
    case saved(NativeAIProviderKeyKind)
    case cleared(NativeAIProviderKeyKind)
    case rejected(NativeAIProviderKeyKind, NativeAIProviderKeyPolicy.Rejection)
    case failed(NativeAIProviderKeyKind, removing: Bool)

    var message: String {
        switch self {
        case .saved(let kind):
            return "\(kind.accessibilityLabel) saved."
        case .cleared(let kind):
            return "\(kind.accessibilityLabel) removed."
        case .rejected(let kind, let rejection):
            return rejection.message(for: kind)
        case .failed(let kind, let removing):
            return removing
                ? "The \(kind.accessibilityLabel) could not be removed from this device. Try again."
                : "The \(kind.accessibilityLabel) could not be saved securely on this device. Try again."
        }
    }

    var isError: Bool {
        switch self {
        case .saved, .cleared: return false
        case .rejected, .failed: return true
        }
    }

    /// A completed save or remove empties the field so the key does not stay
    /// in view state; a refused or failed one keeps it for correction.
    var clearsEntry: Bool { !isError }
}

enum NativeAIProviderKeyPolicy {
    // MARK: RN copy (verbatim)

    static let introHint = "AI features work automatically via our cloud service. Toggle Advanced to use your own API keys instead."
    static let advancedTitle = "Advanced"
    static let advancedAccessibilityLabel = "Advanced AI settings"
    static let storageNote = "Stored only on your device. Never share this key."

    // MARK: Native copy

    static let saveButtonTitle = "Save key"
    static let removeButtonTitle = "Remove key"

    // MARK: Validation

    /// Whole-key length bounds, prefix included. Real keys are 56 (Groq) and
    /// about 108 (Anthropic) characters; the bounds only catch a truncated or
    /// wrong paste.
    static let minimumLength = 20
    static let maximumLength = 512
    /// The characters `NativeErrorRedaction.secretPrefixPattern` consumes after
    /// a credential prefix. A key limited to them is redacted whole, never
    /// with a surviving tail.
    static let allowedCharacters = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-"
    )

    enum Rejection: Equatable, Sendable {
        case wrongPrefix
        case invalidCharacters
        case wrongLength
        /// Signed out, or an account boundary (sign-out, deletion, scrub) is
        /// in progress: keys are owner-bound and cannot change then.
        case unavailable

        func message(for kind: NativeAIProviderKeyKind) -> String {
            switch self {
            case .wrongPrefix:
                return "That doesn't look like a \(kind.accessibilityLabel). \(kind.providerName) keys start with \(kind.requiredPrefix)."
            case .invalidCharacters:
                return "API keys contain only letters, numbers, - and _. Check for extra spaces or characters and try again."
            case .wrongLength:
                return "That doesn't look like a complete \(kind.accessibilityLabel). Paste the whole key and try again."
            case .unavailable:
                return "Sign in to change your AI keys."
            }
        }
    }

    enum Outcome: Equatable, Sendable {
        case store(String)
        case clear
        case rejected(Rejection)
    }

    /// The entry with surrounding whitespace and newlines removed.
    static func normalized(_ entry: String) -> String {
        entry.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Save is offered only when something other than whitespace is typed.
    /// The field never shows the saved key, so an empty field is not a
    /// deletion; removing a key is the explicit Remove action.
    static func canSubmit(_ entry: String) -> Bool {
        !normalized(entry).isEmpty
    }

    /// Save: a well-formed key is stored trimmed; an empty trimmed entry is a
    /// clear (contract §11); anything else is refused. Nothing changes while
    /// `canChange` is false.
    static func outcome(for entry: String, kind: NativeAIProviderKeyKind, canChange: Bool = true) -> Outcome {
        guard canChange else { return .rejected(.unavailable) }
        let key = normalized(entry)
        if key.isEmpty { return .clear }
        guard key.hasPrefix(kind.requiredPrefix) else { return .rejected(.wrongPrefix) }
        guard key.unicodeScalars.allSatisfy(allowedCharacters.contains) else { return .rejected(.invalidCharacters) }
        guard (minimumLength...maximumLength).contains(key.count) else { return .rejected(.wrongLength) }
        return .store(key)
    }

    /// The explicit Remove action.
    static func clearOutcome(canChange: Bool) -> Outcome {
        canChange ? .clear : .rejected(.unavailable)
    }

    /// Applies `outcome` through the secure store's `save`/`clear` and maps
    /// the result. Store errors are reduced to `.failed`; their text (which
    /// names only the Keychain account) is not surfaced.
    static func apply(
        _ outcome: Outcome,
        kind: NativeAIProviderKeyKind,
        save: (String) throws -> Void,
        clear: () throws -> Void
    ) -> NativeAIProviderKeyChange {
        switch outcome {
        case .rejected(let rejection):
            return .rejected(kind, rejection)
        case .store(let key):
            do { try save(key) } catch { return .failed(kind, removing: false) }
            return .saved(kind)
        case .clear:
            do { try clear() } catch { return .failed(kind, removing: true) }
            return .cleared(kind)
        }
    }

    // MARK: Reading and display

    /// The key a Keychain item holds: UTF-8, trimmed, nil when empty. The
    /// same rule the coach used for migrated keys before 11.15.
    static func storedKey(from data: Data?) -> String? {
        guard let data, let value = String(data: data, encoding: .utf8) else { return nil }
        let trimmed = normalized(value)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Masked display. RN has no masked format (its secure field redisplays
    /// the saved value as dots), so native shows the provider name and
    /// "Saved" — no character of the key, not even the last four.
    static func statusTitle(for kind: NativeAIProviderKeyKind) -> String { kind.accessibilityLabel }

    static func savedStatus(isSaved: Bool) -> String { isSaved ? "Saved" : "Not set" }

    /// The provider the coach routes to for these saved keys: exactly
    /// `NativeCoachTransport.provider` (Anthropic, then Groq, then backend).
    static func provider(savedAnthropicKey: String?, savedGroqKey: String?) -> NativeCoachProvider {
        NativeCoachTransport.provider(anthropicKey: savedAnthropicKey ?? "", groqKey: savedGroqKey ?? "")
    }
}

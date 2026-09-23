import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - Coach transport and provider routing (task 10.10, requirement C1)
//
// Port of `utils/aiService.ts`'s three transports plus the provider-precedence
// routing `screens/ChatScreen.tsx#send` performs inline: the user's own
// Anthropic key, then the user's own Groq key, then the authenticated backend
// proxy (`backend-workers/src/routes/aiChat.js`, the live `/api/ai-chat`
// route — NOT the legacy `backend/api/ai-chat.js` Vercel proxy). Secure
// provider keys are sent only in the `x-api-key` / `Authorization` request
// headers — never interpolated into the prompt, an error message, or a log
// line (see `NativeCoachTransportTests` for a fixture proving this).
//
// Networking follows the injected-loader pattern in `NativeInvoiceDelivery.swift`
// rather than the synchronous-bridge one in `NativeAITransport.swift`: coach
// replies are consumed from `async` UI code (10.13's `CoachView` rewrite), so
// there is no need for a blocking semaphore bridge, and an injectable
// `async throws -> (Data, URLResponse)` loader lets host tests run with no
// live network calls. `backendBaseURL` and the session bytes are supplied by
// the caller per-call (mirroring `NativeInvoiceDeliveryService`), so this file
// stays free of `BuildEnvironment`/Keychain dependencies and compiles for the
// focused host-test runner on its own.
//
// RN throws a plain `Error` from all three transports and `ChatScreen.send`
// catches it into an `isError` bubble reading `Something went wrong: <message>`
// (see the contract's §7). This file mirrors that throw contract exactly with
// a typed `NativeCoachTransportError` — a "typed result the UI renders as an
// error bubble" per the task brief, and never a raw/opaque failure.

/// One message in the transcript sent to a provider. RN's `ChatMessage` shape
/// (`{ role: "user" | "assistant", text }`).
struct NativeCoachMessage: Equatable, Sendable {
    enum Role: String, Equatable, Sendable { case user, assistant }
    var role: Role
    var text: String
}

/// Each provider model id is one named constant, so a future model change is
/// a one-line, separately reviewed edit rather than a scattered string change.
enum NativeCoachModel {
    static let anthropic = "claude-sonnet-4-6"
    static let groq = "llama-3.1-8b-instant"
}

/// The provider RN's `ChatScreen.send` selects, in precedence order.
enum NativeCoachProvider: Equatable, Sendable {
    case anthropic(apiKey: String)
    case groq(apiKey: String)
    case backend
}

/// Typed failures mirroring RN's thrown `Error` messages exactly, so the UI's
/// `Something went wrong: \(error.message)` bubble reads identically. Provider
/// keys never appear in any case's message.
enum NativeCoachTransportError: Error, Equatable, Sendable {
    case missingAnthropicKey
    case missingGroqKey
    case backendNotConfigured
    case signInRequired
    /// The provider (or backend) responded with its own error message.
    case providerError(String)
    case emptyResponse
    /// A transport-level failure (network error, non-2xx from the backend, or
    /// an unparseable response body) with no provider-supplied message.
    case unavailable

    var message: String {
        switch self {
        case .missingAnthropicKey:
            return "No AI key set. Add your Anthropic API key in Settings → AI Assistant."
        case .missingGroqKey:
            return "No AI key set. Add your Groq API key in Settings → AI Assistant."
        case .backendNotConfigured:
            return "Backend not configured."
        case .signInRequired:
            return "Sign in to use the AI assistant."
        case .providerError(let text):
            return text
        case .emptyResponse:
            return "No response from AI"
        case .unavailable:
            return "AI error"
        }
    }
}

/// Injectable HTTP loader — the URLSession-like seam `NativeInvoiceDelivery.swift`
/// uses, so host tests never touch the network.
protocol NativeCoachHTTPDataLoading: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}
extension URLSession: NativeCoachHTTPDataLoading {}

struct NativeCoachTransport: Sendable {
    /// `MAX_HISTORY` — the last 20 messages are sent, computed AFTER the new
    /// user message has been appended (so a 21-message history sends 20).
    static let maxHistory = 20
    static let maxTokens = 600
    static let anthropicVersion = "2023-06-01"
    static let anthropicURL = URL(string: "https://api.anthropic.com/v1/messages")!
    static let groqURL = URL(string: "https://api.groq.com/openai/v1/chat/completions")!
    static let backendPath = "api/ai-chat"

    var backendBaseURL: URL?
    var loader: any NativeCoachHTTPDataLoading

    init(backendBaseURL: URL?, loader: any NativeCoachHTTPDataLoading = URLSession.shared) {
        self.backendBaseURL = backendBaseURL
        self.loader = loader
    }

    /// Provider precedence: user Anthropic key -> user Groq key -> backend proxy.
    static func provider(anthropicKey: String, groqKey: String) -> NativeCoachProvider {
        if !anthropicKey.isEmpty { return .anthropic(apiKey: anthropicKey) }
        if !groqKey.isEmpty { return .groq(apiKey: groqKey) }
        return .backend
    }

    /// Routes to the selected provider. `sessionBytes` is the opaque Supabase
    /// session payload (only consulted on the backend path); it is never
    /// logged and only its `access_token` field is read.
    func sendMessage(
        messages: [NativeCoachMessage],
        systemPrompt: String?,
        anthropicKey: String,
        groqKey: String,
        sessionBytes: Data?
    ) async throws -> String {
        switch Self.provider(anthropicKey: anthropicKey, groqKey: groqKey) {
        case .anthropic(let key):
            return try await sendClaude(messages: messages, systemPrompt: systemPrompt, apiKey: key)
        case .groq(let key):
            return try await sendGroq(messages: messages, systemPrompt: systemPrompt, apiKey: key)
        case .backend:
            return try await sendBackend(messages: messages, systemPrompt: systemPrompt, sessionBytes: sessionBytes)
        }
    }

    // MARK: Anthropic (`sendClaudeMessage`)

    func sendClaude(messages: [NativeCoachMessage], systemPrompt: String?, apiKey: String) async throws -> String {
        guard !apiKey.isEmpty else { throw NativeCoachTransportError.missingAnthropicKey }
        let recent = Array(messages.suffix(Self.maxHistory))
        var body: [String: Any] = [
            "model": NativeCoachModel.anthropic,
            "max_tokens": Self.maxTokens,
            "messages": recent.map { ["role": $0.role.rawValue, "content": $0.text] },
        ]
        if let systemPrompt, !systemPrompt.isEmpty { body["system"] = systemPrompt }

        var request = URLRequest(url: Self.anthropicURL)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(Self.anthropicVersion, forHTTPHeaderField: "anthropic-version")

        // RN does not check `res.ok` for the direct providers — only whether
        // the parsed body carries an `error` field — so this mirrors that.
        let json = try await performJSON(request)
        if let error = json["error"] {
            throw NativeCoachTransportError.providerError(Self.errorText(error) ?? "AI error")
        }
        let blocks = json["content"] as? [[String: Any]] ?? []
        let text = blocks.compactMap { $0["text"] as? String }.joined()
        guard !text.isEmpty else { throw NativeCoachTransportError.emptyResponse }
        return text
    }

    // MARK: Groq (`sendGroqMessage`)

    func sendGroq(messages: [NativeCoachMessage], systemPrompt: String?, apiKey: String) async throws -> String {
        guard !apiKey.isEmpty else { throw NativeCoachTransportError.missingGroqKey }
        let recent = Array(messages.suffix(Self.maxHistory))
        var chatMessages: [[String: String]] = []
        if let systemPrompt, !systemPrompt.isEmpty {
            chatMessages.append(["role": "system", "content": systemPrompt])
        }
        chatMessages.append(contentsOf: recent.map { ["role": $0.role.rawValue, "content": $0.text] })
        let body: [String: Any] = [
            "model": NativeCoachModel.groq,
            "messages": chatMessages,
            "max_tokens": Self.maxTokens,
            "temperature": 0.7,
        ]

        var request = URLRequest(url: Self.groqURL)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let json = try await performJSON(request)
        // RN's `if (data.error) throw new Error(data.error.message || "AI error")`
        // is a plain truthiness check on `error` — any present, non-null value,
        // not only an object with a `message` field — so this mirrors that.
        if let error = json["error"], !(error is NSNull) {
            // RN reads `data.error.message` unconditionally (no `typeof` branch
            // like the Anthropic path) — an object's `message` field, or the
            // "AI error" fallback for anything else, including a bare string.
            let message = (error as? [String: Any])?["message"] as? String
            throw NativeCoachTransportError.providerError(message ?? "AI error")
        }
        let choices = json["choices"] as? [[String: Any]] ?? []
        let text = (choices.first?["message"] as? [String: Any])?["content"] as? String ?? ""
        guard !text.isEmpty else { throw NativeCoachTransportError.emptyResponse }
        return text
    }

    // MARK: Backend proxy (`sendBackendGroqMessage`)

    func sendBackend(
        messages: [NativeCoachMessage],
        systemPrompt: String?,
        sessionBytes: Data?
    ) async throws -> String {
        guard let base = backendBaseURL else { throw NativeCoachTransportError.backendNotConfigured }
        guard let token = Self.accessToken(sessionBytes) else { throw NativeCoachTransportError.signInRequired }

        let recent = Array(messages.suffix(Self.maxHistory))
        var body: [String: Any] = [
            "messages": recent.map { ["role": $0.role.rawValue, "text": $0.text] },
        ]
        if let systemPrompt { body["systemPrompt"] = systemPrompt }

        var request = URLRequest(url: base.appending(path: Self.backendPath))
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await load(request)
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        let ok = (response as? HTTPURLResponse).map { (200..<300).contains($0.statusCode) } ?? false
        if !ok || json?["error"] != nil {
            throw NativeCoachTransportError.providerError((json?["error"] as? String) ?? "AI error")
        }
        let text = json?["text"] as? String ?? ""
        guard !text.isEmpty else { throw NativeCoachTransportError.emptyResponse }
        return text
    }

    // MARK: Helpers

    private static func accessToken(_ bytes: Data?) -> String? {
        guard let bytes, !bytes.isEmpty,
              let json = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              let token = json["access_token"] as? String, !token.isEmpty
        else { return nil }
        return token
    }

    private static func errorText(_ error: Any) -> String? {
        if let text = error as? String { return text }
        if let object = error as? [String: Any] { return object["message"] as? String }
        return nil
    }

    private func performJSON(_ request: URLRequest) async throws -> [String: Any] {
        let (data, _) = try await load(request)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NativeCoachTransportError.unavailable
        }
        return json
    }

    private func load(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do { return try await loader.data(for: request) }
        catch { throw NativeCoachTransportError.unavailable }
    }
}

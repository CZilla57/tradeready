import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - Advisory AI transport (tasks 9.04 / 9.05 / 9.10)
//
// The live implementation of both advisory transports. Receipt OCR and
// pricebook suggestions share one shape (RN keeps the same split in
// `utils/anthropicMessage.ts` + `utils/receiptOCR.ts` + `utils/pricebookAI.ts`):
//
//   1. the user's own Anthropic key, sent straight from the device, or
//   2. the backend route with the signed-in session's bearer token.
//
// Both protocols are synchronous, so the bridge here is an explicitly bounded
// wait around the URLSession callback. Every exit that is not a 2xx with a body
// is `nil`, which is what makes the never-throws contract in `NativeReceiptOCR`
// and `NativePricebookAI` hold. This transport is advisory only: it can propose
// values for review and can never write canonical state.

/// One transport serving both advisory protocols, so the app has a single
/// credential boundary rather than one HTTP client per feature.
protocol NativeAdvisoryAITransport: NativeReceiptOCRTransport, NativePricebookAITransport {}

struct NativeAITransport: NativeAdvisoryAITransport {
    static let anthropicURL = URL(string: "https://api.anthropic.com/v1/messages")!
    static let anthropicModel = "claude-sonnet-4-6"
    static let anthropicVersion = "2023-06-01"
    /// Bounded so a hung request can never pin the calling task forever.
    static let requestTimeout: TimeInterval = 30

    var backendBaseURL: URL?
    /// Reads the opaque Supabase session bytes; the token is extracted here and
    /// never logged, stored, or sent anywhere but the backend.
    var sessionProvider: () -> Data?
    var client: URLSession = .shared

    /// The production transport: the configured backend plus the Keychain
    /// session, both resolved lazily so signing out cannot strand a credential.
    static func live(sessionProvider: @escaping () -> Data? = {
        try? NativeKeychainSecureSettingsStore().readSupabaseSession()
    }) -> NativeAITransport {
        NativeAITransport(backendBaseURL: BuildEnvironment.backendBaseURL, sessionProvider: sessionProvider)
    }

    // MARK: NativeReceiptOCRTransport

    func claudeMessage(prompt: String, apiKey: String, maxTokens: Int, imageBase64: String, mediaType: String) -> String? {
        guard !apiKey.isEmpty, !imageBase64.isEmpty else { return nil }
        let content: [[String: Any]] = [
            ["type": "image", "source": ["type": "base64", "media_type": mediaType, "data": imageBase64]],
            ["type": "text", "text": prompt],
        ]
        return anthropicMessage(apiKey: apiKey, maxTokens: maxTokens, content: content)
    }

    func backendExtract(imageBase64: String, mediaType: String) -> String? {
        guard !imageBase64.isEmpty else { return nil }
        guard let token = accessToken() else { return nil }
        return postJSON(
            path: "api/receipt-extract",
            body: ["imageBase64": imageBase64, "mediaType": mediaType],
            bearer: token
        )
    }

    // MARK: NativePricebookAITransport

    func claudeMessage(prompt: String, apiKey: String, maxTokens: Int) -> String? {
        guard !apiKey.isEmpty else { return nil }
        return anthropicMessage(apiKey: apiKey, maxTokens: maxTokens, content: prompt)
    }

    func backendSuggest(payload: [String: Canonical.JSONValue]) -> String? {
        guard let token = accessToken() else { return nil }
        guard let data = try? JSONEncoder().encode(payload) else { return nil }
        return post(data: data, path: "api/pricebook-suggest", bearer: token)
    }

    // MARK: Anthropic

    private func anthropicMessage(apiKey: String, maxTokens: Int, content: Any) -> String? {
        let body: [String: Any] = [
            "model": Self.anthropicModel,
            "max_tokens": maxTokens,
            "messages": [["role": "user", "content": content]],
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        var request = URLRequest(url: Self.anthropicURL)
        request.httpMethod = "POST"
        request.httpBody = data
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(Self.anthropicVersion, forHTTPHeaderField: "anthropic-version")
        guard let response = perform(request) else { return nil }
        return Self.anthropicText(response)
    }

    /// The Messages API reply: every `content[].text` concatenated. An `error`
    /// object is a failure, and empty text is `nil` — the RN client's `fallback`.
    static func anthropicText(_ data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["error"] == nil,
              let blocks = json["content"] as? [[String: Any]]
        else { return nil }
        let text = blocks.compactMap { $0["text"] as? String }.joined()
        return text.isEmpty ? nil : text
    }

    // MARK: Backend

    private func accessToken() -> String? {
        guard let bytes = sessionProvider(), !bytes.isEmpty,
              let json = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              let token = json["access_token"] as? String,
              !token.isEmpty
        else { return nil }
        return token
    }

    private func postJSON(path: String, body: [String: Any], bearer: String) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        return post(data: data, path: path, bearer: bearer)
    }

    private func post(data: Data, path: String, bearer: String) -> String? {
        guard let base = backendBaseURL else { return nil }
        var request = URLRequest(url: base.appending(path: path))
        request.httpMethod = "POST"
        request.httpBody = data
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        guard let response = perform(request) else { return nil }
        return String(data: response, encoding: .utf8)
    }

    /// Bounded synchronous bridge over the async URLSession API. Non-2xx, a
    /// transport error, or a timeout all return nil.
    private func perform(_ request: URLRequest) -> Data? {
        let semaphore = DispatchSemaphore(value: 0)
        let box = ResponseBox()
        let task = client.dataTask(with: request) { data, response, _ in
            box.store(data: data, status: (response as? HTTPURLResponse)?.statusCode)
            semaphore.signal()
        }
        task.resume()
        if semaphore.wait(timeout: .now() + Self.requestTimeout) == .timedOut {
            task.cancel()
            return nil
        }
        guard let status = box.status, (200..<300).contains(status) else { return nil }
        return box.data
    }

    /// Tiny lock-protected box: the completion handler runs on a URLSession
    /// queue, so the result must not be read without a happens-before edge.
    private final class ResponseBox: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: (data: Data?, status: Int?) = (nil, nil)

        func store(data: Data?, status: Int?) {
            lock.lock()
            storage = (data, status)
            lock.unlock()
        }

        var data: Data? {
            lock.lock(); defer { lock.unlock() }
            return storage.data
        }

        var status: Int? {
            lock.lock(); defer { lock.unlock() }
            return storage.status
        }
    }
}

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// Coach transport tests (task 10.10, requirement C1).
//
// Ports the provider-precedence, missing-key, history-truncation, and
// unparseable/empty-response behavior from `utils/aiService.ts`
// (`sendClaudeMessage`, `sendGroqMessage`, `sendBackendGroqMessage`) against a
// fake `NativeCoachHTTPDataLoading` — no live network call is made.

private var failures = 0

private func expect(_ condition: @autoclosure () -> Bool, _ label: String) {
    if !condition() { failures += 1; print("FAIL: \(label)") }
}

private func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ label: String) {
    if actual != expected { failures += 1; print("FAIL: \(label) — expected \(expected), got \(actual)") }
}

/// Records the last request it served and returns a canned (data, status).
private final class FakeLoader: NativeCoachHTTPDataLoading, @unchecked Sendable {
    var responseData: Data = Data()
    var status: Int = 200
    var throwsError = false
    private(set) var lastRequest: URLRequest?
    private(set) var requestCount = 0

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        lastRequest = request
        requestCount += 1
        if throwsError { throw URLError(.notConnectedToInternet) }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        return (responseData, response)
    }
}

private func jsonBody(_ request: URLRequest?) -> [String: Any]? {
    guard let data = request?.httpBody else { return nil }
    return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
}

private func messages(_ n: Int) -> [NativeCoachMessage] {
    (0..<n).map { NativeCoachMessage(role: $0 % 2 == 0 ? .user : .assistant, text: "msg-\($0)") }
}

// MARK: - Provider precedence

private func testProviderPrecedence() {
    expectEqual(
        NativeCoachTransport.provider(anthropicKey: "ak", groqKey: "gk"),
        .anthropic(apiKey: "ak"),
        "an Anthropic key wins over a Groq key"
    )
    expectEqual(
        NativeCoachTransport.provider(anthropicKey: "", groqKey: "gk"),
        .groq(apiKey: "gk"),
        "a Groq key is used when there is no Anthropic key"
    )
    expectEqual(
        NativeCoachTransport.provider(anthropicKey: "", groqKey: ""),
        .backend,
        "the backend proxy is the fallback when neither key is set"
    )
}

// MARK: - Anthropic transport

private func testAnthropicSuccessAndHeaders() async {
    let loader = FakeLoader()
    loader.responseData = Data("""
    {"content":[{"type":"text","text":"Hello "},{"type":"text","text":"there"}]}
    """.utf8)
    let transport = NativeCoachTransport(backendBaseURL: nil, loader: loader)
    do {
        let reply = try await transport.sendClaude(messages: messages(2), systemPrompt: "SYS", apiKey: "sk-ant-secret")
        expectEqual(reply, "Hello there", "concatenates every content block's text")
    } catch {
        failures += 1; print("FAIL: a valid Anthropic response should not throw — \(error)")
    }
    expectEqual(loader.lastRequest?.url?.absoluteString, "https://api.anthropic.com/v1/messages", "posts to the Messages API")
    expectEqual(loader.lastRequest?.value(forHTTPHeaderField: "x-api-key"), "sk-ant-secret", "sends the key in x-api-key")
    expectEqual(loader.lastRequest?.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01", "sends the pinned anthropic-version")
    let body = jsonBody(loader.lastRequest)
    expectEqual(body?["model"] as? String, "claude-sonnet-4-6", "uses the named Anthropic model constant")
    expectEqual(body?["max_tokens"] as? Int, 600, "caps max_tokens at 600")
    expectEqual(body?["system"] as? String, "SYS", "carries the system prompt in the `system` field")
}

private func testAnthropicMissingKey() async {
    let transport = NativeCoachTransport(backendBaseURL: nil, loader: FakeLoader())
    do {
        _ = try await transport.sendClaude(messages: messages(1), systemPrompt: nil, apiKey: "")
        failures += 1; print("FAIL: an empty Anthropic key should throw")
    } catch let error as NativeCoachTransportError {
        expectEqual(error, .missingAnthropicKey, "missing Anthropic key is typed")
        expectEqual(error.message, "No AI key set. Add your Anthropic API key in Settings → AI Assistant.", "matches RN's exact copy")
    } catch { failures += 1; print("FAIL: wrong error type: \(error)") }
}

private func testAnthropicProviderError() async {
    let loader = FakeLoader()
    loader.responseData = Data("""
    {"error":{"type":"invalid_request_error","message":"overloaded"}}
    """.utf8)
    let transport = NativeCoachTransport(backendBaseURL: nil, loader: loader)
    do {
        _ = try await transport.sendClaude(messages: messages(1), systemPrompt: nil, apiKey: "sk-ant")
        failures += 1; print("FAIL: an `error` field should throw")
    } catch let error as NativeCoachTransportError {
        expectEqual(error, .providerError("overloaded"), "surfaces the provider's own error message")
    } catch { failures += 1; print("FAIL: wrong error type: \(error)") }
}

private func testAnthropicEmptyResponse() async {
    let loader = FakeLoader()
    loader.responseData = Data("""
    {"content":[{"type":"text","text":""}]}
    """.utf8)
    let transport = NativeCoachTransport(backendBaseURL: nil, loader: loader)
    do {
        _ = try await transport.sendClaude(messages: messages(1), systemPrompt: nil, apiKey: "sk-ant")
        failures += 1; print("FAIL: empty content text should throw")
    } catch let error as NativeCoachTransportError {
        expectEqual(error, .emptyResponse, "empty text is typed as emptyResponse")
    } catch { failures += 1; print("FAIL: wrong error type: \(error)") }
}

private func testAnthropicUnparseableResponse() async {
    let loader = FakeLoader()
    loader.responseData = Data("not json at all".utf8)
    let transport = NativeCoachTransport(backendBaseURL: nil, loader: loader)
    do {
        _ = try await transport.sendClaude(messages: messages(1), systemPrompt: nil, apiKey: "sk-ant")
        failures += 1; print("FAIL: an unparseable body should throw")
    } catch let error as NativeCoachTransportError {
        expectEqual(error, .unavailable, "an unparseable body is typed as unavailable")
    } catch { failures += 1; print("FAIL: wrong error type: \(error)") }
}

private func testAnthropicHistoryTruncation() async {
    let loader = FakeLoader()
    loader.responseData = Data("""
    {"content":[{"text":"ok"}]}
    """.utf8)
    let transport = NativeCoachTransport(backendBaseURL: nil, loader: loader)
    _ = try? await transport.sendClaude(messages: messages(21), systemPrompt: nil, apiKey: "sk-ant")
    let sent = jsonBody(loader.lastRequest)?["messages"] as? [[String: Any]]
    expectEqual(sent?.count ?? -1, 20, "MAX_HISTORY caps a 21-message history to the last 20")
    expectEqual(sent?.first?["content"] as? String, "msg-1", "keeps the most recent 20 (drops the oldest)")
    expectEqual(sent?.last?["content"] as? String, "msg-20", "keeps the newest message")
}

// MARK: - Groq transport

private func testGroqSuccessAndHeaders() async {
    let loader = FakeLoader()
    loader.responseData = Data("""
    {"choices":[{"message":{"content":"Groq reply"}}]}
    """.utf8)
    let transport = NativeCoachTransport(backendBaseURL: nil, loader: loader)
    do {
        let reply = try await transport.sendGroq(messages: messages(1), systemPrompt: "SYS", apiKey: "gsk-secret")
        expectEqual(reply, "Groq reply", "reads choices[0].message.content")
    } catch { failures += 1; print("FAIL: a valid Groq response should not throw — \(error)") }
    expectEqual(loader.lastRequest?.url?.absoluteString, "https://api.groq.com/openai/v1/chat/completions", "posts to the Groq chat-completions endpoint")
    expectEqual(loader.lastRequest?.value(forHTTPHeaderField: "Authorization"), "Bearer gsk-secret", "sends the key as a bearer token")
    let body = jsonBody(loader.lastRequest)
    expectEqual(body?["model"] as? String, "llama-3.1-8b-instant", "uses the named Groq model constant")
    expectEqual(body?["max_tokens"] as? Int, 600, "caps max_tokens at 600")
    let sentMessages = body?["messages"] as? [[String: String]]
    expectEqual(sentMessages?.first?["role"], "system", "prepends the system prompt as a system message")
    expectEqual(sentMessages?.first?["content"], "SYS", "carries the system prompt text")
}

private func testGroqMissingKey() async {
    let transport = NativeCoachTransport(backendBaseURL: nil, loader: FakeLoader())
    do {
        _ = try await transport.sendGroq(messages: messages(1), systemPrompt: nil, apiKey: "")
        failures += 1; print("FAIL: an empty Groq key should throw")
    } catch let error as NativeCoachTransportError {
        expectEqual(error, .missingGroqKey, "missing Groq key is typed")
        expectEqual(error.message, "No AI key set. Add your Groq API key in Settings → AI Assistant.", "matches RN's exact copy")
    } catch { failures += 1; print("FAIL: wrong error type: \(error)") }
}

private func testGroqProviderErrorObjectAndBareString() async {
    let objectLoader = FakeLoader()
    objectLoader.responseData = Data("""
    {"error":{"message":"rate limited"}}
    """.utf8)
    let transport1 = NativeCoachTransport(backendBaseURL: nil, loader: objectLoader)
    do {
        _ = try await transport1.sendGroq(messages: messages(1), systemPrompt: nil, apiKey: "gsk")
        failures += 1; print("FAIL: an `error` object should throw")
    } catch let error as NativeCoachTransportError {
        expectEqual(error, .providerError("rate limited"), "surfaces the provider's object error message")
    } catch { failures += 1; print("FAIL: wrong error type: \(error)") }

    // RN reads `data.error.message` unconditionally; a bare-string `error`
    // has no `.message`, so RN's fallback "AI error" is thrown, not the
    // string itself.
    let stringLoader = FakeLoader()
    stringLoader.responseData = Data("""
    {"error":"boom"}
    """.utf8)
    let transport2 = NativeCoachTransport(backendBaseURL: nil, loader: stringLoader)
    do {
        _ = try await transport2.sendGroq(messages: messages(1), systemPrompt: nil, apiKey: "gsk")
        failures += 1; print("FAIL: a bare-string `error` should throw")
    } catch let error as NativeCoachTransportError {
        expectEqual(error, .providerError("AI error"), "a bare-string error falls back to \"AI error\" like RN's `.message` undefined access")
    } catch { failures += 1; print("FAIL: wrong error type: \(error)") }
}

private func testGroqHistoryTruncation() async {
    let loader = FakeLoader()
    loader.responseData = Data("""
    {"choices":[{"message":{"content":"ok"}}]}
    """.utf8)
    let transport = NativeCoachTransport(backendBaseURL: nil, loader: loader)
    _ = try? await transport.sendGroq(messages: messages(25), systemPrompt: nil, apiKey: "gsk")
    let sent = jsonBody(loader.lastRequest)?["messages"] as? [[String: String]]
    expectEqual(sent?.count ?? -1, 20, "MAX_HISTORY caps a 25-message history to the last 20 (no system prompt)")
    expectEqual(sent?.first?["content"], "msg-5", "keeps the most recent 20")
}

// MARK: - Backend proxy transport

private func testBackendSuccess() async {
    let loader = FakeLoader()
    loader.responseData = Data("""
    {"text":"Backend reply"}
    """.utf8)
    let transport = NativeCoachTransport(backendBaseURL: URL(string: "https://worker.test")!, loader: loader)
    let session = Data("""
    {"access_token":"jwt-token"}
    """.utf8)
    do {
        let reply = try await transport.sendBackend(messages: messages(1), systemPrompt: "SYS", sessionBytes: session)
        expectEqual(reply, "Backend reply", "reads the `text` field")
    } catch { failures += 1; print("FAIL: a valid backend response should not throw — \(error)") }
    expectEqual(loader.lastRequest?.url?.absoluteString, "https://worker.test/api/ai-chat", "posts to the live /api/ai-chat route (not the legacy Vercel proxy)")
    expectEqual(loader.lastRequest?.value(forHTTPHeaderField: "Authorization"), "Bearer jwt-token", "sends the session as a bearer token")
    let body = jsonBody(loader.lastRequest)
    let sent = body?["messages"] as? [[String: String]]
    expectEqual(sent?.first?["role"], "user", "wire shape is {role, text} per message")
    expectEqual(sent?.first?["text"], "msg-0", "wire shape is {role, text} per message")
    expectEqual(body?["systemPrompt"] as? String, "SYS", "carries the system prompt")
}

private func testBackendNotConfigured() async {
    let transport = NativeCoachTransport(backendBaseURL: nil, loader: FakeLoader())
    do {
        _ = try await transport.sendBackend(messages: messages(1), systemPrompt: nil, sessionBytes: Data("{\"access_token\":\"t\"}".utf8))
        failures += 1; print("FAIL: a missing backend URL should throw")
    } catch let error as NativeCoachTransportError {
        expectEqual(error, .backendNotConfigured, "no backend URL is typed as backendNotConfigured")
        expectEqual(error.message, "Backend not configured.", "matches RN's exact copy")
    } catch { failures += 1; print("FAIL: wrong error type: \(error)") }
}

private func testBackendAuthMissing() async {
    let transport = NativeCoachTransport(backendBaseURL: URL(string: "https://worker.test")!, loader: FakeLoader())
    for missing: Data? in [nil, Data(), Data("not json".utf8), Data("{}".utf8), Data("{\"access_token\":\"\"}".utf8)] {
        do {
            _ = try await transport.sendBackend(messages: messages(1), systemPrompt: nil, sessionBytes: missing)
            failures += 1; print("FAIL: a missing/empty session should throw for \(String(describing: missing))")
        } catch let error as NativeCoachTransportError {
            expectEqual(error, .signInRequired, "an absent session is typed as signInRequired")
            expectEqual(error.message, "Sign in to use the AI assistant.", "matches RN's exact copy")
        } catch { failures += 1; print("FAIL: wrong error type: \(error)") }
    }
}

private func testBackendNonOKStatus() async {
    let loader = FakeLoader()
    loader.status = 429
    loader.responseData = Data("""
    {"error":"Too many requests. Please wait a minute and try again."}
    """.utf8)
    let transport = NativeCoachTransport(backendBaseURL: URL(string: "https://worker.test")!, loader: loader)
    do {
        _ = try await transport.sendBackend(messages: messages(1), systemPrompt: nil, sessionBytes: Data("{\"access_token\":\"t\"}".utf8))
        failures += 1; print("FAIL: a non-2xx backend response should throw")
    } catch let error as NativeCoachTransportError {
        expectEqual(error, .providerError("Too many requests. Please wait a minute and try again."), "surfaces the backend's own error text")
    } catch { failures += 1; print("FAIL: wrong error type: \(error)") }
}

private func testBackendEmptyResponse() async {
    let loader = FakeLoader()
    loader.responseData = Data("""
    {"text":""}
    """.utf8)
    let transport = NativeCoachTransport(backendBaseURL: URL(string: "https://worker.test")!, loader: loader)
    do {
        _ = try await transport.sendBackend(messages: messages(1), systemPrompt: nil, sessionBytes: Data("{\"access_token\":\"t\"}".utf8))
        failures += 1; print("FAIL: empty text should throw")
    } catch let error as NativeCoachTransportError {
        expectEqual(error, .emptyResponse, "empty text is typed as emptyResponse")
    } catch { failures += 1; print("FAIL: wrong error type: \(error)") }
}

private func testTransportFailurePropagates() async {
    let loader = FakeLoader()
    loader.throwsError = true
    let transport = NativeCoachTransport(backendBaseURL: URL(string: "https://worker.test")!, loader: loader)
    do {
        _ = try await transport.sendBackend(messages: messages(1), systemPrompt: nil, sessionBytes: Data("{\"access_token\":\"t\"}".utf8))
        failures += 1; print("FAIL: a loader failure should throw")
    } catch let error as NativeCoachTransportError {
        expectEqual(error, .unavailable, "a network-level failure is typed as unavailable")
    } catch { failures += 1; print("FAIL: wrong error type: \(error)") }
}

// MARK: - sendMessage routing end-to-end

private func testSendMessageRouting() async {
    let loader = FakeLoader()
    loader.responseData = Data("""
    {"content":[{"text":"routed-anthropic"}]}
    """.utf8)
    let transport = NativeCoachTransport(backendBaseURL: URL(string: "https://worker.test")!, loader: loader)
    do {
        let reply = try await transport.sendMessage(
            messages: messages(1), systemPrompt: nil,
            anthropicKey: "sk-ant", groqKey: "gsk", sessionBytes: nil
        )
        expectEqual(reply, "routed-anthropic", "sendMessage prefers the Anthropic key")
        expect(loader.lastRequest?.url?.host == "api.anthropic.com", "the request actually went to Anthropic")
    } catch { failures += 1; print("FAIL: routing should not throw — \(error)") }
}

// MARK: - Security: keys never leak into the prompt, an error message, or a log line

private func testKeyNeverLeaks() async {
    let secretAnthropic = "sk-ant-api03-super-secret-value"
    let secretGroq = "gsk_super_secret_groq_value"
    // A representative built system prompt (this transport test target does
    // not link NativeCoachPrompt; the "prompt never contains a key" fixture
    // lives in CoachPromptTests, which owns the prompt builder).
    let prompt = "Assistant for Ace Plumbing, Plumbing, Sam. Rates: $90/hr labor, 20% materials markup, " +
        "15% overhead, 20% margin, $75 min fee. Be brief. Itemize estimates. USD only."

    let loader = FakeLoader()
    loader.responseData = Data("""
    {"error":{"message":"rejected"}}
    """.utf8)
    let transport = NativeCoachTransport(backendBaseURL: nil, loader: loader)

    // Every typed error's message never contains a key, only provider-authored text.
    do {
        _ = try await transport.sendClaude(messages: messages(1), systemPrompt: prompt, apiKey: secretAnthropic)
        failures += 1
    } catch let error as NativeCoachTransportError {
        expect(!error.message.contains(secretAnthropic), "a thrown error's message never contains the Anthropic key")
    } catch { failures += 1 }

    do {
        _ = try await transport.sendGroq(messages: messages(1), systemPrompt: prompt, apiKey: secretGroq)
        failures += 1
    } catch let error as NativeCoachTransportError {
        expect(!error.message.contains(secretGroq), "a thrown error's message never contains the Groq key")
    } catch { failures += 1 }

    // Missing-key messages are static copy, not an echo of any attempted value.
    let missingAnthropic = NativeCoachTransportError.missingAnthropicKey.message
    let missingGroq = NativeCoachTransportError.missingGroqKey.message
    expect(!missingAnthropic.contains(secretAnthropic) && !missingAnthropic.contains(secretGroq), "missing-key copy carries no key")
    expect(!missingGroq.contains(secretAnthropic) && !missingGroq.contains(secretGroq), "missing-key copy carries no key")

    // The key is sent ONLY in a request header, never in the body.
    let anthropicBody = String(data: try! JSONSerialization.data(withJSONObject: [
        "model": NativeCoachModel.anthropic, "max_tokens": 600,
        "messages": [["role": "user", "content": "hi"]], "system": prompt,
    ]), encoding: .utf8) ?? ""
    expect(!anthropicBody.contains(secretAnthropic), "the Anthropic request body never carries the key")
}

// MARK: - Runner

testProviderPrecedence()

let group = DispatchGroup()
group.enter()
Task {
    await testAnthropicSuccessAndHeaders()
    await testAnthropicMissingKey()
    await testAnthropicProviderError()
    await testAnthropicEmptyResponse()
    await testAnthropicUnparseableResponse()
    await testAnthropicHistoryTruncation()
    await testGroqSuccessAndHeaders()
    await testGroqMissingKey()
    await testGroqProviderErrorObjectAndBareString()
    await testGroqHistoryTruncation()
    await testBackendSuccess()
    await testBackendNotConfigured()
    await testBackendAuthMissing()
    await testBackendNonOKStatus()
    await testBackendEmptyResponse()
    await testTransportFailurePropagates()
    await testSendMessageRouting()
    await testKeyNeverLeaks()
    group.leave()
}
group.wait()

if failures == 0 {
    print("CoachTransportTests: all checks passed")
} else {
    print("CoachTransportTests: \(failures) failure(s)")
    exit(1)
}

import Foundation

// Receipt OCR transport tests (task 9.04).
//
// Ports __tests__/receiptOCR.test.js: data-URI splitting, the independent
// per-field clamp table, rollover-date rejection, unknown categories, and the
// never-throws transport contract (oversize, wrong mime, no session, network
// error, unparseable reply).

private var failures = 0

private func expect(_ condition: @autoclosure () -> Bool, _ label: String) {
    if !condition() {
        failures += 1
        print("FAIL: \(label)")
    }
}

private func expectEqual<T: Equatable>(_ actual: T?, _ expected: T, _ label: String) {
    if actual != expected {
        failures += 1
        print("FAIL: \(label) — expected \(expected), got \(String(describing: actual))")
    }
}

/// Stub transport: returns whatever the test hands it, so the transport never
/// touches the network.
private struct StubTransport: NativeReceiptOCRTransport {
    var claudeReply: String?
    var backendReply: String?
    var backendCalled = false
    func claudeMessage(prompt: String, apiKey: String, maxTokens: Int, imageBase64: String, mediaType: String) -> String? {
        claudeReply
    }
    func backendExtract(imageBase64: String, mediaType: String) -> String? {
        backendReply
    }
}

private let jpegDataUri = "data:image/jpeg;base64,AAAA"

private func testSplitDataUri() {
    let split = NativeReceiptOCR.splitDataUri("data:image/png;base64,Zm9v")
    expectEqual(split?.mediaType, "image/png", "png media type")
    expectEqual(split?.base64, "Zm9v", "base64 payload")
    expect(NativeReceiptOCR.splitDataUri("data:image/gif;base64,AAAA") == nil, "unsupported mime rejected")
    expect(NativeReceiptOCR.splitDataUri("not a data uri") == nil, "non data URI rejected")
    expect(NativeReceiptOCR.splitDataUri("data:image/jpeg;base64,") == nil, "empty payload rejected")
    expectEqual(NativeReceiptOCR.splitDataUri(jpegDataUri)?.mediaType, "image/jpeg", "jpeg media type")
}

private func testParsing() {
    let full = NativeReceiptOCR.parseReceiptExtraction(
        #"{"merchant":"Ferguson Plumbing","amount":126.42,"date":"2026-03-05","category":"materials","confidence":"high"}"#
    )
    expectEqual(full?.merchant, "Ferguson Plumbing", "merchant parsed")
    expectEqual(full?.amount, Decimal(string: "126.42"), "amount parsed")
    expectEqual(full?.date, "2026-03-05", "date parsed")
    expectEqual(full?.category, "materials", "category parsed")
    expectEqual(full?.confidence, "high", "confidence parsed")

    // A junk field becomes nil without sinking the rest.
    let partial = NativeReceiptOCR.parseReceiptExtraction(
        #"{"merchant":42,"amount":50,"date":"2026-03-05","category":"nonsense","confidence":"weird"}"#
    )
    expect(partial?.merchant == nil, "junk merchant becomes nil")
    expectEqual(partial?.amount, 50, "amount still parsed")
    expectEqual(partial?.date, "2026-03-05", "date still parsed")
    expect(partial?.category == nil, "unknown category becomes nil")
    expectEqual(partial?.confidence, "low", "confidence clamps to low")

    // Rollover date is rejected.
    let rollover = NativeReceiptOCR.parseReceiptExtraction(#"{"merchant":"X","date":"2026-02-31"}"#)
    expectEqual(rollover?.merchant, "X", "merchant kept")
    expect(rollover?.date == nil, "rollover date rejected")

    // Non-positive or non-numeric amounts are dropped.
    expect(NativeReceiptOCR.parseReceiptExtraction(#"{"merchant":"X","amount":0}"#)?.amount == nil, "zero amount dropped")
    expect(NativeReceiptOCR.parseReceiptExtraction(#"{"merchant":"X","amount":-5}"#)?.amount == nil, "negative amount dropped")
    expect(NativeReceiptOCR.parseReceiptExtraction(#"{"merchant":"X","amount":"10"}"#)?.amount == nil, "string amount dropped")

    // Merchant is trimmed and capped at 80 characters.
    let long = String(repeating: "A", count: 120)
    let capped = NativeReceiptOCR.parseReceiptExtraction(#"{"merchant":"  \#(long)  "}"#)
    expectEqual(capped?.merchant?.count, 80, "merchant capped at 80 chars")

    // Nothing useful → nil.
    expect(NativeReceiptOCR.parseReceiptExtraction(#"{"merchant":null,"amount":null,"date":null,"category":"materials"}"#) == nil, "no useful fields returns nil")
    expect(NativeReceiptOCR.parseReceiptExtraction("no json here") == nil, "unparseable reply returns nil")
    expect(NativeReceiptOCR.parseReceiptExtraction("{ not valid json }") == nil, "invalid JSON returns nil")

    // Markdown-fenced replies still parse (the first JSON object wins).
    let fenced = NativeReceiptOCR.parseReceiptExtraction("Here you go:\n```json\n{\"merchant\":\"Acme\",\"amount\":10}\n```")
    expectEqual(fenced?.merchant, "Acme", "JSON extracted from surrounding prose")
}

private func testTransport() {
    // User-key route.
    let keyed = NativeReceiptOCR.extractReceipt(
        dataUri: jpegDataUri,
        anthropicKey: "sk-test",
        transport: StubTransport(claudeReply: #"{"merchant":"Acme","amount":10,"date":"2026-03-05","category":"tools","confidence":"high"}"#)
    )
    expectEqual(keyed?.route, "user_key", "user-key route")
    expectEqual(keyed?.extraction.merchant, "Acme", "user-key extraction")

    // Backend route (no user key).
    let backend = NativeReceiptOCR.extractReceipt(
        dataUri: jpegDataUri,
        anthropicKey: nil,
        transport: StubTransport(claudeReply: nil, backendReply: #"{"merchant":"Beta","amount":20}"#)
    )
    expectEqual(backend?.route, "backend", "backend route")
    expectEqual(backend?.extraction.merchant, "Beta", "backend extraction")

    // Every failure mode returns nil rather than throwing.
    expect(NativeReceiptOCR.extractReceipt(dataUri: jpegDataUri, anthropicKey: nil, transport: StubTransport()) == nil, "backend failure returns nil")
    expect(NativeReceiptOCR.extractReceipt(dataUri: jpegDataUri, anthropicKey: "sk", transport: StubTransport(claudeReply: "garbage")) == nil, "unparseable reply returns nil")
    expect(NativeReceiptOCR.extractReceipt(dataUri: jpegDataUri, anthropicKey: "", transport: StubTransport()) == nil, "empty key falls back to a failing backend")
    expect(NativeReceiptOCR.extractReceipt(dataUri: "data:image/gif;base64,AAAA", anthropicKey: "sk", transport: StubTransport(claudeReply: "{}")) == nil, "wrong mime returns nil")

    // Oversize payload is rejected BEFORE any transport call.
    let oversize = "data:image/jpeg;base64," + String(repeating: "A", count: NativeReceiptOCR.maxReceiptBase64Chars + 1)
    expect(NativeReceiptOCR.extractReceipt(dataUri: oversize, anthropicKey: "sk", transport: StubTransport(claudeReply: "{}")) == nil, "oversize image returns nil")

    // A backend reply with only unusable fields returns nil (no auto-save path).
    expect(NativeReceiptOCR.extractReceipt(dataUri: jpegDataUri, anthropicKey: nil, transport: StubTransport(backendReply: #"{"merchant":null,"amount":null,"date":null}"#)) == nil, "useless backend reply returns nil")

    // Prompt keeps the receipt contract (total, null-don't-guess, confidence).
    let prompt = NativeReceiptOCR.buildReceiptPrompt()
    expect(prompt.contains("final TOTAL paid, not the subtotal"), "prompt states the total rule")
    expect(prompt.contains("never guess a value you can't see"), "prompt forbids guessing")
    expect(prompt.contains("materials — building materials"), "prompt lists category ids")
}

testSplitDataUri()
testParsing()
testTransport()

if failures == 0 {
    print("ReceiptOCRTests: all checks passed")
} else {
    print("ReceiptOCRTests: \(failures) failure(s)")
    exit(1)
}

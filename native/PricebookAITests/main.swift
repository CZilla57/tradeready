import Foundation

// Pricebook AI suggestion tests (task 9.05).
//
// The RN client returns the parsed object untouched; the native port must type
// and validate defensively. These checks pin: never-throw, advisory-only results,
// per-field tolerance, and the no-suggestion failure modes (missing key,
// transport error, malformed/partial/oversize).

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

private struct StubAI: NativePricebookAITransport {
    var claudeReply: String?
    var backendReply: String?
    func claudeMessage(prompt: String, apiKey: String, maxTokens: Int) -> String? { claudeReply }
    func backendSuggest(payload: [String: Canonical.JSONValue]) -> String? { backendReply }
}

private let fullReply = """
{"laborHours":{"suggested":3.5,"reasoning":"Typical for this scope."},
 "laborRate":{"suggested":110,"reasoning":"Regional average."},
 "materials":[{"name":"Faucet","suggestedUnitCost":125,"reasoning":"Market rate."},
              {"name":"Supply lines","suggestedUnitCost":18,"reasoning":"Often forgotten."}],
 "overallRange":{"low":300,"mid":420,"high":600,"reasoning":"Residential range."}}
"""

private func input(serviceName: String = "Faucet swap") -> NativePricebookAIInput {
    NativePricebookAIInput(serviceName: serviceName, description: "Replace a faucet", category: "plumbing", trade: "plumbing")
}

private func testParse() {
    let suggestion = NativePricebookAI.parseSuggestion(fullReply)
    expectEqual(suggestion?.laborHours.suggested, 3.5, "labor hours parsed")
    expectEqual(suggestion?.laborHours.reasoning, "Typical for this scope.", "reasoning parsed")
    expectEqual(suggestion?.laborRate.suggested, 110, "labor rate parsed")
    expectEqual(suggestion?.materials.count, 2, "materials parsed")
    expectEqual(suggestion?.materials.first?.name, "Faucet", "material name parsed")
    expectEqual(suggestion?.materials.first?.suggestedUnitCost, 125, "material cost parsed")
    expectEqual(suggestion?.overallRange.mid, 420, "overall range parsed")

    // Prose-wrapped JSON still parses.
    expectEqual(NativePricebookAI.parseSuggestion("Sure!\n```json\n\(fullReply)\n```")?.laborRate.suggested, 110, "fenced JSON parsed")

    // Partial reply: one junk field does not sink the rest.
    let partial = NativePricebookAI.parseSuggestion(#"{"laborHours":{"suggested":"three"},"laborRate":{"suggested":95}}"#)
    expect(partial?.laborHours.suggested == nil, "junk suggestion dropped")
    expectEqual(partial?.laborRate.suggested, 95, "valid field kept")

    // Malformed / empty / unusable replies produce a typed "no suggestion".
    expect(NativePricebookAI.parseSuggestion("not json") == nil, "malformed reply returns nil")
    expect(NativePricebookAI.parseSuggestion("{}") == nil, "empty object returns nil")
    expect(NativePricebookAI.parseSuggestion(#"{"laborHours":{},"laborRate":{},"materials":[]}"#) == nil, "no usable values returns nil")
}

private func testTransport() {
    // Client-key route.
    let keyed = NativePricebookAI.suggestion(input(), anthropicKey: "sk-test", backendAvailable: false, transport: StubAI(claudeReply: fullReply))
    expectEqual(keyed?.laborRate.suggested, 110, "client-key suggestion")

    // Backend route.
    let backend = NativePricebookAI.suggestion(input(), anthropicKey: nil, backendAvailable: true, transport: StubAI(backendReply: fullReply))
    expectEqual(backend?.laborHours.suggested, 3.5, "backend suggestion")

    // Every failure mode returns nil instead of throwing.
    expect(NativePricebookAI.suggestion(input(), anthropicKey: "sk", backendAvailable: false, transport: StubAI(claudeReply: nil)) == nil, "client-key transport failure")
    expect(NativePricebookAI.suggestion(input(), anthropicKey: nil, backendAvailable: false, transport: StubAI(backendReply: fullReply)) == nil, "no backend available")
    expect(NativePricebookAI.suggestion(input(), anthropicKey: nil, backendAvailable: true, transport: StubAI(backendReply: "garbage")) == nil, "backend garbage reply")
    expect(NativePricebookAI.suggestion(input(serviceName: ""), anthropicKey: "sk", backendAvailable: true, transport: StubAI(claudeReply: fullReply)) == nil, "missing service name")
    expect(
        NativePricebookAI.suggestion(input(serviceName: String(repeating: "A", count: 1001)), anthropicKey: "sk", backendAvailable: true, transport: StubAI(claudeReply: fullReply)) == nil,
        "oversize service name refused before any call"
    )
}

private func testApplyIsExplicit() {
    let suggestion = NativePricebookAI.parseSuggestion(fullReply)!
    let draft = NativePricebookEntryDraft(
        name: "Faucet swap", description: nil, category: "plumbing",
        laborHours: 1, laborBreakdown: nil, laborRate: 90, materials: [], materialMarkup: 0,
        jobCosts: [], overhead: 15, margin: 20
    )
    let applied = NativePricebookAI.apply(suggestion, to: draft)
    expectEqual(applied.laborHours, 3.5, "accepted hours applied")
    expectEqual(applied.laborRate, 110, "accepted rate applied")
    expectEqual(applied.name, draft.name, "apply touches only accepted fields")
    expectEqual(applied.margin, draft.margin, "apply does not invent margin")

    // Nothing is written by generating a suggestion: the draft is untouched.
    expectEqual(draft.laborHours, 1, "draft unchanged by suggestion generation")
}

testParse()
testTransport()
testApplyIsExplicit()

if failures == 0 {
    print("PricebookAITests: all checks passed")
} else {
    print("PricebookAITests: \(failures) failure(s)")
    exit(1)
}

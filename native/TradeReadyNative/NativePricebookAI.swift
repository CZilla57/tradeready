import Foundation

// MARK: - Pricebook AI suggestions (task 9.05, requirement P4)
//
// Port of `utils/pricebookAI.ts`: the same client-key / backend-fallback split as
// receipt OCR, against `api/pricebook-suggest`. Unlike the RN client — which
// returns the parsed object untouched — the native port validates and types every
// field independently, because a suggestion is ADVISORY and must never be able to
// write canonical state on its own.

struct NativeAIPricingSuggestion: Equatable {
    struct Estimate: Equatable {
        var suggested: Decimal?
        var reasoning: String?
    }
    struct MaterialSuggestion: Equatable {
        var name: String
        var suggestedUnitCost: Decimal?
        var reasoning: String?
    }
    struct OverallRange: Equatable {
        var low: Decimal?
        var mid: Decimal?
        var high: Decimal?
        var reasoning: String?
    }

    var laborHours: Estimate
    var laborRate: Estimate
    var materials: [MaterialSuggestion]
    var overallRange: OverallRange
}

protocol NativePricebookAITransport {
    /// Returns the assistant's raw text, or nil on any failure.
    func claudeMessage(prompt: String, apiKey: String, maxTokens: Int) -> String?
    /// Returns the backend's raw JSON text, or nil on any failure.
    func backendSuggest(payload: [String: Canonical.JSONValue]) -> String?
}

struct NativePricebookAIInput {
    var serviceName: String
    var description: String = ""
    var category: String = ""
    var materials: [Canonical.Material] = []
    var laborHours: Decimal = 0
    var laborRate: Decimal = 0
    var trade: String = "general"
    var region: String = ""
}

enum NativePricebookAI {
    /// Backend guards, mirrored so the client cannot ship a payload the endpoint
    /// will reject outright.
    static let maxFieldChars = 1000
    static let maxMaterials = 50

    static func buildPrompt(_ input: NativePricebookAIInput) -> String {
        let materialsList = input.materials
            .map { "  - \($0.name): qty \(decimalString($0.quantity)), $\(decimalString($0.unitCost)) each" }
            .joined(separator: "\n")
        let trade = input.trade.isEmpty ? "general" : input.trade
        let regionLine = input.region.isEmpty ? "" : " in \(input.region)"
        let descriptionLine = input.description.isEmpty ? "" : "\nDescription: \(input.description)"
        let categoryLine = input.category.isEmpty ? "" : "\nCategory: \(input.category)"
        let materialsBlock = materialsList.isEmpty ? "No materials listed yet." : "Current materials:\n\(materialsList)"

        return """
        You are a pricing advisor for trade professionals. A \(trade) contractor\(regionLine) wants pricing guidance for a service they're adding to their pricebook.

        Service: \(input.serviceName)\(descriptionLine)\(categoryLine)
        Current labor hours: \(input.laborHours > 0 ? decimalString(input.laborHours) : "not set")
        Current labor rate: $\(input.laborRate > 0 ? decimalString(input.laborRate) : "not set")/hr
        \(materialsBlock)

        Respond ONLY with a JSON object (no markdown, no explanation outside the JSON) in this exact format:
        {
          "laborHours": { "suggested": <number>, "reasoning": "<one sentence>" },
          "laborRate": { "suggested": <number>, "reasoning": "<one sentence>" },
          "materials": [
            { "name": "<material name>", "suggestedUnitCost": <number>, "reasoning": "<one sentence>" }
          ],
          "overallRange": { "low": <number>, "mid": <number>, "high": <number>, "reasoning": "<one sentence>" }
        }

        For materials: include suggestions for each material listed above (with updated pricing if appropriate), plus any commonly-needed materials the contractor may have forgotten. Base prices on current US market rates\(input.region.isEmpty ? "" : " for the \(input.region) area").
        For labor: base on typical complexity and industry standards for this type of work.
        For the overall range: give a realistic low/mid/high that a \(trade) contractor would charge a residential customer.
        """
    }

    private static func decimalString(_ value: Decimal) -> String {
        NSDecimalNumber(decimal: value).stringValue
    }

    /// Defensive parse: each field is validated independently; a malformed reply
    /// yields nil (a typed "no suggestion") rather than a partially-trusted object.
    static func parseSuggestion(_ text: String) -> NativeAIPricingSuggestion? {
        let pattern = try! NSRegularExpression(pattern: "\\{[\\s\\S]*\\}", options: [.dotMatchesLineSeparators])
        guard let match = pattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range, in: text),
              let data = String(text[range]).data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data),
              let raw = json as? [String: Any]
        else { return nil }

        func estimate(_ key: String) -> NativeAIPricingSuggestion.Estimate {
            guard let entry = raw[key] as? [String: Any] else {
                return .init(suggested: nil, reasoning: nil)
            }
            return .init(suggested: number(entry["suggested"]), reasoning: entry["reasoning"] as? String)
        }

        let materials: [NativeAIPricingSuggestion.MaterialSuggestion] = (raw["materials"] as? [[String: Any]] ?? [])
            .compactMap { entry in
                guard let name = entry["name"] as? String, !name.isEmpty else { return nil }
                return .init(name: name, suggestedUnitCost: number(entry["suggestedUnitCost"]), reasoning: entry["reasoning"] as? String)
            }

        var overall = NativeAIPricingSuggestion.OverallRange(low: nil, mid: nil, high: nil, reasoning: nil)
        if let range = raw["overallRange"] as? [String: Any] {
            overall = .init(
                low: number(range["low"]), mid: number(range["mid"]),
                high: number(range["high"]), reasoning: range["reasoning"] as? String
            )
        }

        let laborHours = estimate("laborHours")
        let laborRate = estimate("laborRate")
        // Nothing usable at all → no suggestion.
        if laborHours.suggested == nil && laborRate.suggested == nil && materials.isEmpty
            && overall.low == nil && overall.mid == nil && overall.high == nil {
            return nil
        }
        return NativeAIPricingSuggestion(laborHours: laborHours, laborRate: laborRate, materials: materials, overallRange: overall)
    }

    private static func number(_ value: Any?) -> Decimal? {
        guard let value = value as? NSNumber, value.doubleValue.isFinite else { return nil }
        return Decimal(string: value.stringValue, locale: Locale(identifier: "en_US_POSIX"))
    }

    /// Never throws. Returns nil for a missing key, a transport failure, an
    /// oversized/empty service name, or an unusable reply.
    static func suggestion(
        _ input: NativePricebookAIInput,
        anthropicKey: String?,
        backendAvailable: Bool,
        transport: NativePricebookAITransport
    ) -> NativeAIPricingSuggestion? {
        guard !input.serviceName.isEmpty, input.serviceName.count <= maxFieldChars else { return nil }
        guard input.materials.count <= maxMaterials else { return nil }

        if let key = anthropicKey, !key.isEmpty {
            guard let text = transport.claudeMessage(prompt: buildPrompt(input), apiKey: key, maxTokens: 1000) else { return nil }
            return parseSuggestion(text)
        }

        guard backendAvailable else { return nil }
        let payload: [String: Canonical.JSONValue] = [
            "serviceName": .string(input.serviceName),
            "description": .string(input.description),
            "category": .string(input.category),
            "laborHours": .number(input.laborHours),
            "laborRate": .number(input.laborRate),
            "trade": .string(input.trade),
            "region": .string(input.region),
            "materials": .array(input.materials.map { Canonical.JSONValue.object(NativeImportEngine.fields($0)) }),
        ]
        guard let body = transport.backendSuggest(payload: payload) else { return nil }
        return parseSuggestion(body)
    }

    // MARK: apply (review-only)

    /// Applying a suggestion to a draft is always an explicit, caller-driven
    /// merge — this projects the accepted values and never mutates a record.
    static func apply(
        _ suggestion: NativeAIPricingSuggestion,
        to draft: NativePricebookEntryDraft
    ) -> NativePricebookEntryDraft {
        var updated = draft
        if let hours = suggestion.laborHours.suggested { updated.laborHours = hours }
        if let rate = suggestion.laborRate.suggested { updated.laborRate = rate }
        return updated
    }
}

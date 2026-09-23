import Foundation

// MARK: - Receipt OCR transport (task 9.04, requirement E2)
//
// Port of `utils/receiptOCR.ts`: the receipt prompt, the independent per-field
// clamp table, the data-URI splitter, and the injected transport (user Anthropic
// key first, backend `/api/receipt-extract` bearer fallback).
//
// CONTRACT: `extractReceipt` NEVER throws. Oversize image, unsupported media
// type, no session, network/API error, or unparseable reply all return nil and
// the caller falls back to plain manual entry. The result is ADVISORY — it can
// pre-fill a form for review and must never be committed automatically.

struct NativeReceiptExtraction: Equatable {
    /// Merchant/vendor name, trimmed, capped at 80 chars.
    var merchant: String?
    /// Receipt total (including tax) — finite and > 0.
    var amount: Decimal?
    /// "YYYY-MM-DD", validated as a real calendar date.
    var date: String?
    /// One of the 8 expense-category ids.
    var category: String?
    var confidence: String
}

struct NativeReceiptScanResult: Equatable {
    var extraction: NativeReceiptExtraction
    /// "user_key" | "backend" — analytics only, never sent anywhere.
    var route: String
}

/// Injected transport so tests never touch the network.
protocol NativeReceiptOCRTransport {
    /// Returns the assistant's raw text, or nil on any failure.
    func claudeMessage(prompt: String, apiKey: String, maxTokens: Int, imageBase64: String, mediaType: String) -> String?
    /// Returns the backend's raw JSON text, or nil on any failure (including a
    /// missing session token).
    func backendExtract(imageBase64: String, mediaType: String) -> String?
}

enum NativeReceiptOCR {
    /// Hard cap on the base64 payload (~3.7 MB decoded). The backend enforces
    /// the same cap independently.
    static let maxReceiptBase64Chars = 5_000_000
    static let merchantMaxChars = 80
    static let mediaTypes = ["image/jpeg", "image/png"]

    static func buildReceiptPrompt() -> String {
        let categoryLines = [
            "materials — building materials, parts, supplies (hardware stores, suppliers)",
            "tools — tools and equipment purchases or rentals",
            "fuel — gas stations, fuel, vehicle and transport costs",
            "labor — payments to subcontractors or hired help",
            "insurance — insurance premiums",
            "software — software, apps, subscriptions",
            "marketing — advertising, printing, promotional costs",
            "other — anything that fits none of the above",
        ].map { "  - \($0)" }.joined(separator: "\n")

        return """
        You are reading a photo of a purchase receipt for a small trades business's expense log.

        Extract what you can see and respond ONLY with a JSON object (no markdown, no explanation outside the JSON) in this exact format:
        {
          "merchant": "<store or vendor name, or null>",
          "amount": <the receipt TOTAL including tax as a number, or null>,
          "date": "<purchase date as YYYY-MM-DD, or null>",
          "category": "<one of the ids below, or null>",
          "confidence": "<high or low>"
        }

        Category ids:
        \(categoryLines)

        Rules:
        - amount is the final TOTAL paid, not the subtotal.
        - Use null for any field you cannot read clearly — never guess a value you can't see.
        - confidence is "low" when the image is blurry, cropped, or partly unreadable.
        """
    }

    /// Split a data URI into media type + raw base64; nil for anything else.
    static func splitDataUri(_ dataUri: String) -> (mediaType: String, base64: String)? {
        let pattern = try! NSRegularExpression(pattern: "^data:(image\\/jpeg|image\\/png);base64,(.+)$", options: [.dotMatchesLineSeparators])
        guard let match = pattern.firstMatch(in: dataUri, range: NSRange(dataUri.startIndex..., in: dataUri)) else { return nil }
        guard let mediaRange = Range(match.range(at: 1), in: dataUri),
              let base64Range = Range(match.range(at: 2), in: dataUri) else { return nil }
        return (String(dataUri[mediaRange]), String(dataUri[base64Range]))
    }

    /// Pure parser/validator. Each field is validated INDEPENDENTLY — one junk
    /// field becomes nil without sinking the rest. Returns nil only when
    /// merchant, amount, and date are all null.
    static func parseReceiptExtraction(_ text: String) -> NativeReceiptExtraction? {
        let jsonPattern = try! NSRegularExpression(pattern: "\\{[\\s\\S]*\\}", options: [.dotMatchesLineSeparators])
        guard let match = jsonPattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range, in: text) else { return nil }
        let json = String(text[range])
        guard let data = json.data(using: .utf8),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        var merchant: String?
        if let value = raw["merchant"] as? String {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { merchant = String(trimmed.prefix(merchantMaxChars)) }
        }

        var amount: Decimal?
        if let number = raw["amount"] as? NSNumber, number.doubleValue.isFinite, number.doubleValue > 0 {
            amount = Decimal(string: number.stringValue, locale: Locale(identifier: "en_US_POSIX"))
        }

        let date = (raw["date"] as? String).flatMap { isValidIsoDate($0) ? $0 : nil }

        var category: String?
        if let value = raw["category"] as? String, NativeExpenseCategories.all.contains(where: { $0.id == value }) {
            category = value
        }

        if merchant == nil && amount == nil && date == nil { return nil }
        return NativeReceiptExtraction(
            merchant: merchant,
            amount: amount,
            date: date,
            category: category,
            confidence: (raw["confidence"] as? String) == "high" ? "high" : "low"
        )
    }

    /// Real calendar `YYYY-MM-DD`; rejects rollovers such as 2026-02-31.
    static func isValidIsoDate(_ value: String) -> Bool {
        guard value.count == 10 else { return false }
        let parts = value.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return false }
        guard let date = NativeCashBasis.parseLocalDate(value) else { return false }
        let components = NativeCashBasis.localComponents(date)
        return components.year == parts[0] && components.month == parts[1] - 1 && components.day == parts[2]
    }

    /// Extract expense fields from a receipt photo. Never throws; nil means "no
    /// extraction — carry on with manual entry".
    static func extractReceipt(
        dataUri: String,
        anthropicKey: String?,
        transport: NativeReceiptOCRTransport
    ) -> NativeReceiptScanResult? {
        guard let split = splitDataUri(dataUri) else { return nil }
        guard split.base64.count <= maxReceiptBase64Chars else { return nil }

        if let key = anthropicKey, !key.isEmpty {
            guard let text = transport.claudeMessage(
                prompt: buildReceiptPrompt(), apiKey: key, maxTokens: 300,
                imageBase64: split.base64, mediaType: split.mediaType
            ), let extraction = parseReceiptExtraction(text) else { return nil }
            return NativeReceiptScanResult(extraction: extraction, route: "user_key")
        }

        guard let body = transport.backendExtract(imageBase64: split.base64, mediaType: split.mediaType),
              let extraction = parseReceiptExtraction(body) else { return nil }
        return NativeReceiptScanResult(extraction: extraction, route: "backend")
    }
}

import Foundation

// MARK: - Phase 33: AI drafting of campaign templates (spec §6.2, D8)
//
// The AI drafts a TEMPLATE with merge fields from the owner's short brief.
// Exactly what is sent: the business name, `settings.trade`, the goal, the
// tone, the channel, the owner's Details text and the allowed merge-field
// list. Nothing about any customer is ever an input here, so nothing about a
// customer can reach the provider. Parsing, cleanup, validation and the fact
// check are deterministic; any failure falls back to a built-in template
// (the never-throw contract of RN `utils/oneShotAI.ts`). Foundation only.

enum NativeCampaignDrafting {
    enum Goal: String, CaseIterable, Equatable {
        case tuneUp = "tune_up"
        case checkIn = "check_in"
        case offer
        case seasonal
        case custom

        var displayName: String {
            switch self {
            case .tuneUp: "Seasonal tune-up"
            case .checkIn: "Check-in"
            case .offer: "Special offer"
            case .seasonal: "Seasonal note"
            case .custom: "Custom"
            }
        }
    }

    enum Tone: String, CaseIterable, Equatable {
        case friendly
        case professional

        var displayName: String { self == .friendly ? "Friendly" : "Professional" }
    }

    /// The owner's brief. `details` is the only free text sent (≤ 500).
    struct Brief: Equatable {
        var goal: Goal
        var tone: Tone
        var kind: NativeCampaignMessage.Kind
        var details: String
    }

    struct Draft: Equatable {
        var subject: String?
        var body: String
    }

    enum Source: String, Equatable {
        case ai
        case template
    }

    struct Result: Equatable {
        var draft: Draft
        var source: Source
        /// Shown when the template fallback was used.
        var notice: String?
        /// Fact-check warnings (never blocking).
        var warnings: [String]
    }

    static let fallbackNotice = "AI drafting isn't available right now, so we started you from a template."
    static let detailsFooter =
        "Only your business name, trade and this description are sent to the AI. Don't include customer names."

    /// The merge fields the AI may use (never `{bookingLink}` unless the
    /// owner's link is ready, so a draft never needs a link the owner lacks).
    static func allowedFields(bookingLinkReady: Bool) -> [NativeCampaignMessage.Field] {
        NativeCampaignMessage.Field.allCases.filter { $0 != .bookingLink || bookingLinkReady }
    }

    // MARK: Prompt (spec §6.2)

    /// The system prompt. Inputs are Settings and the brief only.
    static func systemPrompt(
        businessName: String,
        trade: String,
        brief: Brief,
        bookingLinkReady: Bool
    ) -> String {
        let business = businessName.trimmingCharacters(in: .whitespacesAndNewlines)
        let tradeName = trade.trimmingCharacters(in: .whitespacesAndNewlines)
        let fields = allowedFields(bookingLinkReady: bookingLinkReady).map(\.token).joined(separator: ", ")
        var rules = [
            "You write one marketing message for a \(tradeName.isEmpty ? "home services" : tradeName) business named \(business.isEmpty ? "the business" : business), sent to its past customers.",
            "Use only these placeholders, exactly as written: \(fields). Never invent another placeholder.",
            "Never invent prices, discounts, dates, deadlines or facts that are not in the owner's details.",
            "Do not add opt-out text, an unsubscribe line or a mailing address. The app adds them.",
            "Tone: \(brief.tone.displayName.lowercased()).",
        ]
        switch brief.kind {
        case .text:
            rules.append("This is a text message. Keep it under 300 characters, with no subject line.")
            rules.append("Reply exactly as:\nBODY: <the text message>")
        case .email:
            rules.append("This is an email. The subject must never start with \"Re:\", \"Fw:\" or \"Fwd:\".")
            rules.append("Reply exactly as:\nSUBJECT: <the subject>\nBODY: <the email body>")
        }
        return rules.joined(separator: "\n")
    }

    /// The single user message: the goal and the owner's details.
    static func userMessage(brief: Brief) -> String {
        let details = String(brief.details.trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix(NativeCampaignMessage.briefMaxLength))
        return [
            "Goal: \(brief.goal.displayName).",
            "Channel: \(brief.kind == .text ? "text message" : "email").",
            details.isEmpty ? "Details: none." : "Details: \(details)",
        ].joined(separator: "\n")
    }

    // MARK: Parse (spec §6.2)

    /// `SUBJECT: …` (email) then `BODY:` and the body. Known placeholders in
    /// any case are canonicalized, opt-out lines the model added anyway are
    /// removed, and a reply-style subject prefix is stripped. `nil` when the
    /// reply is unusable, so the caller falls back to the template.
    static func parse(_ reply: String, kind: NativeCampaignMessage.Kind) -> Draft? {
        var text = reply.replacingOccurrences(of: "\r\n", with: "\n")
        text = text.replacingOccurrences(of: "```", with: "")
        let lines = text.components(separatedBy: "\n")
        guard let bodyIndex = lines.firstIndex(where: { marker($0, "BODY") != nil }) else { return nil }
        var bodyLines = [marker(lines[bodyIndex], "BODY") ?? ""]
        bodyLines += lines[(bodyIndex + 1)...]
        var body = canonicalized(bodyLines.joined(separator: "\n"))
        body = body.components(separatedBy: "\n").filter { !isComplianceLine($0) }.joined(separator: "\n")
        body = body.trimmingCharacters(in: .whitespacesAndNewlines)
        body = stripQuotes(body)
        guard !body.isEmpty else { return nil }
        switch kind {
        case .text:
            return Draft(subject: nil, body: body)
        case .email:
            guard let subjectLine = lines[..<bodyIndex].lazy.compactMap({ marker($0, "SUBJECT") }).first else { return nil }
            var subject = stripQuotes(canonicalized(subjectLine).trimmingCharacters(in: .whitespacesAndNewlines))
            while NativeCampaignMessage.isDeceptiveSubject(subject), let colon = subject.firstIndex(of: ":") {
                subject = String(subject[subject.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            }
            guard !subject.isEmpty else { return nil }
            return Draft(subject: subject, body: body)
        }
    }

    /// The full pipeline over a provider reply (or a transport failure):
    /// parse and fact-check, else the goal's template and the fallback
    /// notice. Never throws. `NativeCampaignMessage.validate` then runs on
    /// whatever lands in the editor, so a stray placeholder in an AI draft is
    /// shown (and blocks Send) instead of silently discarding the draft.
    static func result(reply: String?, brief: Brief) -> Result {
        if let reply, let draft = parse(reply, kind: brief.kind) {
            return Result(draft: draft, source: .ai, notice: nil, warnings: factCheck(draft: draft, details: brief.details))
        }
        return Result(draft: template(goal: brief.goal, kind: brief.kind), source: .template,
                      notice: fallbackNotice, warnings: [])
    }

    // MARK: Fact check (spec §6.2)

    /// Warns (never blocks) for each money amount, percentage or date in the
    /// draft that is not in the owner's details.
    static func factCheck(draft: Draft, details: String) -> [String] {
        let text = [draft.subject ?? "", draft.body].joined(separator: "\n")
        let given = facts(in: details)
        var warnings: [String] = []
        var seen = Set<String>()
        for fact in facts(in: text) where !given.contains(where: { $0.key == fact.key }) {
            guard seen.insert(fact.key).inserted else { continue }
            let sameKind = given.filter { $0.kind == fact.kind }.map(\.display)
            if sameKind.isEmpty {
                warnings.append("The draft mentions \(fact.display), which isn't in your details. Check it before sending.")
            } else {
                warnings.append("The draft mentions \(fact.display). Your details said \(sameKind.joined(separator: ", ")). Check it before sending.")
            }
        }
        return warnings
    }

    struct Fact: Equatable {
        enum Kind: Equatable { case money, percent, date }
        let kind: Kind
        /// Normalized for comparison.
        let key: String
        /// As written.
        let display: String
    }

    static func facts(in text: String) -> [Fact] {
        var out: [Fact] = []
        let range = NSRange(text.startIndex..., in: text)
        func each(_ pattern: String, _ body: (String) -> Void) {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return }
            for match in regex.matches(in: text, range: range) {
                if let r = Range(match.range, in: text) { body(String(text[r])) }
            }
        }
        each(#"\$\s?\d[\d,]*(?:\.\d{1,2})?"#) { raw in
            var digits = raw.filter { $0.isNumber || $0 == "." }
            if digits.hasSuffix(".00") { digits.removeLast(3) }
            out.append(Fact(kind: .money, key: "$" + digits, display: raw.replacingOccurrences(of: " ", with: "")))
        }
        each(#"\d+(?:\.\d+)?\s?%"#) { raw in
            let number = raw.filter { $0.isNumber || $0 == "." }
            out.append(Fact(kind: .percent, key: number + "%", display: raw.replacingOccurrences(of: " ", with: "")))
        }
        let months = "jan(?:uary)?|feb(?:ruary)?|mar(?:ch)?|apr(?:il)?|may|june?|july?|aug(?:ust)?|sep(?:t(?:ember)?)?|oct(?:ober)?|nov(?:ember)?|dec(?:ember)?"
        each(#"\b(?:"# + months + #")\.?\s+\d{1,2}(?:st|nd|rd|th)?\b"#) { raw in
            let lowered = raw.lowercased()
            let month = String(lowered.prefix(3))
            let day = lowered.split(whereSeparator: { !$0.isNumber }).last.map { String(Int($0) ?? 0) } ?? ""
            out.append(Fact(kind: .date, key: "\(month) \(day)", display: raw))
        }
        each(#"\b\d{1,2}/\d{1,2}(?:/\d{2,4})?\b"#) { raw in
            let parts = raw.split(separator: "/").compactMap { Int($0) }
            guard parts.count >= 2, (1...12).contains(parts[0]) else { return }
            let month = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"][parts[0] - 1]
            out.append(Fact(kind: .date, key: "\(month) \(parts[1])", display: raw))
        }
        return out
    }

    // MARK: Templates (spec §6.2 fallback)

    /// The goal's built-in template, merge fields included.
    static func template(goal: Goal, kind: NativeCampaignMessage.Kind) -> Draft {
        switch (goal, kind) {
        case (.tuneUp, .text):
            return Draft(subject: nil, body: "Hi {firstName}, it's {ownerName} from {businessName}. It's tune-up season, and it's been a while since {lastJob}. Want me to get you on the schedule? Just reply here.")
        case (.tuneUp, .email):
            return Draft(subject: "Time for a tune-up?", body: "Hi {firstName},\n\nIt's {ownerName} from {businessName}. It's tune-up season, and our records show your last service was {lastServiceMonth}. A quick check now can head off problems later.\n\nJust reply to this email and we'll find a time that works.\n\nThanks,\n{ownerName}\n{businessPhone}")
        case (.checkIn, .text):
            return Draft(subject: nil, body: "Hi {firstName}, it's {ownerName} from {businessName}. Just checking in since {lastJob}. Is everything still working well? Reply here if you need anything.")
        case (.checkIn, .email):
            return Draft(subject: "Checking in from {businessName}", body: "Hi {firstName},\n\nIt's {ownerName} from {businessName}. I wanted to check in since {lastJob} ({lastServiceMonth}). Is everything still working well?\n\nIf anything needs a look, just reply and we'll set up a visit.\n\nThanks,\n{ownerName}\n{businessPhone}")
        case (.offer, .text):
            return Draft(subject: nil, body: "Hi {firstName}, it's {ownerName} from {businessName}. We have openings coming up for past customers. Want me to save you a spot? Just reply here.")
        case (.offer, .email):
            return Draft(subject: "Openings for past customers", body: "Hi {firstName},\n\nIt's {ownerName} from {businessName}. We have openings coming up and wanted to offer them to past customers first.\n\nIf you'd like a visit, just reply to this email and we'll find a time.\n\nThanks,\n{ownerName}\n{businessPhone}")
        case (.seasonal, .text):
            return Draft(subject: nil, body: "Hi {firstName}, it's {ownerName} from {businessName}. The season's changing, so it's a good time for a quick check. Reply here if you'd like us to stop by.")
        case (.seasonal, .email):
            return Draft(subject: "Getting ready for the season", body: "Hi {firstName},\n\nIt's {ownerName} from {businessName}. With the season changing, now is a good time for a quick check before things get busy.\n\nJust reply to this email if you'd like us to stop by.\n\nThanks,\n{ownerName}\n{businessPhone}")
        case (.custom, .text):
            return Draft(subject: nil, body: "Hi {firstName}, it's {ownerName} from {businessName}. ")
        case (.custom, .email):
            return Draft(subject: "A note from {businessName}", body: "Hi {firstName},\n\n\n\nThanks,\n{ownerName}\n{businessPhone}")
        }
    }

    // MARK: Private

    /// The text after `NAME:` when the line starts with it (any case, with
    /// optional markdown emphasis).
    private static func marker(_ line: String, _ name: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "*_#"))
            .trimmingCharacters(in: .whitespaces)
        guard trimmed.uppercased().hasPrefix(name + ":") else { return nil }
        var rest = String(trimmed.dropFirst(name.count + 1))
        rest = rest.trimmingCharacters(in: CharacterSet(charactersIn: "*_ ").union(.whitespaces))
        return rest
    }

    /// `{FirstName}` → `{firstName}` for every known field.
    private static func canonicalized(_ text: String) -> String {
        var out = text
        for field in NativeCampaignMessage.Field.allCases {
            out = out.replacingOccurrences(of: field.token, with: field.token, options: [.caseInsensitive])
        }
        return out
    }

    private static func isComplianceLine(_ line: String) -> Bool {
        let lowered = line.lowercased()
        return lowered.contains("reply stop") || lowered.contains("text stop") || lowered.contains("unsubscribe")
            || lowered.contains("opt out") || lowered.contains("opt-out")
    }

    private static func stripQuotes(_ value: String) -> String {
        var out = value
        for (open, close) in [("\"", "\""), ("“", "”")] where out.hasPrefix(open) && out.hasSuffix(close) && out.count >= 2 {
            out = String(out.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return out
    }
}

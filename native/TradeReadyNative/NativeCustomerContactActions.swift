import Foundation

enum NativeCustomerContactAction: String, CaseIterable, Equatable, Sendable {
    case call
    case text
    case email
}

struct NativeCustomerContactTarget: Equatable, Identifiable, Sendable {
    let action: NativeCustomerContactAction
    let recipient: String

    var id: String { "\(action.rawValue):\(recipient)" }

    var externalURL: URL? {
        var components = URLComponents()
        components.scheme = switch action {
        case .call: "tel"
        case .text: "sms"
        case .email: "mailto"
        }
        components.path = recipient
        return components.url
    }
}

/// Pure contact-target normalization shared by customer and job detail views.
/// The UI decides whether to use an in-app composer or an external URL; this
/// layer keeps malformed/blank contact data from reaching either boundary.
enum NativeCustomerContactActions {
    static func targets(phone: String, email: String) -> [NativeCustomerContactTarget] {
        var values: [NativeCustomerContactTarget] = []
        if let phone = normalizedPhone(phone) {
            values.append(.init(action: .call, recipient: phone))
            values.append(.init(action: .text, recipient: phone))
        }
        if let email = normalizedEmail(email) {
            values.append(.init(action: .email, recipient: email))
        }
        return values
    }

    static func target(
        for action: NativeCustomerContactAction,
        phone: String,
        email: String
    ) -> NativeCustomerContactTarget? {
        targets(phone: phone, email: email).first { $0.action == action }
    }

    private static func normalizedPhone(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let digits = trimmed.unicodeScalars.filter { (48...57).contains($0.value) }
        guard !digits.isEmpty else { return nil }
        let prefix = trimmed.first == "+" ? "+" : ""
        return prefix + String(String.UnicodeScalarView(digits))
    }

    private static func normalizedEmail(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.unicodeScalars.contains(where: {
            CharacterSet.controlCharacters.contains($0)
        }) else { return nil }
        return trimmed
    }
}

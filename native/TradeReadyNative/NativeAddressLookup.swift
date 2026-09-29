import Combine
import MapKit

struct NativeAddressSuggestion: Identifiable, Equatable {
    let title: String
    let subtitle: String

    var id: String { "\(title)|\(subtitle)" }
    var address: String { NativeAddressLookup.displayAddress(title: title, subtitle: subtitle) }
}

enum NativeAddressLookupState: Equatable {
    case idle
    case searching
    case results
    case noResults
    case selected
    case unavailable
}

/// Pure formatting and eligibility rules shared by the MapKit adapter and host
/// tests. Address lookup is advisory: a customer can always retain and save the
/// exact free-form value they entered.
enum NativeAddressLookup {
    static let minimumQueryLength = 4

    static func normalizedQuery(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func shouldLookup(_ value: String) -> Bool {
        normalizedQuery(value).count >= minimumQueryLength
    }

    static func displayAddress(title: String, subtitle: String) -> String {
        let cleanTitle = normalizedQuery(title)
        var cleanSubtitle = normalizedQuery(subtitle)

        if cleanSubtitle == "United States" {
            cleanSubtitle = ""
        } else if cleanSubtitle.hasSuffix(", United States") {
            cleanSubtitle.removeLast(", United States".count)
        }

        guard !cleanTitle.isEmpty else { return cleanSubtitle }
        guard !cleanSubtitle.isEmpty else { return cleanTitle }
        guard cleanTitle.caseInsensitiveCompare(cleanSubtitle) != .orderedSame else {
            return cleanTitle
        }
        return "\(cleanTitle), \(cleanSubtitle)"
    }

    static func suggestions(from values: [(title: String, subtitle: String)]) -> [NativeAddressSuggestion] {
        var seen = Set<String>()
        var result: [NativeAddressSuggestion] = []

        for value in values {
            let suggestion = NativeAddressSuggestion(title: value.title, subtitle: value.subtitle)
            let address = suggestion.address
            let key = address.lowercased()
            guard !address.isEmpty, seen.insert(key).inserted else { continue }
            result.append(suggestion)
            if result.count == 5 { break }
        }
        return result
    }
}

/// Long-lived adapter for Apple's address-completion service. MapKit owns its
/// debounce behavior, cancels obsolete fragments, and reports failures without
/// replacing the user's typed address.
@MainActor
final class NativeAddressLookupModel: NSObject, ObservableObject {
    @Published private(set) var suggestions: [NativeAddressSuggestion] = []
    @Published private(set) var state: NativeAddressLookupState = .idle

    private let completer: MKLocalSearchCompleter
    private var selectedAddress: String?
    private var activeQuery: String?

    override init() {
        completer = MKLocalSearchCompleter()
        super.init()
        completer.delegate = self
        completer.resultTypes = .address
        completer.region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 39.5, longitude: -98.35),
            span: MKCoordinateSpan(latitudeDelta: 48, longitudeDelta: 65)
        )
    }

    func update(query: String) {
        let normalized = NativeAddressLookup.normalizedQuery(query)
        if normalized == selectedAddress {
            activeQuery = nil
            suggestions = []
            state = .selected
            return
        }

        selectedAddress = nil
        guard NativeAddressLookup.shouldLookup(normalized) else {
            activeQuery = nil
            completer.cancel()
            suggestions = []
            state = .idle
            return
        }

        suggestions = []
        activeQuery = normalized
        state = .searching
        completer.queryFragment = normalized
    }

    func select(_ suggestion: NativeAddressSuggestion) -> String {
        let address = suggestion.address
        selectedAddress = address
        activeQuery = nil
        completer.cancel()
        suggestions = []
        state = .selected
        return address
    }
}

extension NativeAddressLookupModel: MKLocalSearchCompleterDelegate {
    nonisolated func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        let query = NativeAddressLookup.normalizedQuery(completer.queryFragment)
        let values = completer.results.map { (title: $0.title, subtitle: $0.subtitle) }
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard activeQuery == query, state == .searching else { return }
            suggestions = NativeAddressLookup.suggestions(from: values)
            state = suggestions.isEmpty ? .noResults : .results
        }
    }

    nonisolated func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        let query = NativeAddressLookup.normalizedQuery(completer.queryFragment)
        Task { @MainActor [weak self] in
            guard let self, activeQuery == query else { return }
            suggestions = []
            state = .unavailable
        }
    }
}

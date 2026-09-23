import Foundation
import XCTest
@testable import TradeReadyNative

enum TestSupport {
    static let decoder = JSONDecoder()
    static let encoder = JSONEncoder()

    static func decimal(_ value: String) -> Decimal {
        Decimal(string: value, locale: Locale(identifier: "en_US_POSIX"))!
    }

    static func fixture(_ name: String) throws -> [String: Canonical.JSONValue] {
        let url = try XCTUnwrap(
            Bundle(for: BundleToken.self).url(forResource: name, withExtension: "json"),
            "Missing bundled fixture \(name).json"
        )
        return try decoder.decode([String: Canonical.JSONValue].self, from: Data(contentsOf: url))
    }

    static func field<T: Codable>(
        _ key: String,
        from fixture: [String: Canonical.JSONValue],
        as type: T.Type = T.self
    ) throws -> T {
        let value = try XCTUnwrap(fixture[key], "Missing fixture field \(key)")
        return try decoder.decode(T.self, from: encoder.encode(value))
    }

    static func json<T: Encodable>(_ value: T) throws -> Canonical.JSONValue {
        try decoder.decode(Canonical.JSONValue.self, from: encoder.encode(value))
    }

    static func object<T: Encodable>(_ value: T) throws -> [String: Canonical.JSONValue] {
        guard case let .object(result) = try json(value) else {
            throw NSError(
                domain: "TradeReadyNativeTests",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Expected encoded JSON object"]
            )
        }
        return result
    }

    static func assertRoundTrip<T: Codable>(
        _ type: T.Type,
        field key: String,
        fixture: [String: Canonical.JSONValue],
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let decoded: T = try field(key, from: fixture)
        XCTAssertEqual(try json(decoded), fixture[key], file: file, line: line)
    }
}

private final class BundleToken: NSObject {}

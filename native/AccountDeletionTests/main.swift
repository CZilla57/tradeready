import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

private final class DeletionLoader: NativeHTTPDataLoading {
    let status: Int
    let body: Data
    private(set) var request: URLRequest?

    init(status: Int, body: Data) {
        self.status = status
        self.body = body
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        self.request = request
        return (
            body,
            HTTPURLResponse(
                url: request.url!, statusCode: status,
                httpVersion: nil, headerFields: ["Content-Type": "application/json"]
            )!
        )
    }
}

@main
struct AccountDeletionTests {
    static func main() async throws {
        var failures = 0
        func expect(_ condition: @autoclosure () -> Bool, _ label: String) {
            if !condition() { failures += 1; print("FAIL: \(label)") }
        }

        let session = Data("{\"access_token\":\"private-access\",\"refresh_token\":\"refresh\"}".utf8)
        expect(NativeAccountDeletionConfirmation.matches(" delete ")
               && !NativeAccountDeletionConfirmation.matches("DELETED")
               && !NativeAccountDeletionConfirmation.matches("please DELETE"),
               "typed deletion confirmation matches the React Native boundary")
        let loader = DeletionLoader(status: 200, body: Data("{\"success\":true}".utf8))
        let endpoint = URL(string: "https://backend.example/api/delete-account")!
        try await NativeAccountDeletionClient(endpoint: endpoint, loader: loader)
            .deleteAccount(sessionBytes: session)
        expect(loader.request?.url == endpoint && loader.request?.httpMethod == "POST",
               "account deletion uses the established backend endpoint")
        expect(loader.request?.value(forHTTPHeaderField: "Authorization") == "Bearer private-access"
               && loader.request?.httpBody == nil,
               "account deletion sends only the access token header and no account-data body")

        for (status, expected) in [
            (401, NativeAccountDeletionError.sessionExpired),
            (429, NativeAccountDeletionError.rateLimited),
            (500, NativeAccountDeletionError.rejected)
        ] {
            do {
                try await NativeAccountDeletionClient(
                    endpoint: endpoint,
                    loader: DeletionLoader(status: status, body: Data("{}".utf8))
                ).deleteAccount(sessionBytes: session)
                expect(false, "HTTP \(status) fails closed")
            } catch let error as NativeAccountDeletionError {
                expect(error == expected, "HTTP \(status) maps to a bounded account-deletion error")
            }
        }

        do {
            try await NativeAccountDeletionClient(
                endpoint: endpoint,
                loader: DeletionLoader(status: 200, body: Data("{\"success\":false}".utf8))
            ).deleteAccount(sessionBytes: session)
            expect(false, "ambiguous success response fails closed")
        } catch NativeAccountDeletionError.unexpectedResponse {}

        do {
            try await NativeAccountDeletionClient(
                endpoint: URL(string: "http://remote.example/api/delete-account")!, loader: loader
            ).deleteAccount(sessionBytes: session)
            expect(false, "cleartext remote deletion is rejected")
        } catch NativeAccountDeletionError.invalidConfiguration {}

        if failures > 0 {
            print("FAILED: account deletion tests (\(failures) failure(s))")
            Foundation.exit(1)
        }
        print("PASS: authenticated account deletion tests")
    }
}

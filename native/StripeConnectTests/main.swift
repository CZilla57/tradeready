import Foundation

private var failures = 0
private func expect(_ condition: @autoclosure () -> Bool, _ label: String) { if !condition() { failures += 1; print("FAIL: \(label)") } }

private struct Loader: NativeStripeConnectHTTPDataLoading {
    let responseData: Data
    let status: Int
    let expectedMethod: String
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer token", "authenticated request")
        expect(request.httpMethod == expectedMethod, "expected HTTP method \(expectedMethod)")
        return (responseData, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}

@main
struct StripeConnectTests {
    static func main() async {
        let base = "https://worker.test"
        let session = Data("{\"access_token\":\"token\"}".utf8)
        func service(body: Data, status: Int, method: String) -> NativeStripeConnectService {
            NativeStripeConnectService(
                statusEndpoint: URL(string: "\(base)/api/stripe/connect-status")!,
                connectEndpoint: URL(string: "\(base)/api/stripe/create-connect-account")!,
                disconnectEndpoint: URL(string: "\(base)/api/stripe/disconnect")!,
                loader: Loader(responseData: body, status: status, expectedMethod: method))
        }
        do {
            let connected = try await service(
                body: Data("{\"connected\":true,\"details_submitted\":true,\"display_name\":\"Acme\"}".utf8),
                status: 200, method: "GET").status(sessionBytes: session)
            expect(connected == NativeStripeConnectStatus(connected: true, detailsSubmitted: true, displayName: "Acme"), "connected status decodes")
            let incomplete = try await service(
                body: Data("{\"connected\":true,\"details_submitted\":false}".utf8),
                status: 200, method: "GET").status(sessionBytes: session)
            expect(incomplete.detailsSubmitted == false && incomplete.displayName == nil, "incomplete onboarding decodes")
            let gone = try await service(
                body: Data("{\"connected\":false}".utf8),
                status: 200, method: "GET").status(sessionBytes: session)
            expect(gone.connected == false, "deleted account reads as disconnected")
        } catch { failures += 1; print("FAIL: valid status request threw \(error)") }
        do {
            let url = try await service(
                body: Data("{\"onboarding_url\":\"https://connect.stripe.com/setup/abc\"}".utf8),
                status: 200, method: "POST").beginOnboarding(sessionBytes: session)
            expect(url.absoluteString == "https://connect.stripe.com/setup/abc", "onboarding URL returned for browser open")
        } catch { failures += 1; print("FAIL: valid onboarding request threw \(error)") }
        do {
            try await service(body: Data(), status: 200, method: "POST").disconnect(sessionBytes: session)
        } catch { failures += 1; print("FAIL: valid disconnect threw \(error)") }
        do {
            _ = try await service(body: Data(), status: 401, method: "GET").status(sessionBytes: session)
            failures += 1
        } catch { expect(error as? NativeStripeConnectError == .rejectedSession, "auth rejection surfaces for refresh") }
        do {
            _ = try await service(
                body: Data("{\"onboarding_url\":\"http://evil.test/x\"}".utf8),
                status: 200, method: "POST").beginOnboarding(sessionBytes: session)
            failures += 1
        } catch { expect(error as? NativeStripeConnectError == .invalidResponse, "non-https onboarding URL rejected") }
        do {
            _ = try await service(body: Data(), status: 200, method: "GET").status(sessionBytes: Data())
            failures += 1
        } catch { expect(error as? NativeStripeConnectError == .malformedSession, "malformed session rejected") }
        print(failures == 0 ? "PASS: native stripe connect tests" : "FAILED: \(failures) native stripe connect test(s)")
        if failures != 0 { exit(1) }
    }
}

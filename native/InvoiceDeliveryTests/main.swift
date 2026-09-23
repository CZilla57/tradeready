import Foundation

private var failures = 0
private func expect(_ condition: @autoclosure () -> Bool, _ label: String) { if !condition() { failures += 1; print("FAIL: \(label)") } }

private struct Loader: NativeInvoiceDeliveryHTTPDataLoading {
    let responseData: Data
    let status: Int
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer token", "authenticated request")
        return (responseData, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}

@main
struct InvoiceDeliveryTests {
    static func main() async {
        let paymentEndpoint = URL(string: "https://worker.test/api/create-payment-link")!
        let pdfEndpoint = URL(string: "https://worker.test/api/invoice-pdf")!
        let session = Data("{\"access_token\":\"token\"}".utf8)
        let body = Data("{\"url\":\"https://buy.stripe.com/test\"}".utf8)
        let service = NativeInvoiceDeliveryService(paymentLinkEndpoint: paymentEndpoint, pdfEndpoint: pdfEndpoint, loader: Loader(responseData: body, status: 200))
        let invoice = try! JSONDecoder().decode(Canonical.Invoice.self, from: Data("""
        {"id":"inv1","customer":"Jane","number":"INV-1","amount":100,"due":"2026-10-01","email":"jane@example.test","phone":"","desc":"Work","paid":false}
        """.utf8))
        do {
            let url = try await service.createPaymentLink(invoice: invoice, amount: 100, sessionBytes: session)
            expect(url.absoluteString == "https://buy.stripe.com/test", "strict payment response")
            try await service.uploadPDF(invoiceID: "inv1", pdf: Data("%PDF-1.4".utf8), sessionBytes: session)
        } catch { failures += 1; print("FAIL: valid delivery request threw \(error)") }
        do { _ = try await service.createPaymentLink(invoice: invoice, amount: 0, sessionBytes: session); failures += 1 } catch { expect(error as? NativeInvoiceDeliveryError == .invalidAmount, "non-positive amount rejected") }
        do { _ = try await service.createPaymentLink(invoice: invoice, amount: 1, sessionBytes: Data()) ; failures += 1 } catch { expect(error as? NativeInvoiceDeliveryError == .malformedSession, "malformed session rejected") }
        print(failures == 0 ? "PASS: native invoice delivery tests" : "FAILED: \(failures) native invoice delivery test(s)")
        if failures != 0 { exit(1) }
    }
}

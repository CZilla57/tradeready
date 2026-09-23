import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

enum NativeInvoiceDeliveryError: Error, Equatable { case invalidConfiguration, malformedSession, invalidInvoiceID, invalidAmount, rejectedSession, invalidResponse, unavailable }
protocol NativeInvoiceDeliveryHTTPDataLoading: Sendable { func data(for request: URLRequest) async throws -> (Data, URLResponse) }
extension URLSession: NativeInvoiceDeliveryHTTPDataLoading {}

protocol NativeInvoiceDelivering: Sendable {
    func createPaymentLink(invoice: Canonical.Invoice, amount: Decimal, sessionBytes: Data) async throws -> URL
    func uploadPDF(invoiceID: String, pdf: Data, sessionBytes: Data) async throws
}

struct NativeInvoiceDeliveryService: NativeInvoiceDelivering {
    private struct Session: Decodable { let accessToken: String; enum CodingKeys: String, CodingKey { case accessToken = "access_token" } }
    private struct LinkBody: Encodable { let amount: Decimal; let invoiceNumber: String; let description: String; let invoiceId: String }
    private struct LinkResponse: Decodable { let url: String }
    let paymentLinkEndpoint: URL
    let pdfEndpoint: URL
    let loader: any NativeInvoiceDeliveryHTTPDataLoading

    init(paymentLinkEndpoint: URL, pdfEndpoint: URL, loader: any NativeInvoiceDeliveryHTTPDataLoading = URLSession.shared) {
        self.paymentLinkEndpoint = paymentLinkEndpoint; self.pdfEndpoint = pdfEndpoint; self.loader = loader
    }

    func createPaymentLink(invoice: Canonical.Invoice, amount: Decimal, sessionBytes: Data) async throws -> URL {
        guard Self.validEndpoint(paymentLinkEndpoint), Self.validID(invoice.id), amount > 0 else { throw amount > 0 ? (Self.validID(invoice.id) ? NativeInvoiceDeliveryError.invalidConfiguration : .invalidInvoiceID) : .invalidAmount }
        let token = try accessToken(sessionBytes)
        var request = URLRequest(url: paymentLinkEndpoint); request.httpMethod = "POST"
        request.httpBody = try JSONEncoder().encode(LinkBody(amount: amount, invoiceNumber: invoice.number, description: invoice.desc, invoiceId: invoice.id))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization"); request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await load(request); try success(response)
        guard let body = try? JSONDecoder().decode(LinkResponse.self, from: data), let url = URL(string: body.url), Self.validPublicURL(url) else { throw NativeInvoiceDeliveryError.invalidResponse }
        return url
    }

    func uploadPDF(invoiceID: String, pdf: Data, sessionBytes: Data) async throws {
        guard Self.validEndpoint(pdfEndpoint), Self.validID(invoiceID), pdf.starts(with: Data("%PDF-".utf8)), !pdf.isEmpty else { throw NativeInvoiceDeliveryError.invalidResponse }
        let token = try accessToken(sessionBytes); var request = URLRequest(url: pdfEndpoint); request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: ["invoiceId": invoiceID, "pdfBase64": pdf.base64EncodedString()])
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization"); request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (_, response) = try await load(request); try success(response)
    }

    private func accessToken(_ bytes: Data) throws -> String { guard let session = try? JSONDecoder().decode(Session.self, from: bytes), !session.accessToken.isEmpty else { throw NativeInvoiceDeliveryError.malformedSession }; return session.accessToken }
    private func load(_ request: URLRequest) async throws -> (Data, URLResponse) { do { return try await loader.data(for: request) } catch { throw NativeInvoiceDeliveryError.unavailable } }
    private func success(_ response: URLResponse) throws { guard let http = response as? HTTPURLResponse else { throw NativeInvoiceDeliveryError.invalidResponse }; if http.statusCode == 401 || http.statusCode == 403 { throw NativeInvoiceDeliveryError.rejectedSession }; guard (200..<300).contains(http.statusCode) else { throw NativeInvoiceDeliveryError.unavailable } }
    private static func validID(_ value: String) -> Bool { !value.isEmpty && value.count <= 200 && value == value.trimmingCharacters(in: .whitespacesAndNewlines) && !value.contains("/") }
    private static func validEndpoint(_ url: URL) -> Bool { url.host != nil && url.user == nil && url.password == nil && url.query == nil && url.fragment == nil && (url.scheme == "https" || (url.scheme == "http" && ["localhost", "127.0.0.1", "::1"].contains(url.host ?? ""))) }
    private static func validPublicURL(_ url: URL) -> Bool { url.scheme?.lowercased() == "https" && url.host != nil && url.user == nil && url.password == nil && url.fragment == nil }
}

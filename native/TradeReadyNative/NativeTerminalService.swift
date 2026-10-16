import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Phase 18 (Tap to Pay, spec §2.1): the typed client for the Worker's three
/// `POST /api/terminal/*` routes (`backend-workers/src/routes/terminal.js`).
/// Foundation only, so the host harness compiles it alone.
///
/// MONEY: the Worker's `payment-intent` takes `amount` in DOLLARS (whole
/// cents). This file is the only place cents become dollars (`Decimal`, so the
/// JSON number is exact: 41250 cents is `412.5`), and it refuses a response
/// whose `amountCents` is not the amount that was asked for.
enum NativeTerminalError: Error, Equatable {
    case invalidConfiguration, malformedSession, rejectedSession, invalidResponse, unavailable
    /// 422 `not_synced`: the invoice has not reached the server yet.
    case notSynced
    case notFound
    /// The server's PaymentIntent is for a different amount than asked.
    case amountMismatch
    /// 400 `amount_exceeds_balance`; the server's balance in cents.
    case amountExceedsBalance(balanceCents: Int?)
    case invalidRequest
    /// 400 `below_minimum`: under Stripe's minimum charge.
    case belowMinimum
    /// 409 `operation_conflict`: the operation id was used with other details.
    case operationConflict
    /// 422 `no_connected_account`.
    case noConnectedAccount
    /// 422 `stripe_rejected`.
    case stripeRejected
    case rateLimited
    case serverError
}

struct NativeTerminalPaymentIntent: Equatable, Sendable {
    var paymentIntentID: String
    var clientSecret: String
    var amountCents: Int
}

struct NativeTerminalLocation: Equatable, Sendable {
    var locationID: String?
}

struct NativeTerminalAddress: Equatable, Sendable {
    var line1: String
    var line2: String?
    var city: String
    var state: String
    var postalCode: String
}

/// What the payment flow needs from the Worker. The flow depends on this, not
/// on `URLSession`, so the host tests drive it with a fake.
protocol NativeTerminalServicing: Sendable {
    func connectionToken() async throws -> String
    func locationStatus() async throws -> NativeTerminalLocation
    func ensureLocation(displayName: String, address: NativeTerminalAddress) async throws -> NativeTerminalLocation
    /// `invoiceNumber` is the number the device froze with the operation; the
    /// Worker puts it in the PaymentIntent description, so it must be the same
    /// on every retry of one operation (nil = the Worker uses its own copy).
    func createPaymentIntent(
        invoiceID: String, amountCents: Int, localDate: String, operationID: String, invoiceNumber: String?
    ) async throws -> NativeTerminalPaymentIntent
}

struct NativeTerminalService: NativeTerminalServicing {
    private struct Session: Decodable {
        let accessToken: String
        enum CodingKeys: String, CodingKey { case accessToken = "access_token" }
    }
    private struct TokenBody: Decodable { var secret: String? }
    private struct LocationBody: Decodable { var locationId: String? }
    private struct IntentBody: Decodable {
        var paymentIntentId: String?
        var clientSecret: String?
        var amountCents: Int?
    }
    private struct ErrorBody: Decodable {
        var code: String?
        var balance: Decimal?
    }
    private struct IntentRequest: Encodable {
        var invoiceId: String
        /// Dollars, as a Decimal so the JSON number is exact.
        var amount: Decimal
        var localDate: String
        var operationId: String
        var invoiceNumber: String?
    }
    private struct LocationRequest: Encodable {
        struct Address: Encodable {
            var line1: String
            var line2: String?
            var city: String
            var state: String
            var postal_code: String
            var country = "US"
        }
        var action: String
        var displayName: String?
        var address: Address?
    }

    let connectionTokenEndpoint: URL
    let locationEndpoint: URL
    let paymentIntentEndpoint: URL
    /// The signed-in session's bytes (the same `{"access_token": ...}` the
    /// other services take), read per request so a refreshed session is used.
    let sessionProvider: @Sendable () -> Data?
    let loader: any NativeStripeConnectHTTPDataLoading

    init(
        connectionTokenEndpoint: URL,
        locationEndpoint: URL,
        paymentIntentEndpoint: URL,
        sessionProvider: @escaping @Sendable () -> Data?,
        loader: any NativeStripeConnectHTTPDataLoading = URLSession.shared
    ) {
        self.connectionTokenEndpoint = connectionTokenEndpoint
        self.locationEndpoint = locationEndpoint
        self.paymentIntentEndpoint = paymentIntentEndpoint
        self.sessionProvider = sessionProvider
        self.loader = loader
    }

    func connectionToken() async throws -> String {
        let data = try await post(connectionTokenEndpoint, body: Data("{}".utf8))
        guard let secret = (try? JSONDecoder().decode(TokenBody.self, from: data))?.secret, !secret.isEmpty
        else { throw NativeTerminalError.invalidResponse }
        return secret
    }

    func locationStatus() async throws -> NativeTerminalLocation {
        let body = try JSONEncoder().encode(LocationRequest(action: "status"))
        return try parseLocation(try await post(locationEndpoint, body: body))
    }

    func ensureLocation(displayName: String, address: NativeTerminalAddress) async throws -> NativeTerminalLocation {
        let body = try JSONEncoder().encode(LocationRequest(
            action: "ensure",
            displayName: displayName,
            address: .init(
                line1: address.line1, line2: address.line2, city: address.city,
                state: address.state, postal_code: address.postalCode)))
        return try parseLocation(try await post(locationEndpoint, body: body))
    }

    func createPaymentIntent(
        invoiceID: String, amountCents: Int, localDate: String, operationID: String, invoiceNumber: String?
    ) async throws -> NativeTerminalPaymentIntent {
        guard amountCents > 0, amountCents <= NativeCardPresentPayment.maxChargeCents,
              NativeCardPresentPayment.isValidOperationID(operationID),
              NativeCardPresentPayment.isValidLocalDate(localDate), !invoiceID.isEmpty
        else { throw NativeTerminalError.invalidRequest }
        // The one cents-to-dollars conversion (exact: Decimal, not Double).
        let dollars = Decimal(amountCents) / 100
        let body = try JSONEncoder().encode(IntentRequest(
            invoiceId: invoiceID, amount: dollars, localDate: localDate, operationId: operationID,
            invoiceNumber: NativeCardPresentPayment.cleanInvoiceNumber(invoiceNumber)))
        let data = try await post(paymentIntentEndpoint, body: body)
        guard let parsed = try? JSONDecoder().decode(IntentBody.self, from: data),
              let id = parsed.paymentIntentId, NativeCardPresentPayment.isValidPaymentIntentID(id),
              let secret = parsed.clientSecret, !secret.isEmpty,
              let echoed = parsed.amountCents
        else { throw NativeTerminalError.invalidResponse }
        // Never collect an amount other than the one asked for.
        guard echoed == amountCents else { throw NativeTerminalError.amountMismatch }
        return NativeTerminalPaymentIntent(paymentIntentID: id, clientSecret: secret, amountCents: echoed)
    }

    // MARK: - Plumbing

    private func parseLocation(_ data: Data) throws -> NativeTerminalLocation {
        guard let body = try? JSONDecoder().decode(LocationBody.self, from: data) else {
            throw NativeTerminalError.invalidResponse
        }
        return NativeTerminalLocation(locationID: body.locationId.flatMap { $0.isEmpty ? nil : $0 })
    }

    private func post(_ endpoint: URL, body: Data) async throws -> Data {
        guard Self.validEndpoint(endpoint) else { throw NativeTerminalError.invalidConfiguration }
        guard let bytes = sessionProvider(),
              let session = try? JSONDecoder().decode(Session.self, from: bytes),
              !session.accessToken.isEmpty
        else { throw NativeTerminalError.malformedSession }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        let data: Data
        let response: URLResponse
        do { (data, response) = try await loader.data(for: request) }
        catch { throw NativeTerminalError.unavailable }
        guard let http = response as? HTTPURLResponse else { throw NativeTerminalError.invalidResponse }
        if (200..<300).contains(http.statusCode) { return data }
        throw Self.error(status: http.statusCode, data: data)
    }

    static func error(status: Int, data: Data) -> NativeTerminalError {
        let body = try? JSONDecoder().decode(ErrorBody.self, from: data)
        switch (status, body?.code) {
        case (401, _), (403, _): return .rejectedSession
        case (400, "amount_exceeds_balance"):
            // The server's balance is dollars; whole cents only.
            let cents = body?.balance.flatMap { NativeCardPresentPayment.cents(fromDollars: NSDecimalNumber(decimal: $0).doubleValue) }
            return .amountExceedsBalance(balanceCents: cents)
        case (400, "below_minimum"): return .belowMinimum
        case (400, _): return .invalidRequest
        case (404, _): return .notFound
        case (409, "operation_conflict"): return .operationConflict
        case (422, "not_synced"): return .notSynced
        case (422, "no_connected_account"): return .noConnectedAccount
        case (422, "stripe_rejected"): return .stripeRejected
        case (429, _): return .rateLimited
        case (500..., _): return .serverError
        default: return .unavailable
        }
    }

    private static func validEndpoint(_ url: URL) -> Bool {
        url.host != nil && url.user == nil && url.password == nil
            && url.query == nil && url.fragment == nil
            && (url.scheme == "https"
                || (url.scheme == "http" && ["localhost", "127.0.0.1", "::1"].contains(url.host ?? "")))
    }
}

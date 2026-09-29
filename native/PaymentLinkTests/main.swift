import Foundation

private var failures = 0
private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        failures += 1
        print("FAIL: \(message)")
    }
}

// Deposit resolution: percent of TOTAL, clamped to balance, cents-rounded.
expect(NativeInvoicePaymentLinks.requestedAmount(total: 1000, balance: 1000, mode: .half) == 500, "half of total on fresh invoice")
expect(NativeInvoicePaymentLinks.requestedAmount(total: 1000, balance: 400, mode: .half) == 400, "half clamped to remaining balance")
expect(NativeInvoicePaymentLinks.requestedAmount(total: 1000, balance: 1000, mode: .full) == 1000, "full requests the balance")
expect(NativeInvoicePaymentLinks.requestedAmount(total: 1000, balance: 1000, mode: .customPercent(10)) == 100, "custom percent of total")
expect(NativeInvoicePaymentLinks.requestedAmount(total: 1000, balance: 1000, mode: .customFixed(250)) == 250, "custom fixed amount")
expect(NativeInvoicePaymentLinks.requestedAmount(total: 1000, balance: 1000, mode: .customFixed(-5)) == 0, "negative fixed is nothing to request")
expect(NativeInvoicePaymentLinks.requestedAmount(total: 1000, balance: 1000, mode: .customPercent(.nan)) == 0, "NaN percent is nothing to request")
expect(NativeInvoicePaymentLinks.requestedAmount(total: 100, balance: 100, mode: .customFixed(33.335)) == 33.34, "requests round to cents")

// Deposit ask: nil when effectively the full balance.
expect(NativeInvoicePaymentLinks.depositAsk(total: 1000, balance: 1000, mode: .full) == nil, "full balance is never a deposit ask")
expect(NativeInvoicePaymentLinks.depositAsk(total: 1000, balance: 400, mode: .half) == nil, "clamped-to-balance half is not a deposit ask")
expect(NativeInvoicePaymentLinks.depositAsk(total: 1000, balance: 1000, mode: .half) == NativeDepositAsk(amount: 500, percent: 50), "fresh half carries the percent")
let customAsk = NativeInvoicePaymentLinks.depositAsk(total: 1000, balance: 1000, mode: .customFixed(250))
expect(customAsk == NativeDepositAsk(amount: 250, percent: nil), "fixed ask carries no percent")

// Cache gate: epsilon match, legacy credential refusal.
expect(NativeInvoicePaymentLinks.cachedLinkMatches(url: "https://pay.stripe/abc", amount: 500, requested: 500), "exact-amount link matches")
expect(NativeInvoicePaymentLinks.cachedLinkMatches(url: "https://pay.stripe/abc", amount: 500.004, requested: 500), "sub-half-cent drift still matches")
expect(!NativeInvoicePaymentLinks.cachedLinkMatches(url: "https://pay.stripe/abc", amount: 450, requested: 500), "stale amount after partial payment never matches")
expect(!NativeInvoicePaymentLinks.cachedLinkMatches(url: "https://squareup.com/pay/SECRET", amount: 500, requested: 500), "legacy Square credential link never matches")
expect(!NativeInvoicePaymentLinks.cachedLinkMatches(url: nil, amount: 500, requested: 500), "missing link never matches")

// Square shape gate.
expect(NativeInvoicePaymentLinks.isSquarePaymentLink("https://square.link/u/abc"), "https square.link is usable")
expect(NativeInvoicePaymentLinks.isSquarePaymentLink("square.link/u/abc"), "scheme-less square.link is usable")
expect(!NativeInvoicePaymentLinks.isSquarePaymentLink("sq-access-token-xyz"), "a pasted access token is unusable")
expect(!NativeInvoicePaymentLinks.isProviderConfigured(.stripe, key: "anything"), "stripe always needs the backend")
expect(!NativeInvoicePaymentLinks.isProviderConfigured(.square, key: "sq-access-token-xyz"), "token-shaped Square value is not configured")
expect(!NativeInvoicePaymentLinks.isProviderConfigured(.paypal, key: "  "), "blank key is not configured")

// Offline builders mirror the RN URL shapes.
let square = try? NativeInvoicePaymentLinks.offlineLink(invoiceNumber: "INV-1", description: "Work", provider: .square, providerKey: "square.link/u/abc", amount: 100)
expect(square == "https://square.link/u/abc?amount=100.00&invoice=INV-1", "square link shape")
let paypal = try? NativeInvoicePaymentLinks.offlineLink(invoiceNumber: "INV-1", description: "Work", provider: .paypal, providerKey: "johndoe", amount: 100)
expect(paypal == "https://paypal.me/johndoe/100.00", "paypal link shape")
let venmo = try? NativeInvoicePaymentLinks.offlineLink(invoiceNumber: "INV-1", description: "Fix & repair", provider: .venmo, providerKey: "janedoe", amount: 50)
expect(venmo == "https://venmo.com/janedoe?txn=pay&amount=50.00&note=INV-1%20-%20Fix%20%26%20repair", "venmo link shape with encoded note")
do {
    _ = try NativeInvoicePaymentLinks.offlineLink(invoiceNumber: "INV-1", description: "Work", provider: .stripe, providerKey: "", amount: 100)
    expect(false, "stripe must require the backend")
} catch NativePaymentLinkError.requiresBackend { } catch { expect(false, "stripe throws requiresBackend") }
do {
    _ = try NativeInvoicePaymentLinks.offlineLink(invoiceNumber: "INV-1", description: "Work", provider: .paypal, providerKey: "x", amount: 0)
    expect(false, "zero amount must refuse")
} catch NativePaymentLinkError.nothingToRequest { } catch { expect(false, "zero amount throws nothingToRequest") }

if failures == 0 { print("PaymentLinkTests: all tests passed") } else { print("PaymentLinkTests: \(failures) failure(s)") }
exit(failures == 0 ? 0 : 1)

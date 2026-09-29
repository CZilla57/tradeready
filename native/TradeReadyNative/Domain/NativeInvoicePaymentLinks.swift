import Foundation

/// Pure payment-link policy mirroring `utils/invoiceHelpers.ts`
/// (`buildPaymentLink`, `cachedLinkMatches`, `isSquarePaymentLink`) and the
/// deposit selector in `screens/OutreachScreen.tsx`.
///
/// Standalone-compilable (Foundation only) so the `swiftc` focused harness
/// compiles it alone. Amounts are `Double` here to match the UI layer; the
/// epsilon rule duplicates `PaymentLedger.paidEpsilon` deliberately (see the
/// Phase 6 half-cent note on standalone-compilable files).
enum NativePaymentProvider: String, CaseIterable {
    case stripe, square, paypal, venmo, custom
}

enum NativeDepositMode: Equatable {
    case full
    case half
    case customPercent(Double)
    case customFixed(Double)
}

struct NativeDepositAsk: Equatable {
    var amount: Double
    var percent: Double?
}

enum NativePaymentLinkError: Error, Equatable {
    /// Stripe links are minted by the backend; there is no offline builder.
    case requiresBackend
    /// Nothing to request (non-positive or unparseable amount).
    case nothingToRequest
}

enum NativeInvoicePaymentLinks {
    static let epsilon = 0.005

    // MARK: - Deposit resolution

    /// Percent applies to the INVOICE TOTAL, clamped to the remaining
    /// balance (`resolveDepositAmount` parity). Returns 0 for nonsense input;
    /// callers treat 0 as "nothing to request" and disable link generation.
    static func requestedAmount(total: Double, balance: Double, mode: NativeDepositMode) -> Double {
        let clampedBalance = max(0, balance)
        switch mode {
        case .full:
            return cents(clampedBalance)
        case .half:
            return resolve(total: total, balance: clampedBalance, requested: total * 50 / 100)
        case .customPercent(let percent):
            guard percent.isFinite else { return 0 }
            return resolve(total: total, balance: clampedBalance, requested: total * percent / 100)
        case .customFixed(let fixed):
            guard fixed.isFinite else { return 0 }
            return resolve(total: total, balance: clampedBalance, requested: fixed)
        }
    }

    /// The active deposit ask, or nil when the request is effectively the full
    /// balance — messages and persistence must never call the whole balance a
    /// "deposit" (`OutreachScreen.depositAsk` parity).
    static func depositAsk(total: Double, balance: Double, mode: NativeDepositMode) -> NativeDepositAsk? {
        guard mode != .full else { return nil }
        let requested = requestedAmount(total: total, balance: balance, mode: mode)
        guard requested > 0, requested < cents(max(0, balance)) else { return nil }
        let percent: Double? = switch mode {
        case .half: 50
        case .customPercent(let p): p.isFinite ? p : nil
        default: nil
        }
        return NativeDepositAsk(amount: requested, percent: percent)
    }

    // MARK: - Link cache

    /// The display-side cache gate (`cachedLinkMatches` parity): reuse the
    /// stored link only when it was minted for the amount being requested
    /// now. Legacy Square credential links (`squareup.com/pay/…`) never match.
    static func cachedLinkMatches(url: String?, amount: Double?, requested: Double) -> Bool {
        guard let url, !url.isEmpty, let amount, amount.isFinite else { return false }
        let lower = url.lowercased()
        if lower.hasPrefix("http://squareup.com/pay/")
            || lower.hasPrefix("https://squareup.com/pay/")
            || lower.hasPrefix("http://www.squareup.com/pay/")
            || lower.hasPrefix("https://www.squareup.com/pay/") {
            return false
        }
        return abs(amount - requested) <= epsilon
    }

    // MARK: - Offline builders

    /// The SINGLE definition of "safe to emit" for Square values
    /// (`isSquarePaymentLink` parity): http(s), or scheme-less square.link /
    /// checkout.square.site paths. Anything else (notably a pasted Square
    /// access token) is unusable and the credential never leaves the device.
    static func isSquarePaymentLink(_ value: String) -> Bool {
        let raw = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return false }
        let lower = raw.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") { return true }
        let host = lower.hasPrefix("www.") ? String(lower.dropFirst(4)) : lower
        return host.hasPrefix("square.link/") || host.hasPrefix("checkout.square.site/")
    }

    /// A stored provider value is only presented as a usable payment link when
    /// configured: Stripe always needs the backend, Square needs a
    /// link-shaped value, every other provider needs a non-empty key.
    /// Placeholders are never presented as usable customer payment links.
    static func isProviderConfigured(_ provider: NativePaymentProvider, key: String) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        switch provider {
        case .stripe:
            return false
        case .square:
            return isSquarePaymentLink(trimmed)
        case .paypal, .venmo, .custom:
            return !trimmed.isEmpty
        }
    }

    /// Offline URL builders for the non-Stripe providers (`buildPaymentLink`
    /// parity). Stripe throws `.requiresBackend`; a non-positive amount throws
    /// `.nothingToRequest`.
    static func offlineLink(
        invoiceNumber: String,
        description: String,
        provider: NativePaymentProvider,
        providerKey: String,
        amount: Double
    ) throws -> String {
        guard amount.isFinite, amount > 0 else { throw NativePaymentLinkError.nothingToRequest }
        let amt = String(format: "%.2f", amount)
        switch provider {
        case .stripe:
            throw NativePaymentLinkError.requiresBackend
        case .square:
            let base = squareBase(providerKey)
            return "\(base)\(base.contains("?") ? "&" : "?")amount=\(amt)&invoice=\(invoiceNumber)"
        case .paypal:
            let key = providerKey.trimmingCharacters(in: .whitespacesAndNewlines)
            return "https://paypal.me/\(key.isEmpty ? "yourusername" : key)/\(amt)"
        case .venmo:
            let key = providerKey.trimmingCharacters(in: .whitespacesAndNewlines)
            let note = encodeURIComponent("\(invoiceNumber) - \(description)")
            return "https://venmo.com/\(key.isEmpty ? "yourusername" : key)?txn=pay&amount=\(amt)&note=\(note)"
        case .custom:
            let key = providerKey.trimmingCharacters(in: .whitespacesAndNewlines)
            let base = key.isEmpty ? "https://yourpaymentpage.com" : key
            return "\(base)\(base.contains("?") ? "&" : "?")amount=\(amt)&invoice=\(invoiceNumber)"
        }
    }

    // MARK: - Private

    private static func resolve(total: Double, balance: Double, requested: Double) -> Double {
        guard requested.isFinite, requested > 0 else { return 0 }
        return cents(min(requested, balance))
    }

    private static func cents(_ value: Double) -> Double {
        (value * 100).rounded() / 100
    }

    private static func squareBase(_ providerKey: String) -> String {
        let value = providerKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isSquarePaymentLink(value) else { return "https://square.link/u/yourlink" }
        let lower = value.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") { return value }
        return "https://\(value)"
    }

    /// JavaScript `encodeURIComponent` parity: leaves `A-Za-z0-9 -_.!~*'()`
    /// unescaped, percent-encodes everything else as UTF-8.
    private static func encodeURIComponent(_ value: String) -> String {
        let unescaped = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_.!~*'()"))
        return value.addingPercentEncoding(withAllowedCharacters: unescaped) ?? value
    }
}

/// Task 11.13 fix round 2 (contract §17.2 G4/G5): the Square provider-key
/// policy. An RN build before the 2026-08 Square credential fix told users to
/// paste their Square ACCESS TOKEN under Settings → Square, so a live
/// credential can sit in the synced settings blob. Native never saves one
/// (`validate`, the Settings save), and heals one it finds (`scrubbed`, the
/// port of RN `scrubLegacySquareToken`, `utils/storage/settings.ts`). The
/// Square rule is `isSquarePaymentLink` itself, the single RN definition of
/// "safe to emit"; every other provider keeps RN's unvalidated save.
enum NativeSquareProviderKeyPolicy {
    /// The `providerKeys` entry RN's heal deletes.
    static let providerID = NativePaymentProvider.square.rawValue

    /// Shown when a Square entry is refused. RN's Square hint
    /// (`screens/SettingsPaymentsScreen.tsx`), framed as a refusal; it never
    /// echoes what was typed, so a pasted credential is not shown back.
    static let rejectionMessage = "That isn't a Square payment link, so it wasn't saved. "
        + "Paste your Square payment link (create one in Square Dashboard → Payment Links, "
        + "e.g. https://square.link/u/abc123) — never an access token."

    enum Decision: Equatable {
        /// Persist this value (Square: trimmed-empty clears to "").
        case save(String)
        /// Persist nothing; show this message.
        case reject(String)
    }

    static func validate(_ value: String, provider: String) -> Decision {
        guard provider == providerID else { return .save(value) }
        if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .save("") }
        return NativeInvoicePaymentLinks.isSquarePaymentLink(value) ? .save(value) : .reject(rejectionMessage)
    }

    /// RN `scrubLegacySquareToken` semantics exactly: when the Square entry is
    /// a non-empty value `isSquarePaymentLink` refuses, the key is deleted.
    /// Nil means nothing to scrub, and the caller MUST NOT write (RN: a run
    /// that finds nothing never saves, since saving re-enqueues an upsert).
    static func scrubbed(_ providerKeys: [String: String]) -> [String: String]? {
        guard let square = providerKeys[providerID], !square.isEmpty,
              !NativeInvoicePaymentLinks.isSquarePaymentLink(square) else { return nil }
        var cleaned = providerKeys
        cleaned.removeValue(forKey: providerID)
        return cleaned
    }
}

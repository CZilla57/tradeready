import Foundation

// MARK: - Phase 33: opaque attribution codes (campaigns spec §9.2)
//
// A campaign's `code` rides on its booking link as `?c=<code>`: 16 lowercase
// Crockford base32 characters (80 random bits), the shape the Worker's
// `CAMPAIGN_CODE_RE = /^[0-9a-hjkmnp-tv-z]{16}$/` keeps. The spec reuses
// Phase 34's `NativeReferrals.makeCode`; Phase 34 is not on this branch, so
// the encoder lives here as the shared `NativeAttributionCode` the spec names
// for that case. It is random, carries no PII, and is never looked up,
// logged or echoed server-side.

enum NativeAttributionCode {
    /// Crockford base32, lowercase: no `i`, `l`, `o` or `u`.
    static let alphabet = Array("0123456789abcdefghjkmnpqrstvwxyz")
    static let length = 16

    /// A source of uniformly random bytes. Production uses the system CSPRNG
    /// (`SystemRandomNumberGenerator`, which reads the kernel's
    /// cryptographically secure generator on Apple platforms); tests inject
    /// fixed bytes.
    typealias RandomBytes = (_ count: Int) -> [UInt8]

    static let systemBytes: RandomBytes = { count in
        var generator = SystemRandomNumberGenerator()
        return (0..<count).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
    }

    /// 16 characters from 10 random bytes (5 bits per character, no modulo
    /// bias).
    static func makeCode(randomBytes: RandomBytes = systemBytes) -> String {
        let bytes = randomBytes(10)
        var bits: UInt64 = 0
        var bitCount = 0
        var out = ""
        for byte in bytes {
            bits = (bits << 8) | UInt64(byte)
            bitCount += 8
            while bitCount >= 5, out.count < length {
                bitCount -= 5
                out.append(alphabet[Int((bits >> UInt64(bitCount)) & 0x1f)])
            }
            bits &= (1 << UInt64(bitCount)) - 1
        }
        // A short byte source pads with zeros so the length invariant holds.
        while out.count < length { out.append(alphabet[0]) }
        return out
    }

    /// A code that is not already taken (a collision is ~2^-80, but a fixed
    /// test source can repeat).
    static func makeUniqueCode(existing: Set<String>, randomBytes: RandomBytes = systemBytes) -> String {
        for _ in 0..<8 {
            let code = makeCode(randomBytes: randomBytes)
            if !existing.contains(code) { return code }
        }
        return makeCode(randomBytes: systemBytes)
    }

    /// The Worker's format check, ported: exactly 16 characters from the
    /// alphabet, after trimming and lowercasing.
    static func isValid(_ raw: String) -> Bool {
        let code = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let allowed = Set(alphabet)
        return code.count == length && code.allSatisfy { allowed.contains($0) }
    }
}

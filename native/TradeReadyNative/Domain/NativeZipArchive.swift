import Foundation

// MARK: - Deterministic stored ZIP writer (task 9.06, requirement X2)
//
// Pure port of `utils/zipStore.ts`: a stored (method 0) ZIP with the only
// otherwise-variable header fields (DOS mod time/date) fixed to zero, so identical
// entries produce byte-identical archives. CRCs, UTF-8 names, and base64 are
// hand-rolled to match the JS byte-for-byte.

struct NativeZipEntry: Equatable {
    var name: String
    var bytes: [UInt8]
}

enum NativeZipArchive {
    private static let crcTable: [UInt32] = {
        var table = [UInt32](repeating: 0, count: 256)
        for n in 0..<256 {
            var c = UInt32(n)
            for _ in 0..<8 {
                c = (c & 1) == 1 ? (0xEDB8_8320 ^ (c >> 1)) : (c >> 1)
            }
            table[n] = c
        }
        return table
    }()

    /// Standard CRC-32 (poly 0xEDB88320, init/final 0xFFFFFFFF).
    static func crc32(_ bytes: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in bytes {
            crc = crcTable[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFF_FFFF
    }

    /// UTF-8 including surrogate-pair (astral) handling.
    static func utf8Encode(_ string: String) -> [UInt8] {
        var out: [UInt8] = []
        let scalars = Array(string.unicodeScalars)
        var index = 0
        while index < scalars.count {
            var code = UInt32(scalars[index].value)
            // Combine a surrogate pair the way the JS hand-rolled encoder does.
            if code >= 0xD800, code <= 0xDBFF, index + 1 < scalars.count {
                let next = UInt32(scalars[index + 1].value)
                if next >= 0xDC00, next <= 0xDFFF {
                    code = 0x10000 + ((code - 0xD800) << 10) + (next - 0xDC00)
                    index += 1
                }
            }
            if code < 0x80 {
                out.append(UInt8(code))
            } else if code < 0x800 {
                out.append(UInt8(0xC0 | (code >> 6)))
                out.append(UInt8(0x80 | (code & 0x3F)))
            } else if code < 0x10000 {
                out.append(UInt8(0xE0 | (code >> 12)))
                out.append(UInt8(0x80 | ((code >> 6) & 0x3F)))
                out.append(UInt8(0x80 | (code & 0x3F)))
            } else {
                out.append(UInt8(0xF0 | (code >> 18)))
                out.append(UInt8(0x80 | ((code >> 12) & 0x3F)))
                out.append(UInt8(0x80 | ((code >> 6) & 0x3F)))
                out.append(UInt8(0x80 | (code & 0x3F)))
            }
            index += 1
        }
        return out
    }

    private static let base64Alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/")

    /// Standard base64 with `=` padding and no line breaks.
    static func base64Encode(_ bytes: [UInt8]) -> String {
        var out = ""
        var i = 0
        while i + 2 < bytes.count {
            let n = (UInt32(bytes[i]) << 16) | (UInt32(bytes[i + 1]) << 8) | UInt32(bytes[i + 2])
            out.append(base64Alphabet[Int((n >> 18) & 63)])
            out.append(base64Alphabet[Int((n >> 12) & 63)])
            out.append(base64Alphabet[Int((n >> 6) & 63)])
            out.append(base64Alphabet[Int(n & 63)])
            i += 3
        }
        let remaining = bytes.count - i
        if remaining == 1 {
            let n = UInt32(bytes[i]) << 16
            out.append(base64Alphabet[Int((n >> 18) & 63)])
            out.append(base64Alphabet[Int((n >> 12) & 63)])
            out.append("==")
        } else if remaining == 2 {
            let n = (UInt32(bytes[i]) << 16) | (UInt32(bytes[i + 1]) << 8)
            out.append(base64Alphabet[Int((n >> 18) & 63)])
            out.append(base64Alphabet[Int((n >> 12) & 63)])
            out.append(base64Alphabet[Int((n >> 6) & 63)])
            out.append("=")
        }
        return out
    }

    private static func u16(_ value: UInt32) -> [UInt8] {
        [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF)]
    }

    private static func u32(_ value: UInt32) -> [UInt8] {
        [
            UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF),
            UInt8((value >> 16) & 0xFF), UInt8((value >> 24) & 0xFF),
        ]
    }

    /// Deterministic stored ZIP. Flag bit 11 (0x0800) marks UTF-8 names; mod
    /// time/date are zeroed; compressed size equals uncompressed size.
    static func buildZip(_ entries: [NativeZipEntry]) -> [UInt8] {
        var out: [UInt8] = []
        var records: [(nameBytes: [UInt8], crc: UInt32, size: Int, offset: Int)] = []

        for entry in entries {
            let nameBytes = utf8Encode(entry.name)
            let crc = crc32(entry.bytes)
            let size = entry.bytes.count
            let offset = out.count
            out += u32(0x0403_4B50) + u16(20) + u16(0x0800) + u16(0)
                + u16(0) + u16(0) + u32(crc) + u32(UInt32(size)) + u32(UInt32(size))
                + u16(UInt32(nameBytes.count)) + u16(0)
            out += nameBytes
            out += entry.bytes
            records.append((nameBytes, crc, size, offset))
        }

        let centralStart = out.count
        for record in records {
            out += u32(0x0201_4B50) + u16(20) + u16(20) + u16(0x0800) + u16(0)
                + u16(0) + u16(0) + u32(record.crc) + u32(UInt32(record.size)) + u32(UInt32(record.size))
                + u16(UInt32(record.nameBytes.count)) + u16(0) + u16(0) + u16(0) + u16(0)
                + u32(0) + u32(UInt32(record.offset))
            out += record.nameBytes
        }
        let centralSize = out.count - centralStart

        out += u32(0x0605_4B50) + u16(0) + u16(0)
            + u16(UInt32(records.count)) + u16(UInt32(records.count))
            + u32(UInt32(centralSize)) + u32(UInt32(centralStart)) + u16(0)

        return out
    }
}

import Foundation

/// The two text encodings PROTOCOL.md uses on the wire: base64url without padding for binary
/// values and 32 lowercase hex characters for 16-byte ids.
public enum WireEncoding {
    /// Length in bytes of every id (accountId, deviceId, notebookId, docId, clientUpdateId).
    public static let idLength = 16

    /// Length in characters of an id in its hex form.
    public static let idHexLength = 32

    private static let base64Alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_".utf8)
    private static let hexDigits = Array("0123456789abcdef".utf8)

    // MARK: base64url

    /// Encodes bytes as base64url without padding.
    public static func base64URLString(_ bytes: Data) -> String {
        var out = [UInt8]()
        out.reserveCapacity((bytes.count * 4 + 2) / 3)
        var acc: UInt32 = 0
        var bits = 0
        for byte in bytes {
            acc = (acc << 8) | UInt32(byte)
            bits += 8
            while bits >= 6 {
                bits -= 6
                out.append(base64Alphabet[Int((acc >> UInt32(bits)) & 63)])
            }
            acc &= (1 << UInt32(bits)) - 1
        }
        if bits > 0 {
            out.append(base64Alphabet[Int((acc << UInt32(6 - bits)) & 63)])
        }
        return String(decoding: out, as: UTF8.self)
    }

    /// Decodes base64url without padding. Returns nil for anything else: padding characters,
    /// whitespace, the standard base64 characters `+` and `/`, an impossible length, or unused
    /// trailing bits that are not zero (so every value has exactly one accepted spelling).
    public static func data(base64URL text: String) -> Data? {
        let input = text.utf8
        let length = input.count
        if length % 4 == 1 {
            return nil
        }

        var out = [UInt8]()
        out.reserveCapacity(length / 4 * 3 + 2)
        var acc: UInt32 = 0
        var bits = 0
        for c in input {
            let value: UInt32
            switch c {
            case UInt8(ascii: "A")...UInt8(ascii: "Z"): value = UInt32(c - UInt8(ascii: "A"))
            case UInt8(ascii: "a")...UInt8(ascii: "z"): value = UInt32(c - UInt8(ascii: "a")) + 26
            case UInt8(ascii: "0")...UInt8(ascii: "9"): value = UInt32(c - UInt8(ascii: "0")) + 52
            case UInt8(ascii: "-"): value = 62
            case UInt8(ascii: "_"): value = 63
            default: return nil
            }
            acc = (acc << 6) | value
            bits += 6
            if bits >= 8 {
                bits -= 8
                out.append(UInt8(truncatingIfNeeded: acc >> UInt32(bits)))
            }
            acc &= (1 << UInt32(bits)) - 1
        }

        // Whatever is left over (2 or 4 bits) is filler and must be zero.
        if acc != 0 {
            return nil
        }
        return Data(out)
    }

    // MARK: ids

    /// A new random 16-byte id.
    public static func newId() -> Data {
        Data(Sodium.randomBytes(count: idLength))
    }

    /// Formats a 16-byte id as 32 lowercase hex characters.
    public static func hexString(id: Data) throws(CryptoInputError) -> String {
        guard id.count == idLength else {
            throw .wrongLength(.id, expected: idLength)
        }
        return hex(id)
    }

    /// Parses exactly 32 lowercase hex characters into a 16-byte id; nil otherwise (uppercase
    /// is rejected).
    public static func id(hex text: String) -> Data? {
        let input = Array(text.utf8)
        guard input.count == idHexLength else {
            return nil
        }
        var out = [UInt8]()
        out.reserveCapacity(idLength)
        for i in stride(from: 0, to: idHexLength, by: 2) {
            guard let high = nibble(input[i]), let low = nibble(input[i + 1]) else {
                return nil
            }
            out.append(high << 4 | low)
        }
        return Data(out)
    }

    static func hex(_ bytes: some Sequence<UInt8>) -> String {
        var out = [UInt8]()
        for byte in bytes {
            out.append(hexDigits[Int(byte >> 4)])
            out.append(hexDigits[Int(byte & 15)])
        }
        return String(decoding: out, as: UTF8.self)
    }

    private static func nibble(_ c: UInt8) -> UInt8? {
        switch c {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): return c - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): return c - UInt8(ascii: "a") + 10
        default: return nil
        }
    }
}

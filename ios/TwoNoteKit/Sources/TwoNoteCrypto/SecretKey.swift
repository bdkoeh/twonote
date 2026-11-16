import Foundation

/// Thrown when text is not a Secret Key. Deliberately carries nothing: the input is a secret
/// (or nearly one) and must not travel in an error.
public struct SecretKeyFormatError: Error, Equatable, Sendable {
    public init() {}
}

/// The 128-bit Secret Key (PROTOCOL.md 1.1): the second secret that never leaves the user's
/// devices. Display form `T2-XXXXXX-XXXXXX-XXXXXX-XXXXXXXX` (Crockford base32).
public struct SecretKey: Sendable, Equatable {
    /// Length of the raw key in bytes.
    public static let length = 16

    private static let encodedLength = 26
    private static let prefixLength = 2
    private static let maxInputLength = 256
    private static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ".utf8)

    /// The 16 raw bytes.
    public let bytes: SecretBytes

    private init(unchecked bytes: SecretBytes) {
        self.bytes = bytes
    }

    /// Generates a new random Secret Key.
    public static func generate() -> SecretKey {
        SecretKey(unchecked: .random(count: length))
    }

    /// Wraps a copy of 16 raw bytes.
    public init(bytes: some ContiguousBytes) throws(CryptoInputError) {
        let copy = SecretBytes(copying: bytes)
        guard copy.count == Self.length else {
            throw .wrongLength(.secretKey, expected: Self.length)
        }
        self.bytes = copy
    }

    /// Parses the display form; see ``parse(_:)`` for what is accepted.
    public init(parsing text: String) throws(SecretKeyFormatError) {
        guard let key = Self.parse(text) else {
            throw SecretKeyFormatError()
        }
        self = key
    }

    /// Parses the display form tolerantly: case, hyphens and whitespace are ignored, and `O`
    /// reads as `0`, `I` and `L` as `1`. The `T2` prefix may be omitted. Anything else (wrong
    /// length, other characters such as `U`, or stray bits in the final character) gives nil.
    public static func parse(_ text: String) -> SecretKey? {
        // The longest sensible input is far below this; refuse anything silly up front.
        if text.utf16.count > maxInputLength {
            return nil
        }

        var symbols = [UInt8]()
        symbols.reserveCapacity(prefixLength + encodedLength)
        defer { Sodium.zero(&symbols) }
        for scalar in text.unicodeScalars {
            if scalar == "-" || isWhitespace(scalar) {
                continue
            }
            // Nothing outside ASCII is ever valid; 0xFF stands in for it and is rejected below.
            symbols.append(scalar.isASCII ? UInt8(scalar.value) : 0xFF)
        }

        var body = symbols[...]
        if body.count == prefixLength + encodedLength,
           body[0] == UInt8(ascii: "T") || body[0] == UInt8(ascii: "t"),
           body[1] == UInt8(ascii: "2") {
            body = body.dropFirst(prefixLength)
        }
        guard body.count == encodedLength else {
            return nil
        }

        // 26 symbols carry 130 bits: the 128 key bits, most significant first, then two zero bits.
        var valid = true
        let raw = SecretBytes.make(count: length) { out in
            var acc: UInt64 = 0
            var bits = 0
            var written = 0
            for c in body {
                guard let value = symbolValue(c) else {
                    valid = false
                    return
                }
                acc = (acc << 5) | UInt64(value)
                bits += 5
                if bits >= 8, written < length {
                    bits -= 8
                    out[written] = UInt8(truncatingIfNeeded: acc >> UInt64(bits))
                    written += 1
                }
            }
            valid = written == length && bits == 2 && acc & 0b11 == 0
        }
        return valid ? SecretKey(unchecked: raw) : nil
    }

    /// The display form `T2-XXXXXX-XXXXXX-XXXXXX-XXXXXXXX`. This is the secret itself: show it,
    /// never log it.
    public func formatted() -> String {
        var encoded = [UInt8]()
        encoded.reserveCapacity(Self.encodedLength + 5)
        defer { Sodium.zero(&encoded) }
        encoded.append(contentsOf: "T2".utf8)

        var produced = 0
        func emit(_ value: UInt64) {
            // Groups of 6, 6, 6 and 8 symbols, each introduced by a hyphen.
            if produced == 0 || produced == 6 || produced == 12 || produced == 18 {
                encoded.append(UInt8(ascii: "-"))
            }
            encoded.append(Self.alphabet[Int(value & 31)])
            produced += 1
        }

        bytes.withUnsafeBytes { source in
            var acc: UInt64 = 0
            var bits = 0
            for byte in source {
                acc = (acc << 8) | UInt64(byte)
                bits += 8
                while bits >= 5 {
                    bits -= 5
                    emit(acc >> UInt64(bits))
                }
                acc &= (1 << UInt64(bits)) - 1
            }
            // 128 bits leave three bits over; two zero bits fill the last symbol.
            emit(acc << UInt64(5 - bits))
        }
        return String(decoding: encoded, as: UTF8.self)
    }

    private static func symbolValue(_ symbol: UInt8) -> UInt8? {
        var c = symbol
        if c >= UInt8(ascii: "a"), c <= UInt8(ascii: "z") {
            c -= 32
        }
        switch c {
        case UInt8(ascii: "O"): return 0
        case UInt8(ascii: "I"), UInt8(ascii: "L"): return 1
        case UInt8(ascii: "0")...UInt8(ascii: "9"): return c - UInt8(ascii: "0")
        case UInt8(ascii: "A")...UInt8(ascii: "Z"):
            return alphabet.firstIndex(of: c).map { UInt8($0) } // nil for U
        default: return nil
        }
    }

    /// The characters .NET's `char.IsWhiteSpace` accepts, so both clients ignore the same set:
    /// Unicode White_Space plus the four ASCII separators U+001C to U+001F.
    private static func isWhitespace(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x09...0x0D, 0x1C...0x1F, 0x20, 0x85, 0xA0, 0x1680, 0x2000...0x200A,
             0x2028, 0x2029, 0x202F, 0x205F, 0x3000:
            return true
        default:
            return false
        }
    }
}

extension SecretKey: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    /// A placeholder; use ``formatted()`` for the display form.
    public var description: String { "SecretKey(redacted)" }

    public var debugDescription: String { description }

    public var customMirror: Mirror { Mirror(self, children: [], displayStyle: .struct) }
}

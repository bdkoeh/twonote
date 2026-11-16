/// Fractional index strings for the `order` field of PROTOCOL.md 5.1.
/// A key is one or more characters of `0-9 A-Z a-z` (which is also their byte order) that does
/// not end in `0`; read it as the digits of a base-62 fraction between 0 and 1. Keys are compared
/// as plain byte strings, so any client can sort them without this code. Between any two
/// different keys there is always another one.
public enum FractionalIndex {
    private static let digits = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz".utf8)
    private static let base = 62

    /// The key given to the first item of an empty list.
    public static let first = "V"

    /// True when `key` is a well-formed key.
    public static func isValid(_ key: String) -> Bool {
        let bytes = Array(key.utf8)
        guard let last = bytes.last, last != UInt8(ascii: "0") else { return false }
        return bytes.allSatisfy { digit($0) >= 0 }
    }

    /// Orders two strings the way every client must: by UTF-16 code unit, which for valid keys is byte order.
    public static func precedes(_ a: String, _ b: String) -> Bool {
        a.utf16.lexicographicallyPrecedes(b.utf16)
    }

    /// Returns a key that sorts strictly between `before` and `after`; nil means "no neighbour on
    /// that side". Returns nil when a key is malformed or `before` does not sort before `after`.
    public static func between(_ before: String?, _ after: String?) -> String? {
        if let before, !isValid(before) { return nil }
        if let after, !isValid(after) { return nil }
        switch (before, after) {
        case (nil, nil):
            return first
        case (nil, let after?):
            return string(self.before(Array(after.utf8)))
        case (let before?, nil):
            return string(self.after(Array(before.utf8)))
        case (let before?, let after?):
            guard precedes(before, after) else { return nil }
            return string(midpoint(Array(before.utf8), Array(after.utf8)))
        }
    }

    /// A key just above `key`. Appending to a list grows the key by one character roughly every
    /// 60 items instead of every few, which plain bisection would do.
    private static func after(_ key: [UInt8]) -> [UInt8] {
        for (i, c) in key.enumerated() {
            let d = digit(c)
            if d < base - 1 {
                return Array(key[..<i]) + [digits[d + 1]]
            }
        }
        return key + [UInt8(ascii: "1")] // all 'z': go one digit deeper
    }

    /// A key just below `key`; the mirror image of `after`.
    private static func before(_ key: [UInt8]) -> [UInt8] {
        for (i, c) in key.enumerated() {
            let d = digit(c)
            if d >= 2 {
                return Array(key[..<i]) + [digits[d - 1]]
            }
        }
        // Only 0s and 1s (and it cannot end in 0, so there is a 1): replace the first 1 by "0y".
        let one = key.firstIndex(of: UInt8(ascii: "1"))!
        return Array(key[..<one]) + Array("0y".utf8)
    }

    /// The shortest key between two keys, biased to the middle.
    private static func midpoint(_ lower: [UInt8], _ upper: [UInt8]) -> [UInt8] {
        var a = lower[...]
        var b: ArraySlice<UInt8>? = upper[...]
        var result: [UInt8] = []
        while true {
            if let upper = b {
                // Copy the common prefix (a is padded with zeros).
                var n = 0
                while n < upper.count, (n < a.count ? a[a.startIndex + n] : UInt8(ascii: "0")) == upper[upper.startIndex + n] {
                    n += 1
                }
                if n > 0 {
                    result.append(contentsOf: upper.prefix(n))
                    a = a.dropFirst(n)
                    b = upper.dropFirst(n)
                }
            }

            let digitA = a.first.map(digit) ?? 0
            let digitB = b.map { digit($0.first!) } ?? base
            if digitB - digitA > 1 {
                result.append(digits[(digitA + digitB + 1) / 2])
                return result
            }

            // The first digits are adjacent.
            if let upper = b, upper.count > 1 {
                result.append(upper.first!)
                return result
            }

            // Keep a's first digit and find something above the rest of a.
            result.append(digits[digitA])
            a = a.dropFirst()
            b = nil
        }
    }

    private static func digit(_ c: UInt8) -> Int {
        switch c {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): Int(c) - 48
        case UInt8(ascii: "A")...UInt8(ascii: "Z"): Int(c) - 65 + 10
        case UInt8(ascii: "a")...UInt8(ascii: "z"): Int(c) - 97 + 36
        default: -1
        }
    }

    private static func string(_ bytes: [UInt8]) -> String {
        String(decoding: bytes, as: UTF8.self)
    }
}

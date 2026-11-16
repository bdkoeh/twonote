import Clibsodium
import Foundation

/// Owns a piece of key material. The bytes live in memory this object allocated itself (so
/// Swift never copies them behind its back) and are zeroed when the last reference goes away.
/// Printing, interpolating or reflecting a value never reveals the contents.
///
/// Immutable once created, hence safe to share between tasks.
public final class SecretBytes: @unchecked Sendable {
    /// Number of bytes held.
    public let count: Int

    private let base: UnsafeMutableRawPointer

    private init(zeroedCount count: Int) {
        precondition(count >= 0, "count must not be negative")
        Sodium.ensureReady()
        self.count = count
        base = UnsafeMutableRawPointer.allocate(byteCount: max(count, 1), alignment: 16)
        sodium_memzero(base, max(count, 1))
    }

    deinit {
        sodium_memzero(base, max(count, 1))
        base.deallocate()
    }

    /// Allocates zeroed storage and lets `fill` write the secret straight into it. If `fill`
    /// throws, whatever it wrote is zeroed.
    static func make(
        count: Int,
        fill: (UnsafeMutableRawBufferPointer) throws -> Void
    ) rethrows -> SecretBytes {
        let secret = SecretBytes(zeroedCount: count)
        // The base address is never nil, even when count is 0.
        try fill(UnsafeMutableRawBufferPointer(start: secret.base, count: count))
        return secret
    }

    /// Copies `bytes` (`Data`, `[UInt8]`, …). The caller stays responsible for its own copy.
    public convenience init(copying bytes: some ContiguousBytes) {
        let length = bytes.withUnsafeBytes { $0.count }
        self.init(zeroedCount: length)
        bytes.withUnsafeBytes { source in
            UnsafeMutableRawBufferPointer(start: base, count: length).copyMemory(from: source)
        }
    }

    /// `count` cryptographically random bytes.
    public static func random(count: Int) -> SecretBytes {
        precondition(count > 0, "count must be positive")
        return make(count: count) { randombytes_buf($0.baseAddress!, $0.count) }
    }

    /// Gives read access to the key material. The pointer must not escape `body`.
    public func withUnsafeBytes<R>(_ body: (UnsafeRawBufferPointer) throws -> R) rethrows -> R {
        try body(UnsafeRawBufferPointer(start: base, count: count))
    }

    /// Read access as a byte pointer for libsodium. Never nil, even for an empty value.
    func withBytePointer<R>(_ body: (UnsafePointer<UInt8>) throws -> R) rethrows -> R {
        try body(UnsafePointer(base.assumingMemoryBound(to: UInt8.self)))
    }

    /// Copies the key material out, for example to store it in the Keychain. The copy is
    /// ordinary memory that nothing zeroes: keep it short-lived.
    public func copyToData() -> Data {
        Data(bytes: base, count: count)
    }
}

extension SecretBytes: Equatable {
    /// Constant-time comparison of the contents.
    public static func == (lhs: SecretBytes, rhs: SecretBytes) -> Bool {
        lhs.count == rhs.count && sodium_memcmp(lhs.base, rhs.base, lhs.count) == 0
    }
}

extension SecretBytes: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    /// A placeholder; never the contents.
    public var description: String { "SecretBytes(\(count) bytes, redacted)" }

    public var debugDescription: String { description }

    public var customMirror: Mirror { Mirror(self, children: [], displayStyle: .class) }
}

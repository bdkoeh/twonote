import Clibsodium
import Foundation

/// libsodium start-up and the few helpers every file needs.
enum Sodium {
    /// `sodium_init` is safe to call from several threads and more than once; a Swift global
    /// runs it exactly once anyway.
    private static let isReady: Bool = sodium_init() >= 0

    static func ensureReady() {
        precondition(isReady, "libsodium failed to initialise")
    }

    static func randomBytes(count: Int) -> [UInt8] {
        ensureReady()
        var bytes = [UInt8](repeating: 0, count: count)
        bytes.withUnsafeMutableBytes { buffer in
            if let base = buffer.baseAddress {
                randombytes_buf(base, buffer.count)
            }
        }
        return bytes
    }

    /// Overwrites an array's storage. Best effort: Swift may have made other copies.
    static func zero(_ bytes: inout [UInt8]) {
        bytes.withUnsafeMutableBytes { buffer in
            if let base = buffer.baseAddress {
                sodium_memzero(base, buffer.count)
            }
        }
    }
}

/// A caller mistake or an input this library refuses to work with. Never carries secret values.
public enum CryptoInputError: Error, Equatable, Sendable {
    /// A fixed-length value has the wrong number of bytes.
    case wrongLength(CryptoField, expected: Int)
    /// `kdfParams` is outside what PROTOCOL.md 1.2 allows a client to accept.
    case unsupportedKdfParams
    /// The password is not valid Unicode (it contains an unpaired surrogate).
    case invalidPassword
    /// Argon2id could not run, in practice because the memory could not be allocated.
    case keyDerivationFailed
}

/// Which value a ``CryptoInputError/wrongLength(_:expected:)`` is about.
public enum CryptoField: String, Sendable {
    case key
    case id
    case nonce
    case kdfSalt
    case secretKey
    case privateKey
    case wrappedKey
}

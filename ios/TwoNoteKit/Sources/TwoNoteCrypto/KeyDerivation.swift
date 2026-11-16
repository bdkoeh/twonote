import Clibsodium
import CryptoKit
import Foundation

/// The `kdfParams` object of PROTOCOL.md 1.2, e.g.
/// `{ "alg": "argon2id13", "ops": 3, "memKiB": 65536 }`. Codable with those names.
public struct KdfParams: Codable, Equatable, Sendable {
    /// The only algorithm in protocol v1: Argon2id version 1.3.
    public static let argon2id13 = "argon2id13"

    /// Lowest and highest accepted pass count.
    public static let opsRange = 1...16

    /// Lowest (8 MiB) and highest (1 GiB) accepted memory size, so a hostile server cannot
    /// make a client allocate without bound.
    public static let memKiBRange = 8 * 1024...1024 * 1024

    /// The parameters new accounts use: 3 passes over 64 MiB.
    public static let `default` = KdfParams(alg: argon2id13, ops: 3, memKiB: 65536)

    public var alg: String
    public var ops: Int
    public var memKiB: Int

    public init(alg: String, ops: Int, memKiB: Int) {
        self.alg = alg
        self.ops = ops
        self.memKiB = memKiB
    }

    /// True when this library can and will run a derivation with these parameters.
    public var isSupported: Bool {
        alg == Self.argon2id13 && Self.opsRange.contains(ops) && Self.memKiBRange.contains(memKiB)
    }
}

/// What ``KeyDerivation`` produces.
public struct DerivedKeys: Sendable {
    /// 32-byte key that wraps the vaultKey.
    public let unlockKey: SecretBytes

    /// 64-byte Ed25519 private key (libsodium layout: seed followed by public key). Pass to
    /// ``LoginSignature/sign(authPrivateKey:nonce:)``.
    public let authPrivateKey: SecretBytes

    /// 32-byte Ed25519 public key; this is what the server stores. Not secret.
    public let authPublicKey: Data
}

extension DerivedKeys: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String { "DerivedKeys(redacted)" }

    public var debugDescription: String { description }

    public var customMirror: Mirror { Mirror(self, children: [], displayStyle: .struct) }
}

/// Every value of one run of 1.2, for the test vectors only.
struct DerivationTrace {
    let kPw: SecretBytes
    let kSk: SecretBytes
    let root: SecretBytes
    let unlockKey: SecretBytes
    let authSeed: SecretBytes
}

/// Two-secret key derivation (PROTOCOL.md 1.2).
public enum KeyDerivation {
    /// Length of kdfSalt in bytes.
    public static let saltLength = 16

    /// Length of unlockKey, vaultKey and notebookKey in bytes.
    public static let keyLength = 32

    /// Length of the Ed25519 public key in bytes.
    public static let authPublicKeyLength = 32

    /// Length of the Ed25519 private key in bytes (seed followed by public key).
    public static let authPrivateKeyLength = 64

    /// A fresh random kdfSalt.
    public static func newSalt() -> Data {
        Data(Sodium.randomBytes(count: saltLength))
    }

    /// Derives unlockKey and the Ed25519 login key pair from the password and the Secret Key.
    /// Takes a noticeable fraction of a second and 64 MiB with the default parameters; call it
    /// off the main actor.
    ///
    /// A Swift `String` cannot hold an unpaired surrogate: by the time ill-formed UTF-16 (from
    /// an `NSString`, a text field, the pasteboard) has become a `String`, each lone surrogate
    /// has been replaced by U+FFFD. U+FFFD is a legitimate character and is accepted, so this
    /// entry point cannot reject such input. Code that still holds the UTF-16 code units
    /// should call ``derive(passwordUTF16:secretKey:accountId:kdfSalt:kdfParams:)``, which can.
    public static func derive(
        password: String,
        secretKey: SecretKey,
        accountId: Data,
        kdfSalt: Data,
        kdfParams: KdfParams
    ) throws(CryptoInputError) -> DerivedKeys {
        try check(accountId: accountId, kdfSalt: kdfSalt, kdfParams: kdfParams)
        let passwordBytes = try normalisePassword(password)
        return try keys(from: trace(passwordBytes, secretKey, accountId, kdfSalt, kdfParams))
    }

    /// As ``derive(password:secretKey:accountId:kdfSalt:kdfParams:)`` for a password held as
    /// UTF-16 code units. An unpaired surrogate is rejected with
    /// ``CryptoInputError/invalidPassword``.
    public static func derive(
        passwordUTF16: some Sequence<UInt16>,
        secretKey: SecretKey,
        accountId: Data,
        kdfSalt: Data,
        kdfParams: KdfParams
    ) throws(CryptoInputError) -> DerivedKeys {
        try check(accountId: accountId, kdfSalt: kdfSalt, kdfParams: kdfParams)
        let passwordBytes = try normalisePassword(utf16: passwordUTF16)
        return try keys(from: trace(passwordBytes, secretKey, accountId, kdfSalt, kdfParams))
    }

    // MARK: password

    /// UTF8(NFKC(password)).
    static func normalisePassword(_ password: String) throws(CryptoInputError) -> SecretBytes {
        // Cannot fail for a native String (see `derive(password:...)`); kept in case a bridged
        // string ever exposes a lone surrogate through its UTF-16 view.
        try checkSurrogates(password.utf16)
        let normalised = password.precomposedStringWithCompatibilityMapping
        let utf8 = normalised.utf8
        return SecretBytes.make(count: utf8.count) { $0.copyBytes(from: utf8) }
    }

    /// UTF8(NFKC(password)) for UTF-16 input.
    static func normalisePassword(utf16: some Sequence<UInt16>) throws(CryptoInputError) -> SecretBytes {
        var units = Array(utf16)
        defer {
            units.withUnsafeMutableBytes { buffer in
                if let base = buffer.baseAddress {
                    sodium_memzero(base, buffer.count)
                }
            }
        }
        try checkSurrogates(units)
        return try normalisePassword(String(decoding: units, as: UTF16.self))
    }

    private static func checkSurrogates(_ units: some Sequence<UInt16>) throws(CryptoInputError) {
        var expectLow = false
        for unit in units {
            let isHigh = (0xD800...0xDBFF).contains(unit)
            let isLow = (0xDC00...0xDFFF).contains(unit)
            if expectLow != isLow {
                throw .invalidPassword
            }
            expectLow = isHigh
        }
        if expectLow {
            throw .invalidPassword
        }
    }

    // MARK: derivation

    private static func check(accountId: Data, kdfSalt: Data, kdfParams: KdfParams) throws(CryptoInputError) {
        guard accountId.count == WireEncoding.idLength else {
            throw .wrongLength(.id, expected: WireEncoding.idLength)
        }
        guard kdfSalt.count == saltLength else {
            throw .wrongLength(.kdfSalt, expected: saltLength)
        }
        guard kdfParams.isSupported else {
            throw .unsupportedKdfParams
        }
    }

    /// Runs 1.2 on an already normalised password and keeps every intermediate value.
    static func trace(
        _ passwordBytes: SecretBytes,
        _ secretKey: SecretKey,
        _ accountId: Data,
        _ kdfSalt: Data,
        _ kdfParams: KdfParams
    ) throws(CryptoInputError) -> DerivationTrace {
        try check(accountId: accountId, kdfSalt: kdfSalt, kdfParams: kdfParams)
        Sodium.ensureReady()

        // k_pw = Argon2id(UTF8(NFKC(password)), kdfSalt, ops, memKiB * 1024, 32)
        let salt = [UInt8](kdfSalt)
        var status: Int32 = -1
        let kPw = SecretBytes.make(count: keyLength) { out in
            passwordBytes.withUnsafeBytes { pw in
                status = crypto_pwhash(
                    out.baseAddress!.assumingMemoryBound(to: UInt8.self),
                    UInt64(keyLength),
                    pw.baseAddress!.assumingMemoryBound(to: CChar.self),
                    UInt64(pw.count),
                    salt,
                    UInt64(kdfParams.ops),
                    kdfParams.memKiB * 1024,
                    crypto_pwhash_alg_argon2id13())
            }
        }
        guard status == 0 else {
            throw .keyDerivationFailed
        }

        // k_sk = HKDF-SHA256(ikm = secretKey, salt = accountId, info = "twonote/v1/2skd")
        let kSk = hkdf(secretKey.bytes, salt: accountId, info: "twonote/v1/2skd")

        // root = k_pw XOR k_sk
        let root = SecretBytes.make(count: keyLength) { out in
            kPw.withUnsafeBytes { a in
                kSk.withUnsafeBytes { b in
                    for i in 0..<keyLength {
                        out[i] = a[i] ^ b[i]
                    }
                }
            }
        }

        // An empty salt is the RFC 5869 default of HashLen zero bytes.
        return DerivationTrace(
            kPw: kPw,
            kSk: kSk,
            root: root,
            unlockKey: hkdf(root, salt: Data(), info: "twonote/v1/unlock"),
            authSeed: hkdf(root, salt: Data(), info: "twonote/v1/auth"))
    }

    private static func keys(from trace: DerivationTrace) -> DerivedKeys {
        var publicKey = [UInt8](repeating: 0, count: authPublicKeyLength)
        let privateKey = SecretBytes.make(count: authPrivateKeyLength) { sk in
            trace.authSeed.withBytePointer { seed in
                _ = crypto_sign_seed_keypair(&publicKey, sk.baseAddress!.assumingMemoryBound(to: UInt8.self), seed)
            }
        }
        return DerivedKeys(unlockKey: trace.unlockKey, authPrivateKey: privateKey, authPublicKey: Data(publicKey))
    }

    private static func hkdf(_ ikm: SecretBytes, salt: Data, info: String) -> SecretBytes {
        // SymmetricKey keeps its bytes in storage CryptoKit zeroes on release.
        let input = ikm.withUnsafeBytes { SymmetricKey(data: $0) }
        let output = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: input,
            salt: salt,
            info: Data(info.utf8),
            outputByteCount: keyLength)
        return output.withUnsafeBytes { SecretBytes(copying: $0) }
    }
}

import Clibsodium
import Foundation

/// What a sealed blob protects; the raw value is the `kind` string in its additional data.
public enum BlobKind: String, CaseIterable, Sendable {
    /// vaultKey under unlockKey, id = accountId.
    case vault
    /// notebookKey under vaultKey, id = notebookId.
    case notebookKey = "nbkey"
    /// One Yjs update under notebookKey, id = docId.
    case update
    /// A full-state Yjs update under notebookKey, id = docId.
    case snapshot

    /// True for the kinds whose plaintext is a 32-byte key.
    var holdsKey: Bool { self == .vault || self == .notebookKey }
}

/// Why a sealed blob could not be opened. Such a blob is discarded and reported, never applied.
public enum SealedBlobError: Error, Equatable, Sendable {
    /// Shorter than version byte + nonce + authentication tag.
    case truncated
    /// The first byte is not 0x01.
    case unsupportedVersion
    /// Wrong key, wrong kind or id, the blob was modified, or a `vault`/`nbkey` blob does not
    /// hold exactly 32 bytes.
    case authenticationFailed
}

/// The one encrypted format (PROTOCOL.md 1.3):
/// `0x01 || nonce(24) || XChaCha20-Poly1305(key, nonce, plaintext, aad)` with
/// `aad = UTF8("twonote/v1|" + kind + "|" + id)`, id as 32 lowercase hex characters.
public enum SealedBlob {
    /// The version byte every v1 blob starts with.
    public static let version: UInt8 = 0x01

    /// Key length in bytes.
    public static let keyLength = 32

    /// Nonce length in bytes.
    public static let nonceLength = 24

    /// Poly1305 tag length in bytes.
    public static let tagLength = 16

    /// Bytes a blob adds to its plaintext (version + nonce + tag = 41).
    public static let overhead = 1 + nonceLength + tagLength

    /// The additional data for a kind and 16-byte id, as text (it is pure ASCII).
    public static func additionalData(kind: BlobKind, id: Data) throws(CryptoInputError) -> String {
        let hex = try WireEncoding.hexString(id: id)
        return "twonote/v1|\(kind.rawValue)|\(hex)"
    }

    /// Encrypts `plaintext` under a fresh random nonce.
    ///
    /// Throws ``CryptoInputError`` when the key is not 32 bytes, the id is not 16 bytes, or a
    /// `vault`/`nbkey` plaintext is not 32 bytes.
    public static func seal(
        key: SecretBytes, kind: BlobKind, id: Data, plaintext: Data
    ) throws(CryptoInputError) -> Data {
        if kind.holdsKey, plaintext.count != keyLength {
            throw .wrongLength(.wrappedKey, expected: keyLength)
        }
        let aad = try additionalDataBytes(key: key, kind: kind, id: id)
        let nonce = Sodium.randomBytes(count: nonceLength)
        return plaintext.withUnsafeBytes { encrypt(key: key, aad: aad, plaintext: $0, nonce: nonce) }
    }

    /// Seals a 32-byte key without it ever leaving ``SecretBytes``.
    static func sealKey(
        _ inner: SecretBytes, under key: SecretBytes, kind: BlobKind, id: Data
    ) throws(CryptoInputError) -> Data {
        guard inner.count == keyLength else {
            throw .wrongLength(.wrappedKey, expected: keyLength)
        }
        let aad = try additionalDataBytes(key: key, kind: kind, id: id)
        let nonce = Sodium.randomBytes(count: nonceLength)
        return inner.withUnsafeBytes { encrypt(key: key, aad: aad, plaintext: $0, nonce: nonce) }
    }

    /// Seals with a caller-chosen nonce and no check on what a key blob holds. Only for
    /// reproducing the test vectors: a nonce must never repeat under one key.
    static func seal(
        key: SecretBytes, kind: BlobKind, id: Data, plaintext: Data, nonce: Data
    ) throws(CryptoInputError) -> Data {
        guard nonce.count == nonceLength else {
            throw .wrongLength(.nonce, expected: nonceLength)
        }
        let aad = try additionalDataBytes(key: key, kind: kind, id: id)
        let nonceBytes = [UInt8](nonce)
        return plaintext.withUnsafeBytes { encrypt(key: key, aad: aad, plaintext: $0, nonce: nonceBytes) }
    }

    /// Checks the key and id and returns the additional data as bytes.
    private static func additionalDataBytes(
        key: SecretBytes, kind: BlobKind, id: Data
    ) throws(CryptoInputError) -> [UInt8] {
        guard key.count == keyLength else {
            throw .wrongLength(.key, expected: keyLength)
        }
        return Array(try additionalData(kind: kind, id: id).utf8)
    }

    /// The format itself. Key (32 bytes) and nonce (24 bytes) lengths are the caller's job.
    private static func encrypt(
        key: SecretBytes, aad: [UInt8], plaintext: UnsafeRawBufferPointer, nonce: [UInt8]
    ) -> Data {
        Sodium.ensureReady()
        var blob = [UInt8](repeating: 0, count: overhead + plaintext.count)
        blob[0] = version
        blob.replaceSubrange(1..<1 + nonceLength, with: nonce)
        // An empty plaintext may come without an address; libsodium wants one regardless.
        var placeholder: UInt8 = 0
        blob.withUnsafeMutableBufferPointer { out in
            key.withBytePointer { k in
                withUnsafePointer(to: &placeholder) { spare in
                    var written: UInt64 = 0
                    _ = crypto_aead_xchacha20poly1305_ietf_encrypt(
                        out.baseAddress! + 1 + nonceLength,
                        &written,
                        plaintext.baseAddress?.assumingMemoryBound(to: UInt8.self) ?? spare,
                        UInt64(plaintext.count),
                        aad,
                        UInt64(aad.count),
                        nil,
                        nonce,
                        k)
                }
            }
        }
        return Data(blob)
    }

    /// Decrypts a blob, returning the plaintext.
    ///
    /// Throws ``SealedBlobError`` when the blob is truncated, has the wrong version, does not
    /// authenticate under this key, kind and id, or is a `vault`/`nbkey` blob that does not
    /// hold 32 bytes. Throws ``CryptoInputError`` when the key is not 32 bytes or the id is
    /// not 16 bytes (a caller bug, not a bad blob). `try?` covers both.
    public static func open(key: SecretBytes, kind: BlobKind, id: Data, blob: Data) throws -> Data {
        var plaintext = try openBytes(key: key, kind: kind, id: id, blob: blob)
        defer { Sodium.zero(&plaintext) }
        return Data(plaintext)
    }

    /// As ``open(key:kind:id:blob:)`` for a blob that holds a key: the plaintext goes straight
    /// into a ``SecretBytes``.
    static func openKey(key: SecretBytes, kind: BlobKind, id: Data, blob: Data) throws -> SecretBytes {
        var plaintext = try openBytes(key: key, kind: kind, id: id, blob: blob)
        defer { Sodium.zero(&plaintext) }
        guard plaintext.count == keyLength else {
            throw SealedBlobError.authenticationFailed
        }
        return SecretBytes(copying: plaintext)
    }

    private static func openBytes(key: SecretBytes, kind: BlobKind, id: Data, blob: Data) throws -> [UInt8] {
        let aad = try additionalDataBytes(key: key, kind: kind, id: id)
        var output = try decrypt(key: key, aad: aad, blob: blob)

        // PROTOCOL.md 1.3: a key blob that does not hold exactly 32 bytes is a failed open.
        if kind.holdsKey, output.count != keyLength {
            Sodium.zero(&output)
            throw SealedBlobError.authenticationFailed
        }
        return output
    }

    /// The format itself, the other way. The key length (32 bytes) is the caller's job.
    private static func decrypt(key: SecretBytes, aad: [UInt8], blob: Data) throws -> [UInt8] {
        Sodium.ensureReady()

        guard blob.count >= overhead else {
            throw SealedBlobError.truncated
        }
        let bytes = [UInt8](blob)
        guard bytes[0] == version else {
            throw SealedBlobError.unsupportedVersion
        }

        let length = bytes.count - overhead
        // One spare byte so there is always an address to decrypt into.
        var output = [UInt8](repeating: 0, count: length + 1)
        let status = output.withUnsafeMutableBufferPointer { out in
            bytes.withUnsafeBufferPointer { input in
                key.withBytePointer { k in
                    var written: UInt64 = 0
                    return crypto_aead_xchacha20poly1305_ietf_decrypt(
                        out.baseAddress!,
                        &written,
                        nil,
                        input.baseAddress! + 1 + nonceLength,
                        UInt64(input.count - 1 - nonceLength),
                        aad,
                        UInt64(aad.count),
                        input.baseAddress! + 1,
                        k)
                }
            }
        }
        guard status == 0 else {
            Sodium.zero(&output)
            throw SealedBlobError.authenticationFailed
        }
        output.removeLast()
        return output
    }
}

// MARK: Secrets that stay on one device

extension SealedBlob {
    /// The additional data of a device-local blob. The prefix differs from the protocol's
    /// (`twonote/v1|`), so such a blob can never be taken for a blob of PROTOCOL.md, or the
    /// other way round, even though both are sealed under keys of the same hierarchy.
    static func localAdditionalData(label: String) -> [UInt8] {
        Array("twonote/local/v1|\(label)".utf8)
    }

    /// Seals a secret that never leaves this device (it is not part of the protocol and is
    /// never sent anywhere) under a key of the hierarchy, in the format of every other blob.
    /// `label` says what the secret is; it must be given again to open the blob.
    public static func sealLocal(key: SecretBytes, label: String, secret: SecretBytes) throws(CryptoInputError) -> Data {
        guard key.count == keyLength else {
            throw .wrongLength(.key, expected: keyLength)
        }
        let nonce = Sodium.randomBytes(count: nonceLength)
        return secret.withUnsafeBytes { encrypt(key: key, aad: localAdditionalData(label: label), plaintext: $0, nonce: nonce) }
    }

    /// Opens a blob made by ``sealLocal(key:label:secret:)``.
    ///
    /// Throws ``SealedBlobError`` when the blob does not open under this key and label, and
    /// ``CryptoInputError`` when the key is not 32 bytes.
    public static func openLocal(key: SecretBytes, label: String, blob: Data) throws -> SecretBytes {
        guard key.count == keyLength else {
            throw CryptoInputError.wrongLength(.key, expected: keyLength)
        }
        var plaintext = try decrypt(key: key, aad: localAdditionalData(label: label), blob: blob)
        defer { Sodium.zero(&plaintext) }
        return SecretBytes(copying: plaintext)
    }
}

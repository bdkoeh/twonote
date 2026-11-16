import Clibsodium
import Foundation

/// Why a sealed box could not be opened: it was not sealed to this key pair, or it was modified.
public struct SealedBoxError: Error, Equatable, Sendable {
    public init() {}
}

/// Anonymous public-key encryption: libsodium's sealed box (`crypto_box_seal`: an ephemeral
/// X25519 key pair per message, XSalsa20-Poly1305). Anyone who has the public key can seal;
/// only the holder of the private key can open, and the sealer cannot open its own message.
///
/// Not part of PROTOCOL.md and never sent to the server. The iOS app uses it for its share
/// inbox: a part of the app that runs while the notes are locked (the share extension) leaves
/// items that only the unlocked app can read.
public enum SealedBox {
    /// Length of a public key and of a private key in bytes.
    public static let keyLength = 32

    /// Bytes a sealed box adds to its plaintext (ephemeral public key + tag = 48).
    public static let overhead = 48

    /// Generates a key pair.
    public static func generateKeyPair() -> (publicKey: Data, privateKey: SecretBytes) {
        checkSizes()
        var publicKey = [UInt8](repeating: 0, count: keyLength)
        let privateKey = SecretBytes.make(count: keyLength) { secret in
            _ = crypto_box_keypair(&publicKey, secret.baseAddress!.assumingMemoryBound(to: UInt8.self))
        }
        return (Data(publicKey), privateKey)
    }

    /// The public key that belongs to a private key.
    public static func publicKey(for privateKey: SecretBytes) throws(CryptoInputError) -> Data {
        checkSizes()
        guard privateKey.count == keyLength else {
            throw .wrongLength(.privateKey, expected: keyLength)
        }
        var publicKey = [UInt8](repeating: 0, count: keyLength)
        privateKey.withBytePointer { _ = crypto_scalarmult_base(&publicKey, $0) }
        return Data(publicKey)
    }

    /// Seals `plaintext` so that only the holder of the private key of `publicKey` can read it.
    public static func seal(_ plaintext: Data, to publicKey: Data) throws(CryptoInputError) -> Data {
        checkSizes()
        guard publicKey.count == keyLength else {
            throw .wrongLength(.key, expected: keyLength)
        }
        let message = [UInt8](plaintext)
        var sealed = [UInt8](repeating: 0, count: message.count + overhead)
        let status = crypto_box_seal(&sealed, message, UInt64(message.count), [UInt8](publicKey))
        guard status == 0 else {
            throw .wrongLength(.key, expected: keyLength) // the public key is not a usable point
        }
        return Data(sealed)
    }

    /// Opens a sealed box.
    ///
    /// Throws ``SealedBoxError`` when the box was not sealed to this key pair or was modified,
    /// and ``CryptoInputError`` when a key has the wrong length.
    public static func open(_ sealed: Data, publicKey: Data, privateKey: SecretBytes) throws -> Data {
        checkSizes()
        guard publicKey.count == keyLength else {
            throw CryptoInputError.wrongLength(.key, expected: keyLength)
        }
        guard privateKey.count == keyLength else {
            throw CryptoInputError.wrongLength(.privateKey, expected: keyLength)
        }
        guard sealed.count >= overhead else {
            throw SealedBoxError()
        }
        let input = [UInt8](sealed)
        // One spare byte so there is always an address to decrypt into.
        var output = [UInt8](repeating: 0, count: input.count - overhead + 1)
        let status = privateKey.withBytePointer { secret in
            crypto_box_seal_open(&output, input, UInt64(input.count), [UInt8](publicKey), secret)
        }
        guard status == 0 else {
            Sodium.zero(&output)
            throw SealedBoxError()
        }
        output.removeLast()
        defer { Sodium.zero(&output) }
        return Data(output)
    }

    private static func checkSizes() {
        Sodium.ensureReady()
        precondition(
            crypto_box_publickeybytes() == keyLength && crypto_box_secretkeybytes() == keyLength
                && crypto_box_sealbytes() == overhead && crypto_scalarmult_bytes() == keyLength,
            "libsodium's sealed box has unexpected sizes")
    }
}

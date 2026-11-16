import Clibsodium
import Foundation

/// Login signature (PROTOCOL.md 1.4):
/// `Ed25519-Sign(authPrivateKey, UTF8("twonote/v1/login") || nonce)`.
/// The client signs; the server verifies with the stored authPublicKey.
public enum LoginSignature {
    /// Length in bytes of the nonce issued by `auth/start`.
    public static let nonceLength = 32

    /// Length in bytes of an Ed25519 signature.
    public static let signatureLength = 64

    /// Length in bytes of the public key.
    public static let publicKeyLength = 32

    /// Length in bytes of the private key (seed followed by public key).
    public static let privateKeyLength = 64

    private static let context = Array("twonote/v1/login".utf8)

    /// A fresh random login nonce (what a server would issue; here for tests).
    public static func newNonce() -> Data {
        Data(Sodium.randomBytes(count: nonceLength))
    }

    /// The bytes that get signed: the context string followed by the nonce.
    static func message(nonce: Data) -> [UInt8] {
        context + nonce
    }

    /// Signs a login nonce with ``DerivedKeys/authPrivateKey``.
    public static func sign(authPrivateKey: SecretBytes, nonce: Data) throws(CryptoInputError) -> Data {
        guard authPrivateKey.count == privateKeyLength else {
            throw .wrongLength(.privateKey, expected: privateKeyLength)
        }
        guard nonce.count == nonceLength else {
            throw .wrongLength(.nonce, expected: nonceLength)
        }
        Sodium.ensureReady()

        let message = message(nonce: nonce)
        var signature = [UInt8](repeating: 0, count: signatureLength)
        authPrivateKey.withBytePointer { sk in
            _ = crypto_sign_detached(&signature, nil, message, UInt64(message.count), sk)
        }
        return Data(signature)
    }

    /// Verifies a login signature. A wrong length, a malformed public key and a bad signature
    /// all give false.
    public static func verify(authPublicKey: Data, nonce: Data, signature: Data) -> Bool {
        guard authPublicKey.count == publicKeyLength,
              nonce.count == nonceLength,
              signature.count == signatureLength else {
            return false
        }
        Sodium.ensureReady()

        let message = message(nonce: nonce)
        return crypto_sign_verify_detached(
            [UInt8](signature),
            message,
            UInt64(message.count),
            [UInt8](authPublicKey)) == 0
    }
}

import Foundation
@testable import TwoNoteCrypto

/// Decodes lowercase or uppercase hex. Written here, not borrowed from the library, so the
/// tests do not check the library against itself.
func hex(_ text: String) -> Data {
    let digits = Array(text.utf8)
    precondition(digits.count % 2 == 0, "odd hex length")
    func value(_ c: UInt8) -> UInt8 {
        switch c {
        case 48...57: return c - 48
        case 97...102: return c - 87
        case 65...70: return c - 55
        default: preconditionFailure("not a hex digit")
        }
    }
    var out = Data(capacity: digits.count / 2)
    for i in stride(from: 0, to: digits.count, by: 2) {
        out.append(value(digits[i]) << 4 | value(digits[i + 1]))
    }
    return out
}

extension Data {
    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}

extension SecretBytes {
    var hexString: String { copyToData().hexString }
}

func secret(_ text: String) -> SecretBytes { SecretBytes(copying: hex(text)) }

/// docs/test-vectors.json (PROTOCOL.md 1.5), read from the repository next to `ios/`.
struct Vectors: Decodable, Sendable {
    struct SecretKeySection: Decodable, Sendable {
        let bytes: String
        let formatted: String
        let accepted: [String]
        let rejected: [String]
    }

    struct KeyDerivationCase: Decodable, Sendable, CustomStringConvertible {
        let name: String
        let password: String
        let passwordNfkcUtf8: String
        let secretKey: String
        let accountId: String
        let kdfSalt: String
        let kdfParams: KdfParams
        let kPw: String
        let kSk: String
        let root: String
        let unlockKey: String
        let authSeed: String
        let authPublicKey: String

        var description: String { name }
    }

    struct SealedBlobCase: Decodable, Sendable, CustomStringConvertible {
        let name: String
        let kind: String
        let key: String
        let id: String
        let nonce: String
        let plaintext: String
        let aad: String
        let blob: String

        var description: String { name }
    }

    struct LoginSignatureSection: Decodable, Sendable {
        let note: String
        let authSeed: String
        let authPublicKey: String
        let nonce: String
        let message: String
        let signature: String
    }

    struct WireEncodingSection: Decodable, Sendable {
        struct Pair: Decodable, Sendable, CustomStringConvertible {
            let bytes: String
            let text: String

            var description: String { "'\(text)'" }
        }

        let base64Url: [Pair]
        let id: Pair
    }

    let description: String
    let binaryEncoding: String
    let secretKey: SecretKeySection
    let keyDerivation: [KeyDerivationCase]
    let sealedBlob: [SealedBlobCase]
    let loginSignature: LoginSignatureSection
    let wireEncoding: WireEncodingSection

    /// Tests/TwoNoteCryptoTests/Support.swift -> repository root -> docs/test-vectors.json.
    static let url: URL = {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 {
            root.deleteLastPathComponent()
        }
        return root.appendingPathComponent("docs/test-vectors.json")
    }()

    static let shared: Vectors = {
        do {
            return try JSONDecoder().decode(Vectors.self, from: Data(contentsOf: url))
        } catch {
            fatalError("Cannot read \(url.path): \(error)")
        }
    }()

    func keyDerivationCase(_ name: String) -> KeyDerivationCase {
        keyDerivation.first { $0.name == name }!
    }

    func sealedBlobCase(_ name: String) -> SealedBlobCase {
        sealedBlob.first { $0.name == name }!
    }
}

import CryptoKit
import Foundation
import Testing
@testable import TwoNoteCrypto

/// Asserts the implementation against docs/test-vectors.json (PROTOCOL.md 1.5).
@Suite("docs/test-vectors.json")
struct VectorFileTests {
    private static let vectors = Vectors.shared

    /// If the file grows a section or a field, this fails until the tests here cover it.
    @Test func fileHoldsExactlyTheFieldsTheseTestsCover() throws {
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: Vectors.url))
        let top = try #require(json as? [String: Any])
        func keys(_ value: Any?) -> Set<String> { Set((value as? [String: Any] ?? [:]).keys) }

        #expect(Set(top.keys) == [
            "description", "binaryEncoding", "secretKey", "keyDerivation", "sealedBlob",
            "loginSignature", "wireEncoding",
        ])
        #expect(keys(top["secretKey"]) == ["bytes", "formatted", "accepted", "rejected"])

        let kdfCases = try #require(top["keyDerivation"] as? [Any])
        #expect(kdfCases.count == 2)
        for c in kdfCases {
            #expect(keys(c) == [
                "name", "password", "passwordNfkcUtf8", "secretKey", "accountId", "kdfSalt",
                "kdfParams", "kPw", "kSk", "root", "unlockKey", "authSeed", "authPublicKey",
            ])
            #expect(keys((c as? [String: Any])?["kdfParams"]) == ["alg", "ops", "memKiB"])
        }

        let blobCases = try #require(top["sealedBlob"] as? [Any])
        #expect(blobCases.count == 5)
        for c in blobCases {
            #expect(keys(c) == ["name", "kind", "key", "id", "nonce", "plaintext", "aad", "blob"])
        }

        #expect(keys(top["loginSignature"]) == [
            "note", "authSeed", "authPublicKey", "nonce", "message", "signature",
        ])
        #expect(keys(top["wireEncoding"]) == ["base64Url", "id"])
        let wire = try #require(top["wireEncoding"] as? [String: Any])
        #expect(keys(wire["id"]) == ["bytes", "text"])
        let pairs = try #require(wire["base64Url"] as? [Any])
        #expect(pairs.count == 6)
        for pair in pairs {
            #expect(keys(pair) == ["bytes", "text"])
        }

        #expect(Self.vectors.secretKey.accepted.count == 7)
        #expect(Self.vectors.secretKey.rejected.count == 8)
    }

    // MARK: 1.1

    @Test func secretKeyFormatsAsInTheVectors() throws {
        let section = Self.vectors.secretKey
        let key = try SecretKey(bytes: hex(section.bytes))
        #expect(key.formatted() == section.formatted)
    }

    @Test(arguments: vectors.secretKey.accepted)
    func secretKeyAcceptedFormParsesToTheVectorBytes(text: String) throws {
        let key = try #require(SecretKey.parse(text))
        #expect(key.bytes.hexString == Self.vectors.secretKey.bytes)
        #expect(try SecretKey(parsing: text) == key)
        #expect(key.formatted() == Self.vectors.secretKey.formatted)
    }

    @Test(arguments: vectors.secretKey.rejected)
    func secretKeyRejectedFormDoesNotParse(text: String) {
        #expect(SecretKey.parse(text) == nil)
        #expect(throws: SecretKeyFormatError.self) { try SecretKey(parsing: text) }
    }

    // MARK: 1.2

    @Test(arguments: vectors.keyDerivation)
    func keyDerivationUsesTheRealArgon2Parameters(c: Vectors.KeyDerivationCase) {
        #expect(c.kdfParams.alg == "argon2id13")
        #expect(c.kdfParams.ops == 3)
        #expect(c.kdfParams.memKiB == 65536)
        #expect(c.kdfParams == KdfParams.default)
        #expect(c.kdfParams.isSupported)
    }

    @Test(arguments: vectors.keyDerivation)
    func keyDerivationMatchesEveryIntermediateValue(c: Vectors.KeyDerivationCase) throws {
        let passwordBytes = try KeyDerivation.normalisePassword(c.password)
        #expect(passwordBytes.hexString == c.passwordNfkcUtf8)
        #expect(try KeyDerivation.normalisePassword(utf16: Array(c.password.utf16)).hexString == c.passwordNfkcUtf8)

        let trace = try KeyDerivation.trace(
            passwordBytes, SecretKey(bytes: hex(c.secretKey)), hex(c.accountId), hex(c.kdfSalt), c.kdfParams)
        #expect(trace.kPw.hexString == c.kPw)
        #expect(trace.kSk.hexString == c.kSk)
        #expect(trace.root.hexString == c.root)
        #expect(trace.unlockKey.hexString == c.unlockKey)
        #expect(trace.authSeed.hexString == c.authSeed)
    }

    @Test(arguments: vectors.keyDerivation)
    func keyDerivationPublicAPIMatchesTheVectors(c: Vectors.KeyDerivationCase) throws {
        let secretKey = try SecretKey(bytes: hex(c.secretKey))
        let keys = try KeyDerivation.derive(
            password: c.password, secretKey: secretKey, accountId: hex(c.accountId),
            kdfSalt: hex(c.kdfSalt), kdfParams: c.kdfParams)

        #expect(keys.unlockKey.hexString == c.unlockKey)
        #expect(keys.authPublicKey.hexString == c.authPublicKey)
        // libsodium private key layout: seed || public key.
        #expect(keys.authPrivateKey.hexString == c.authSeed + c.authPublicKey)

        let fromUTF16 = try KeyDerivation.derive(
            passwordUTF16: Array(c.password.utf16), secretKey: secretKey, accountId: hex(c.accountId),
            kdfSalt: hex(c.kdfSalt), kdfParams: c.kdfParams)
        #expect(fromUTF16.unlockKey == keys.unlockKey)
        #expect(fromUTF16.authPrivateKey == keys.authPrivateKey)
        #expect(fromUTF16.authPublicKey == keys.authPublicKey)
    }

    @Test func nfkcCaseReallyIsChangedByNormalisation() {
        let c = Self.vectors.keyDerivationCase("nfkc")
        #expect(Data(c.password.utf8).hexString != c.passwordNfkcUtf8)
        #expect(Array(c.password.utf16) == [
            0xFF50, 0x61, 0x308, 0x73, 0x73, 0x77, 0x6F, 0x308, 0x72, 0x64, 0x20, 0xFB01, 0x2460, 0x20, 0x212B,
        ])
        #expect(Array(String(decoding: hex(c.passwordNfkcUtf8), as: UTF8.self).unicodeScalars) == Array(
            "p\u{E4}ssw\u{F6}rd fi1 \u{C5}".unicodeScalars))
    }

    /// An implementation that shares no code with the library agrees on the Ed25519 public key.
    @Test(arguments: vectors.keyDerivation)
    func cryptoKitDerivesTheSamePublicKeyFromTheSeed(c: Vectors.KeyDerivationCase) throws {
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: hex(c.authSeed))
        #expect(key.publicKey.rawRepresentation.hexString == c.authPublicKey)
    }

    // MARK: 1.3

    @Test(arguments: vectors.sealedBlob)
    func sealedBlobMatchesTheVectors(c: Vectors.SealedBlobCase) throws {
        let kind = try #require(BlobKind(rawValue: c.kind))
        let key = secret(c.key)
        let id = hex(c.id)
        let plaintext = hex(c.plaintext)
        let blob = hex(c.blob)

        #expect(try SealedBlob.additionalData(kind: kind, id: id) == c.aad)
        #expect(try SealedBlob.seal(key: key, kind: kind, id: id, plaintext: plaintext, nonce: hex(c.nonce)).hexString == c.blob)
        #expect(try SealedBlob.open(key: key, kind: kind, id: id, blob: blob) == plaintext)

        #expect(blob[0] == 0x01)
        #expect(blob[1..<25].hexString == c.nonce)
        #expect(blob.count == plaintext.count + 41)

        // The vector blob does not open as any other kind, or for another id.
        for other in BlobKind.allCases where other != kind {
            #expect(throws: SealedBlobError.authenticationFailed) {
                try SealedBlob.open(key: key, kind: other, id: id, blob: blob)
            }
        }
        var otherId = id
        otherId[15] ^= 1
        #expect(throws: SealedBlobError.authenticationFailed) {
            try SealedBlob.open(key: key, kind: kind, id: otherId, blob: blob)
        }
    }

    @Test func sealedBlobVectorsCoverEveryKind() {
        let kinds = Set(Self.vectors.sealedBlob.map(\.kind))
        #expect(kinds == Set(BlobKind.allCases.map(\.rawValue)))
        #expect(kinds == ["vault", "nbkey", "update", "snapshot"])
    }

    @Test func vaultVectorUnwrapsThroughTheKeyHierarchy() throws {
        let vault = Self.vectors.sealedBlobCase("vault")
        let vaultKey = try KeyHierarchy.unwrapVaultKey(
            unlockKey: secret(vault.key), accountId: hex(vault.id), wrappedVaultKey: hex(vault.blob))
        #expect(vaultKey.hexString == vault.plaintext)

        // The vault case is keyed by the unlockKey of the first derivation case, end to end.
        #expect(Self.vectors.keyDerivationCase("ascii").unlockKey == vault.key)
        #expect(Self.vectors.keyDerivationCase("ascii").accountId == vault.id)

        let nb = Self.vectors.sealedBlobCase("nbkey")
        #expect(nb.key == vault.plaintext)
        let notebookKey = try KeyHierarchy.unwrapNotebookKey(
            vaultKey: vaultKey, notebookId: hex(nb.id), wrappedNotebookKey: hex(nb.blob))
        #expect(notebookKey.hexString == nb.plaintext)

        // And the notebook key opens the document vectors.
        let update = Self.vectors.sealedBlobCase("update")
        #expect(update.key == nb.plaintext)
        #expect(try KeyHierarchy.openUpdate(
            notebookKey: notebookKey, docId: hex(update.id), blob: hex(update.blob)) == hex(update.plaintext))
        let snapshot = Self.vectors.sealedBlobCase("snapshot")
        #expect(try KeyHierarchy.openSnapshot(
            notebookKey: notebookKey, docId: hex(snapshot.id), blob: hex(snapshot.blob)) == hex(snapshot.plaintext))
        let empty = Self.vectors.sealedBlobCase("update-empty-plaintext")
        #expect(try KeyHierarchy.openUpdate(
            notebookKey: notebookKey, docId: hex(empty.id), blob: hex(empty.blob)) == Data())
    }

    // MARK: 1.4

    @Test func loginSignatureMatchesTheVectors() throws {
        let s = Self.vectors.loginSignature
        let nonce = hex(s.nonce)
        let publicKey = hex(s.authPublicKey)
        let privateKey = SecretBytes(copying: hex(s.authSeed) + publicKey)

        #expect(Data(LoginSignature.message(nonce: nonce)).hexString == s.message)
        #expect(Data("twonote/v1/login".utf8) + nonce == hex(s.message))
        #expect(try LoginSignature.sign(authPrivateKey: privateKey, nonce: nonce).hexString == s.signature)
        #expect(LoginSignature.verify(authPublicKey: publicKey, nonce: nonce, signature: hex(s.signature)))

        let ascii = Self.vectors.keyDerivationCase("ascii")
        #expect(s.authSeed == ascii.authSeed)
        #expect(s.authPublicKey == ascii.authPublicKey)

        // CryptoKit, which shares no code with libsodium, accepts the vector signature.
        let cryptoKitKey = try Curve25519.Signing.PublicKey(rawRepresentation: publicKey)
        #expect(cryptoKitKey.isValidSignature(hex(s.signature), for: hex(s.message)))
    }

    // MARK: wire encoding

    @Test(arguments: vectors.wireEncoding.base64Url)
    func base64UrlMatchesTheVectors(pair: Vectors.WireEncodingSection.Pair) {
        #expect(WireEncoding.base64URLString(hex(pair.bytes)) == pair.text)
        #expect(WireEncoding.data(base64URL: pair.text) == hex(pair.bytes))
    }

    @Test func idEncodingMatchesTheVectors() throws {
        let id = Self.vectors.wireEncoding.id
        #expect(try WireEncoding.hexString(id: hex(id.bytes)) == id.text)
        #expect(WireEncoding.id(hex: id.text) == hex(id.bytes))
    }
}

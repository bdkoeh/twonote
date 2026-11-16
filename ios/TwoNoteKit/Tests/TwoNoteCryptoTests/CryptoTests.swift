import CryptoKit
import Foundation
import Testing
@testable import TwoNoteCrypto

private func dumped(_ value: Any) -> String {
    var out = ""
    dump(value, to: &out)
    return out + String(describing: value) + String(reflecting: value) + "\(value)"
}

@Suite struct SecretKeyTests {
    @Test func generateGivesDistinctKeysInTheDisplayShape() throws {
        let a = SecretKey.generate()
        let b = SecretKey.generate()
        #expect(a != b)
        #expect(a.bytes.count == 16)
        let shape = /T2-[0-9A-HJKMNP-TV-Z]{6}-[0-9A-HJKMNP-TV-Z]{6}-[0-9A-HJKMNP-TV-Z]{6}-[0-9A-HJKMNP-TV-Z]{8}/
        #expect(try shape.wholeMatch(in: a.formatted()) != nil)
    }

    @Test func formatThenParseRoundTripsManyKeys() throws {
        for _ in 0..<500 {
            let key = SecretKey.generate()
            #expect(try SecretKey(parsing: key.formatted()) == key)
        }
    }

    @Test func edgeValuesRoundTrip() throws {
        for fill: UInt8 in [0x00, 0xFF, 0xA5] {
            let key = try SecretKey(bytes: [UInt8](repeating: fill, count: 16))
            #expect(try SecretKey(parsing: key.formatted()).bytes.copyToData() == Data(repeating: fill, count: 16))
        }
        #expect(try SecretKey(bytes: [UInt8](repeating: 0, count: 16)).formatted() == "T2-000000-000000-000000-00000000")
        #expect(try SecretKey(bytes: [UInt8](repeating: 0xFF, count: 16)).formatted() == "T2-ZZZZZZ-ZZZZZZ-ZZZZZZ-ZZZZZZZW")
    }

    @Test(arguments: [
        "t2-oooooo-OOOOOO-000000-00000000",
        "T2 000000 000000 000000 00000000",
        "T200000000000000000000000000",
        "00000000000000000000000000",
        "\tT2-000000-\n000000-000000-00000000 ",
        "T2--000000-00000000-0000-0000-0000",
        "T2\u{A0}000000\u{2003}000000\u{3000}000000\u{1F}00000000",
    ])
    func parseToleratesCaseSeparatorsAndLookalikes(text: String) throws {
        #expect(try SecretKey(parsing: text).bytes.copyToData() == Data(count: 16))
    }

    @Test func lookalikeLettersMapToDigits() throws {
        let ones = try SecretKey(parsing: "T2-111111-111111-111111-11111110")
        let letters = try SecretKey(parsing: "t2-IiLlIi-LlIiLl-IiLlIi-LlIiLlIO")
        #expect(ones == letters)
    }

    @Test func aBodyThatHappensToStartWithT2NeedsNoPrefix() throws {
        // 26 symbols, so nothing is stripped: T and 2 are data.
        let key = try SecretKey(parsing: "T20000-000000-000000-00000000")
        #expect(key.formatted() == "T2-T20000-000000-000000-00000000")
    }

    @Test(arguments: [
        "",
        "T2",
        "T2-000000-000000-000000-0000000",
        "T2-000000-000000-000000-000000000",
        "T2-U00000-000000-000000-00000000",
        "T2-u00000-000000-000000-00000000",
        "T2-00000!-000000-000000-00000000",
        "T2-000000-000000-000000-00000001",
        "T2-000000-000000-000000-00000002",
        "T2-000000-000000-000000-00000003",
        "X2-000000-000000-000000-00000000",
        "T2-000000-000000-000000-0000000\u{E9}",
        "T2-000000-000000-000000-0000000\u{1F600}",
        "T2-000000_000000_000000_00000000",
        "T2T2-000000-000000-000000-00000000",
    ])
    func parseRejectsMalformedInput(text: String) {
        #expect(SecretKey.parse(text) == nil)
        #expect(throws: SecretKeyFormatError()) { try SecretKey(parsing: text) }
    }

    @Test func parseRejectsAbsurdlyLongInput() {
        #expect(SecretKey.parse(String(repeating: "-", count: 100_000)) == nil)
        #expect(SecretKey.parse(String(repeating: " ", count: 300) + "00000000000000000000000000") == nil)
    }

    @Test func fromBytesRequiresSixteenBytes() {
        #expect(throws: CryptoInputError.wrongLength(.secretKey, expected: 16)) { try SecretKey(bytes: Data(count: 15)) }
        #expect(throws: CryptoInputError.wrongLength(.secretKey, expected: 16)) { try SecretKey(bytes: Data(count: 17)) }
    }

    @Test func descriptionsDoNotRevealTheKey() throws {
        let key = try SecretKey(bytes: hex("8f3a1c5ed247b906e17d4ac3902bf865"))
        let text = dumped(key) + dumped(key.bytes) + dumped(SecretKeyFormatError())
        #expect(!text.contains("HWX1RQ"))
        #expect(!text.lowercased().contains("8f3a"))
        #expect(!text.contains("143")) // 0x8f
        #expect("\(key)" == "SecretKey(redacted)")
    }
}

@Suite struct SecretBytesTests {
    @Test func copiesAndComparesByContent() {
        let a = SecretBytes(copying: [1, 2, 3] as [UInt8])
        let b = SecretBytes(copying: Data([9, 1, 2, 3]).dropFirst()) // a slice with a non-zero start
        #expect(a.count == 3)
        #expect(a == b)
        #expect(a != SecretBytes(copying: [1, 2, 4] as [UInt8]))
        #expect(a != SecretBytes(copying: [1, 2] as [UInt8]))
        #expect(a.copyToData() == Data([1, 2, 3]))
        #expect(a.withUnsafeBytes { Array($0) } == [1, 2, 3])
        #expect(SecretBytes(copying: Data()).count == 0)
        #expect("\(a)" == "SecretBytes(3 bytes, redacted)")
    }

    @Test func randomIsRandom() {
        let a = SecretBytes.random(count: 32)
        let b = SecretBytes.random(count: 32)
        #expect(a.count == 32)
        #expect(a != b)
        #expect(a != SecretBytes(copying: Data(count: 32)))
    }
}

@Suite struct KeyDerivationTests {
    static let sk = hex("8f3a1c5ed247b906e17d4ac3902bf865")
    static let accountId = hex("a1b2c3d4e5f60718293a4b5c6d7e8f90")
    static let salt = hex("202122232425262728292a2b2c2d2e2f")

    // Derivation cost is not what these tests are about; the vector tests run the real parameters.
    static let cheap = KdfParams(alg: KdfParams.argon2id13, ops: 1, memKiB: 8192)

    struct Output: Equatable {
        let unlock: String
        let publicKey: String
    }

    static func derive(
        _ password: String, sk: Data = sk, accountId: Data = accountId, salt: Data = salt, p: KdfParams = cheap
    ) throws -> Output {
        let keys = try KeyDerivation.derive(
            password: password, secretKey: SecretKey(bytes: sk), accountId: accountId, kdfSalt: salt, kdfParams: p)
        return Output(unlock: keys.unlockKey.hexString, publicKey: keys.authPublicKey.hexString)
    }

    @Test func defaultParametersAreThreePassesOver64MiB() {
        #expect(KdfParams.default.alg == "argon2id13")
        #expect(KdfParams.default.ops == 3)
        #expect(KdfParams.default.memKiB == 65536)
        #expect(KdfParams.default.isSupported)
    }

    @Test func kdfParamsUseTheProtocolFieldNames() throws {
        let wire = Data(#"{"alg":"argon2id13","ops":3,"memKiB":65536,"somethingNew":1}"#.utf8)
        #expect(try JSONDecoder().decode(KdfParams.self, from: wire) == .default)

        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(KdfParams.default))
        let object = try #require(encoded as? [String: Any])
        #expect(Set(object.keys) == ["alg", "ops", "memKiB"])
        #expect(object["alg"] as? String == "argon2id13")
        #expect(object["ops"] as? Int == 3)
        #expect(object["memKiB"] as? Int == 65536)

        for bad in [#"{"alg":"argon2id13","ops":3.5,"memKiB":65536}"#, #"{"alg":"argon2id13","ops":"3","memKiB":65536}"#, #"{"alg":"argon2id13","ops":3}"#] {
            #expect(throws: DecodingError.self) { try JSONDecoder().decode(KdfParams.self, from: Data(bad.utf8)) }
        }
    }

    @Test(arguments: [
        (KdfParams(alg: "argon2id13", ops: 1, memKiB: 8192), true),
        (KdfParams(alg: "argon2id13", ops: 16, memKiB: 1_048_576), true),
        (KdfParams(alg: "argon2id13", ops: 0, memKiB: 65536), false),
        (KdfParams(alg: "argon2id13", ops: 17, memKiB: 65536), false),
        (KdfParams(alg: "argon2id13", ops: -1, memKiB: 65536), false),
        (KdfParams(alg: "argon2id13", ops: 3, memKiB: 8191), false),
        (KdfParams(alg: "argon2id13", ops: 3, memKiB: 1_048_577), false),
        (KdfParams(alg: "argon2id13", ops: 3, memKiB: 1024), false),
        (KdfParams(alg: "argon2id13", ops: 3, memKiB: Int.max), false),
        (KdfParams(alg: "argon2id13", ops: 1000, memKiB: 65536), false),
        (KdfParams(alg: "scrypt", ops: 3, memKiB: 65536), false),
        (KdfParams(alg: "argon2i13", ops: 3, memKiB: 65536), false),
        (KdfParams(alg: "Argon2id13", ops: 3, memKiB: 65536), false),
        (KdfParams(alg: "", ops: 3, memKiB: 65536), false),
    ])
    func kdfParamsBoundsAreEnforced(p: KdfParams, supported: Bool) {
        #expect(p.isSupported == supported)
        if !supported {
            #expect(throws: CryptoInputError.unsupportedKdfParams) { try Self.derive("x", p: p) }
            #expect(throws: CryptoInputError.unsupportedKdfParams) {
                try KeyDerivation.derive(
                    passwordUTF16: [0x78], secretKey: SecretKey(bytes: Self.sk), accountId: Self.accountId,
                    kdfSalt: Self.salt, kdfParams: p)
            }
        }
    }

    @Test func derivationIsDeterministic() throws {
        #expect(try Self.derive("hunter2") == Self.derive("hunter2"))
    }

    @Test func canonicallyEquivalentPasswordsDeriveTheSameKeys() throws {
        // Precomposed, decomposed and compatibility forms of the same text.
        let composed = try Self.derive("p\u{E4}ssw\u{F6}rd fi1")
        #expect(try Self.derive("pa\u{308}sswo\u{308}rd fi1") == composed)
        #expect(try Self.derive("\u{FF50}\u{E4}ssw\u{F6}rd \u{FB01}1") == composed)
        #expect(try Self.derive("P\u{E4}ssw\u{F6}rd fi1") != composed)
    }

    @Test func everyInputChangesTheOutput() throws {
        let baseline = try Self.derive("hunter2")
        var other = Self.sk
        other[0] ^= 1

        let variants = try [
            Self.derive("hunter3"),
            Self.derive("Hunter2"),
            Self.derive("hunter2 "),
            Self.derive(""),
            Self.derive("hunter2", sk: other),
            Self.derive("hunter2", accountId: WireEncoding.newId()),
            Self.derive("hunter2", salt: KeyDerivation.newSalt()),
            Self.derive("hunter2", p: KdfParams(alg: "argon2id13", ops: 2, memKiB: 8192)),
            Self.derive("hunter2", p: KdfParams(alg: "argon2id13", ops: 1, memKiB: 16384)),
        ]
        for v in variants {
            #expect(v.unlock != baseline.unlock)
            #expect(v.publicKey != baseline.publicKey)
        }
        #expect(Set(variants.map(\.unlock)).count == variants.count)
    }

    @Test func unlockKeyAndAuthSeedAreDifferentKeys() throws {
        let keys = try KeyDerivation.derive(
            password: "hunter2", secretKey: SecretKey(bytes: Self.sk), accountId: Self.accountId,
            kdfSalt: Self.salt, kdfParams: Self.cheap)
        #expect(keys.unlockKey.count == 32)
        #expect(keys.authPrivateKey.count == 64)
        #expect(keys.authPublicKey.count == 32)
        let privateKey = keys.authPrivateKey.copyToData()
        #expect(privateKey.prefix(32) != keys.unlockKey.copyToData())
        #expect(privateKey.suffix(32) == keys.authPublicKey)
        #expect(KeyDerivation.newSalt().count == 16)
        #expect(KeyDerivation.newSalt() != KeyDerivation.newSalt())
    }

    @Test func wrongLengthsAreRejected() {
        #expect(throws: CryptoInputError.wrongLength(.id, expected: 16)) { try Self.derive("x", accountId: Data(count: 17)) }
        #expect(throws: CryptoInputError.wrongLength(.id, expected: 16)) { try Self.derive("x", accountId: Data()) }
        #expect(throws: CryptoInputError.wrongLength(.kdfSalt, expected: 16)) { try Self.derive("x", salt: Data(count: 8)) }
        #expect(throws: CryptoInputError.wrongLength(.kdfSalt, expected: 16)) { try Self.derive("x", salt: Data(count: 32)) }
        #expect(throws: CryptoInputError.wrongLength(.secretKey, expected: 16)) { try Self.derive("x", sk: Data(count: 15)) }
    }

    @Test func inputsMayBeDataSlices() throws {
        let padded = Data([0xEE]) + Self.accountId + Data([0xEE])
        let slice = padded[1..<17]
        #expect(try Self.derive("hunter2", accountId: slice) == Self.derive("hunter2"))
        let saltSlice = (Data([0xEE, 0xEE]) + Self.salt).dropFirst(2)
        #expect(try Self.derive("hunter2", salt: saltSlice) == Self.derive("hunter2"))
    }

    @Test(arguments: [
        [0x61, 0x62, 0x63, 0xD800, 0x64, 0x65, 0x66], // lone high surrogate, as in the .NET test
        [0xD800],
        [0x61, 0xDBFF],
        [0xDC00, 0x61],
        [0x61, 0xDFFF, 0x62],
        [0xDC00, 0xD800], // the pair the wrong way round
        [0xD83D, 0xD83D, 0xDE00],
    ] as [[UInt16]])
    func utf16PasswordWithAnUnpairedSurrogateIsRejected(units: [UInt16]) throws {
        #expect(throws: CryptoInputError.invalidPassword) { try KeyDerivation.normalisePassword(utf16: units) }
        #expect(throws: CryptoInputError.invalidPassword) {
            try KeyDerivation.derive(
                passwordUTF16: units, secretKey: SecretKey(bytes: Self.sk), accountId: Self.accountId,
                kdfSalt: Self.salt, kdfParams: Self.cheap)
        }
    }

    @Test func wellFormedSurrogatePairsAreAccepted() throws {
        let emoji: [UInt16] = [0x61, 0xD83D, 0xDE00, 0x62]
        #expect(try KeyDerivation.normalisePassword(utf16: emoji).copyToData() == Data("a\u{1F600}b".utf8))
        #expect(try KeyDerivation.normalisePassword("a\u{1F600}b").copyToData() == Data("a\u{1F600}b".utf8))
        #expect(try KeyDerivation.normalisePassword("").count == 0)
        #expect(try KeyDerivation.normalisePassword(utf16: [] as [UInt16]).count == 0)
    }

    /// Where Swift differs from .NET: bridging an NSString that holds a lone surrogate already
    /// replaces it with U+FFFD, so the String entry point cannot see it and accepts the text.
    /// Reading the UTF-16 code units from the NSString itself keeps the surrogate, and the
    /// UTF-16 entry point rejects it.
    @Test func loneSurrogateInAnNSStringIsOnlyVisibleAsUTF16() throws {
        let units: [UInt16] = [0x61, 0xD800, 0x62]
        let ns = NSString(characters: units, length: units.count)

        let bridged = ns as String
        #expect(Array(bridged.utf16) == [0x61, 0xFFFD, 0x62])
        #expect(try KeyDerivation.normalisePassword(bridged).hexString == "61efbfbd62")
        #expect(try KeyDerivation.normalisePassword("a\u{FFFD}b").hexString == "61efbfbd62")

        var raw = [UInt16](repeating: 0, count: ns.length)
        ns.getCharacters(&raw, range: NSRange(location: 0, length: ns.length))
        #expect(raw == units)
        #expect(throws: CryptoInputError.invalidPassword) { try KeyDerivation.normalisePassword(utf16: raw) }
    }

    @Test func descriptionsDoNotRevealTheKeys() throws {
        let keys = try KeyDerivation.derive(
            password: "hunter2", secretKey: SecretKey(bytes: Self.sk), accountId: Self.accountId,
            kdfSalt: Self.salt, kdfParams: Self.cheap)
        #expect("\(keys)" == "DerivedKeys(redacted)")
        let text = dumped(keys)
        #expect(!text.contains(keys.unlockKey.hexString.prefix(8)))
        #expect(!text.contains("Data"))
    }
}

@Suite struct SealedBlobTests {
    static let key = SecretBytes.random(count: 32)
    static let id = WireEncoding.newId()
    static let plaintext = Data("some Yjs update bytes".utf8)

    private func expectFailure(
        _ expected: SealedBlobError, key: SecretBytes = key, kind: BlobKind = .update, id: Data = id, blob: Data,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        #expect(throws: expected, sourceLocation: sourceLocation) {
            try SealedBlob.open(key: key, kind: kind, id: id, blob: blob)
        }
        #expect((try? SealedBlob.open(key: key, kind: kind, id: id, blob: blob)) == nil, sourceLocation: sourceLocation)
    }

    @Test(arguments: [BlobKind.update, .snapshot])
    func sealThenOpenRoundTrips(kind: BlobKind) throws {
        let blob = try SealedBlob.seal(key: Self.key, kind: kind, id: Self.id, plaintext: Self.plaintext)
        #expect(try SealedBlob.open(key: Self.key, kind: kind, id: Self.id, blob: blob) == Self.plaintext)
    }

    @Test(arguments: [BlobKind.vault, .notebookKey])
    func keyKindsRoundTripThirtyTwoBytes(kind: BlobKind) throws {
        let inner = Data(Sodium.randomBytes(count: 32))
        let blob = try SealedBlob.seal(key: Self.key, kind: kind, id: Self.id, plaintext: inner)
        #expect(blob.count == 73)
        #expect(try SealedBlob.open(key: Self.key, kind: kind, id: Self.id, blob: blob) == inner)
    }

    @Test(arguments: [0, 1, 31, 33, 64])
    func keyKindsRefuseAnyOtherPlaintextLength(length: Int) throws {
        for kind in [BlobKind.vault, .notebookKey] {
            let inner = Data(count: length)
            #expect(throws: CryptoInputError.wrongLength(.wrappedKey, expected: 32)) {
                try SealedBlob.seal(key: Self.key, kind: kind, id: Self.id, plaintext: inner)
            }
            // A blob that authenticates but does not hold a 32-byte key is a failed open (1.3).
            let forged = try SealedBlob.seal(
                key: Self.key, kind: kind, id: Self.id, plaintext: inner, nonce: Data(Sodium.randomBytes(count: 24)))
            expectFailure(.authenticationFailed, kind: kind, blob: forged)
        }
    }

    @Test(arguments: [0, 1, 100_000])
    func roundTripsAnyPlaintextLength(length: Int) throws {
        let plaintext = Data(Sodium.randomBytes(count: length))
        let blob = try SealedBlob.seal(key: Self.key, kind: .update, id: Self.id, plaintext: plaintext)
        #expect(blob.count == length + SealedBlob.overhead)
        #expect(try SealedBlob.open(key: Self.key, kind: .update, id: Self.id, blob: blob) == plaintext)
    }

    @Test func blobLayoutIsVersionThenNonceThenCiphertext() throws {
        let a = try SealedBlob.seal(key: Self.key, kind: .update, id: Self.id, plaintext: Self.plaintext)
        let b = try SealedBlob.seal(key: Self.key, kind: .update, id: Self.id, plaintext: Self.plaintext)
        #expect(SealedBlob.overhead == 41)
        #expect(a.count == 1 + 24 + Self.plaintext.count + 16)
        #expect(a[0] == 0x01)

        // A fresh random nonce every time, so the same plaintext never seals to the same bytes.
        #expect(a[1..<25] != b[1..<25])
        #expect(a[25...] != b[25...])
        #expect(a[1..<25] != Data(count: 24))
    }

    @Test func additionalDataIsTheProtocolString() throws {
        let id = hex("00112233445566778899AABBCCDDEEFF")
        #expect(try SealedBlob.additionalData(kind: .vault, id: id) == "twonote/v1|vault|00112233445566778899aabbccddeeff")
        #expect(try SealedBlob.additionalData(kind: .notebookKey, id: id) == "twonote/v1|nbkey|00112233445566778899aabbccddeeff")
        #expect(try SealedBlob.additionalData(kind: .update, id: id) == "twonote/v1|update|00112233445566778899aabbccddeeff")
        #expect(try SealedBlob.additionalData(kind: .snapshot, id: id) == "twonote/v1|snapshot|00112233445566778899aabbccddeeff")
    }

    @Test func wrongKeyFails() throws {
        let blob = try SealedBlob.seal(key: Self.key, kind: .update, id: Self.id, plaintext: Self.plaintext)
        var wrong = Self.key.copyToData()
        wrong[31] ^= 0x80
        expectFailure(.authenticationFailed, key: SecretBytes(copying: wrong), blob: blob)
        expectFailure(.authenticationFailed, key: .random(count: 32), blob: blob)
    }

    @Test func wrongKindFails() throws {
        let blob = try SealedBlob.seal(key: Self.key, kind: .update, id: Self.id, plaintext: Self.plaintext)
        for kind in [BlobKind.snapshot, .vault, .notebookKey] {
            expectFailure(.authenticationFailed, kind: kind, blob: blob)
        }
        // Also when the length would suit a key: the kind alone must stop it.
        let thirtyTwo = try SealedBlob.seal(key: Self.key, kind: .update, id: Self.id, plaintext: Data(count: 32))
        for kind in [BlobKind.snapshot, .vault, .notebookKey] {
            expectFailure(.authenticationFailed, kind: kind, blob: thirtyTwo)
        }
    }

    @Test func wrongIdFails() throws {
        let blob = try SealedBlob.seal(key: Self.key, kind: .update, id: Self.id, plaintext: Self.plaintext)
        for i in 0..<16 {
            var other = Self.id
            other[i] ^= 1
            expectFailure(.authenticationFailed, id: other, blob: blob)
        }
    }

    @Test func everyTruncationFails() throws {
        let blob = try SealedBlob.seal(key: Self.key, kind: .update, id: Self.id, plaintext: Self.plaintext)
        for length in 0..<blob.count {
            expectFailure(length < SealedBlob.overhead ? .truncated : .authenticationFailed, blob: blob.prefix(length))
        }
        // Cut from the front as well.
        expectFailure(.unsupportedVersion, blob: blob.dropFirst())
    }

    @Test func trailingGarbageFails() throws {
        let blob = try SealedBlob.seal(key: Self.key, kind: .update, id: Self.id, plaintext: Self.plaintext)
        expectFailure(.authenticationFailed, blob: blob + [0x00])
    }

    @Test(arguments: [0x00, 0x02, 0xFF] as [UInt8])
    func wrongVersionFails(version: UInt8) throws {
        var blob = try SealedBlob.seal(key: Self.key, kind: .update, id: Self.id, plaintext: Self.plaintext)
        blob[0] = version
        expectFailure(.unsupportedVersion, blob: blob)
    }

    @Test func flippingAnySingleBitFails() throws {
        let blob = try SealedBlob.seal(key: Self.key, kind: .update, id: Self.id, plaintext: Self.plaintext)
        for i in 0..<blob.count {
            for bit in 0..<8 {
                var tampered = blob
                tampered[i] ^= 1 << UInt8(bit)
                expectFailure(i == 0 ? .unsupportedVersion : .authenticationFailed, blob: tampered)
            }
        }
    }

    @Test func blobMayBeADataSlice() throws {
        let blob = try SealedBlob.seal(key: Self.key, kind: .update, id: Self.id, plaintext: Self.plaintext)
        let slice = (Data([0xAA, 0xBB, 0xCC]) + blob + Data([0xDD])).dropFirst(3).dropLast()
        #expect(slice.startIndex == 3)
        #expect(try SealedBlob.open(key: Self.key, kind: .update, id: Self.id, blob: slice) == Self.plaintext)
        let plaintextSlice = (Data([0xAA]) + Self.plaintext).dropFirst()
        let again = try SealedBlob.seal(key: Self.key, kind: .update, id: Self.id, plaintext: plaintextSlice)
        #expect(try SealedBlob.open(key: Self.key, kind: .update, id: Self.id, blob: again) == Self.plaintext)
    }

    @Test func callerBugsAreInputErrorsNotBlobFailures() throws {
        let blob = try SealedBlob.seal(key: Self.key, kind: .update, id: Self.id, plaintext: Self.plaintext)
        let shortKey = SecretBytes(copying: Data(count: 31))
        let longKey = SecretBytes(copying: Data(count: 33))
        #expect(throws: CryptoInputError.wrongLength(.key, expected: 32)) {
            try SealedBlob.seal(key: shortKey, kind: .update, id: Self.id, plaintext: Self.plaintext)
        }
        #expect(throws: CryptoInputError.wrongLength(.id, expected: 16)) {
            try SealedBlob.seal(key: Self.key, kind: .update, id: Data(count: 15), plaintext: Self.plaintext)
        }
        #expect(throws: CryptoInputError.wrongLength(.key, expected: 32)) {
            try SealedBlob.open(key: longKey, kind: .update, id: Self.id, blob: blob)
        }
        #expect(throws: CryptoInputError.wrongLength(.id, expected: 16)) {
            try SealedBlob.open(key: Self.key, kind: .update, id: Data(count: 32), blob: blob)
        }
        #expect(throws: CryptoInputError.wrongLength(.nonce, expected: 24)) {
            try SealedBlob.seal(key: Self.key, kind: .update, id: Self.id, plaintext: Self.plaintext, nonce: Data(count: 23))
        }
        #expect(throws: CryptoInputError.wrongLength(.id, expected: 16)) {
            try SealedBlob.additionalData(kind: .update, id: Data(count: 17))
        }
    }
}

@Suite struct KeyHierarchyTests {
    static let accountId = WireEncoding.newId()
    static let notebookId = WireEncoding.newId()

    @Test func fullChainWrapsAndUnwraps() throws {
        let unlockKey = SecretBytes.random(count: 32)
        let vaultKey = KeyHierarchy.createVaultKey()
        let notebookKey = KeyHierarchy.createNotebookKey()
        #expect(vaultKey.count == 32)
        #expect(notebookKey.count == 32)
        #expect(vaultKey != notebookKey)

        let wrappedVault = try KeyHierarchy.wrapVaultKey(unlockKey: unlockKey, accountId: Self.accountId, vaultKey: vaultKey)
        let wrappedNotebook = try KeyHierarchy.wrapNotebookKey(vaultKey: vaultKey, notebookId: Self.notebookId, notebookKey: notebookKey)
        #expect(wrappedVault.count == 32 + SealedBlob.overhead)
        #expect(wrappedNotebook.count == 32 + SealedBlob.overhead)

        let vaultKey2 = try KeyHierarchy.unwrapVaultKey(unlockKey: unlockKey, accountId: Self.accountId, wrappedVaultKey: wrappedVault)
        let notebookKey2 = try KeyHierarchy.unwrapNotebookKey(vaultKey: vaultKey2, notebookId: Self.notebookId, wrappedNotebookKey: wrappedNotebook)
        #expect(vaultKey2 == vaultKey)
        #expect(notebookKey2 == notebookKey)

        // The wrapped forms are ordinary sealed blobs.
        #expect(try SealedBlob.open(key: unlockKey, kind: .vault, id: Self.accountId, blob: wrappedVault) == vaultKey.copyToData())

        let docId = WireEncoding.newId()
        let update = try KeyHierarchy.sealUpdate(notebookKey: notebookKey2, docId: docId, update: Data("edit".utf8))
        #expect(try KeyHierarchy.openUpdate(notebookKey: notebookKey, docId: docId, blob: update) == Data("edit".utf8))
        let snapshot = try KeyHierarchy.sealSnapshot(notebookKey: notebookKey2, docId: docId, snapshot: Data("state".utf8))
        #expect(try KeyHierarchy.openSnapshot(notebookKey: notebookKey, docId: docId, blob: snapshot) == Data("state".utf8))
    }

    @Test func updatesAndSnapshotsAreNotInterchangeable() throws {
        let notebookKey = KeyHierarchy.createNotebookKey()
        let docId = WireEncoding.newId()
        let otherDoc = WireEncoding.newId()
        let update = try KeyHierarchy.sealUpdate(notebookKey: notebookKey, docId: docId, update: Data("edit".utf8))
        let snapshot = try KeyHierarchy.sealSnapshot(notebookKey: notebookKey, docId: docId, snapshot: Data("edit".utf8))

        #expect(throws: SealedBlobError.authenticationFailed) { try KeyHierarchy.openSnapshot(notebookKey: notebookKey, docId: docId, blob: update) }
        #expect(throws: SealedBlobError.authenticationFailed) { try KeyHierarchy.openUpdate(notebookKey: notebookKey, docId: docId, blob: snapshot) }
        #expect(throws: SealedBlobError.authenticationFailed) { try KeyHierarchy.openUpdate(notebookKey: notebookKey, docId: otherDoc, blob: update) }
        #expect(throws: SealedBlobError.authenticationFailed) { try KeyHierarchy.openSnapshot(notebookKey: notebookKey, docId: otherDoc, blob: snapshot) }
        #expect(throws: SealedBlobError.authenticationFailed) {
            try KeyHierarchy.openUpdate(notebookKey: KeyHierarchy.createNotebookKey(), docId: docId, blob: update)
        }
        #expect(throws: SealedBlobError.truncated) { try KeyHierarchy.openUpdate(notebookKey: notebookKey, docId: docId, blob: Data()) }
    }

    @Test func wrongUnlockKeyDoesNotUnwrapTheVault() throws {
        let unlockKey = SecretBytes.random(count: 32)
        let wrongKey = SecretBytes.random(count: 32)
        let vaultKey = KeyHierarchy.createVaultKey()
        let wrapped = try KeyHierarchy.wrapVaultKey(unlockKey: unlockKey, accountId: Self.accountId, vaultKey: vaultKey)

        #expect(throws: SealedBlobError.authenticationFailed) {
            try KeyHierarchy.unwrapVaultKey(unlockKey: wrongKey, accountId: Self.accountId, wrappedVaultKey: wrapped)
        }
        #expect((try? KeyHierarchy.unwrapVaultKey(unlockKey: wrongKey, accountId: Self.accountId, wrappedVaultKey: wrapped)) == nil)
        #expect((try? KeyHierarchy.unwrapVaultKey(unlockKey: unlockKey, accountId: Self.accountId, wrappedVaultKey: wrapped)) == vaultKey)
    }

    @Test func wrappedKeysAreBoundToTheirKindAndId() throws {
        let key = SecretBytes.random(count: 32)
        let inner = SecretBytes.random(count: 32)
        let asVault = try KeyHierarchy.wrapVaultKey(unlockKey: key, accountId: Self.accountId, vaultKey: inner)
        let asNotebook = try KeyHierarchy.wrapNotebookKey(vaultKey: key, notebookId: Self.accountId, notebookKey: inner)

        #expect(throws: SealedBlobError.authenticationFailed) {
            try KeyHierarchy.unwrapNotebookKey(vaultKey: key, notebookId: Self.accountId, wrappedNotebookKey: asVault)
        }
        #expect(throws: SealedBlobError.authenticationFailed) {
            try KeyHierarchy.unwrapVaultKey(unlockKey: key, accountId: Self.accountId, wrappedVaultKey: asNotebook)
        }
        #expect(throws: SealedBlobError.authenticationFailed) {
            try KeyHierarchy.unwrapNotebookKey(vaultKey: key, notebookId: Self.notebookId, wrappedNotebookKey: asNotebook)
        }
        #expect(throws: SealedBlobError.authenticationFailed) {
            try KeyHierarchy.unwrapVaultKey(unlockKey: key, accountId: Self.notebookId, wrappedVaultKey: asVault)
        }
    }

    @Test func aBlobThatOpensButIsNotAKeyIsRefused() throws {
        let key = SecretBytes.random(count: 32)
        for length in [0, 31, 33] {
            let notAKey = try SealedBlob.seal(
                key: key, kind: .vault, id: Self.accountId, plaintext: Data(count: length),
                nonce: Data(Sodium.randomBytes(count: 24)))
            #expect(throws: SealedBlobError.authenticationFailed) {
                try KeyHierarchy.unwrapVaultKey(unlockKey: key, accountId: Self.accountId, wrappedVaultKey: notAKey)
            }
        }
        #expect(throws: CryptoInputError.wrongLength(.wrappedKey, expected: 32)) {
            try KeyHierarchy.wrapVaultKey(unlockKey: key, accountId: Self.accountId, vaultKey: SecretBytes(copying: Data(count: 31)))
        }
        #expect(throws: CryptoInputError.wrongLength(.wrappedKey, expected: 32)) {
            try KeyHierarchy.wrapNotebookKey(vaultKey: key, notebookId: Self.notebookId, notebookKey: SecretBytes(copying: Data(count: 33)))
        }
        #expect(throws: CryptoInputError.wrongLength(.key, expected: 32)) {
            try KeyHierarchy.wrapVaultKey(unlockKey: SecretBytes(copying: Data(count: 16)), accountId: Self.accountId, vaultKey: key)
        }
        #expect(throws: CryptoInputError.wrongLength(.id, expected: 16)) {
            try KeyHierarchy.wrapVaultKey(unlockKey: key, accountId: Data(count: 8), vaultKey: key)
        }
    }
}

@Suite struct LoginSignatureTests {
    static func keys(_ password: String = "hunter2") throws -> DerivedKeys {
        try KeyDerivation.derive(
            password: password, secretKey: SecretKey(bytes: hex("8f3a1c5ed247b906e17d4ac3902bf865")),
            accountId: Data(count: 16), kdfSalt: Data(count: 16), kdfParams: KeyDerivationTests.cheap)
    }

    @Test func signThenVerifySucceeds() throws {
        let keys = try Self.keys()
        let nonce = LoginSignature.newNonce()
        let signature = try LoginSignature.sign(authPrivateKey: keys.authPrivateKey, nonce: nonce)
        #expect(signature.count == 64)
        #expect(nonce.count == 32)
        #expect(LoginSignature.verify(authPublicKey: keys.authPublicKey, nonce: nonce, signature: signature))
        // Ed25519 as libsodium does it is deterministic.
        #expect(try LoginSignature.sign(authPrivateKey: keys.authPrivateKey, nonce: nonce) == signature)
    }

    @Test func signatureCoversTheContextStringNotTheBareNonce() throws {
        let keys = try Self.keys()
        let nonce = LoginSignature.newNonce()
        // CryptoKit signs the bare nonce with the same key.
        let seed = keys.authPrivateKey.copyToData().prefix(32)
        let cryptoKitKey = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
        #expect(cryptoKitKey.publicKey.rawRepresentation == keys.authPublicKey)
        let bare = try cryptoKitKey.signature(for: nonce)
        #expect(!LoginSignature.verify(authPublicKey: keys.authPublicKey, nonce: nonce, signature: bare))

        // With the context in front, CryptoKit's signature verifies here and ours verifies there.
        let withContext = try cryptoKitKey.signature(for: Data("twonote/v1/login".utf8) + nonce)
        #expect(LoginSignature.verify(authPublicKey: keys.authPublicKey, nonce: nonce, signature: withContext))
        let ours = try LoginSignature.sign(authPrivateKey: keys.authPrivateKey, nonce: nonce)
        #expect(cryptoKitKey.publicKey.isValidSignature(ours, for: Data("twonote/v1/login".utf8) + nonce))
        #expect(!cryptoKitKey.publicKey.isValidSignature(ours, for: nonce))
    }

    @Test func wrongNonceKeyOrSignatureFails() throws {
        let keys = try Self.keys()
        let otherKeys = try Self.keys("another password")
        let nonce = LoginSignature.newNonce()
        let signature = try LoginSignature.sign(authPrivateKey: keys.authPrivateKey, nonce: nonce)

        #expect(!LoginSignature.verify(authPublicKey: keys.authPublicKey, nonce: LoginSignature.newNonce(), signature: signature))
        #expect(!LoginSignature.verify(authPublicKey: otherKeys.authPublicKey, nonce: nonce, signature: signature))
        for i in 0..<signature.count {
            var tampered = signature
            tampered[i] ^= 0x01
            #expect(!LoginSignature.verify(authPublicKey: keys.authPublicKey, nonce: nonce, signature: tampered))
        }
    }

    @Test func verifyReturnsFalseForMalformedInput() throws {
        let keys = try Self.keys()
        let nonce = LoginSignature.newNonce()
        let signature = try LoginSignature.sign(authPrivateKey: keys.authPrivateKey, nonce: nonce)
        let publicKey = keys.authPublicKey

        #expect(!LoginSignature.verify(authPublicKey: publicKey.prefix(31), nonce: nonce, signature: signature))
        #expect(!LoginSignature.verify(authPublicKey: publicKey, nonce: nonce.prefix(31), signature: signature))
        #expect(!LoginSignature.verify(authPublicKey: publicKey, nonce: nonce, signature: signature.prefix(63)))
        #expect(!LoginSignature.verify(authPublicKey: Data(), nonce: Data(), signature: Data()))
        #expect(!LoginSignature.verify(authPublicKey: Data(count: 32), nonce: nonce, signature: signature))
        #expect(!LoginSignature.verify(authPublicKey: publicKey, nonce: nonce, signature: Data(count: 64)))
        #expect(!LoginSignature.verify(authPublicKey: Data(repeating: 0xFF, count: 32), nonce: nonce, signature: signature))
    }

    @Test func signRejectsWrongLengths() throws {
        let keys = try Self.keys()
        let seedOnly = SecretBytes(copying: keys.authPrivateKey.copyToData().prefix(32))
        #expect(throws: CryptoInputError.wrongLength(.privateKey, expected: 64)) {
            try LoginSignature.sign(authPrivateKey: seedOnly, nonce: Data(count: 32))
        }
        #expect(throws: CryptoInputError.wrongLength(.nonce, expected: 32)) {
            try LoginSignature.sign(authPrivateKey: keys.authPrivateKey, nonce: Data(count: 31))
        }
        #expect(throws: CryptoInputError.wrongLength(.nonce, expected: 32)) {
            try LoginSignature.sign(authPrivateKey: keys.authPrivateKey, nonce: Data(count: 33))
        }
    }
}

@Suite struct WireEncodingTests {
    @Test func base64UrlHasNoPaddingAndUsesTheUrlAlphabet() {
        #expect(WireEncoding.base64URLString(Data([0xFB, 0xFF])) == "-_8")
        #expect(WireEncoding.base64URLString(Data([0x00])) == "AA")
        #expect(WireEncoding.base64URLString(Data()) == "")
        #expect(WireEncoding.data(base64URL: "-_8") == Data([0xFB, 0xFF]))
        #expect(WireEncoding.data(base64URL: "") == Data())
    }

    @Test func base64UrlRoundTripsEveryLengthAndAgreesWithFoundation() {
        for length in 0..<70 {
            let bytes = Data(Sodium.randomBytes(count: length))
            let text = WireEncoding.base64URLString(bytes)
            #expect(!text.contains("="))
            #expect(!text.contains("+"))
            #expect(!text.contains("/"))
            #expect(WireEncoding.data(base64URL: text) == bytes)

            let foundation = bytes.base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
            #expect(text == foundation)
        }
        let slice = Data([0xEE, 0xFB, 0xFF]).dropFirst()
        #expect(WireEncoding.base64URLString(slice) == "-_8")
    }

    @Test(arguments: [
        "AA==", "AA=", "+/8", "A", "AAAAA", "AA AA", "AAAA\n", " AAAA", "AA\u{E9}A", "AA.A",
        // Unused trailing bits that are not zero (.NET's Base64Url refuses these too).
        "AB", "AAB", "-_9", "AAAAAR",
    ])
    func base64UrlRejectsPaddingStandardAlphabetAndJunk(text: String) {
        #expect(WireEncoding.data(base64URL: text) == nil)
    }

    @Test func idsAreSixteenBytesAndThirtyTwoLowercaseHex() throws {
        let id = WireEncoding.newId()
        #expect(id.count == 16)
        let text = try WireEncoding.hexString(id: id)
        #expect(try /[0-9a-f]{32}/.wholeMatch(in: text) != nil)
        #expect(WireEncoding.id(hex: text) == id)
        #expect(WireEncoding.newId() != id)
        #expect(try WireEncoding.hexString(id: (Data([0xEE]) + id).dropFirst()) == text)
        #expect(try WireEncoding.hexString(id: hex("000102030405060708090A0B0C0D0E0F")) == "000102030405060708090a0b0c0d0e0f")
    }

    @Test(arguments: [
        "",
        "00112233445566778899aabbccddeef",
        "00112233445566778899aabbccddeeff0",
        "00112233445566778899AABBCCDDEEFF",
        "00112233445566778899aabbccddeefg",
        "00112233-4455-6677-8899-aabbccddeeff",
        " 0112233445566778899aabbccddeeff",
        "0x112233445566778899aabbccddeeff",
        "00112233445566778899aabbccddee\u{FF46}\u{FF46}",
    ])
    func malformedIdsAreRejected(text: String) {
        #expect(WireEncoding.id(hex: text) == nil)
    }

    @Test func hexStringRequiresSixteenBytes() {
        #expect(throws: CryptoInputError.wrongLength(.id, expected: 16)) { try WireEncoding.hexString(id: Data(count: 15)) }
        #expect(throws: CryptoInputError.wrongLength(.id, expected: 16)) { try WireEncoding.hexString(id: Data(count: 17)) }
    }
}

// Not part of the protocol: what the iOS app's share inbox is built on.
@Suite struct SealedBoxTests {
    @Test func whatIsSealedToAPublicKeyOpensOnlyWithItsPrivateKey() throws {
        let pair = SealedBox.generateKeyPair()
        #expect(pair.publicKey.count == 32 && pair.privateKey.count == 32)
        #expect(try SealedBox.publicKey(for: pair.privateKey) == pair.publicKey)

        let message = Data("Booming call heard at dawn".utf8)
        let sealed = try SealedBox.seal(message, to: pair.publicKey)
        #expect(sealed.count == message.count + SealedBox.overhead)
        #expect(sealed.range(of: message) == nil)
        #expect(try SealedBox.seal(message, to: pair.publicKey) != sealed, "a fresh ephemeral key every time")
        #expect(try SealedBox.open(sealed, publicKey: pair.publicKey, privateKey: pair.privateKey) == message)

        let empty = try SealedBox.seal(Data(), to: pair.publicKey)
        #expect(try SealedBox.open(empty, publicKey: pair.publicKey, privateKey: pair.privateKey) == Data())

        // Another key pair, a changed byte and a cut-off box all fail the same way.
        let other = SealedBox.generateKeyPair()
        #expect(other.publicKey != pair.publicKey)
        #expect(throws: SealedBoxError()) { try SealedBox.open(sealed, publicKey: other.publicKey, privateKey: other.privateKey) }
        #expect(throws: SealedBoxError()) { try SealedBox.open(sealed, publicKey: other.publicKey, privateKey: pair.privateKey) }
        var changed = sealed
        changed[changed.count - 1] ^= 1
        #expect(throws: SealedBoxError()) { try SealedBox.open(changed, publicKey: pair.publicKey, privateKey: pair.privateKey) }
        #expect(throws: SealedBoxError()) { try SealedBox.open(sealed.prefix(47), publicKey: pair.publicKey, privateKey: pair.privateKey) }
        #expect(throws: SealedBoxError()) { try SealedBox.open(Data(), publicKey: pair.publicKey, privateKey: pair.privateKey) }

        #expect(throws: CryptoInputError.wrongLength(.key, expected: 32)) { try SealedBox.seal(message, to: Data(count: 31)) }
        #expect(throws: CryptoInputError.wrongLength(.privateKey, expected: 32)) {
            try SealedBox.open(sealed, publicKey: pair.publicKey, privateKey: SecretBytes(copying: Data(count: 16)))
        }
    }

    @Test func aDeviceLocalBlobOpensOnlyUnderItsKeyAndLabelAndIsNeverAProtocolBlob() throws {
        let vaultKey = KeyHierarchy.createVaultKey()
        let secret = SecretBytes.random(count: 32)
        let blob = try SealedBlob.sealLocal(key: vaultKey, label: "share-inbox", secret: secret)
        #expect(blob.count == 32 + SealedBlob.overhead && blob.first == SealedBlob.version)
        #expect(try SealedBlob.openLocal(key: vaultKey, label: "share-inbox", blob: blob) == secret)

        #expect(throws: SealedBlobError.authenticationFailed) { try SealedBlob.openLocal(key: vaultKey, label: "other", blob: blob) }
        #expect(throws: SealedBlobError.authenticationFailed) {
            try SealedBlob.openLocal(key: KeyHierarchy.createVaultKey(), label: "share-inbox", blob: blob)
        }
        #expect(throws: SealedBlobError.truncated) { try SealedBlob.openLocal(key: vaultKey, label: "share-inbox", blob: blob.prefix(40)) }

        // Sealed under the vault key like a notebook key, but it does not open as one, nor as
        // anything else of the protocol; and a wrapped notebook key does not open as a local blob.
        let id = WireEncoding.newId()
        for kind in BlobKind.allCases {
            #expect(throws: SealedBlobError.authenticationFailed) { try SealedBlob.open(key: vaultKey, kind: kind, id: id, blob: blob) }
        }
        let wrapped = try KeyHierarchy.wrapNotebookKey(vaultKey: vaultKey, notebookId: id, notebookKey: KeyHierarchy.createNotebookKey())
        #expect(throws: SealedBlobError.authenticationFailed) { try SealedBlob.openLocal(key: vaultKey, label: "share-inbox", blob: wrapped) }
        #expect(throws: CryptoInputError.wrongLength(.key, expected: 32)) {
            try SealedBlob.sealLocal(key: SecretBytes(copying: Data(count: 16)), label: "x", secret: secret)
        }
    }
}

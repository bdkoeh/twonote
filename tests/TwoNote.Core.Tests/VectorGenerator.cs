using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using TwoNote.Core.Crypto;

namespace TwoNote.Core.Tests;

/// <summary>
/// Builds docs/test-vectors.json from fixed inputs and this implementation. The file in the
/// repo is the contract; <see cref="VectorFileTests"/> checks it still matches, and
/// crosscheck/verify_vectors.py checks it against independent implementations.
/// To rewrite the file after a deliberate protocol change:
/// <c>$env:TWONOTE_WRITE_VECTORS='1'; dotnet test tests/TwoNote.Core.Tests</c>
/// </summary>
internal static class VectorGenerator
{
    private const string SecretKeyHex = "8f3a1c5ed247b906e17d4ac3902bf865";
    private const string AccountIdHex = "a1b2c3d4e5f60718293a4b5c6d7e8f90";
    private const string NotebookIdHex = "0f1e2d3c4b5a69788796a5b4c3d2e1f0";
    private const string DocIdHex = "00112233445566778899aabbccddeeff";
    private const string VaultKeyHex = "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f";
    private const string NotebookKeyHex = "f0e1d2c3b4a5968778695a4b3c2d1e0fffeeddccbbaa99887766554433221100";
    private const string LoginNonceHex = "6c6f67696e2d6e6f6e63652d666f722d74776f6e6f74652d766563746f727321";

    public static JsonSerializerOptions JsonOptions { get; } = new() { WriteIndented = true };

    public static JsonObject Build()
    {
        var secretKey = Hex(SecretKeyHex);
        var accountId = Hex(AccountIdHex);

        var kdfCases = new JsonArray
        {
            KdfCase("ascii", "correct horse battery staple", secretKey, accountId,
                Hex("202122232425262728292a2b2c2d2e2f"), out var unlockKey, out var authSeed, out var authPublicKey),

            // Fullwidth p, a + combining diaeresis, o + combining diaeresis, the fi ligature,
            // circled digit one and the angstrom sign: NFKC turns this into "pässwörd fi1 Å".
            KdfCase("nfkc", "ｐässwörd ﬁ① Å", secretKey, accountId,
                Hex("303132333435363738393a3b3c3d3e3f"), out _, out _, out _),
        };

        var vaultKey = Hex(VaultKeyHex);
        var notebookKey = Hex(NotebookKeyHex);
        var sealedCases = new JsonArray
        {
            SealedCase("vault", BlobKind.Vault, unlockKey, accountId, vaultKey,
                Hex("404142434445464748494a4b4c4d4e4f5051525354555657")),
            SealedCase("nbkey", BlobKind.NotebookKey, vaultKey, Hex(NotebookIdHex), notebookKey,
                Hex("606162636465666768696a6b6c6d6e6f7071727374757677")),
            SealedCase("update", BlobKind.Update, notebookKey, Hex(DocIdHex),
                Encoding.UTF8.GetBytes("stand-in for one Yjs v1 update"),
                Hex("808182838485868788898a8b8c8d8e8f9091929394959697")),
            SealedCase("snapshot", BlobKind.Snapshot, notebookKey, Hex(DocIdHex),
                Encoding.UTF8.GetBytes("stand-in for a Yjs v1 full-state update"),
                Hex("a0a1a2a3a4a5a6a7a8a9aaabacadaeafb0b1b2b3b4b5b6b7")),
            SealedCase("update-empty-plaintext", BlobKind.Update, notebookKey, Hex(DocIdHex), [],
                Hex("c0c1c2c3c4c5c6c7c8c9cacbcccdcecfd0d1d2d3d4d5d6d7")),
        };

        return new JsonObject
        {
            ["description"] = "TwoNote protocol v1 test vectors for PROTOCOL.md sections 1.1 to 1.4. "
                + "Every client implementation must reproduce every expected value.",
            ["binaryEncoding"] = "All binary values are lowercase hex. Strings are JSON strings; "
                + "non-ASCII characters are written as \\u escapes.",
            ["secretKey"] = SecretKeySection(secretKey),
            ["keyDerivation"] = kdfCases,
            ["sealedBlob"] = sealedCases,
            ["loginSignature"] = LoginSection(authSeed, authPublicKey),
            ["wireEncoding"] = WireEncodingSection(),
        };
    }

    private static JsonObject SecretKeySection(byte[] bytes)
    {
        using var key = SecretKey.FromBytes(bytes);
        var formatted = key.Format();
        var body = formatted["T2-".Length..];

        var accepted = new JsonArray
        {
            formatted,
            formatted.ToLowerInvariant(),
            formatted.Replace("-", string.Empty),
            "  " + formatted.Replace("-", " ") + "  ",
            "T2-" + body.Replace('0', 'O').Replace('1', 'I'),
            "t2-" + body.ToLowerInvariant().Replace('0', 'o').Replace('1', 'l'),
            body,
        };

        var rejected = new JsonArray
        {
            string.Empty,
            "T2-",
            formatted[..^1],
            formatted + "0",
            "T3-" + body,
            // U is not in the Crockford alphabet.
            "T2-" + "U" + body[1..],
            // The last character carries only three key bits; its two low bits must be zero.
            formatted[..^1] + "1",
            "T2-" + body.Replace('-', '_'),
        };

        return new JsonObject
        {
            ["bytes"] = Convert.ToHexStringLower(bytes),
            ["formatted"] = formatted,
            ["accepted"] = accepted,
            ["rejected"] = rejected,
        };
    }

    private static JsonObject KdfCase(
        string name, string password, byte[] secretKey, byte[] accountId, byte[] kdfSalt,
        out byte[] unlockKey, out byte[] authSeed, out byte[] authPublicKey)
    {
        var buffer = new byte[DerivationTrace.Size];
        var trace = new DerivationTrace(buffer);
        KeyDerivation.DeriveCore(password, secretKey, accountId, kdfSalt, KdfParams.Default, trace);

        using var keys = KeyDerivation.Derive(password, secretKey, accountId, kdfSalt, KdfParams.Default);
        unlockKey = trace.UnlockKey.ToArray();
        authSeed = trace.AuthSeed.ToArray();
        authPublicKey = keys.AuthPublicKey.ToArray();

        return new JsonObject
        {
            ["name"] = name,
            ["password"] = password,
            ["passwordNfkcUtf8"] = Convert.ToHexStringLower(KeyDerivation.NormalisePassword(password)),
            ["secretKey"] = Convert.ToHexStringLower(secretKey),
            ["accountId"] = Convert.ToHexStringLower(accountId),
            ["kdfSalt"] = Convert.ToHexStringLower(kdfSalt),
            ["kdfParams"] = new JsonObject
            {
                ["alg"] = KdfParams.Default.Alg,
                ["ops"] = KdfParams.Default.Ops,
                ["memKiB"] = KdfParams.Default.MemKiB,
            },
            ["kPw"] = Convert.ToHexStringLower(trace.KPw),
            ["kSk"] = Convert.ToHexStringLower(trace.KSk),
            ["root"] = Convert.ToHexStringLower(trace.Root),
            ["unlockKey"] = Convert.ToHexStringLower(trace.UnlockKey),
            ["authSeed"] = Convert.ToHexStringLower(trace.AuthSeed),
            ["authPublicKey"] = Convert.ToHexStringLower(authPublicKey),
        };
    }

    private static JsonObject SealedCase(string name, BlobKind kind, byte[] key, byte[] id, byte[] plaintext, byte[] nonce) =>
        new()
        {
            ["name"] = name,
            ["kind"] = SealedBlob.KindName(kind),
            ["key"] = Convert.ToHexStringLower(key),
            ["id"] = Convert.ToHexStringLower(id),
            ["nonce"] = Convert.ToHexStringLower(nonce),
            ["plaintext"] = Convert.ToHexStringLower(plaintext),
            ["aad"] = SealedBlob.AdditionalData(kind, id),
            ["blob"] = Convert.ToHexStringLower(SealedBlob.SealWithNonce(key, kind, id, plaintext, nonce)),
        };

    private static JsonObject LoginSection(byte[] authSeed, byte[] authPublicKey)
    {
        var nonce = Hex(LoginNonceHex);

        // libsodium's 64-byte private key is the seed followed by the public key.
        byte[] privateKey = [.. authSeed, .. authPublicKey];
        return new JsonObject
        {
            ["note"] = "authSeed and authPublicKey are those of the keyDerivation case named ascii.",
            ["authSeed"] = Convert.ToHexStringLower(authSeed),
            ["authPublicKey"] = Convert.ToHexStringLower(authPublicKey),
            ["nonce"] = Convert.ToHexStringLower(nonce),
            ["message"] = Convert.ToHexStringLower([.. "twonote/v1/login"u8, .. nonce]),
            ["signature"] = Convert.ToHexStringLower(LoginSignature.Sign(privateKey, nonce)),
        };
    }

    private static JsonObject WireEncodingSection()
    {
        var base64Url = new JsonArray();
        foreach (var hex in new[] { string.Empty, "00", "fbff", "fbffbe", "00112233445566778899aabbccddeeff", LoginNonceHex })
        {
            base64Url.Add(new JsonObject
            {
                ["bytes"] = hex,
                ["text"] = WireEncoding.ToBase64Url(Hex(hex)),
            });
        }

        return new JsonObject
        {
            ["base64Url"] = base64Url,
            ["id"] = new JsonObject
            {
                ["bytes"] = AccountIdHex,
                ["text"] = WireEncoding.IdToHex(Hex(AccountIdHex)),
            },
        };
    }

    private static byte[] Hex(string hex) => Convert.FromHexString(hex);
}

using System.Text.Json;
using System.Text.Json.Nodes;
using TwoNote.Core.Crypto;
using Xunit;

namespace TwoNote.Core.Tests;

/// <summary>Asserts the implementation against docs/test-vectors.json (PROTOCOL.md 1.5).</summary>
public class VectorFileTests
{
    private static readonly JsonNode Vectors = Load();

    private static JsonNode Load()
    {
        var path = Path.Combine(AppContext.BaseDirectory, "test-vectors.json");
        return JsonNode.Parse(File.ReadAllText(path))
            ?? throw new InvalidOperationException("test-vectors.json is empty.");
    }

    private static byte[] Hex(JsonNode? node) => Convert.FromHexString(node!.GetValue<string>());

    private static string Str(JsonNode? node) => node!.GetValue<string>();

    public static TheoryData<string> KdfCaseNames() => Names("keyDerivation");

    public static TheoryData<string> SealedCaseNames() => Names("sealedBlob");

    private static TheoryData<string> Names(string section)
    {
        var data = new TheoryData<string>();
        foreach (var item in Vectors[section]!.AsArray())
        {
            data.Add(Str(item!["name"]));
        }

        return data;
    }

    private static JsonNode Case(string section, string name) =>
        Vectors[section]!.AsArray().Single(c => Str(c!["name"]) == name)!;

    [Fact]
    public void File_matches_what_the_generator_produces()
    {
        var generated = VectorGenerator.Build();

        if (Environment.GetEnvironmentVariable("TWONOTE_WRITE_VECTORS") == "1")
        {
            var docs = FindDocsDirectory();
            File.WriteAllText(
                Path.Combine(docs, "test-vectors.json"),
                generated.ToJsonString(VectorGenerator.JsonOptions).ReplaceLineEndings("\n") + "\n");
            return;
        }

        Assert.True(
            JsonNode.DeepEquals(generated, Vectors),
            "docs/test-vectors.json no longer matches the implementation. If the protocol changed on purpose, "
            + "regenerate with TWONOTE_WRITE_VECTORS=1 and re-run crosscheck/verify_vectors.py.");
    }

    [Fact]
    public void Secret_key_formats_as_in_the_vectors()
    {
        var section = Vectors["secretKey"]!;
        using var key = SecretKey.FromBytes(Hex(section["bytes"]));
        Assert.Equal(Str(section["formatted"]), key.Format());
    }

    [Fact]
    public void Secret_key_accepted_forms_parse_to_the_vector_bytes()
    {
        var section = Vectors["secretKey"]!;
        var expected = Hex(section["bytes"]);
        var accepted = section["accepted"]!.AsArray();
        Assert.NotEmpty(accepted);
        foreach (var text in accepted)
        {
            Assert.True(SecretKey.TryParse(Str(text), out var key), $"should parse: '{Str(text)}'");
            using (key)
            {
                Assert.Equal(expected, key.Bytes.ToArray());
            }
        }
    }

    [Fact]
    public void Secret_key_rejected_forms_do_not_parse()
    {
        var rejected = Vectors["secretKey"]!["rejected"]!.AsArray();
        Assert.NotEmpty(rejected);
        foreach (var text in rejected)
        {
            Assert.False(SecretKey.TryParse(Str(text), out _), $"should not parse: '{Str(text)}'");
            Assert.Throws<FormatException>(() => SecretKey.Parse(Str(text)));
        }
    }

    [Theory]
    [MemberData(nameof(KdfCaseNames))]
    public void Key_derivation_uses_the_real_argon2_parameters(string name)
    {
        var p = Case("keyDerivation", name)["kdfParams"]!;
        Assert.Equal("argon2id13", Str(p["alg"]));
        Assert.Equal(3, p["ops"]!.GetValue<int>());
        Assert.Equal(65536, p["memKiB"]!.GetValue<int>());

        var parsed = p.Deserialize<KdfParams>();
        Assert.Equal(KdfParams.Default, parsed);
    }

    [Theory]
    [MemberData(nameof(KdfCaseNames))]
    public void Key_derivation_matches_every_intermediate_value(string name)
    {
        var c = Case("keyDerivation", name);
        var kdfParams = c["kdfParams"].Deserialize<KdfParams>()!;

        Assert.Equal(Hex(c["passwordNfkcUtf8"]), KeyDerivation.NormalisePassword(Str(c["password"])));

        var buffer = new byte[DerivationTrace.Size];
        var trace = new DerivationTrace(buffer);
        KeyDerivation.DeriveCore(
            Str(c["password"]), Hex(c["secretKey"]), Hex(c["accountId"]), Hex(c["kdfSalt"]), kdfParams, trace);

        Assert.Equal(Hex(c["kPw"]), trace.KPw.ToArray());
        Assert.Equal(Hex(c["kSk"]), trace.KSk.ToArray());
        Assert.Equal(Hex(c["root"]), trace.Root.ToArray());
        Assert.Equal(Hex(c["unlockKey"]), trace.UnlockKey.ToArray());
        Assert.Equal(Hex(c["authSeed"]), trace.AuthSeed.ToArray());
    }

    [Theory]
    [MemberData(nameof(KdfCaseNames))]
    public void Key_derivation_public_api_matches_the_vectors(string name)
    {
        var c = Case("keyDerivation", name);
        using var secretKey = SecretKey.FromBytes(Hex(c["secretKey"]));
        using var keys = KeyDerivation.Derive(
            Str(c["password"]), secretKey, Hex(c["accountId"]), Hex(c["kdfSalt"]), c["kdfParams"].Deserialize<KdfParams>()!);

        Assert.Equal(Hex(c["unlockKey"]), keys.UnlockKey.ToArray());
        Assert.Equal(Hex(c["authPublicKey"]), keys.AuthPublicKey.ToArray());

        // libsodium private key layout: seed || public key.
        Assert.Equal(Hex(c["authSeed"]), keys.AuthPrivateKey[..32].ToArray());
        Assert.Equal(Hex(c["authPublicKey"]), keys.AuthPrivateKey[32..].ToArray());
    }

    [Fact]
    public void Nfkc_case_really_is_changed_by_normalisation()
    {
        var c = Case("keyDerivation", "nfkc");
        var raw = System.Text.Encoding.UTF8.GetBytes(Str(c["password"]));
        Assert.NotEqual(raw, Hex(c["passwordNfkcUtf8"]));
        Assert.Equal("pässwörd fi1 Å", System.Text.Encoding.UTF8.GetString(Hex(c["passwordNfkcUtf8"])));
    }

    [Theory]
    [MemberData(nameof(SealedCaseNames))]
    public void Sealed_blob_matches_the_vectors(string name)
    {
        var c = Case("sealedBlob", name);
        var kind = KindFromName(Str(c["kind"]));
        var key = Hex(c["key"]);
        var id = Hex(c["id"]);
        var plaintext = Hex(c["plaintext"]);
        var blob = Hex(c["blob"]);

        Assert.Equal(Str(c["aad"]), SealedBlob.AdditionalData(kind, id));
        Assert.Equal(blob, SealedBlob.SealWithNonce(key, kind, id, plaintext, Hex(c["nonce"])));
        Assert.Equal(plaintext, SealedBlob.Open(key, kind, id, blob));

        Assert.Equal(0x01, blob[0]);
        Assert.Equal(Hex(c["nonce"]), blob[1..25]);
        Assert.Equal(plaintext.Length + 41, blob.Length);
    }

    [Fact]
    public void Sealed_blob_vectors_cover_every_kind()
    {
        var kinds = Vectors["sealedBlob"]!.AsArray().Select(c => Str(c!["kind"])).ToHashSet();
        Assert.Superset(new HashSet<string> { "vault", "nbkey", "update", "snapshot" }, kinds);
    }

    [Fact]
    public void Vault_vector_unwraps_through_the_key_hierarchy()
    {
        var vault = Case("sealedBlob", "vault");
        using var vaultKey = KeyHierarchy.UnwrapVaultKey(Hex(vault["key"]), Hex(vault["id"]), Hex(vault["blob"]));
        Assert.Equal(Hex(vault["plaintext"]), vaultKey.Span.ToArray());

        // The vault case is keyed by the unlockKey of the first derivation case, end to end.
        Assert.Equal(Str(Case("keyDerivation", "ascii")["unlockKey"]), Str(vault["key"]));

        var nb = Case("sealedBlob", "nbkey");
        using var notebookKey = KeyHierarchy.UnwrapNotebookKey(vaultKey.Span, Hex(nb["id"]), Hex(nb["blob"]));
        Assert.Equal(Hex(nb["plaintext"]), notebookKey.Span.ToArray());
    }

    [Fact]
    public void Login_signature_matches_the_vectors()
    {
        var s = Vectors["loginSignature"]!;
        var nonce = Hex(s["nonce"]);
        var publicKey = Hex(s["authPublicKey"]);
        byte[] privateKey = [.. Hex(s["authSeed"]), .. publicKey];

        byte[] message = [.. "twonote/v1/login"u8, .. nonce];
        Assert.Equal(Hex(s["message"]), message);
        Assert.Equal(Hex(s["signature"]), LoginSignature.Sign(privateKey, nonce));
        Assert.True(LoginSignature.Verify(publicKey, nonce, Hex(s["signature"])));
    }

    [Fact]
    public void Wire_encoding_matches_the_vectors()
    {
        var section = Vectors["wireEncoding"]!;
        foreach (var item in section["base64Url"]!.AsArray())
        {
            Assert.Equal(Str(item!["text"]), WireEncoding.ToBase64Url(Hex(item["bytes"])));
            Assert.Equal(Hex(item["bytes"]), WireEncoding.FromBase64Url(Str(item["text"])));
        }

        var id = section["id"]!;
        Assert.Equal(Str(id["text"]), WireEncoding.IdToHex(Hex(id["bytes"])));
        Assert.Equal(Hex(id["bytes"]), WireEncoding.IdFromHex(Str(id["text"])));
    }

    private static BlobKind KindFromName(string name) =>
        Enum.GetValues<BlobKind>().Single(k => SealedBlob.KindName(k) == name);

    private static string FindDocsDirectory()
    {
        for (var dir = new DirectoryInfo(AppContext.BaseDirectory); dir is not null; dir = dir.Parent)
        {
            var docs = Path.Combine(dir.FullName, "docs");
            if (File.Exists(Path.Combine(docs, "PROTOCOL.md")))
            {
                return docs;
            }
        }

        throw new InvalidOperationException("Could not find the docs directory above the test output.");
    }
}

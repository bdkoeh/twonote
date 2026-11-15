using System.Security.Cryptography;
using System.Text.Json;
using TwoNote.Core.Crypto;
using Xunit;

namespace TwoNote.Core.Tests;

public class SecretKeyTests
{
    [Fact]
    public void Generate_gives_distinct_keys_in_the_display_shape()
    {
        using var a = SecretKey.Generate();
        using var b = SecretKey.Generate();
        Assert.NotEqual(a.Bytes.ToArray(), b.Bytes.ToArray());
        Assert.Matches("^T2-[0-9A-HJKMNP-TV-Z]{6}-[0-9A-HJKMNP-TV-Z]{6}-[0-9A-HJKMNP-TV-Z]{6}-[0-9A-HJKMNP-TV-Z]{8}$", a.Format());
    }

    [Fact]
    public void Format_then_parse_round_trips_many_keys()
    {
        for (var i = 0; i < 500; i++)
        {
            using var key = SecretKey.Generate();
            using var parsed = SecretKey.Parse(key.Format());
            Assert.Equal(key.Bytes.ToArray(), parsed.Bytes.ToArray());
        }
    }

    [Fact]
    public void Edge_values_round_trip()
    {
        foreach (var fill in new byte[] { 0x00, 0xFF, 0xA5 })
        {
            var bytes = new byte[16];
            Array.Fill(bytes, fill);
            using var key = SecretKey.FromBytes(bytes);
            using var parsed = SecretKey.Parse(key.Format());
            Assert.Equal(bytes, parsed.Bytes.ToArray());
        }

        using var zero = SecretKey.FromBytes(new byte[16]);
        Assert.Equal("T2-000000-000000-000000-00000000", zero.Format());
    }

    [Theory]
    [InlineData("t2-oooooo-OOOOOO-000000-00000000")]
    [InlineData("T2 000000 000000 000000 00000000")]
    [InlineData("T200000000000000000000000000")]
    [InlineData("00000000000000000000000000")]
    [InlineData("\tT2-000000-\n000000-000000-00000000 ")]
    [InlineData("T2--000000-00000000-0000-0000-0000")]
    public void Parse_tolerates_case_separators_and_lookalikes(string text)
    {
        using var key = SecretKey.Parse(text);
        Assert.Equal(new byte[16], key.Bytes.ToArray());
    }

    [Fact]
    public void Lookalike_letters_map_to_digits()
    {
        using var ones = SecretKey.Parse("T2-111111-111111-111111-11111110");
        using var letters = SecretKey.Parse("t2-IiLlIi-LlIiLl-IiLlIi-LlIiLlIO");
        Assert.Equal(ones.Bytes.ToArray(), letters.Bytes.ToArray());
    }

    [Theory]
    [InlineData("")]
    [InlineData("T2")]
    [InlineData("T2-000000-000000-000000-0000000")]
    [InlineData("T2-000000-000000-000000-000000000")]
    [InlineData("T2-U00000-000000-000000-00000000")]
    [InlineData("T2-00000!-000000-000000-00000000")]
    [InlineData("T2-000000-000000-000000-00000001")]
    [InlineData("T2-000000-000000-000000-00000002")]
    [InlineData("X2-000000-000000-000000-00000000")]
    [InlineData("T2-000000-000000-000000-0000000é")]
    public void Parse_rejects_malformed_input(string text)
    {
        Assert.False(SecretKey.TryParse(text, out var key));
        Assert.Null(key);
        var e = Assert.Throws<FormatException>(() => SecretKey.Parse(text));
        if (text.Length > 4)
        {
            Assert.DoesNotContain(text, e.Message);
        }
    }

    [Fact]
    public void Parse_rejects_absurdly_long_input()
    {
        Assert.False(SecretKey.TryParse(new string('-', 100_000), out _));
    }

    [Fact]
    public void FromBytes_requires_sixteen_bytes()
    {
        Assert.Throws<ArgumentException>(() => SecretKey.FromBytes(new byte[15]));
        Assert.Throws<ArgumentException>(() => SecretKey.FromBytes(new byte[17]));
    }

    [Fact]
    public void ToString_does_not_reveal_the_key_and_dispose_blocks_access()
    {
        var key = SecretKey.Generate();
        var formatted = key.Format();
        Assert.DoesNotContain(formatted[3..9], key.ToString());
        key.Dispose();
        Assert.Throws<ObjectDisposedException>(() => key.Bytes.ToArray());
        Assert.Throws<ObjectDisposedException>(() => key.Format());
    }
}

public class SecretBytesTests
{
    [Fact]
    public void Dispose_blocks_further_access_and_is_idempotent()
    {
        var secret = SecretBytes.CopyFrom([1, 2, 3]);
        Assert.Equal(3, secret.Length);
        Assert.Equal(new byte[] { 1, 2, 3 }, secret.Span.ToArray());
        Assert.DoesNotContain("1", secret.ToString().Replace("(3 bytes", string.Empty));
        secret.Dispose();
        secret.Dispose();
        Assert.Throws<ObjectDisposedException>(() => secret.Span.ToArray());
    }

    [Fact]
    public void Random_is_random()
    {
        using var a = SecretBytes.Random(32);
        using var b = SecretBytes.Random(32);
        Assert.NotEqual(a.Span.ToArray(), b.Span.ToArray());
        Assert.Throws<ArgumentOutOfRangeException>(() => SecretBytes.Random(0));
    }
}

public class KeyDerivationTests
{
    private static readonly byte[] Sk = Convert.FromHexString("8f3a1c5ed247b906e17d4ac3902bf865");
    private static readonly byte[] AccountId = Convert.FromHexString("a1b2c3d4e5f60718293a4b5c6d7e8f90");
    private static readonly byte[] Salt = Convert.FromHexString("202122232425262728292a2b2c2d2e2f");

    // Derivation cost is not what these tests are about; the vector tests run the real parameters.
    private static readonly KdfParams Cheap = new(KdfParams.Argon2id13, 1, KdfParams.MinMemKiB);

    private static (string Unlock, string Public) Derive(
        string password, byte[]? sk = null, byte[]? accountId = null, byte[]? salt = null, KdfParams? p = null)
    {
        using var keys = KeyDerivation.Derive(password, sk ?? Sk, accountId ?? AccountId, salt ?? Salt, p ?? Cheap);
        return (Convert.ToHexStringLower(keys.UnlockKey), Convert.ToHexStringLower(keys.AuthPublicKey));
    }

    [Fact]
    public void Default_parameters_are_three_passes_over_64_MiB()
    {
        Assert.Equal("argon2id13", KdfParams.Default.Alg);
        Assert.Equal(3, KdfParams.Default.Ops);
        Assert.Equal(65536, KdfParams.Default.MemKiB);
        Assert.True(KdfParams.Default.IsSupported);
    }

    [Fact]
    public void KdfParams_serialise_with_the_protocol_field_names()
    {
        var json = JsonSerializer.Serialize(KdfParams.Default);
        Assert.Equal("""{"alg":"argon2id13","ops":3,"memKiB":65536}""", json);
        Assert.Equal(KdfParams.Default, JsonSerializer.Deserialize<KdfParams>(json));
    }

    [Fact]
    public void Derivation_is_deterministic()
    {
        Assert.Equal(Derive("hunter2"), Derive("hunter2"));
    }

    [Fact]
    public void Canonically_equivalent_passwords_derive_the_same_keys()
    {
        // Precomposed, decomposed and compatibility forms of the same text.
        var composed = Derive("pässwörd fi1");
        Assert.Equal(composed, Derive("pässwörd fi1"));
        Assert.Equal(composed, Derive("ｐässwörd ﬁ1"));
    }

    [Fact]
    public void Every_input_changes_the_output()
    {
        var baseline = Derive("hunter2");
        var other = (byte[])Sk.Clone();
        other[0] ^= 1;

        var variants = new[]
        {
            Derive("hunter3"),
            Derive("Hunter2"),
            Derive("hunter2 "),
            Derive("hunter2", sk: other),
            Derive("hunter2", accountId: WireEncoding.NewId()),
            Derive("hunter2", salt: KeyDerivation.NewSalt()),
            Derive("hunter2", p: Cheap with { Ops = 2 }),
            Derive("hunter2", p: Cheap with { MemKiB = KdfParams.MinMemKiB * 2 }),
        };

        foreach (var v in variants)
        {
            Assert.NotEqual(baseline.Unlock, v.Unlock);
            Assert.NotEqual(baseline.Public, v.Public);
        }
    }

    [Fact]
    public void Unlock_key_and_auth_seed_are_different_keys()
    {
        using var keys = KeyDerivation.Derive("hunter2", Sk, AccountId, Salt, Cheap);
        Assert.Equal(32, keys.UnlockKey.Length);
        Assert.Equal(64, keys.AuthPrivateKey.Length);
        Assert.Equal(32, keys.AuthPublicKey.Length);
        Assert.NotEqual(keys.UnlockKey.ToArray(), keys.AuthPrivateKey[..32].ToArray());
    }

    [Fact]
    public void Wrong_lengths_and_unsupported_parameters_are_rejected()
    {
        Assert.Throws<ArgumentException>(() => Derive("x", sk: new byte[15]));
        Assert.Throws<ArgumentException>(() => Derive("x", accountId: new byte[17]));
        Assert.Throws<ArgumentException>(() => Derive("x", salt: new byte[8]));
        Assert.Throws<ArgumentException>(() => Derive("x", p: new KdfParams("scrypt", 3, 65536)));
        Assert.Throws<ArgumentException>(() => Derive("x", p: new KdfParams("argon2id13", 0, 65536)));
        Assert.Throws<ArgumentException>(() => Derive("x", p: new KdfParams("argon2id13", 3, 1024)));
        Assert.Throws<ArgumentException>(() => Derive("x", p: new KdfParams("argon2id13", 3, int.MaxValue)));
        Assert.Throws<ArgumentException>(() => Derive("x", p: new KdfParams("argon2id13", 1000, 65536)));
    }

    [Fact]
    public void Password_with_a_lone_surrogate_is_rejected_cleanly()
    {
        Assert.Throws<ArgumentException>(() => Derive("abc\uD800def"));
    }

    [Fact]
    public void Disposed_keys_cannot_be_read()
    {
        var keys = KeyDerivation.Derive("hunter2", Sk, AccountId, Salt, Cheap);
        keys.Dispose();
        Assert.Throws<ObjectDisposedException>(() => keys.UnlockKey.ToArray());
        Assert.Throws<ObjectDisposedException>(() => keys.AuthPrivateKey.ToArray());
    }
}

public class SealedBlobTests
{
    private static readonly byte[] Key = RandomNumberGenerator.GetBytes(32);
    private static readonly byte[] Id = WireEncoding.NewId();
    private static readonly byte[] Plaintext = "some Yjs update bytes"u8.ToArray();

    private static void AssertFails(SealedBlobError expected, byte[] key, BlobKind kind, byte[] id, byte[] blob)
    {
        var e = Assert.Throws<SealedBlobException>(() => SealedBlob.Open(key, kind, id, blob));
        Assert.Equal(expected, e.Error);
        Assert.False(SealedBlob.TryOpen(key, kind, id, blob, out var plaintext));
        Assert.Null(plaintext);
    }

    [Theory]
    [InlineData(BlobKind.Vault)]
    [InlineData(BlobKind.NotebookKey)]
    [InlineData(BlobKind.Update)]
    [InlineData(BlobKind.Snapshot)]
    public void Seal_then_open_round_trips(BlobKind kind)
    {
        var blob = SealedBlob.Seal(Key, kind, Id, Plaintext);
        Assert.Equal(Plaintext, SealedBlob.Open(Key, kind, Id, blob));
        Assert.True(SealedBlob.TryOpen(Key, kind, Id, blob, out var opened));
        Assert.Equal(Plaintext, opened);
    }

    [Theory]
    [InlineData(0)]
    [InlineData(1)]
    [InlineData(100_000)]
    public void Round_trips_any_plaintext_length(int length)
    {
        var plaintext = RandomNumberGenerator.GetBytes(length);
        var blob = SealedBlob.Seal(Key, BlobKind.Update, Id, plaintext);
        Assert.Equal(length + SealedBlob.Overhead, blob.Length);
        Assert.Equal(plaintext, SealedBlob.Open(Key, BlobKind.Update, Id, blob));
    }

    [Fact]
    public void Blob_layout_is_version_then_nonce_then_ciphertext()
    {
        var a = SealedBlob.Seal(Key, BlobKind.Update, Id, Plaintext);
        var b = SealedBlob.Seal(Key, BlobKind.Update, Id, Plaintext);
        Assert.Equal(41, SealedBlob.Overhead);
        Assert.Equal(1 + 24 + Plaintext.Length + 16, a.Length);
        Assert.Equal(0x01, a[0]);

        // A fresh random nonce every time, so the same plaintext never seals to the same bytes.
        Assert.NotEqual(a[1..25], b[1..25]);
        Assert.NotEqual(a[25..], b[25..]);
    }

    [Fact]
    public void Additional_data_is_the_protocol_string()
    {
        var id = Convert.FromHexString("00112233445566778899AABBCCDDEEFF");
        Assert.Equal("twonote/v1|vault|00112233445566778899aabbccddeeff", SealedBlob.AdditionalData(BlobKind.Vault, id));
        Assert.Equal("twonote/v1|nbkey|00112233445566778899aabbccddeeff", SealedBlob.AdditionalData(BlobKind.NotebookKey, id));
        Assert.Equal("twonote/v1|update|00112233445566778899aabbccddeeff", SealedBlob.AdditionalData(BlobKind.Update, id));
        Assert.Equal("twonote/v1|snapshot|00112233445566778899aabbccddeeff", SealedBlob.AdditionalData(BlobKind.Snapshot, id));
    }

    [Fact]
    public void Wrong_key_fails()
    {
        var blob = SealedBlob.Seal(Key, BlobKind.Update, Id, Plaintext);
        var wrong = (byte[])Key.Clone();
        wrong[31] ^= 0x80;
        AssertFails(SealedBlobError.AuthenticationFailed, wrong, BlobKind.Update, Id, blob);
    }

    [Fact]
    public void Wrong_kind_fails()
    {
        var blob = SealedBlob.Seal(Key, BlobKind.Update, Id, Plaintext);
        foreach (var kind in new[] { BlobKind.Snapshot, BlobKind.Vault, BlobKind.NotebookKey })
        {
            AssertFails(SealedBlobError.AuthenticationFailed, Key, kind, Id, blob);
        }
    }

    [Fact]
    public void Wrong_id_fails()
    {
        var blob = SealedBlob.Seal(Key, BlobKind.Update, Id, Plaintext);
        var other = (byte[])Id.Clone();
        other[0] ^= 1;
        AssertFails(SealedBlobError.AuthenticationFailed, Key, BlobKind.Update, other, blob);
    }

    [Fact]
    public void Every_truncation_fails()
    {
        var blob = SealedBlob.Seal(Key, BlobKind.Update, Id, Plaintext);
        for (var length = 0; length < blob.Length; length++)
        {
            var expected = length < SealedBlob.Overhead ? SealedBlobError.Truncated : SealedBlobError.AuthenticationFailed;
            AssertFails(expected, Key, BlobKind.Update, Id, blob[..length]);
        }
    }

    [Fact]
    public void Trailing_garbage_fails()
    {
        var blob = SealedBlob.Seal(Key, BlobKind.Update, Id, Plaintext);
        AssertFails(SealedBlobError.AuthenticationFailed, Key, BlobKind.Update, Id, [.. blob, 0x00]);
    }

    [Theory]
    [InlineData(0x00)]
    [InlineData(0x02)]
    [InlineData(0xFF)]
    public void Wrong_version_fails(byte version)
    {
        var blob = SealedBlob.Seal(Key, BlobKind.Update, Id, Plaintext);
        blob[0] = version;
        AssertFails(SealedBlobError.UnsupportedVersion, Key, BlobKind.Update, Id, blob);
    }

    [Fact]
    public void Flipping_any_single_byte_fails()
    {
        var blob = SealedBlob.Seal(Key, BlobKind.Update, Id, Plaintext);
        for (var i = 1; i < blob.Length; i++)
        {
            var tampered = (byte[])blob.Clone();
            tampered[i] ^= 0x01;
            AssertFails(SealedBlobError.AuthenticationFailed, Key, BlobKind.Update, Id, tampered);
        }
    }

    [Fact]
    public void Caller_bugs_are_argument_exceptions_not_blob_failures()
    {
        var blob = SealedBlob.Seal(Key, BlobKind.Update, Id, Plaintext);
        Assert.Throws<ArgumentException>(() => SealedBlob.Seal(new byte[31], BlobKind.Update, Id, Plaintext));
        Assert.Throws<ArgumentException>(() => SealedBlob.Seal(Key, BlobKind.Update, new byte[15], Plaintext));
        Assert.Throws<ArgumentException>(() => SealedBlob.Open(new byte[33], BlobKind.Update, Id, blob));
        Assert.Throws<ArgumentException>(() => SealedBlob.TryOpen(Key, BlobKind.Update, new byte[32], blob, out _));
        Assert.Throws<ArgumentOutOfRangeException>(() => SealedBlob.Seal(Key, (BlobKind)99, Id, Plaintext));
    }
}

public class KeyHierarchyTests
{
    private static readonly byte[] AccountId = WireEncoding.NewId();
    private static readonly byte[] NotebookId = WireEncoding.NewId();

    [Fact]
    public void Full_chain_wraps_and_unwraps()
    {
        using var unlockKey = SecretBytes.Random(32);
        using var vaultKey = KeyHierarchy.CreateVaultKey();
        using var notebookKey = KeyHierarchy.CreateNotebookKey();
        Assert.Equal(32, vaultKey.Length);
        Assert.Equal(32, notebookKey.Length);
        Assert.NotEqual(vaultKey.Span.ToArray(), notebookKey.Span.ToArray());

        var wrappedVault = KeyHierarchy.WrapVaultKey(unlockKey.Span, AccountId, vaultKey.Span);
        var wrappedNotebook = KeyHierarchy.WrapNotebookKey(vaultKey.Span, NotebookId, notebookKey.Span);
        Assert.Equal(32 + SealedBlob.Overhead, wrappedVault.Length);

        using var vaultKey2 = KeyHierarchy.UnwrapVaultKey(unlockKey.Span, AccountId, wrappedVault);
        using var notebookKey2 = KeyHierarchy.UnwrapNotebookKey(vaultKey2.Span, NotebookId, wrappedNotebook);
        Assert.Equal(vaultKey.Span.ToArray(), vaultKey2.Span.ToArray());
        Assert.Equal(notebookKey.Span.ToArray(), notebookKey2.Span.ToArray());

        var docId = WireEncoding.NewId();
        var update = SealedBlob.Seal(notebookKey2.Span, BlobKind.Update, docId, "edit"u8);
        Assert.Equal("edit"u8.ToArray(), SealedBlob.Open(notebookKey.Span, BlobKind.Update, docId, update));
    }

    [Fact]
    public void Wrong_unlock_key_does_not_unwrap_the_vault()
    {
        using var unlockKey = SecretBytes.Random(32);
        using var wrongKey = SecretBytes.Random(32);
        using var vaultKey = KeyHierarchy.CreateVaultKey();
        var wrapped = KeyHierarchy.WrapVaultKey(unlockKey.Span, AccountId, vaultKey.Span);

        Assert.Throws<SealedBlobException>(() => KeyHierarchy.UnwrapVaultKey(wrongKey.Span, AccountId, wrapped));
        Assert.False(KeyHierarchy.TryUnwrapVaultKey(wrongKey.Span, AccountId, wrapped, out var none));
        Assert.Null(none);
        Assert.True(KeyHierarchy.TryUnwrapVaultKey(unlockKey.Span, AccountId, wrapped, out var some));
        some!.Dispose();
    }

    [Fact]
    public void Wrapped_keys_are_bound_to_their_kind_and_id()
    {
        using var key = SecretBytes.Random(32);
        using var inner = SecretBytes.Random(32);
        var asVault = KeyHierarchy.WrapVaultKey(key.Span, AccountId, inner.Span);
        var asNotebook = KeyHierarchy.WrapNotebookKey(key.Span, AccountId, inner.Span);

        Assert.Throws<SealedBlobException>(() => KeyHierarchy.UnwrapNotebookKey(key.Span, AccountId, asVault));
        Assert.Throws<SealedBlobException>(() => KeyHierarchy.UnwrapVaultKey(key.Span, AccountId, asNotebook));
        Assert.Throws<SealedBlobException>(() => KeyHierarchy.UnwrapNotebookKey(key.Span, NotebookId, asNotebook));
        Assert.False(KeyHierarchy.TryUnwrapNotebookKey(key.Span, NotebookId, asNotebook, out _));
    }

    [Fact]
    public void A_blob_that_opens_but_is_not_a_key_is_refused()
    {
        using var key = SecretBytes.Random(32);
        var notAKey = SealedBlob.Seal(key.Span, BlobKind.Vault, AccountId, new byte[31]);
        Assert.Throws<SealedBlobException>(() => KeyHierarchy.UnwrapVaultKey(key.Span, AccountId, notAKey));
        Assert.False(KeyHierarchy.TryUnwrapVaultKey(key.Span, AccountId, notAKey, out _));
        Assert.Throws<ArgumentException>(() => KeyHierarchy.WrapVaultKey(key.Span, AccountId, new byte[31]));
        Assert.Throws<ArgumentException>(() => KeyHierarchy.WrapNotebookKey(key.Span, NotebookId, new byte[33]));
    }
}

public class LoginSignatureTests
{
    private static readonly KdfParams Cheap = new(KdfParams.Argon2id13, 1, KdfParams.MinMemKiB);

    private static DerivedKeys Keys(string password = "hunter2")
    {
        using var sk = SecretKey.FromBytes(Convert.FromHexString("8f3a1c5ed247b906e17d4ac3902bf865"));
        return KeyDerivation.Derive(password, sk, new byte[16], new byte[16], Cheap);
    }

    [Fact]
    public void Sign_then_verify_succeeds()
    {
        using var keys = Keys();
        var nonce = LoginSignature.NewNonce();
        var signature = LoginSignature.Sign(keys.AuthPrivateKey, nonce);
        Assert.Equal(64, signature.Length);
        Assert.Equal(32, nonce.Length);
        Assert.True(LoginSignature.Verify(keys.AuthPublicKey, nonce, signature));
    }

    [Fact]
    public void Signature_covers_the_context_string_not_the_bare_nonce()
    {
        using var keys = Keys();
        var nonce = LoginSignature.NewNonce();
        var bare = new byte[64];
        Geralt.Ed25519.Sign(bare, nonce, keys.AuthPrivateKey);
        Assert.False(LoginSignature.Verify(keys.AuthPublicKey, nonce, bare));
    }

    [Fact]
    public void Wrong_nonce_key_or_signature_fails()
    {
        using var keys = Keys();
        using var otherKeys = Keys("another password");
        var nonce = LoginSignature.NewNonce();
        var signature = LoginSignature.Sign(keys.AuthPrivateKey, nonce);

        Assert.False(LoginSignature.Verify(keys.AuthPublicKey, LoginSignature.NewNonce(), signature));
        Assert.False(LoginSignature.Verify(otherKeys.AuthPublicKey, nonce, signature));

        for (var i = 0; i < signature.Length; i++)
        {
            var tampered = (byte[])signature.Clone();
            tampered[i] ^= 0x01;
            Assert.False(LoginSignature.Verify(keys.AuthPublicKey, nonce, tampered));
        }
    }

    [Fact]
    public void Verify_returns_false_for_malformed_input_instead_of_throwing()
    {
        using var keys = Keys();
        var nonce = LoginSignature.NewNonce();
        var signature = LoginSignature.Sign(keys.AuthPrivateKey, nonce);
        var publicKey = keys.AuthPublicKey.ToArray();

        Assert.False(LoginSignature.Verify(publicKey[..31], nonce, signature));
        Assert.False(LoginSignature.Verify(publicKey, nonce[..31], signature));
        Assert.False(LoginSignature.Verify(publicKey, nonce, signature[..63]));
        Assert.False(LoginSignature.Verify([], [], []));
        Assert.False(LoginSignature.Verify(new byte[32], nonce, signature));
        Assert.False(LoginSignature.Verify(publicKey, nonce, new byte[64]));

        var allOnes = new byte[32];
        Array.Fill(allOnes, (byte)0xFF);
        Assert.False(LoginSignature.Verify(allOnes, nonce, signature));
    }

    [Fact]
    public void Sign_rejects_wrong_lengths()
    {
        using var keys = Keys();
        var privateKey = keys.AuthPrivateKey.ToArray();
        Assert.Throws<ArgumentException>(() => LoginSignature.Sign(privateKey[..32], new byte[32]));
        Assert.Throws<ArgumentException>(() => LoginSignature.Sign(privateKey, new byte[31]));
    }
}

public class WireEncodingTests
{
    [Fact]
    public void Base64Url_has_no_padding_and_uses_the_url_alphabet()
    {
        Assert.Equal("-_8", WireEncoding.ToBase64Url([0xFB, 0xFF]));
        Assert.Equal("AA", WireEncoding.ToBase64Url([0x00]));
        Assert.Equal(string.Empty, WireEncoding.ToBase64Url([]));
        Assert.Equal(new byte[] { 0xFB, 0xFF }, WireEncoding.FromBase64Url("-_8"));
        Assert.Empty(WireEncoding.FromBase64Url(string.Empty));
    }

    [Fact]
    public void Base64Url_round_trips_every_length()
    {
        for (var length = 0; length < 70; length++)
        {
            var bytes = RandomNumberGenerator.GetBytes(length);
            var text = WireEncoding.ToBase64Url(bytes);
            Assert.DoesNotContain('=', text);
            Assert.DoesNotContain('+', text);
            Assert.DoesNotContain('/', text);
            Assert.Equal(bytes, WireEncoding.FromBase64Url(text));
        }
    }

    [Theory]
    [InlineData("AA==")]
    [InlineData("+/8")]
    [InlineData("A")]
    [InlineData("AAAAA")]
    [InlineData("AA AA")]
    [InlineData("AAAA\n")]
    [InlineData("AAéA")]
    public void Base64Url_rejects_padding_standard_alphabet_and_junk(string text)
    {
        Assert.False(WireEncoding.TryFromBase64Url(text, out var bytes));
        Assert.Null(bytes);
        Assert.Throws<FormatException>(() => WireEncoding.FromBase64Url(text));
    }

    [Fact]
    public void Base64Url_try_decode_handles_null()
    {
        Assert.False(WireEncoding.TryFromBase64Url(null, out _));
    }

    [Fact]
    public void Ids_are_sixteen_bytes_and_thirty_two_lowercase_hex()
    {
        var id = WireEncoding.NewId();
        Assert.Equal(16, id.Length);
        var hex = WireEncoding.IdToHex(id);
        Assert.Matches("^[0-9a-f]{32}$", hex);
        Assert.Equal(id, WireEncoding.IdFromHex(hex));
        Assert.NotEqual(id, WireEncoding.NewId());
    }

    [Theory]
    [InlineData("")]
    [InlineData("00112233445566778899aabbccddeef")]
    [InlineData("00112233445566778899aabbccddeeff0")]
    [InlineData("00112233445566778899AABBCCDDEEFF")]
    [InlineData("00112233445566778899aabbccddeefg")]
    [InlineData("00112233-4455-6677-8899-aabbccddeeff")]
    public void Malformed_ids_are_rejected(string hex)
    {
        Assert.False(WireEncoding.TryIdFromHex(hex, out var id));
        Assert.Null(id);
        Assert.Throws<FormatException>(() => WireEncoding.IdFromHex(hex));
    }

    [Fact]
    public void IdToHex_requires_sixteen_bytes()
    {
        Assert.Throws<ArgumentException>(() => WireEncoding.IdToHex(new byte[15]));
        Assert.False(WireEncoding.TryIdFromHex(null, out _));
    }
}

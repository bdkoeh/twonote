using System.Diagnostics.CodeAnalysis;
using System.Security.Cryptography;
using System.Text;
using Geralt;

namespace TwoNote.Core.Crypto;

/// <summary>What a sealed blob protects; selects the <c>kind</c> string in its additional data.</summary>
public enum BlobKind
{
    /// <summary><c>vault</c>: vaultKey under unlockKey, id = accountId.</summary>
    Vault,

    /// <summary><c>nbkey</c>: notebookKey under vaultKey, id = notebookId.</summary>
    NotebookKey,

    /// <summary><c>update</c>: one Yjs update under notebookKey, id = docId.</summary>
    Update,

    /// <summary><c>snapshot</c>: a full-state Yjs update under notebookKey, id = docId.</summary>
    Snapshot,
}

/// <summary>Why a sealed blob could not be opened.</summary>
public enum SealedBlobError
{
    /// <summary>Shorter than version byte + nonce + authentication tag.</summary>
    Truncated,

    /// <summary>The first byte is not 0x01.</summary>
    UnsupportedVersion,

    /// <summary>Wrong key, wrong kind or id, or the blob was modified.</summary>
    AuthenticationFailed,
}

/// <summary>Thrown when a sealed blob does not open. The blob must be discarded and reported, never applied.</summary>
public sealed class SealedBlobException : Exception
{
    /// <summary>Creates the exception for <paramref name="error"/>.</summary>
    public SealedBlobException(SealedBlobError error)
        : base(error switch
        {
            SealedBlobError.Truncated => "Sealed blob is too short.",
            SealedBlobError.UnsupportedVersion => "Sealed blob has an unsupported version byte.",
            _ => "Sealed blob failed authentication.",
        })
    {
        Error = error;
    }

    /// <summary>The failure category.</summary>
    public SealedBlobError Error { get; }
}

/// <summary>
/// The one encrypted format (PROTOCOL.md 1.3):
/// <c>0x01 || nonce(24) || XChaCha20-Poly1305(key, nonce, plaintext, aad)</c> with
/// <c>aad = UTF8("twonote/v1|" + kind + "|" + id)</c>, id as 32 lowercase hex characters.
/// </summary>
public static class SealedBlob
{
    /// <summary>The version byte every v1 blob starts with.</summary>
    public const byte Version = 0x01;

    /// <summary>Key length in bytes.</summary>
    public const int KeyLength = 32;

    /// <summary>Nonce length in bytes.</summary>
    public const int NonceLength = 24;

    /// <summary>Poly1305 tag length in bytes.</summary>
    public const int TagLength = 16;

    /// <summary>Bytes a blob adds to its plaintext (version + nonce + tag = 41).</summary>
    public const int Overhead = 1 + NonceLength + TagLength;

    private const int AadLength = 11 + 8 + 1 + WireEncoding.IdHexLength; // "twonote/v1|" + longest kind + "|" + id

    /// <summary>The wire string for a kind: <c>vault</c>, <c>nbkey</c>, <c>update</c> or <c>snapshot</c>.</summary>
    public static string KindName(BlobKind kind) => kind switch
    {
        BlobKind.Vault => "vault",
        BlobKind.NotebookKey => "nbkey",
        BlobKind.Update => "update",
        BlobKind.Snapshot => "snapshot",
        _ => throw new ArgumentOutOfRangeException(nameof(kind)),
    };

    /// <summary>The additional data for a kind and 16-byte id, as text (it is pure ASCII).</summary>
    public static string AdditionalData(BlobKind kind, ReadOnlySpan<byte> id) =>
        $"twonote/v1|{KindName(kind)}|{WireEncoding.IdToHex(id)}";

    /// <summary>Encrypts <paramref name="plaintext"/> under a fresh random nonce.</summary>
    /// <exception cref="ArgumentException">The key is not 32 bytes or the id is not 16 bytes.</exception>
    public static byte[] Seal(ReadOnlySpan<byte> key, BlobKind kind, ReadOnlySpan<byte> id, ReadOnlySpan<byte> plaintext)
    {
        Span<byte> nonce = stackalloc byte[NonceLength];
        RandomNumberGenerator.Fill(nonce);
        return SealWithNonce(key, kind, id, plaintext, nonce);
    }

    /// <summary>Seals with a caller-chosen nonce. Only for reproducing the test vectors: a nonce must never repeat under one key.</summary>
    internal static byte[] SealWithNonce(
        ReadOnlySpan<byte> key, BlobKind kind, ReadOnlySpan<byte> id, ReadOnlySpan<byte> plaintext, ReadOnlySpan<byte> nonce)
    {
        CheckKey(key);
        if (nonce.Length != NonceLength)
        {
            throw new ArgumentException($"The nonce is exactly {NonceLength} bytes.", nameof(nonce));
        }

        Span<byte> aad = stackalloc byte[AadLength];
        aad = aad[..WriteAdditionalData(aad, kind, id)];

        var blob = new byte[Overhead + plaintext.Length];
        blob[0] = Version;
        nonce.CopyTo(blob.AsSpan(1, NonceLength));
        XChaCha20Poly1305.Encrypt(blob.AsSpan(1 + NonceLength), plaintext, nonce, key, aad);
        return blob;
    }

    /// <summary>Decrypts a blob, returning the plaintext.</summary>
    /// <exception cref="SealedBlobException">The blob is truncated, has the wrong version, or does not authenticate under this key, kind and id.</exception>
    /// <exception cref="ArgumentException">The key is not 32 bytes or the id is not 16 bytes.</exception>
    public static byte[] Open(ReadOnlySpan<byte> key, BlobKind kind, ReadOnlySpan<byte> id, ReadOnlySpan<byte> blob)
    {
        var error = OpenCore(key, kind, id, blob, out var plaintext);
        return error is null ? plaintext! : throw new SealedBlobException(error.Value);
    }

    /// <summary>Decrypts a blob without throwing on bad input: returns false for anything <see cref="Open"/> would reject as a <see cref="SealedBlobException"/>.</summary>
    /// <exception cref="ArgumentException">The key is not 32 bytes or the id is not 16 bytes (a caller bug, not a bad blob).</exception>
    public static bool TryOpen(
        ReadOnlySpan<byte> key, BlobKind kind, ReadOnlySpan<byte> id, ReadOnlySpan<byte> blob,
        [NotNullWhen(true)] out byte[]? plaintext) =>
        OpenCore(key, kind, id, blob, out plaintext) is null;

    private static SealedBlobError? OpenCore(
        ReadOnlySpan<byte> key, BlobKind kind, ReadOnlySpan<byte> id, ReadOnlySpan<byte> blob, out byte[]? plaintext)
    {
        plaintext = null;
        CheckKey(key);
        Span<byte> aad = stackalloc byte[AadLength];
        aad = aad[..WriteAdditionalData(aad, kind, id)];

        if (blob.Length < Overhead)
        {
            return SealedBlobError.Truncated;
        }

        if (blob[0] != Version)
        {
            return SealedBlobError.UnsupportedVersion;
        }

        var nonce = blob.Slice(1, NonceLength);
        var ciphertext = blob[(1 + NonceLength)..];
        var output = new byte[ciphertext.Length - TagLength];
        try
        {
            XChaCha20Poly1305.Decrypt(output, ciphertext, nonce, key, aad);
        }
        catch (CryptographicException)
        {
            CryptographicOperations.ZeroMemory(output);
            return SealedBlobError.AuthenticationFailed;
        }

        plaintext = output;
        return null;
    }

    private static int WriteAdditionalData(Span<byte> destination, BlobKind kind, ReadOnlySpan<byte> id) =>
        Encoding.ASCII.GetBytes(AdditionalData(kind, id), destination);

    private static void CheckKey(ReadOnlySpan<byte> key)
    {
        if (key.Length != KeyLength)
        {
            throw new ArgumentException($"The key is exactly {KeyLength} bytes.", nameof(key));
        }
    }
}

using System.Security.Cryptography;

namespace TwoNote.Core.Crypto;

/// <summary>
/// unlockKey wraps vaultKey; vaultKey wraps one notebookKey per notebook (PROTOCOL.md 1.3).
/// The wrapped forms are sealed blobs, ready for <c>wrappedVaultKey</c> / <c>wrappedKey</c>
/// after base64url encoding.
/// </summary>
public static class KeyHierarchy
{
    /// <summary>Length of vaultKey and notebookKey in bytes.</summary>
    public const int KeyLength = SealedBlob.KeyLength;

    /// <summary>Generates a random vaultKey.</summary>
    public static SecretBytes CreateVaultKey() => SecretBytes.Random(KeyLength);

    /// <summary>Generates a random notebookKey.</summary>
    public static SecretBytes CreateNotebookKey() => SecretBytes.Random(KeyLength);

    /// <summary>Seals vaultKey under unlockKey, bound to the account.</summary>
    public static byte[] WrapVaultKey(ReadOnlySpan<byte> unlockKey, ReadOnlySpan<byte> accountId, ReadOnlySpan<byte> vaultKey)
    {
        CheckWrappedKey(vaultKey, nameof(vaultKey));
        return SealedBlob.Seal(unlockKey, BlobKind.Vault, accountId, vaultKey);
    }

    /// <summary>Opens a wrapped vaultKey.</summary>
    /// <exception cref="SealedBlobException">Wrong password or Secret Key, wrong account, or a damaged blob.</exception>
    public static SecretBytes UnwrapVaultKey(ReadOnlySpan<byte> unlockKey, ReadOnlySpan<byte> accountId, ReadOnlySpan<byte> wrappedVaultKey) =>
        Unwrap(unlockKey, BlobKind.Vault, accountId, wrappedVaultKey);

    /// <summary>Opens a wrapped vaultKey; false means wrong credentials or a damaged blob.</summary>
    public static bool TryUnwrapVaultKey(
        ReadOnlySpan<byte> unlockKey, ReadOnlySpan<byte> accountId, ReadOnlySpan<byte> wrappedVaultKey, out SecretBytes? vaultKey) =>
        TryUnwrap(unlockKey, BlobKind.Vault, accountId, wrappedVaultKey, out vaultKey);

    /// <summary>Seals notebookKey under vaultKey, bound to the notebook.</summary>
    public static byte[] WrapNotebookKey(ReadOnlySpan<byte> vaultKey, ReadOnlySpan<byte> notebookId, ReadOnlySpan<byte> notebookKey)
    {
        CheckWrappedKey(notebookKey, nameof(notebookKey));
        return SealedBlob.Seal(vaultKey, BlobKind.NotebookKey, notebookId, notebookKey);
    }

    /// <summary>Opens a wrapped notebookKey.</summary>
    /// <exception cref="SealedBlobException">Wrong vaultKey, wrong notebook, or a damaged blob.</exception>
    public static SecretBytes UnwrapNotebookKey(ReadOnlySpan<byte> vaultKey, ReadOnlySpan<byte> notebookId, ReadOnlySpan<byte> wrappedNotebookKey) =>
        Unwrap(vaultKey, BlobKind.NotebookKey, notebookId, wrappedNotebookKey);

    /// <summary>Opens a wrapped notebookKey; false means the wrong vaultKey or notebook, or a damaged blob.</summary>
    public static bool TryUnwrapNotebookKey(
        ReadOnlySpan<byte> vaultKey, ReadOnlySpan<byte> notebookId, ReadOnlySpan<byte> wrappedNotebookKey, out SecretBytes? notebookKey) =>
        TryUnwrap(vaultKey, BlobKind.NotebookKey, notebookId, wrappedNotebookKey, out notebookKey);

    private static SecretBytes Unwrap(ReadOnlySpan<byte> key, BlobKind kind, ReadOnlySpan<byte> id, ReadOnlySpan<byte> blob)
    {
        var plaintext = SealedBlob.Open(key, kind, id, blob);
        try
        {
            // A blob that authenticates but does not hold a 32-byte key is as unusable as one that does not open.
            return plaintext.Length == KeyLength
                ? SecretBytes.CopyFrom(plaintext)
                : throw new SealedBlobException(SealedBlobError.AuthenticationFailed);
        }
        finally
        {
            CryptographicOperations.ZeroMemory(plaintext);
        }
    }

    private static bool TryUnwrap(ReadOnlySpan<byte> key, BlobKind kind, ReadOnlySpan<byte> id, ReadOnlySpan<byte> blob, out SecretBytes? unwrapped)
    {
        unwrapped = null;
        if (!SealedBlob.TryOpen(key, kind, id, blob, out var plaintext))
        {
            return false;
        }

        try
        {
            if (plaintext.Length != KeyLength)
            {
                return false;
            }

            unwrapped = SecretBytes.CopyFrom(plaintext);
            return true;
        }
        finally
        {
            CryptographicOperations.ZeroMemory(plaintext);
        }
    }

    private static void CheckWrappedKey(ReadOnlySpan<byte> key, string name)
    {
        if (key.Length != KeyLength)
        {
            throw new ArgumentException($"The key is exactly {KeyLength} bytes.", name);
        }
    }
}

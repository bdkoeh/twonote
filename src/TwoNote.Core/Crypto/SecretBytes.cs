using System.Security.Cryptography;

namespace TwoNote.Core.Crypto;

/// <summary>
/// Owns a piece of key material. The bytes live in a pinned array (so the garbage collector
/// never leaves stray copies behind) and are zeroed on <see cref="Dispose"/>.
/// <see cref="ToString"/> never reveals the contents.
/// </summary>
public sealed class SecretBytes : IDisposable
{
    private readonly byte[] _bytes;
    private bool _disposed;

    private SecretBytes(int length)
    {
        _bytes = GC.AllocateArray<byte>(length, pinned: true);
    }

    /// <summary>Number of bytes held.</summary>
    public int Length => _bytes.Length;

    /// <summary>The key material. Throws <see cref="ObjectDisposedException"/> after disposal.</summary>
    public ReadOnlySpan<byte> Span
    {
        get
        {
            ObjectDisposedException.ThrowIf(_disposed, this);
            return _bytes;
        }
    }

    /// <summary>Creates <paramref name="length"/> cryptographically random bytes.</summary>
    public static SecretBytes Random(int length)
    {
        ArgumentOutOfRangeException.ThrowIfNegativeOrZero(length);
        var secret = new SecretBytes(length);
        RandomNumberGenerator.Fill(secret._bytes);
        return secret;
    }

    /// <summary>Copies <paramref name="source"/>. The caller stays responsible for zeroing its own copy.</summary>
    public static SecretBytes CopyFrom(ReadOnlySpan<byte> source)
    {
        var secret = new SecretBytes(source.Length);
        source.CopyTo(secret._bytes);
        return secret;
    }

    /// <summary>Allocates zeroed storage and lets <paramref name="fill"/> write the secret straight into it.</summary>
    internal static SecretBytes Create<TState>(int length, TState state, FillAction<TState> fill)
        where TState : allows ref struct
    {
        var secret = new SecretBytes(length);
        try
        {
            fill(secret._bytes, state);
            return secret;
        }
        catch
        {
            secret.Dispose();
            throw;
        }
    }

    internal delegate void FillAction<in TState>(Span<byte> destination, TState state)
        where TState : allows ref struct;

    /// <summary>Zeroes the key material.</summary>
    public void Dispose()
    {
        if (!_disposed)
        {
            CryptographicOperations.ZeroMemory(_bytes);
            _disposed = true;
        }
    }

    /// <summary>Returns a placeholder; never the contents.</summary>
    public override string ToString() => $"SecretBytes({_bytes.Length} bytes, redacted)";
}

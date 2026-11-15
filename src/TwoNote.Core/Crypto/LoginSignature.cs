using System.Security.Cryptography;
using Geralt;

namespace TwoNote.Core.Crypto;

/// <summary>
/// Login signature (PROTOCOL.md 1.4):
/// <c>Ed25519-Sign(authPrivateKey, UTF8("twonote/v1/login") || nonce)</c>.
/// The client signs; the server verifies with the stored authPublicKey.
/// </summary>
public static class LoginSignature
{
    /// <summary>Length in bytes of the nonce issued by <c>auth/start</c>.</summary>
    public const int NonceLength = 32;

    /// <summary>Length in bytes of an Ed25519 signature.</summary>
    public const int SignatureLength = 64;

    /// <summary>Length in bytes of the public key.</summary>
    public const int PublicKeyLength = 32;

    /// <summary>Length in bytes of the private key (seed followed by public key).</summary>
    public const int PrivateKeyLength = 64;

    private static ReadOnlySpan<byte> Context => "twonote/v1/login"u8;

    /// <summary>Returns a fresh random login nonce (server side).</summary>
    public static byte[] NewNonce() => RandomNumberGenerator.GetBytes(NonceLength);

    /// <summary>Signs a login nonce with <see cref="DerivedKeys.AuthPrivateKey"/>.</summary>
    /// <exception cref="ArgumentException">The private key is not 64 bytes or the nonce is not 32 bytes.</exception>
    public static byte[] Sign(ReadOnlySpan<byte> authPrivateKey, ReadOnlySpan<byte> nonce)
    {
        if (authPrivateKey.Length != PrivateKeyLength)
        {
            throw new ArgumentException($"The private key is exactly {PrivateKeyLength} bytes.", nameof(authPrivateKey));
        }

        if (nonce.Length != NonceLength)
        {
            throw new ArgumentException($"The nonce is exactly {NonceLength} bytes.", nameof(nonce));
        }

        Span<byte> message = stackalloc byte[Context.Length + NonceLength];
        BuildMessage(message, nonce);
        var signature = new byte[SignatureLength];
        Ed25519.Sign(signature, message, authPrivateKey);
        return signature;
    }

    /// <summary>
    /// Verifies a login signature. Never throws on untrusted input: a wrong length, a malformed
    /// public key or a bad signature all return false.
    /// </summary>
    public static bool Verify(ReadOnlySpan<byte> authPublicKey, ReadOnlySpan<byte> nonce, ReadOnlySpan<byte> signature)
    {
        if (authPublicKey.Length != PublicKeyLength || nonce.Length != NonceLength || signature.Length != SignatureLength)
        {
            return false;
        }

        Span<byte> message = stackalloc byte[Context.Length + NonceLength];
        BuildMessage(message, nonce);
        try
        {
            return Ed25519.Verify(signature, message, authPublicKey);
        }
        catch (Exception e) when (e is CryptographicException or ArgumentException or FormatException)
        {
            return false;
        }
    }

    private static void BuildMessage(Span<byte> message, ReadOnlySpan<byte> nonce)
    {
        Context.CopyTo(message);
        nonce.CopyTo(message[Context.Length..]);
    }
}

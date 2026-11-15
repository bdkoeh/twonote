using System.Security.Cryptography;
using System.Text;
using Geralt;

namespace TwoNote.Core.Crypto;

/// <summary>What <see cref="KeyDerivation.Derive(ReadOnlySpan{char}, SecretKey, ReadOnlySpan{byte}, ReadOnlySpan{byte}, KdfParams)"/> produces.</summary>
public sealed class DerivedKeys : IDisposable
{
    private readonly SecretBytes _unlockKey;
    private readonly SecretBytes _authPrivateKey;
    private readonly byte[] _authPublicKey;

    internal DerivedKeys(SecretBytes unlockKey, SecretBytes authPrivateKey, byte[] authPublicKey)
    {
        _unlockKey = unlockKey;
        _authPrivateKey = authPrivateKey;
        _authPublicKey = authPublicKey;
    }

    /// <summary>32-byte key that wraps the vaultKey.</summary>
    public ReadOnlySpan<byte> UnlockKey => _unlockKey.Span;

    /// <summary>64-byte Ed25519 private key (libsodium layout: seed followed by public key). Pass to <see cref="LoginSignature.Sign"/>.</summary>
    public ReadOnlySpan<byte> AuthPrivateKey => _authPrivateKey.Span;

    /// <summary>32-byte Ed25519 public key; this is what the server stores. Not secret.</summary>
    public ReadOnlySpan<byte> AuthPublicKey => _authPublicKey;

    /// <summary>Zeroes the unlock key and the private key.</summary>
    public void Dispose()
    {
        _unlockKey.Dispose();
        _authPrivateKey.Dispose();
    }
}

/// <summary>Two-secret key derivation (PROTOCOL.md 1.2).</summary>
public static class KeyDerivation
{
    /// <summary>Length of kdfSalt in bytes.</summary>
    public const int SaltLength = 16;

    /// <summary>Length of unlockKey, vaultKey and notebookKey in bytes.</summary>
    public const int KeyLength = 32;

    /// <summary>Length of the Ed25519 public key in bytes.</summary>
    public const int AuthPublicKeyLength = 32;

    /// <summary>Length of the Ed25519 private key in bytes (seed followed by public key).</summary>
    public const int AuthPrivateKeyLength = 64;

    private static ReadOnlySpan<byte> SecretKeyInfo => "twonote/v1/2skd"u8;
    private static ReadOnlySpan<byte> UnlockInfo => "twonote/v1/unlock"u8;
    private static ReadOnlySpan<byte> AuthInfo => "twonote/v1/auth"u8;

    /// <summary>Returns a fresh random kdfSalt.</summary>
    public static byte[] NewSalt() => RandomNumberGenerator.GetBytes(SaltLength);

    /// <summary>
    /// Derives unlockKey and the Ed25519 login key pair from the password and the Secret Key.
    /// Takes roughly a tenth of a second and 64 MiB with the default parameters; call it off
    /// the UI thread.
    /// </summary>
    /// <exception cref="ArgumentException">A length is wrong, the parameters are not supported, or the password is not valid UTF-16.</exception>
    public static DerivedKeys Derive(
        ReadOnlySpan<char> password,
        SecretKey secretKey,
        ReadOnlySpan<byte> accountId,
        ReadOnlySpan<byte> kdfSalt,
        KdfParams kdfParams)
    {
        ArgumentNullException.ThrowIfNull(secretKey);
        return Derive(password, secretKey.Bytes, accountId, kdfSalt, kdfParams);
    }

    /// <inheritdoc cref="Derive(ReadOnlySpan{char}, SecretKey, ReadOnlySpan{byte}, ReadOnlySpan{byte}, KdfParams)"/>
    public static DerivedKeys Derive(
        ReadOnlySpan<char> password,
        ReadOnlySpan<byte> secretKey,
        ReadOnlySpan<byte> accountId,
        ReadOnlySpan<byte> kdfSalt,
        KdfParams kdfParams)
    {
        Span<byte> trace = stackalloc byte[DerivationTrace.Size];
        try
        {
            var t = new DerivationTrace(trace);
            DeriveCore(password, secretKey, accountId, kdfSalt, kdfParams, t);

            var publicKey = new byte[AuthPublicKeyLength];
            var unlockKey = SecretBytes.CopyFrom(t.UnlockKey);
            try
            {
                var privateKey = SecretBytes.Create(AuthPrivateKeyLength, new SeedAndPublicKey(t.AuthSeed, publicKey),
                    static (destination, state) => Ed25519.GenerateKeyPair(state.PublicKey, destination, state.Seed));
                return new DerivedKeys(unlockKey, privateKey, publicKey);
            }
            catch
            {
                unlockKey.Dispose();
                throw;
            }
        }
        finally
        {
            CryptographicOperations.ZeroMemory(trace);
        }
    }

    /// <summary>Runs 1.2 and exposes every intermediate value, for the test vectors only.</summary>
    internal static void DeriveCore(
        ReadOnlySpan<char> password,
        ReadOnlySpan<byte> secretKey,
        ReadOnlySpan<byte> accountId,
        ReadOnlySpan<byte> kdfSalt,
        KdfParams kdfParams,
        DerivationTrace trace)
    {
        ArgumentNullException.ThrowIfNull(kdfParams);
        if (secretKey.Length != SecretKey.Length)
        {
            throw new ArgumentException($"secretKey is exactly {SecretKey.Length} bytes.", nameof(secretKey));
        }

        if (accountId.Length != WireEncoding.IdLength)
        {
            throw new ArgumentException($"accountId is exactly {WireEncoding.IdLength} bytes.", nameof(accountId));
        }

        if (kdfSalt.Length != SaltLength)
        {
            throw new ArgumentException($"kdfSalt is exactly {SaltLength} bytes.", nameof(kdfSalt));
        }

        if (!kdfParams.IsSupported)
        {
            throw new ArgumentException("Unsupported kdfParams.", nameof(kdfParams));
        }

        var passwordBytes = NormalisePassword(password);
        try
        {
            // k_pw = Argon2id(UTF8(NFKC(password)), kdfSalt, ops, memKiB * 1024, 32)
            Argon2id.DeriveKey(trace.KPw, passwordBytes, kdfSalt, kdfParams.Ops, kdfParams.MemKiB * 1024);
        }
        finally
        {
            CryptographicOperations.ZeroMemory(passwordBytes);
        }

        // k_sk = HKDF-SHA256(ikm = secretKey, salt = accountId, info = "twonote/v1/2skd")
        HKDF.DeriveKey(HashAlgorithmName.SHA256, secretKey, trace.KSk, accountId, SecretKeyInfo);

        // root = k_pw XOR k_sk
        for (var i = 0; i < KeyLength; i++)
        {
            trace.Root[i] = (byte)(trace.KPw[i] ^ trace.KSk[i]);
        }

        // An empty salt is the RFC 5869 default of HashLen zero bytes.
        HKDF.DeriveKey(HashAlgorithmName.SHA256, trace.Root, trace.UnlockKey, salt: default, UnlockInfo);
        HKDF.DeriveKey(HashAlgorithmName.SHA256, trace.Root, trace.AuthSeed, salt: default, AuthInfo);
    }

    /// <summary>UTF8(NFKC(password)) in a pinned array the caller must zero.</summary>
    internal static byte[] NormalisePassword(ReadOnlySpan<char> password)
    {
        if (password.IsEmpty)
        {
            return [];
        }

        // NFKC can grow a string (the worst single code point expands 18-fold), so ask first.
        int normalisedLength;
        try
        {
            normalisedLength = password.GetNormalizedLength(NormalizationForm.FormKC);
        }
        catch (ArgumentException)
        {
            throw new ArgumentException("The password contains invalid Unicode.", nameof(password));
        }

        var chars = GC.AllocateArray<char>(normalisedLength, pinned: true);
        try
        {
            if (!password.TryNormalize(chars, out var written, NormalizationForm.FormKC))
            {
                throw new ArgumentException("The password could not be normalised.", nameof(password));
            }

            var normalised = chars.AsSpan(0, written);
            var bytes = GC.AllocateArray<byte>(Encoding.UTF8.GetByteCount(normalised), pinned: true);
            Encoding.UTF8.GetBytes(normalised, bytes);
            return bytes;
        }
        finally
        {
            Array.Clear(chars);
        }
    }

    private readonly ref struct SeedAndPublicKey(ReadOnlySpan<byte> seed, Span<byte> publicKey)
    {
        public ReadOnlySpan<byte> Seed { get; } = seed;

        public Span<byte> PublicKey { get; } = publicKey;
    }
}

/// <summary>Scratch space for one derivation: five 32-byte values laid out in a caller-owned buffer.</summary>
internal readonly ref struct DerivationTrace
{
    public const int Size = 5 * KeyDerivation.KeyLength;

    private readonly Span<byte> _buffer;

    public DerivationTrace(Span<byte> buffer)
    {
        if (buffer.Length != Size)
        {
            throw new ArgumentException($"Trace buffer is exactly {Size} bytes.", nameof(buffer));
        }

        _buffer = buffer;
    }

    public Span<byte> KPw => _buffer.Slice(0, 32);

    public Span<byte> KSk => _buffer.Slice(32, 32);

    public Span<byte> Root => _buffer.Slice(64, 32);

    public Span<byte> UnlockKey => _buffer.Slice(96, 32);

    public Span<byte> AuthSeed => _buffer.Slice(128, 32);
}

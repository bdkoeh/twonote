using System.Collections.Concurrent;
using System.Security.Cryptography;
using System.Text;
using TwoNote.Core.Crypto;

namespace TwoNote.Server;

/// <summary>Login challenges: in memory, single use, short lived.</summary>
public sealed class ChallengeStore(TwoNoteOptions options, TimeProvider time)
{
    public sealed record Challenge(byte[] Nonce, DateTimeOffset ExpiresAt, bool IsReal);

    private readonly ConcurrentDictionary<string, Challenge> _challenges = new();

    public (string ChallengeId, byte[] Nonce) Issue(bool isReal)
    {
        var now = time.GetUtcNow();
        if (_challenges.Count >= options.MaxPendingChallenges)
        {
            foreach (var (id, c) in _challenges)
                if (c.ExpiresAt <= now) _challenges.TryRemove(id, out _);
            if (_challenges.Count >= options.MaxPendingChallenges)
                throw new ApiException(429, "rate_limited", "Too many pending logins; try again shortly");
        }

        var challengeId = Codec.NewId();
        var nonce = RandomNumberGenerator.GetBytes(32);
        _challenges[challengeId] = new Challenge(nonce, now + options.ChallengeLifetime, isReal);
        return (challengeId, nonce);
    }

    /// <summary>Removes the challenge (so it can never be used twice) and returns it if still valid.</summary>
    public Challenge? Take(string challengeId) =>
        _challenges.TryRemove(challengeId, out var c) && c.ExpiresAt > time.GetUtcNow() ? c : null;
}

/// <summary>Counts failed logins per source address in a sliding window.</summary>
public sealed class LoginRateLimiter(TwoNoteOptions options, TimeProvider time)
{
    private readonly Lock _lock = new();
    private readonly Dictionary<string, Queue<DateTimeOffset>> _failures = [];

    /// <summary>Null when the source may try; otherwise how long until it may.</summary>
    public TimeSpan? BlockedFor(string source)
    {
        lock (_lock)
        {
            var now = time.GetUtcNow();
            if (!_failures.TryGetValue(source, out var queue)) return null;
            Trim(queue, now);
            if (queue.Count == 0)
            {
                _failures.Remove(source);
                return null;
            }
            return queue.Count >= options.LoginFailureLimit ? queue.Peek() + options.LoginFailureWindow - now : null;
        }
    }

    public void RecordFailure(string source)
    {
        lock (_lock)
        {
            var now = time.GetUtcNow();
            if (_failures.Count > 50_000)
            {
                foreach (var key in _failures.Keys.ToList())
                {
                    Trim(_failures[key], now);
                    if (_failures[key].Count == 0) _failures.Remove(key);
                }
            }

            if (!_failures.TryGetValue(source, out var queue)) _failures[source] = queue = new Queue<DateTimeOffset>();
            Trim(queue, now);
            queue.Enqueue(now);
        }
    }

    private void Trim(Queue<DateTimeOffset> queue, DateTimeOffset now)
    {
        while (queue.Count > 0 && queue.Peek() + options.LoginFailureWindow <= now) queue.Dequeue();
    }
}

internal static class LoginCrypto
{
    /// <summary>A 32-byte value that is a point on the curve; anything else could never verify a login.</summary>
    public static bool IsValidPublicKey(byte[] publicKey)
    {
        if (publicKey.Length != LoginSignature.PublicKeyLength) return false;
        try
        {
            Span<byte> scratch = stackalloc byte[32];
            Geralt.Ed25519.ComputeX25519PublicKey(scratch, publicKey);
            return true;
        }
        catch (Exception e) when (e is CryptographicException or ArgumentException or FormatException)
        {
            return false;
        }
    }

    /// <summary>PROTOCOL 1.4: Ed25519 over UTF8("twonote/v1/login") || nonce.</summary>
    public static bool Verify(byte[] publicKey, byte[] nonce, byte[] signature) =>
        LoginSignature.Verify(publicKey, nonce, signature);

    /// <summary>Stable stand-in values for a username that has no account.</summary>
    public static (string AccountId, byte[] KdfSalt) FakeIdentity(byte[] serverSecret, string normalizedUsername)
    {
        static byte[] Derive(byte[] secret, string label, string username) =>
            HMACSHA256.HashData(secret, Encoding.UTF8.GetBytes(label + "|" + username))[..16];

        return (Convert.ToHexStringLower(Derive(serverSecret, "twonote/fake/accountId", normalizedUsername)),
                Derive(serverSecret, "twonote/fake/kdfSalt", normalizedUsername));
    }

    public static string NormalizeUsername(string username) => username.Trim().ToLowerInvariant();
}

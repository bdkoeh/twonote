using System.Diagnostics.CodeAnalysis;
using System.Security.Cryptography;

namespace TwoNote.Core;

/// <summary>
/// The two text encodings PROTOCOL.md uses on the wire: base64url without padding for binary
/// values and 32 lowercase hex characters for 16-byte ids.
/// </summary>
public static class WireEncoding
{
    /// <summary>Length in bytes of every id (accountId, deviceId, notebookId, docId, clientUpdateId).</summary>
    public const int IdLength = 16;

    /// <summary>Length in characters of an id in its hex form.</summary>
    public const int IdHexLength = 32;

    /// <summary>Encodes bytes as base64url without padding.</summary>
    public static string ToBase64Url(ReadOnlySpan<byte> bytes) =>
        System.Buffers.Text.Base64Url.EncodeToString(bytes);

    /// <summary>Decodes base64url without padding. Throws <see cref="FormatException"/> on anything else.</summary>
    public static byte[] FromBase64Url(string text)
    {
        ArgumentNullException.ThrowIfNull(text);
        return TryFromBase64Url(text, out var bytes)
            ? bytes
            : throw new FormatException("Value is not base64url without padding.");
    }

    /// <summary>
    /// Decodes base64url without padding. Padding characters, whitespace and the standard
    /// base64 characters '+' and '/' are rejected.
    /// </summary>
    public static bool TryFromBase64Url([NotNullWhen(true)] string? text, [NotNullWhen(true)] out byte[]? bytes)
    {
        bytes = null;
        if (text is null || text.Length % 4 == 1)
        {
            return false;
        }

        foreach (var c in text)
        {
            var ok = c is (>= 'A' and <= 'Z') or (>= 'a' and <= 'z') or (>= '0' and <= '9') or '-' or '_';
            if (!ok)
            {
                return false;
            }
        }

        var buffer = new byte[text.Length / 4 * 3 + 2];
        if (!System.Buffers.Text.Base64Url.TryDecodeFromChars(text, buffer, out var written))
        {
            return false;
        }

        bytes = buffer.AsSpan(0, written).ToArray();
        CryptographicOperations.ZeroMemory(buffer);
        return true;
    }

    /// <summary>Returns a new random 16-byte id.</summary>
    public static byte[] NewId() => RandomNumberGenerator.GetBytes(IdLength);

    /// <summary>Formats a 16-byte id as 32 lowercase hex characters.</summary>
    public static string IdToHex(ReadOnlySpan<byte> id)
    {
        if (id.Length != IdLength)
        {
            throw new ArgumentException($"An id is exactly {IdLength} bytes.", nameof(id));
        }

        return Convert.ToHexStringLower(id);
    }

    /// <summary>Parses 32 lowercase hex characters into a 16-byte id. Throws <see cref="FormatException"/> otherwise.</summary>
    public static byte[] IdFromHex(string hex)
    {
        ArgumentNullException.ThrowIfNull(hex);
        return TryIdFromHex(hex, out var id)
            ? id
            : throw new FormatException("An id is exactly 32 lowercase hex characters.");
    }

    /// <summary>Parses 32 lowercase hex characters into a 16-byte id. Uppercase is rejected.</summary>
    public static bool TryIdFromHex([NotNullWhen(true)] string? hex, [NotNullWhen(true)] out byte[]? id)
    {
        id = null;
        if (hex is null || hex.Length != IdHexLength)
        {
            return false;
        }

        foreach (var c in hex)
        {
            if (c is not ((>= '0' and <= '9') or (>= 'a' and <= 'f')))
            {
                return false;
            }
        }

        id = Convert.FromHexString(hex);
        return true;
    }
}

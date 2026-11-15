using System.Buffers.Text;
using System.Security.Cryptography;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace TwoNote.Server;

/// <summary>An error that maps directly onto the protocol's error body.</summary>
public sealed class ApiException(int status, string code, string message) : Exception(message)
{
    public int Status { get; } = status;
    public string Code { get; } = code;

    public static ApiException Invalid(string message) => new(400, "invalid_request", message);
}

internal static class Json
{
    // Field names are exactly camelCase (no case-insensitive matching), unknown fields are ignored.
    public static readonly JsonSerializerOptions Options = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
    };
}

internal static class Codec
{
    /// <summary>Ids are 16 bytes written as exactly 32 lowercase hex characters.</summary>
    public static bool IsId(string? s)
    {
        if (s is not { Length: 32 }) return false;
        foreach (var c in s)
            if (c is not ((>= '0' and <= '9') or (>= 'a' and <= 'f'))) return false;
        return true;
    }

    public static string NewId() => Convert.ToHexStringLower(RandomNumberGenerator.GetBytes(16));

    public static string B64(ReadOnlySpan<byte> bytes) => Base64Url.EncodeToString(bytes);

    /// <summary>Strict base64url: URL alphabet only, no padding, no whitespace.</summary>
    public static bool TryB64(string? s, out byte[] bytes)
    {
        bytes = [];
        if (s is null || s.Length % 4 == 1) return false;
        foreach (var c in s)
            if (c is not ((>= 'A' and <= 'Z') or (>= 'a' and <= 'z') or (>= '0' and <= '9') or '-' or '_'))
                return false;
        try
        {
            bytes = Base64Url.DecodeFromChars(s);
            return true;
        }
        catch (FormatException)
        {
            return false;
        }
    }

    public static string Id(string? value, string field) =>
        IsId(value) ? value! : throw ApiException.Invalid($"{field} must be 32 lowercase hex characters");

    public static byte[] Bytes(string? value, string field, int exactLength)
    {
        if (!TryB64(value, out var bytes))
            throw ApiException.Invalid($"{field} must be base64url without padding");
        if (bytes.Length != exactLength)
            throw ApiException.Invalid($"{field} must be {exactLength} bytes");
        return bytes;
    }

    public static byte[] Blob(string? value, string field, int maxLength)
    {
        if (value is null) throw ApiException.Invalid($"{field} is required");
        // Cheap pre-check so an oversized value is never decoded.
        if ((long)value.Length / 4 * 3 > maxLength + 3L)
            throw new ApiException(413, "blob_too_large", $"{field} exceeds {maxLength} bytes");
        if (!TryB64(value, out var bytes))
            throw ApiException.Invalid($"{field} must be base64url without padding");
        if (bytes.Length == 0) throw ApiException.Invalid($"{field} must not be empty");
        if (bytes.Length > maxLength)
            throw new ApiException(413, "blob_too_large", $"{field} exceeds {maxLength} bytes");
        return bytes;
    }

    public static string Text(string? value, string field, int maxLength)
    {
        var text = value?.Trim();
        if (string.IsNullOrEmpty(text)) throw ApiException.Invalid($"{field} is required");
        if (text.Length > maxLength) throw ApiException.Invalid($"{field} is longer than {maxLength} characters");
        foreach (var c in text)
            if (char.IsControl(c)) throw ApiException.Invalid($"{field} contains control characters");
        return text;
    }

    public static string Timestamp(long unixMs) =>
        DateTimeOffset.FromUnixTimeMilliseconds(unixMs).UtcDateTime.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'");
}

internal static class Tokens
{
    public const int Length = 32;

    /// <summary>Returns a fresh token (shown to the client once) and the hash that is stored.</summary>
    public static (string Token, byte[] Hash) Create()
    {
        var raw = RandomNumberGenerator.GetBytes(Length);
        return (Codec.B64(raw), SHA256.HashData(raw));
    }

    public static byte[]? HashOf(string? token) =>
        Codec.TryB64(token, out var raw) && raw.Length == Length ? SHA256.HashData(raw) : null;
}

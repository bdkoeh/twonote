using System.Text.Json;
using System.Text.Json.Serialization;
using TwoNote.Core.Crypto;

namespace TwoNote.Core.Api;

/// <summary>The server answered with a protocol error (PROTOCOL.md section 3, "Error codes").</summary>
public sealed class ApiException : Exception
{
    /// <summary>Creates the exception.</summary>
    public ApiException(int status, string code, string message, TimeSpan? retryAfter = null)
        : base(message)
    {
        Status = status;
        Code = code;
        RetryAfter = retryAfter;
    }

    /// <summary>The HTTP status.</summary>
    public int Status { get; }

    /// <summary>The protocol error code, e.g. <c>bad_signature</c> or <c>doc_deleted</c>.</summary>
    public string Code { get; }

    /// <summary>The <c>Retry-After</c> value of a 429, when the server sent one.</summary>
    public TimeSpan? RetryAfter { get; }
}

/// <summary>The server could not be reached, or the connection failed before a complete answer arrived.</summary>
public sealed class ServerUnreachableException : Exception
{
    /// <summary>Creates the exception.</summary>
    public ServerUnreachableException(string message, Exception? inner = null)
        : base(message, inner)
    {
    }
}

/// <summary>The server answered with something PROTOCOL.md does not allow.</summary>
public sealed class ProtocolViolationException : Exception
{
    /// <summary>Creates the exception.</summary>
    public ProtocolViolationException(string message)
        : base(message)
    {
    }
}

/// <summary>The protocol error codes a client reacts to.</summary>
public static class ErrorCodes
{
    /// <summary>401: missing, unknown or revoked token.</summary>
    public const string Unauthorized = "unauthorized";

    /// <summary>401: the login signature did not verify, or the challenge was unknown, expired or reused.</summary>
    public const string BadSignature = "bad_signature";

    /// <summary>403: an account already exists.</summary>
    public const string RegistrationClosed = "registration_closed";

    /// <summary>404: the notebook does not exist (any more).</summary>
    public const string UnknownNotebook = "unknown_notebook";

    /// <summary>404: the document does not exist.</summary>
    public const string UnknownDoc = "unknown_doc";

    /// <summary>404: the document has no snapshot.</summary>
    public const string NoSnapshot = "no_snapshot";

    /// <summary>409: a snapshot covering a higher seq is already stored.</summary>
    public const string StaleSnapshot = "stale_snapshot";

    /// <summary>410: the document was deleted; its outbox must be dropped.</summary>
    public const string DocDeleted = "doc_deleted";

    /// <summary>429: too many attempts.</summary>
    public const string RateLimited = "rate_limited";
}

/// <summary><c>GET /status</c>.</summary>
public sealed record ServerStatus(string Version, int Protocol, bool RegistrationOpen);

/// <summary>Body of <c>POST /register</c>.</summary>
public sealed record RegisterRequest(
    string Username, string AccountId, byte[] KdfSalt, KdfParams KdfParams, byte[] AuthPublicKey, byte[] WrappedVaultKey, string DeviceName);

/// <summary>Answer of <c>POST /register</c>.</summary>
public sealed record DeviceSession(string DeviceId, string Token);

/// <summary>Answer of <c>POST /auth/start</c>.</summary>
public sealed record AuthChallenge(string AccountId, byte[] KdfSalt, KdfParams KdfParams, string ChallengeId, byte[] Nonce);

/// <summary>Answer of <c>POST /auth/finish</c>.</summary>
public sealed record AuthResult(string DeviceId, string Token, byte[] WrappedVaultKey);

/// <summary>One entry of <c>GET /devices</c>.</summary>
public sealed record DeviceInfo(string DeviceId, string Name, DateTimeOffset CreatedAt, DateTimeOffset LastSeenAt, bool Current);

/// <summary>Body of <c>POST /account/rekey</c>.</summary>
public sealed record RekeyRequest(byte[] KdfSalt, KdfParams KdfParams, byte[] AuthPublicKey, byte[] WrappedVaultKey);

/// <summary>One entry of <c>GET /notebooks</c>.</summary>
public sealed record NotebookEntry(string NotebookId, byte[] WrappedKey);

/// <summary>One entry of <c>GET /docs</c>.</summary>
public sealed record DocEntry(string DocId, string NotebookId, long SnapshotSeq);

/// <summary>One update in a push.</summary>
public sealed record OutgoingUpdate(string ClientUpdateId, byte[] Blob);

/// <summary>Answer of <c>POST /docs/{docId}/updates</c>.</summary>
public sealed record PushResult(IReadOnlyList<long> Seqs, long Head);

/// <summary>A stored snapshot.</summary>
public sealed record SnapshotEntry(long CoveredSeq, byte[] Blob);

/// <summary>Answer of <c>PUT /docs/{docId}/snapshot</c>.</summary>
public sealed record PutSnapshotResult(long Seq, long Head);

/// <summary>One event of <c>GET /events</c>. Which fields are set depends on <see cref="Type"/>.</summary>
public sealed record ServerEvent(long Seq, string Type, string? DocId, string? NotebookId, string? DeviceId, byte[]? Blob, long? CoveredSeq)
{
    /// <summary><c>update</c>.</summary>
    public const string Update = "update";

    /// <summary><c>snapshot</c>.</summary>
    public const string Snapshot = "snapshot";

    /// <summary><c>docDeleted</c>.</summary>
    public const string DocDeleted = "docDeleted";

    /// <summary><c>notebooksChanged</c>.</summary>
    public const string NotebooksChanged = "notebooksChanged";
}

/// <summary>Answer of <c>GET /events</c>.</summary>
public sealed record EventsPage(IReadOnlyList<ServerEvent> Events, long Head, bool More);

internal sealed record HeadMessage(long Head);

internal sealed record ErrorBody(string? Error, string? Message);

internal sealed record AuthStartBody(string Username);

internal sealed record AuthFinishBody(string ChallengeId, byte[] Signature, string DeviceName, string? DeviceId);

internal sealed record PutNotebookBody(byte[] WrappedKey);

internal sealed record PushBody(string NotebookId, IReadOnlyList<OutgoingUpdate> Updates);

internal sealed record TokenHello(string Token);

/// <summary>Binary values travel as base64url without padding.</summary>
internal sealed class Base64UrlConverter : JsonConverter<byte[]>
{
    public override byte[]? Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options) =>
        WireEncoding.TryFromBase64Url(reader.GetString(), out var bytes)
            ? bytes
            : throw new JsonException("Value is not base64url without padding.");

    public override void Write(Utf8JsonWriter writer, byte[] value, JsonSerializerOptions options) =>
        writer.WriteStringValue(WireEncoding.ToBase64Url(value));
}

internal static class WireJson
{
    public static readonly JsonSerializerOptions Options = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
        Converters = { new Base64UrlConverter() },
    };
}

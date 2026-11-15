namespace TwoNote.Server;

// Wire shapes from docs/PROTOCOL.md section 3. Request fields are nullable so that a missing
// field becomes a 400 with a useful message instead of a deserialisation failure.

public sealed record KdfParams(string? Alg, int Ops, int MemKiB)
{
    public static readonly KdfParams Default = new("argon2id13", 3, 65536);
}

public sealed record StatusResponse(string Version, int Protocol, bool RegistrationOpen);

public sealed record RegisterRequest(
    string? Username, string? AccountId, string? KdfSalt, KdfParams? KdfParams,
    string? AuthPublicKey, string? WrappedVaultKey, string? DeviceName);

public sealed record RegisterResponse(string DeviceId, string Token);

public sealed record AuthStartRequest(string? Username);

public sealed record AuthStartResponse(
    string AccountId, string KdfSalt, KdfParams KdfParams, string ChallengeId, string Nonce);

public sealed record AuthFinishRequest(string? ChallengeId, string? Signature, string? DeviceName, string? DeviceId);

public sealed record AuthFinishResponse(string DeviceId, string Token, string WrappedVaultKey);

public sealed record DeviceResponse(string DeviceId, string Name, string CreatedAt, string LastSeenAt, bool Current);

public sealed record RekeyRequest(string? KdfSalt, KdfParams? KdfParams, string? AuthPublicKey, string? WrappedVaultKey);

public sealed record NotebookResponse(string NotebookId, string WrappedKey);

public sealed record PutNotebookRequest(string? WrappedKey);

public sealed record DocResponse(string DocId, string NotebookId, long SnapshotSeq);

public sealed record UpdateItem(string? ClientUpdateId, string? Blob);

public sealed record PushUpdatesRequest(string? NotebookId, List<UpdateItem?>? Updates);

public sealed record PushUpdatesResponse(List<long> Seqs, long Head);

public sealed record SnapshotBody(long? CoveredSeq, string? Blob);

public sealed record SnapshotResponse(long CoveredSeq, string Blob);

public sealed record PutSnapshotResponse(long Seq, long Head);

public sealed record HeadResponse(long Head);

public sealed record EventResponse(
    long Seq, string Type, string? DocId, string? NotebookId, string? DeviceId, string? Blob, long? CoveredSeq);

public sealed record EventsResponse(List<EventResponse> Events, long Head, bool More);

public sealed record ErrorResponse(string Error, string Message);

public sealed record WsHello(string? Token);

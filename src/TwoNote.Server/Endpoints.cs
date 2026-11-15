using System.Reflection;
using System.Text.Json;

namespace TwoNote.Server;

internal static class Endpoints
{
    private const string DeviceKey = "twonote.device";

    private static readonly string Version =
        (typeof(Endpoints).Assembly.GetCustomAttribute<AssemblyInformationalVersionAttribute>()?.InformationalVersion ?? "0.0.0")
        .Split('+')[0];

    public static void MapTwoNoteApi(this WebApplication app)
    {
        var api = app.MapGroup("/api/v1");

        api.MapGet("/status", (Store store) => Ok(new StatusResponse(Version, 1, !store.HasAccount())));
        api.MapPost("/register", Register);
        api.MapPost("/auth/start", AuthStart);
        api.MapPost("/auth/finish", AuthFinish);
        api.MapGet("/ws", WebSocketEndpoint.Handle);

        var authed = api.MapGroup("").AddEndpointFilter(RequireBearer);

        authed.MapGet("/devices", (HttpContext ctx, Store store) =>
        {
            var current = Device(ctx).DeviceId;
            return Ok(store.ListDevices().Select(d => new DeviceResponse(
                d.DeviceId, d.Name, Codec.Timestamp(d.CreatedAt), Codec.Timestamp(d.LastSeenAt), d.DeviceId == current)));
        });

        authed.MapDelete("/devices/{deviceId}", (string deviceId, Store store, ILoggerFactory log) =>
        {
            store.DeleteDevice(Codec.Id(deviceId, "deviceId"));
            Log(log).LogInformation("Device {DeviceId} revoked", deviceId);
            return Results.NoContent();
        });

        authed.MapPost("/account/rekey", Rekey);

        authed.MapGet("/notebooks", (Store store) =>
            Ok(store.ListNotebooks().Select(n => new NotebookResponse(n.NotebookId, Codec.B64(n.WrappedKey)))));

        authed.MapPut("/notebooks/{notebookId}", async (string notebookId, HttpContext ctx, Store store, TwoNoteOptions options) =>
        {
            Codec.Id(notebookId, "notebookId");
            var body = await Body<PutNotebookRequest>(ctx, options);
            var wrappedKey = Codec.Blob(body.WrappedKey, "wrappedKey", options.MaxWrappedKeyBytes);
            return Ok(new HeadResponse(store.PutNotebook(notebookId, wrappedKey)));
        });

        authed.MapDelete("/notebooks/{notebookId}", (string notebookId, Store store) =>
            Ok(new HeadResponse(store.DeleteNotebook(Codec.Id(notebookId, "notebookId")))));

        authed.MapGet("/docs", (Store store) =>
            Ok(store.ListDocs().Select(d => new DocResponse(d.DocId, d.NotebookId, d.SnapshotSeq))));

        authed.MapPost("/docs/{docId}/updates", PushUpdates);

        authed.MapGet("/docs/{docId}/snapshot", (string docId, Store store) =>
            store.GetSnapshot(Codec.Id(docId, "docId")) is { } s
                ? Ok(new SnapshotResponse(s.CoveredSeq, Codec.B64(s.Blob)))
                : throw new ApiException(404, "no_snapshot", "The document has no snapshot"));

        authed.MapPut("/docs/{docId}/snapshot", async (string docId, HttpContext ctx, Store store, TwoNoteOptions options) =>
        {
            Codec.Id(docId, "docId");
            var body = await Body<SnapshotBody>(ctx, options);
            if (body.CoveredSeq is not { } coveredSeq || coveredSeq < 1)
                throw ApiException.Invalid("coveredSeq must be a positive integer");
            var blob = Codec.Blob(body.Blob, "blob", options.MaxBlobBytes);
            var (seq, head) = store.PutSnapshot(docId, coveredSeq, blob);
            return Ok(new PutSnapshotResponse(seq, head));
        });

        authed.MapDelete("/docs/{docId}", (string docId, Store store) =>
            Ok(new HeadResponse(store.DeleteDoc(Codec.Id(docId, "docId")))));

        authed.MapGet("/events", GetEvents);

        app.MapFallback(() => { throw new ApiException(404, "not_found", "No such endpoint"); });
    }

    // ---- unauthenticated ------------------------------------------------------------------

    private static async Task<IResult> Register(HttpContext ctx, Store store, TwoNoteOptions options, ILoggerFactory log)
    {
        var body = await Body<RegisterRequest>(ctx, options);
        var account = new AccountRow(
            Codec.Text(body.Username, "username", 64),
            Codec.Id(body.AccountId, "accountId"),
            Codec.Bytes(body.KdfSalt, "kdfSalt", 16),
            ValidKdfParams(body.KdfParams),
            ValidPublicKey(body.AuthPublicKey),
            Codec.Blob(body.WrappedVaultKey, "wrappedVaultKey", options.MaxWrappedKeyBytes));
        var deviceName = Codec.Text(body.DeviceName, "deviceName", 100);

        var (token, hash) = Tokens.Create();
        var deviceId = store.Register(account, deviceName, hash);
        Log(log).LogInformation("Account registered; first device {DeviceId}", deviceId);
        return Results.Json(new RegisterResponse(deviceId, token), Json.Options, statusCode: 201);
    }

    private static async Task<IResult> AuthStart(HttpContext ctx, Store store, ChallengeStore challenges, TwoNoteOptions options)
    {
        var body = await Body<AuthStartRequest>(ctx, options);
        var username = LoginCrypto.NormalizeUsername(Codec.Text(body.Username, "username", 64));

        var account = store.GetAccount();
        var isReal = account is not null && LoginCrypto.NormalizeUsername(account.Username) == username;
        var (challengeId, nonce) = challenges.Issue(isReal);

        if (isReal)
            return Ok(new AuthStartResponse(account!.AccountId, Codec.B64(account.KdfSalt), account.KdfParams, challengeId, Codec.B64(nonce)));

        // Unknown username: same shape, values that never change for that name.
        var (fakeAccountId, fakeSalt) = LoginCrypto.FakeIdentity(store.ServerSecret, username);
        return Ok(new AuthStartResponse(
            fakeAccountId, Codec.B64(fakeSalt), account?.KdfParams ?? KdfParams.Default, challengeId, Codec.B64(nonce)));
    }

    private static async Task<IResult> AuthFinish(
        HttpContext ctx, Store store, ChallengeStore challenges, LoginRateLimiter limiter, TwoNoteOptions options, ILoggerFactory log)
    {
        var source = ctx.Connection.RemoteIpAddress?.ToString() ?? "unknown";
        if (limiter.BlockedFor(source) is { } wait)
        {
            ctx.Response.Headers.RetryAfter = Math.Max(1, (int)Math.Ceiling(wait.TotalSeconds)).ToString();
            throw new ApiException(429, "rate_limited", "Too many failed login attempts; try again later");
        }

        var body = await Body<AuthFinishRequest>(ctx, options);
        var challengeId = Codec.Id(body.ChallengeId, "challengeId");
        if (!Codec.TryB64(body.Signature, out var signature))
            throw ApiException.Invalid("signature must be base64url without padding");
        var deviceName = Codec.Text(body.DeviceName, "deviceName", 100);
        var deviceId = body.DeviceId is null ? null : Codec.Id(body.DeviceId, "deviceId");

        var challenge = challenges.Take(challengeId);
        var account = store.GetAccount();
        var ok = challenge is { IsReal: true } && account is not null
                 && LoginCrypto.Verify(account.AuthPublicKey, challenge.Nonce, signature);
        if (!ok)
        {
            limiter.RecordFailure(source);
            Log(log).LogWarning("Failed login attempt from {Source}", source);
            throw new ApiException(401, "bad_signature",
                challenge is null ? "The challenge is unknown, expired or already used" : "The signature is not valid");
        }

        var (token, hash) = Tokens.Create();
        var id = store.Login(deviceId, deviceName, hash);
        Log(log).LogInformation("Device {DeviceId} logged in from {Source}", id, source);
        return Ok(new AuthFinishResponse(id, token, Codec.B64(account!.WrappedVaultKey)));
    }

    // ---- authenticated --------------------------------------------------------------------

    private static async ValueTask<object?> RequireBearer(EndpointFilterInvocationContext context, EndpointFilterDelegate next)
    {
        var ctx = context.HttpContext;
        var device = Authenticate(ctx.Request.Headers.Authorization.ToString(), ctx.RequestServices);
        if (device is null)
        {
            ctx.Response.Headers.WWWAuthenticate = "Bearer";
            throw new ApiException(401, "unauthorized", "A valid bearer token is required");
        }

        ctx.Items[DeviceKey] = device;
        return await next(context);
    }

    private static DeviceRow? Authenticate(string header, IServiceProvider services)
    {
        const string scheme = "Bearer ";
        return header.StartsWith(scheme, StringComparison.OrdinalIgnoreCase)
            ? AuthenticateToken(header[scheme.Length..].Trim(), services)
            : null;
    }

    /// <summary>Resolves a token to its device, refreshing lastSeenAt at most once a minute.</summary>
    public static DeviceRow? AuthenticateToken(string? token, IServiceProvider services)
    {
        if (Tokens.HashOf(token) is not { } hash) return null;
        var store = services.GetRequiredService<Store>();
        var device = store.FindDevice(hash);
        if (device is null) return null;
        var now = services.GetRequiredService<TimeProvider>().GetUtcNow().ToUnixTimeMilliseconds();
        if (now - device.LastSeenAt > 60_000) store.TouchDevice(device.DeviceId);
        return device;
    }

    private static DeviceRow Device(HttpContext ctx) => (DeviceRow)ctx.Items[DeviceKey]!;

    private static async Task<IResult> Rekey(HttpContext ctx, Store store, TwoNoteOptions options, ILoggerFactory log)
    {
        var body = await Body<RekeyRequest>(ctx, options);
        var device = Device(ctx);
        store.Rekey(
            Codec.Bytes(body.KdfSalt, "kdfSalt", 16),
            ValidKdfParams(body.KdfParams),
            ValidPublicKey(body.AuthPublicKey),
            Codec.Blob(body.WrappedVaultKey, "wrappedVaultKey", options.MaxWrappedKeyBytes),
            device.DeviceId);
        Log(log).LogInformation("Credentials replaced by device {DeviceId}; other devices revoked", device.DeviceId);
        return Results.NoContent();
    }

    private static async Task<IResult> PushUpdates(string docId, HttpContext ctx, Store store, TwoNoteOptions options)
    {
        Codec.Id(docId, "docId");
        var body = await Body<PushUpdatesRequest>(ctx, options);
        var notebookId = Codec.Id(body.NotebookId, "notebookId");
        if (body.Updates is not { Count: > 0 } items) throw ApiException.Invalid("updates must not be empty");
        if (items.Count > options.MaxUpdatesPerRequest)
            throw ApiException.Invalid($"At most {options.MaxUpdatesPerRequest} updates per request");

        var updates = new List<(string, byte[])>(items.Count);
        foreach (var item in items)
        {
            if (item is null) throw ApiException.Invalid("updates must not contain null");
            updates.Add((Codec.Id(item.ClientUpdateId, "clientUpdateId"), Codec.Blob(item.Blob, "blob", options.MaxBlobBytes)));
        }

        var (seqs, head) = store.PushUpdates(docId, notebookId, Device(ctx).DeviceId, updates);
        return Ok(new PushUpdatesResponse(seqs, head));
    }

    private static IResult GetEvents(HttpContext ctx, Store store, TwoNoteOptions options)
    {
        long after = 0;
        var limit = options.EventsDefaultLimit;
        if (ctx.Request.Query.TryGetValue("after", out var afterText) && (!long.TryParse(afterText, out after) || after < 0))
            throw ApiException.Invalid("after must be a non-negative integer");
        if (ctx.Request.Query.TryGetValue("limit", out var limitText) && (!int.TryParse(limitText, out limit) || limit < 1))
            throw ApiException.Invalid("limit must be a positive integer");
        limit = Math.Min(limit, options.EventsMaxLimit);

        var (events, head, more) = store.GetEvents(after, limit, options.EventsPageByteBudget);
        return Ok(new EventsResponse(
            events.Select(e => new EventResponse(
                e.Seq, e.Type, e.DocId, e.NotebookId, e.DeviceId, e.Blob is null ? null : Codec.B64(e.Blob), e.CoveredSeq)).ToList(),
            head, more));
    }

    // ---- helpers --------------------------------------------------------------------------

    private static IResult Ok<T>(T value) => Results.Json(value, Json.Options);

    private static ILogger Log(ILoggerFactory factory) => factory.CreateLogger("TwoNote.Server.Api");

    private static KdfParams ValidKdfParams(KdfParams? p)
    {
        if (p is null) throw ApiException.Invalid("kdfParams is required");
        if (p.Alg != "argon2id13") throw ApiException.Invalid("kdfParams.alg must be \"argon2id13\"");
        if (p.Ops < 1 || p.MemKiB < 8) throw ApiException.Invalid("kdfParams.ops and kdfParams.memKiB are out of range");
        return p;
    }

    private static byte[] ValidPublicKey(string? value)
    {
        var key = Codec.Bytes(value, "authPublicKey", 32);
        return LoginCrypto.IsValidPublicKey(key) ? key : throw ApiException.Invalid("authPublicKey is not a valid Ed25519 public key");
    }

    private static async Task<T> Body<T>(HttpContext ctx, TwoNoteOptions options) where T : class
    {
        if (ctx.Request.ContentLength > options.MaxRequestBodyBytes)
            throw new ApiException(413, "payload_too_large", "The request body is too large");
        try
        {
            return await JsonSerializer.DeserializeAsync<T>(ctx.Request.Body, Json.Options, ctx.RequestAborted)
                   ?? throw ApiException.Invalid("A JSON object is required");
        }
        catch (JsonException)
        {
            // The parser's message can quote input, so it is not passed on or logged.
            throw ApiException.Invalid("The request body is not valid JSON for this endpoint");
        }
    }
}

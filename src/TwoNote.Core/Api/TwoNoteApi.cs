using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Text.Json;

namespace TwoNote.Core.Api;

/// <summary>
/// Typed client for every HTTP endpoint of PROTOCOL.md section 3. Failures surface as
/// <see cref="ApiException"/> (the server said no), <see cref="ServerUnreachableException"/>
/// (no usable answer) or <see cref="ProtocolViolationException"/> (an answer outside the protocol).
/// Thread safe.
/// </summary>
public sealed class TwoNoteApi : IDisposable
{
    private readonly HttpClient _http;
    private volatile string? _token;

    /// <summary>Creates a client for the server at <paramref name="serverUrl"/> (scheme, host and port; no path).</summary>
    /// <param name="serverUrl">For example <c>http://nas.local:8080</c>.</param>
    /// <param name="handler">Optional transport, used by tests to talk to an in-process server.</param>
    /// <param name="timeout">Per-request timeout; 30 seconds by default.</param>
    public TwoNoteApi(Uri serverUrl, HttpMessageHandler? handler = null, TimeSpan? timeout = null)
    {
        ArgumentNullException.ThrowIfNull(serverUrl);
        ServerUrl = serverUrl;
        _http = handler is null ? new HttpClient() : new HttpClient(handler, disposeHandler: false);
        _http.BaseAddress = new Uri(serverUrl, "/api/v1/");
        _http.Timeout = timeout ?? TimeSpan.FromSeconds(30);
    }

    /// <summary>The server this client talks to.</summary>
    public Uri ServerUrl { get; }

    /// <summary>The session token sent with authenticated requests. Never logged.</summary>
    public string? Token
    {
        get => _token;
        set => _token = value;
    }

    /// <summary>The WebSocket address of the head listener endpoint.</summary>
    public Uri WebSocketUrl =>
        new UriBuilder(new Uri(ServerUrl, "/api/v1/ws")) { Scheme = ServerUrl.Scheme == Uri.UriSchemeHttps ? "wss" : "ws" }.Uri;

    // ---- unauthenticated ------------------------------------------------------------------

    /// <summary><c>GET /status</c>.</summary>
    public Task<ServerStatus> GetStatusAsync(CancellationToken ct = default) =>
        SendAsync<ServerStatus>(HttpMethod.Get, "status", null, authenticated: false, ct);

    /// <summary><c>POST /register</c>: creates the account and its first device.</summary>
    public Task<DeviceSession> RegisterAsync(RegisterRequest request, CancellationToken ct = default) =>
        SendAsync<DeviceSession>(HttpMethod.Post, "register", request, authenticated: false, ct);

    /// <summary><c>POST /auth/start</c>: fetches the KDF inputs and a login challenge.</summary>
    public Task<AuthChallenge> AuthStartAsync(string username, CancellationToken ct = default) =>
        SendAsync<AuthChallenge>(HttpMethod.Post, "auth/start", new AuthStartBody(username), authenticated: false, ct);

    /// <summary><c>POST /auth/finish</c>: answers the challenge. <paramref name="deviceId"/> re-uses an existing device.</summary>
    public Task<AuthResult> AuthFinishAsync(
        string challengeId, byte[] signature, string deviceName, string? deviceId = null, CancellationToken ct = default) =>
        SendAsync<AuthResult>(HttpMethod.Post, "auth/finish", new AuthFinishBody(challengeId, signature, deviceName, deviceId), authenticated: false, ct);

    // ---- authenticated --------------------------------------------------------------------

    /// <summary><c>GET /devices</c>.</summary>
    public Task<IReadOnlyList<DeviceInfo>> GetDevicesAsync(CancellationToken ct = default) =>
        SendAsync<IReadOnlyList<DeviceInfo>>(HttpMethod.Get, "devices", null, authenticated: true, ct);

    /// <summary><c>DELETE /devices/{deviceId}</c>: revokes that device's token.</summary>
    public Task DeleteDeviceAsync(string deviceId, CancellationToken ct = default) =>
        SendAsync<object>(HttpMethod.Delete, "devices/" + Id(deviceId), null, authenticated: true, ct, expectBody: false);

    /// <summary><c>POST /account/rekey</c>: replaces the credentials; other devices are revoked.</summary>
    public Task RekeyAsync(RekeyRequest request, CancellationToken ct = default) =>
        SendAsync<object>(HttpMethod.Post, "account/rekey", request, authenticated: true, ct, expectBody: false);

    /// <summary><c>GET /notebooks</c>.</summary>
    public Task<IReadOnlyList<NotebookEntry>> GetNotebooksAsync(CancellationToken ct = default) =>
        SendAsync<IReadOnlyList<NotebookEntry>>(HttpMethod.Get, "notebooks", null, authenticated: true, ct);

    /// <summary><c>PUT /notebooks/{notebookId}</c>: creates or replaces; returns the new head.</summary>
    public async Task<long> PutNotebookAsync(string notebookId, byte[] wrappedKey, CancellationToken ct = default) =>
        (await SendAsync<HeadMessage>(HttpMethod.Put, "notebooks/" + Id(notebookId), new PutNotebookBody(wrappedKey), authenticated: true, ct)
            .ConfigureAwait(false)).Head;

    /// <summary><c>DELETE /notebooks/{notebookId}</c>; returns the new head.</summary>
    public async Task<long> DeleteNotebookAsync(string notebookId, CancellationToken ct = default) =>
        (await SendAsync<HeadMessage>(HttpMethod.Delete, "notebooks/" + Id(notebookId), null, authenticated: true, ct).ConfigureAwait(false)).Head;

    /// <summary><c>GET /docs</c>.</summary>
    public Task<IReadOnlyList<DocEntry>> GetDocsAsync(CancellationToken ct = default) =>
        SendAsync<IReadOnlyList<DocEntry>>(HttpMethod.Get, "docs", null, authenticated: true, ct);

    /// <summary><c>POST /docs/{docId}/updates</c>. Idempotent per <c>clientUpdateId</c>.</summary>
    public async Task<PushResult> PushUpdatesAsync(
        string docId, string notebookId, IReadOnlyList<OutgoingUpdate> updates, CancellationToken ct = default)
    {
        var result = await SendAsync<PushResult>(
            HttpMethod.Post, $"docs/{Id(docId)}/updates", new PushBody(notebookId, updates), authenticated: true, ct).ConfigureAwait(false);
        if (result.Seqs is null || result.Seqs.Count != updates.Count)
        {
            throw new ProtocolViolationException("The server acknowledged a different number of updates than were pushed.");
        }

        return result;
    }

    /// <summary><c>GET /docs/{docId}/snapshot</c>; null when the document has none (or does not exist).</summary>
    public async Task<SnapshotEntry?> GetSnapshotAsync(string docId, CancellationToken ct = default)
    {
        try
        {
            return await SendAsync<SnapshotEntry>(HttpMethod.Get, $"docs/{Id(docId)}/snapshot", null, authenticated: true, ct).ConfigureAwait(false);
        }
        catch (ApiException e) when (e.Status == 404)
        {
            return null;
        }
    }

    /// <summary><c>PUT /docs/{docId}/snapshot</c>.</summary>
    public Task<PutSnapshotResult> PutSnapshotAsync(string docId, long coveredSeq, byte[] blob, CancellationToken ct = default) =>
        SendAsync<PutSnapshotResult>(HttpMethod.Put, $"docs/{Id(docId)}/snapshot", new SnapshotEntry(coveredSeq, blob), authenticated: true, ct);

    /// <summary><c>DELETE /docs/{docId}</c>; returns the new head.</summary>
    public async Task<long> DeleteDocAsync(string docId, CancellationToken ct = default) =>
        (await SendAsync<HeadMessage>(HttpMethod.Delete, "docs/" + Id(docId), null, authenticated: true, ct).ConfigureAwait(false)).Head;

    /// <summary><c>GET /events?after=&amp;limit=</c>.</summary>
    public async Task<EventsPage> GetEventsAsync(long after, int limit = 500, CancellationToken ct = default)
    {
        var page = await SendAsync<EventsPage>(HttpMethod.Get, $"events?after={after}&limit={limit}", null, authenticated: true, ct).ConfigureAwait(false);
        if (page.Events is null)
        {
            throw new ProtocolViolationException("The events answer has no event list.");
        }

        var last = after;
        foreach (var e in page.Events)
        {
            // Order is a correctness requirement (PROTOCOL.md section 4), so it is checked, not assumed.
            if (e is null || e.Type is null || e.Seq <= last)
            {
                throw new ProtocolViolationException("The server returned events out of seq order.");
            }

            last = e.Seq;
        }

        return page;
    }

    /// <inheritdoc />
    public void Dispose() => _http.Dispose();

    private static string Id(string id) =>
        WireEncoding.TryIdFromHex(id, out _) ? id : throw new ArgumentException("An id is exactly 32 lowercase hex characters.", nameof(id));

    private async Task<T> SendAsync<T>(
        HttpMethod method, string path, object? body, bool authenticated, CancellationToken ct, bool expectBody = true)
        where T : class
    {
        using var request = new HttpRequestMessage(method, path);
        if (body is not null)
        {
            request.Content = JsonContent.Create(body, body.GetType(), options: WireJson.Options);
        }

        if (authenticated)
        {
            var token = _token ?? throw new ApiException(401, ErrorCodes.Unauthorized, "This device has no session token.");
            request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
        }

        HttpResponseMessage response;
        byte[] payload;
        try
        {
            response = await _http.SendAsync(request, HttpCompletionOption.ResponseContentRead, ct).ConfigureAwait(false);
            payload = await response.Content.ReadAsByteArrayAsync(ct).ConfigureAwait(false);
        }
        catch (OperationCanceledException) when (!ct.IsCancellationRequested)
        {
            throw new ServerUnreachableException("The server did not answer in time.");
        }
        catch (Exception e) when (e is HttpRequestException or IOException)
        {
            // The exception text names the host and the socket error; it never contains request content.
            throw new ServerUnreachableException("The server could not be reached.", e);
        }

        using (response)
        {
            var status = (int)response.StatusCode;
            if (status is >= 200 and < 300)
            {
                if (!expectBody)
                {
                    return null!;
                }

                try
                {
                    return JsonSerializer.Deserialize<T>(payload, WireJson.Options)
                           ?? throw new ProtocolViolationException("The server sent an empty answer.");
                }
                catch (JsonException)
                {
                    throw new ProtocolViolationException("The server sent an answer that is not valid for this endpoint.");
                }
            }

            ErrorBody? error = null;
            try
            {
                error = JsonSerializer.Deserialize<ErrorBody>(payload, WireJson.Options);
            }
            catch (JsonException)
            {
            }

            // Gateways in front of the server answer 502-504 without a protocol body: that is "unreachable".
            if (error?.Error is null && status is 502 or 503 or 504)
            {
                throw new ServerUnreachableException($"The server is unavailable (HTTP {status}).");
            }

            TimeSpan? retryAfter = response.Headers.RetryAfter?.Delta;
            throw new ApiException(status, error?.Error ?? "http_" + status, error?.Message ?? $"HTTP {status}", retryAfter);
        }
    }
}

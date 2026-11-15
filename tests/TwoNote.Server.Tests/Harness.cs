using System.Buffers.Text;
using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Net.WebSockets;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Microsoft.AspNetCore.Mvc.Testing;
using Microsoft.AspNetCore.TestHost;
using Microsoft.Data.Sqlite;
using Microsoft.Extensions.DependencyInjection;
using TwoNote.Core.Crypto;

namespace TwoNote.Server.Tests;

public sealed class ManualTime : TimeProvider
{
    private DateTimeOffset _now = DateTimeOffset.UtcNow;
    public override DateTimeOffset GetUtcNow() => _now;
    public void Advance(TimeSpan by) => _now += by;
}

/// <summary>The real server in-process, on a SQLite file in a temp directory.</summary>
public sealed class TestApp : IDisposable
{
    private readonly bool _ownsDir;
    private readonly WebApplicationFactory<Program> _factory;

    public string DataDir { get; }
    public ManualTime Time { get; } = new();
    public Api Api { get; }

    public TestApp(string? dataDir = null, Action<TwoNoteOptions>? configure = null)
    {
        _ownsDir = dataDir is null;
        DataDir = dataDir ?? NewDataDir();
        var options = new TwoNoteOptions { DataDir = DataDir };
        configure?.Invoke(options);

        _factory = new WebApplicationFactory<Program>().WithWebHostBuilder(b => b.ConfigureTestServices(services =>
        {
            services.AddSingleton(options);
            services.AddSingleton<TimeProvider>(Time);
        }));
        Api = new Api(_factory.CreateClient());
    }

    public static string NewDataDir()
    {
        var dir = Path.Combine(Path.GetTempPath(), "twonote-tests", Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(dir);
        return dir;
    }

    public Task<WebSocket> ConnectWebSocketAsync() =>
        _factory.Server.CreateWebSocketClient().ConnectAsync(new Uri("ws://localhost/api/v1/ws"), CancellationToken.None);

    public void Dispose()
    {
        _factory.Dispose();
        if (_ownsDir) DeleteDataDir(DataDir);
    }

    public static void DeleteDataDir(string dir)
    {
        SqliteConnection.ClearAllPools();
        try
        {
            Directory.Delete(dir, recursive: true);
        }
        catch (IOException)
        {
            // Another test's pooled handle; the temp directory is cleaned up by the OS eventually.
        }
    }
}

/// <summary>Thin HTTP helper that works against the in-process server or a real one.</summary>
public sealed class Api(HttpClient http)
{
    public HttpClient Http => http;

    public async Task<HttpResponseMessage> Send(HttpMethod method, string path, object? body = null, string? token = null)
    {
        var request = new HttpRequestMessage(method, "/api/v1" + path);
        if (body is string raw) request.Content = new StringContent(raw, Encoding.UTF8, "application/json");
        else if (body is not null) request.Content = JsonContent.Create(body);
        if (token is not null) request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
        return await http.SendAsync(request);
    }

    public Task<HttpResponseMessage> Get(string path, string? token = null) => Send(HttpMethod.Get, path, null, token);
    public Task<HttpResponseMessage> Post(string path, object? body, string? token = null) => Send(HttpMethod.Post, path, body, token);
    public Task<HttpResponseMessage> Put(string path, object? body, string? token = null) => Send(HttpMethod.Put, path, body, token);
    public Task<HttpResponseMessage> Delete(string path, string? token = null) => Send(HttpMethod.Delete, path, null, token);

    /// <summary>Sends, asserts the status, and returns the JSON body (or default when empty).</summary>
    public async Task<JsonElement> Json(HttpMethod method, string path, object? body = null, string? token = null, int expect = 200)
    {
        using var response = await Send(method, path, body, token);
        var text = await response.Content.ReadAsStringAsync();
        Assert.True((int)response.StatusCode == expect, $"{method} {path}: expected {expect}, got {(int)response.StatusCode}: {Truncate(text)}");
        return text.Length == 0 ? default : JsonDocument.Parse(text).RootElement.Clone();
    }

    public Task<JsonElement> GetJson(string path, string? token = null, int expect = 200) => Json(HttpMethod.Get, path, null, token, expect);
    public Task<JsonElement> PostJson(string path, object? body, string? token = null, int expect = 200) => Json(HttpMethod.Post, path, body, token, expect);
    public Task<JsonElement> PutJson(string path, object? body, string? token = null, int expect = 200) => Json(HttpMethod.Put, path, body, token, expect);
    public Task<JsonElement> DeleteJson(string path, string? token = null, int expect = 200) => Json(HttpMethod.Delete, path, null, token, expect);

    /// <summary>Asserts a protocol error: status plus { error, message }.</summary>
    public async Task<JsonElement> Error(HttpMethod method, string path, int status, string code, object? body = null, string? token = null)
    {
        var error = await Json(method, path, body, token, status);
        Assert.Equal(["error", "message"], T.Names(error));
        Assert.Equal(code, error.GetProperty("error").GetString());
        Assert.False(string.IsNullOrWhiteSpace(error.GetProperty("message").GetString()));
        return error;
    }

    private static string Truncate(string s) => s.Length > 300 ? s[..300] + "…" : s;
}

/// <summary>An Ed25519 login key pair (libsodium layout: the private key is seed followed by public key).</summary>
public sealed record Key(byte[] Public, byte[] Private);

/// <summary>A client-side identity: the Ed25519 login key and the values a real client would derive.</summary>
public sealed class TestAccount
{
    public string Username { get; init; } = "bob";
    public string AccountId { get; } = T.NewId();
    public byte[] KdfSalt { get; private set; } = RandomNumberGenerator.GetBytes(16);
    public byte[] WrappedVaultKey { get; private set; } = RandomNumberGenerator.GetBytes(73);
    public Key Key { get; private set; } = NewKey();

    public static Key NewKey()
    {
        var key = new Key(new byte[32], new byte[64]);
        Geralt.Ed25519.GenerateKeyPair(key.Public, key.Private);
        return key;
    }
    public static object KdfParams => new { alg = "argon2id13", ops = 3, memKiB = 65536 };
    public string PublicKey => T.B64(Key.Public);

    public string Sign(byte[] nonce, Key? key = null) =>
        T.B64(LoginSignature.Sign((key ?? Key).Private, nonce));

    public object RegisterBody(string deviceName = "first device") => new
    {
        username = Username,
        accountId = AccountId,
        kdfSalt = T.B64(KdfSalt),
        kdfParams = KdfParams,
        authPublicKey = PublicKey,
        wrappedVaultKey = T.B64(WrappedVaultKey),
        deviceName,
    };

    public async Task<(string DeviceId, string Token)> Register(Api api, string deviceName = "first device")
    {
        var r = await api.PostJson("/register", RegisterBody(deviceName), expect: 201);
        Assert.Equal(["deviceId", "token"], T.Names(r));
        return (r.GetProperty("deviceId").GetString()!, r.GetProperty("token").GetString()!);
    }

    public async Task<(string ChallengeId, byte[] Nonce, JsonElement Body)> Start(Api api, string? username = null)
    {
        var r = await api.PostJson("/auth/start", new { username = username ?? Username });
        return (r.GetProperty("challengeId").GetString()!, T.FromB64(r.GetProperty("nonce").GetString()!), r);
    }

    public async Task<(string DeviceId, string Token, JsonElement Body)> Login(Api api, string deviceName = "another device", string? deviceId = null)
    {
        var (challengeId, nonce, _) = await Start(api);
        var r = await api.PostJson("/auth/finish", new { challengeId, signature = Sign(nonce), deviceName, deviceId });
        Assert.Equal(["deviceId", "token", "wrappedVaultKey"], T.Names(r));
        return (r.GetProperty("deviceId").GetString()!, r.GetProperty("token").GetString()!, r);
    }

    /// <summary>New credentials, as after a password change; returns the rekey request body.</summary>
    public object Rekey()
    {
        Key = NewKey();
        KdfSalt = RandomNumberGenerator.GetBytes(16);
        WrappedVaultKey = RandomNumberGenerator.GetBytes(73);
        return new { kdfSalt = T.B64(KdfSalt), kdfParams = KdfParams, authPublicKey = PublicKey, wrappedVaultKey = T.B64(WrappedVaultKey) };
    }
}

public static class T
{
    public static string NewId() => Convert.ToHexStringLower(RandomNumberGenerator.GetBytes(16));
    public static string B64(ReadOnlySpan<byte> bytes) => Base64Url.EncodeToString(bytes);
    public static byte[] FromB64(string s) => Base64Url.DecodeFromChars(s);
    public static byte[] Blob(int length = 48) => RandomNumberGenerator.GetBytes(length);

    public static string[] Names(JsonElement obj) => obj.EnumerateObject().Select(p => p.Name).Order(StringComparer.Ordinal).ToArray();

    public static bool IsId(string? s) => s is { Length: 32 } && s.All(c => c is (>= '0' and <= '9') or (>= 'a' and <= 'f'));

    public static object Update(byte[] blob, string? clientUpdateId = null) =>
        new { clientUpdateId = clientUpdateId ?? NewId(), blob = B64(blob) };

    /// <summary>Creates a notebook and returns its id.</summary>
    public static async Task<string> Notebook(Api api, string token)
    {
        var id = NewId();
        await api.PutJson($"/notebooks/{id}", new { wrappedKey = B64(Blob(73)) }, token);
        return id;
    }

    /// <summary>Pushes one update per blob and returns the assigned seqs.</summary>
    public static async Task<long[]> Push(Api api, string token, string docId, string notebookId, params byte[][] blobs)
    {
        var r = await api.PostJson($"/docs/{docId}/updates", new { notebookId, updates = blobs.Select(b => Update(b)).ToArray() }, token);
        return r.GetProperty("seqs").EnumerateArray().Select(s => s.GetInt64()).ToArray();
    }

    public static async Task<List<JsonElement>> AllEvents(Api api, string token, long after = 0, int limit = 500)
    {
        var all = new List<JsonElement>();
        while (true)
        {
            var page = await api.GetJson($"/events?after={after}&limit={limit}", token);
            var events = page.GetProperty("events").EnumerateArray().ToList();
            all.AddRange(events);
            if (!page.GetProperty("more").GetBoolean()) return all;
            after = events[^1].GetProperty("seq").GetInt64();
        }
    }

    // ---- WebSocket ----

    public static Task SendText(WebSocket ws, string text) =>
        ws.SendAsync(Encoding.UTF8.GetBytes(text), WebSocketMessageType.Text, true, CancellationToken.None);

    /// <summary>Next frame: the head from a {"head": n} message, or null with the close status.</summary>
    public static async Task<(long? Head, WebSocketCloseStatus? Close)> Receive(WebSocket ws, int timeoutMs = 10_000)
    {
        using var cts = new CancellationTokenSource(timeoutMs);
        var buffer = new byte[1024];
        var result = await ws.ReceiveAsync(buffer, cts.Token);
        if (result.MessageType == WebSocketMessageType.Close) return (null, result.CloseStatus);
        var json = JsonDocument.Parse(buffer.AsMemory(0, result.Count)).RootElement;
        Assert.Equal(["head"], Names(json));
        return (json.GetProperty("head").GetInt64(), null);
    }

    public static async Task AssertClosed(WebSocket ws, WebSocketCloseStatus status)
    {
        var (head, close) = await Receive(ws);
        Assert.Null(head);
        Assert.Equal(status, close);
    }

    public static async Task<long> ReceiveHead(WebSocket ws, int timeoutMs = 10_000)
    {
        var (head, close) = await Receive(ws, timeoutMs);
        Assert.True(head is not null, $"expected a head message, socket closed with {close}");
        return head!.Value;
    }
}

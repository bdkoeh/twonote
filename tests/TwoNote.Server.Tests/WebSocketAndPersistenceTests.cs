using System.Net.WebSockets;
using System.Text.Json;

namespace TwoNote.Server.Tests;

public class WebSocketTests
{
    [Fact]
    public async Task Socket_sends_head_after_the_token_and_again_whenever_it_advances()
    {
        using var app = new TestApp();
        var account = new TestAccount();
        var (_, token) = await account.Register(app.Api);
        var notebook = await T.Notebook(app.Api, token); // head 1

        using var ws = await app.ConnectWebSocketAsync();
        await T.SendText(ws, JsonSerializer.Serialize(new { token }));
        Assert.Equal(1, await T.ReceiveHead(ws));

        var doc = T.NewId();
        await T.Push(app.Api, token, doc, notebook, T.Blob());
        Assert.Equal(2, await T.ReceiveHead(ws));

        // A second device's socket hears about writes from the first, and vice versa.
        var (_, token2, _) = await account.Login(app.Api);
        using var ws2 = await app.ConnectWebSocketAsync();
        await T.SendText(ws2, JsonSerializer.Serialize(new { token = token2 }));
        Assert.Equal(2, await T.ReceiveHead(ws2));

        await T.Push(app.Api, token2, doc, notebook, T.Blob());
        Assert.Equal(3, await T.ReceiveHead(ws));
        Assert.Equal(3, await T.ReceiveHead(ws2));

        await app.Api.PutJson($"/docs/{doc}/snapshot", new { coveredSeq = 3, blob = T.B64(T.Blob()) }, token);
        Assert.Equal(4, await T.ReceiveHead(ws));
        await app.Api.DeleteJson($"/docs/{doc}", token);
        Assert.Equal(5, await T.ReceiveHead(ws));
        await app.Api.DeleteJson($"/notebooks/{notebook}", token);
        Assert.Equal(6, await T.ReceiveHead(ws));
        long last;
        do last = await T.ReceiveHead(ws2); while (last < 6); // intermediate heads may be coalesced; the latest always arrives
        Assert.Equal(6, last);

        // Requests that do not advance head say nothing.
        await app.Api.GetJson("/events", token);
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => T.Receive(ws, timeoutMs: 300));
    }

    [Fact]
    public async Task Socket_closes_cleanly_when_the_client_closes()
    {
        using var app = new TestApp();
        var (_, token) = await new TestAccount().Register(app.Api);
        using var ws = await app.ConnectWebSocketAsync();
        await T.SendText(ws, JsonSerializer.Serialize(new { token }));
        Assert.Equal(0, await T.ReceiveHead(ws));

        using var cts = new CancellationTokenSource(5000);
        await ws.CloseAsync(WebSocketCloseStatus.NormalClosure, null, cts.Token);
        Assert.Equal(WebSocketState.Closed, ws.State);
    }

    [Theory]
    [InlineData("{\"token\":\"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA\"}")] // well-formed, unknown
    [InlineData("{\"token\":\"nope\"}")]
    [InlineData("{}")]
    [InlineData("{\"Token\":null}")]
    [InlineData("hello")]
    public async Task Socket_is_closed_with_policy_violation_when_the_first_frame_is_not_a_valid_token(string frame)
    {
        using var app = new TestApp();
        await new TestAccount().Register(app.Api);
        using var ws = await app.ConnectWebSocketAsync();
        await T.SendText(ws, frame);
        await T.AssertClosed(ws, WebSocketCloseStatus.PolicyViolation);
    }

    [Fact]
    public async Task Socket_is_closed_with_policy_violation_when_no_token_arrives_in_time()
    {
        using var app = new TestApp(configure: o => o.WebSocketAuthTimeout = TimeSpan.FromMilliseconds(300));
        await new TestAccount().Register(app.Api);
        using var ws = await app.ConnectWebSocketAsync();
        await T.AssertClosed(ws, WebSocketCloseStatus.PolicyViolation);
    }

    [Fact]
    public void Socket_token_timeout_defaults_to_ten_seconds() =>
        Assert.Equal(TimeSpan.FromSeconds(10), new TwoNoteOptions().WebSocketAuthTimeout);

    [Fact]
    public async Task Socket_of_a_revoked_device_is_closed()
    {
        using var app = new TestApp();
        var account = new TestAccount();
        var (_, token1) = await account.Register(app.Api);
        var (device2, token2, _) = await account.Login(app.Api);

        using var ws = await app.ConnectWebSocketAsync();
        await T.SendText(ws, JsonSerializer.Serialize(new { token = token2 }));
        Assert.Equal(0, await T.ReceiveHead(ws));

        await app.Api.DeleteJson($"/devices/{device2}", token1, expect: 204);
        await T.AssertClosed(ws, WebSocketCloseStatus.PolicyViolation);
    }

    [Fact]
    public async Task Plain_get_on_the_socket_endpoint_is_a_400()
    {
        using var app = new TestApp();
        await app.Api.Error(HttpMethod.Get, "/ws", 400, "invalid_request");
    }
}

public class PersistenceTests
{
    [Fact]
    public async Task Everything_survives_a_restart_on_the_same_database_file()
    {
        var dir = TestApp.NewDataDir();
        try
        {
            var account = new TestAccount();
            string token, deviceId, notebook, doc, fakeBefore, eventsBefore, snapshotBefore;
            var updateId = T.NewId();

            using (var app = new TestApp(dir))
            {
                (deviceId, token) = await account.Register(app.Api);
                notebook = await T.Notebook(app.Api, token);                                   // 1
                doc = T.NewId();
                await app.Api.PostJson($"/docs/{doc}/updates",
                    new { notebookId = notebook, updates = new[] { T.Update(T.Blob(), updateId) } }, token); // 2
                await T.Push(app.Api, token, doc, notebook, T.Blob(), T.Blob());               // 3, 4
                await app.Api.PutJson($"/docs/{doc}/snapshot", new { coveredSeq = 2, blob = T.B64(T.Blob()) }, token); // 5
                fakeBefore = (await account.Start(app.Api, "ghost")).Body.GetProperty("accountId").GetString()!;
                eventsBefore = (await app.Api.GetJson("/events", token)).GetRawText();
                snapshotBefore = (await app.Api.GetJson($"/docs/{doc}/snapshot", token)).GetRawText();
            }

            Assert.True(File.Exists(Path.Combine(dir, "twonote.db")));

            using (var app = new TestApp(dir))
            {
                // Account: registration stays closed, the old token and the login key still work.
                Assert.False((await app.Api.GetJson("/status")).GetProperty("registrationOpen").GetBoolean());
                await app.Api.Error(HttpMethod.Post, "/register", 403, "registration_closed", new TestAccount().RegisterBody());
                var device = Assert.Single((await app.Api.GetJson("/devices", token)).EnumerateArray());
                Assert.Equal(deviceId, device.GetProperty("deviceId").GetString());
                await account.Login(app.Api);

                // Data: identical log, snapshot, notebooks and documents.
                Assert.Equal(eventsBefore, (await app.Api.GetJson("/events", token)).GetRawText());
                Assert.Equal(snapshotBefore, (await app.Api.GetJson($"/docs/{doc}/snapshot", token)).GetRawText());
                Assert.Equal(notebook, Assert.Single((await app.Api.GetJson("/notebooks", token)).EnumerateArray()).GetProperty("notebookId").GetString());
                Assert.Equal(2, Assert.Single((await app.Api.GetJson("/docs", token)).EnumerateArray()).GetProperty("snapshotSeq").GetInt64());

                // The counter carries on, idempotency records survive, and a new socket starts at the stored head.
                using var ws = await app.ConnectWebSocketAsync();
                await T.SendText(ws, JsonSerializer.Serialize(new { token }));
                Assert.Equal(5, await T.ReceiveHead(ws));
                var repeat = await app.Api.PostJson($"/docs/{doc}/updates",
                    new { notebookId = notebook, updates = new[] { T.Update(T.Blob(), updateId) } }, token);
                Assert.Equal(2, repeat.GetProperty("seqs")[0].GetInt64());
                Assert.Equal(new long[] { 6L }, await T.Push(app.Api, token, doc, notebook, T.Blob()));
                Assert.Equal(6, await T.ReceiveHead(ws));

                // The fake-identity secret is persisted too.
                Assert.Equal(fakeBefore, (await account.Start(app.Api, "ghost")).Body.GetProperty("accountId").GetString());
            }
        }
        finally
        {
            TestApp.DeleteDataDir(dir);
        }
    }

    [Fact]
    public async Task Tokens_are_stored_only_as_hashes_and_the_database_uses_wal()
    {
        var dir = TestApp.NewDataDir();
        try
        {
            string token;
            using (var app = new TestApp(dir))
            {
                (_, token) = await new TestAccount().Register(app.Api);

                await using var db = new Microsoft.Data.Sqlite.SqliteConnection($"Data Source={Path.Combine(dir, "twonote.db")};Mode=ReadOnly;Pooling=False");
                db.Open();
                await using var cmd = db.CreateCommand();
                cmd.CommandText = "PRAGMA journal_mode";
                Assert.Equal("wal", (string)cmd.ExecuteScalar()!);
                cmd.CommandText = "SELECT version FROM schema_version";
                Assert.Equal(2L, (long)cmd.ExecuteScalar()!);
                cmd.CommandText = "SELECT token_hash FROM devices";
                var stored = (byte[])cmd.ExecuteScalar()!;
                Assert.Equal(System.Security.Cryptography.SHA256.HashData(T.FromB64(token)), stored);
            }

            Microsoft.Data.Sqlite.SqliteConnection.ClearAllPools();
            // The raw token appears nowhere in the data directory.
            var raw = T.FromB64(token);
            foreach (var file in Directory.GetFiles(dir))
                Assert.Equal(-1, File.ReadAllBytes(file).AsSpan().IndexOf(raw));
        }
        finally
        {
            TestApp.DeleteDataDir(dir);
        }
    }
}

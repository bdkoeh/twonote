using System.Diagnostics;
using System.Net.WebSockets;
using System.Text.Json;

namespace TwoNote.Server.Tests;

/// <summary>
/// Runs against a real, freshly started server (normally the Docker container) instead of the
/// in-process one. Skipped unless TWONOTE_E2E_URL is set, e.g. http://localhost:18080.
/// If TWONOTE_E2E_RESTART_CMD is also set (e.g. "wsl -d Ubuntu -- docker restart twonote-e2e"),
/// the test runs it half way through and checks that everything survived.
/// </summary>
public class ContainerRoundTripTests
{
    [Fact]
    public async Task Register_login_push_events_and_restart_against_a_running_server()
    {
        var baseUrl = Environment.GetEnvironmentVariable("TWONOTE_E2E_URL");
        Assert.SkipWhen(string.IsNullOrWhiteSpace(baseUrl), "TWONOTE_E2E_URL is not set");
        var restart = Environment.GetEnvironmentVariable("TWONOTE_E2E_RESTART_CMD");

        using var http = new HttpClient { BaseAddress = new Uri(baseUrl!), Timeout = TimeSpan.FromSeconds(15) };
        var api = new Api(http);

        var status = await api.GetJson("/status");
        Assert.Equal(1, status.GetProperty("protocol").GetInt32());
        Assert.True(status.GetProperty("registrationOpen").GetBoolean(), "this test needs a server with an empty data volume");

        // Register, then log in as a second device with a real Ed25519 signature.
        var account = new TestAccount();
        var (device1, token1) = await account.Register(api, "e2e desktop");
        await api.Error(HttpMethod.Post, "/register", 403, "registration_closed", account.RegisterBody());
        var (device2, token2, login) = await account.Login(api, "e2e laptop");
        Assert.Equal(T.B64(account.WrappedVaultKey), login.GetProperty("wrappedVaultKey").GetString());
        var (badChallenge, badNonce, _) = await account.Start(api);
        await api.Error(HttpMethod.Post, "/auth/finish", 401, "bad_signature",
            new { challengeId = badChallenge, signature = account.Sign(badNonce, TestAccount.NewKey()), deviceName = "x" });

        // Device 2 listens; device 1 pushes.
        using var ws = await Connect(http.BaseAddress!, token2);
        Assert.Equal(0, await T.ReceiveHead(ws));

        var notebook = await T.Notebook(api, token1);
        var doc = T.NewId();
        var blobs = new[] { T.Blob(100), T.Blob(2000), T.Blob(1) };
        Assert.Equal(new long[] { 2L, 3L, 4L }, await T.Push(api, token1, doc, notebook, blobs));
        long head;
        do head = await T.ReceiveHead(ws); while (head < 4);
        Assert.Equal(4, head);

        // Device 2 pulls exactly what device 1 pushed.
        var events = await T.AllEvents(api, token2, limit: 2);
        Assert.Equal([1L, 2L, 3L, 4L], events.Select(e => e.GetProperty("seq").GetInt64()));
        Assert.Equal(blobs.Select(b => T.B64(b)), events.Skip(1).Select(e => e.GetProperty("blob").GetString()));
        Assert.All(events.Skip(1), e => Assert.Equal(device1, e.GetProperty("deviceId").GetString()));
        var before = (await api.GetJson("/events", token2)).GetRawText();

        if (!string.IsNullOrWhiteSpace(restart))
        {
            await Run(restart);
            await WaitUntilUp(api);
            // The old socket died with the server: either a close frame or a broken connection.
            try
            {
                Assert.Null((await T.Receive(ws, timeoutMs: 5000)).Head);
            }
            catch (Exception e) when (e is WebSocketException or OperationCanceledException or IOException)
            {
            }
        }

        // Same account, same tokens, same log; the counter carries on.
        Assert.False((await api.GetJson("/status")).GetProperty("registrationOpen").GetBoolean());
        Assert.Equal(before, (await api.GetJson("/events", token2)).GetRawText());
        Assert.Equal(2, (await api.GetJson("/devices", token1)).GetArrayLength());
        Assert.Equal(notebook, Assert.Single((await api.GetJson("/notebooks", token2)).EnumerateArray()).GetProperty("notebookId").GetString());
        await account.Login(api, "e2e laptop", deviceId: device2);

        using var ws2 = await Connect(http.BaseAddress!, token1);
        Assert.Equal(4, await T.ReceiveHead(ws2));
        await api.PutJson($"/docs/{doc}/snapshot", new { coveredSeq = 4, blob = T.B64(T.Blob(300)) }, token1);
        Assert.Equal(5, await T.ReceiveHead(ws2));
        var after = await T.AllEvents(api, token1);
        Assert.Equal([1L, 5L], after.Select(e => e.GetProperty("seq").GetInt64()));
        Assert.Equal("snapshot", after[1].GetProperty("type").GetString());
    }

    private static async Task<ClientWebSocket> Connect(Uri baseAddress, string token)
    {
        var ws = new ClientWebSocket();
        var uri = new UriBuilder(baseAddress) { Scheme = baseAddress.Scheme == "https" ? "wss" : "ws", Path = "/api/v1/ws" }.Uri;
        using var cts = new CancellationTokenSource(10_000);
        await ws.ConnectAsync(uri, cts.Token);
        await T.SendText(ws, JsonSerializer.Serialize(new { token }));
        return ws;
    }

    private static async Task Run(string commandLine)
    {
        var parts = commandLine.Split(' ', StringSplitOptions.RemoveEmptyEntries);
        using var process = Process.Start(new ProcessStartInfo(parts[0], parts[1..]) { UseShellExecute = false })!;
        await process.WaitForExitAsync();
        Assert.Equal(0, process.ExitCode);
    }

    private static async Task WaitUntilUp(Api api)
    {
        var deadline = DateTime.UtcNow.AddSeconds(60);
        while (true)
        {
            try
            {
                using var response = await api.Get("/status");
                if (response.IsSuccessStatusCode) return;
            }
            catch (Exception) when (DateTime.UtcNow < deadline)
            {
            }

            Assert.True(DateTime.UtcNow < deadline, "server did not come back after the restart");
            await Task.Delay(500);
        }
    }
}

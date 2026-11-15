using System.Net.WebSockets;
using System.Text;
using Microsoft.AspNetCore.Mvc.Testing;
using Microsoft.AspNetCore.TestHost;
using Microsoft.Data.Sqlite;
using Microsoft.Extensions.DependencyInjection;
using TwoNote.Core.Api;
using TwoNote.Core.Crypto;
using TwoNote.Core.Documents;
using TwoNote.Core.Sync;
using KdfParams = TwoNote.Core.Crypto.KdfParams;
using TwoNoteOptions = TwoNote.Server.TwoNoteOptions;
using Xunit;

namespace TwoNote.Core.Tests;

/// <summary>The real server, in-process, on a SQLite file in a temp directory.</summary>
internal sealed class TestServer : IDisposable
{
    private readonly WebApplicationFactory<Program> _factory;

    public TestServer()
    {
        DataDir = Path.Combine(Path.GetTempPath(), "twonote-core-tests", Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(DataDir);
        var options = new TwoNoteOptions { DataDir = DataDir };
        _factory = new WebApplicationFactory<Program>().WithWebHostBuilder(b => b.ConfigureTestServices(s => s.AddSingleton(options)));
        _ = _factory.Server; // start now
    }

    public string DataDir { get; }

    public static Uri Url { get; } = new("http://localhost");

    public HttpMessageHandler CreateHandler() => _factory.Server.CreateHandler();

    public WebSocketConnector Connector => (_, ct) =>
        _factory.Server.CreateWebSocketClient().ConnectAsync(new Uri("ws://localhost/api/v1/ws"), ct);

    public void Dispose()
    {
        _factory.Dispose();
        SqliteConnection.ClearAllPools();
        try
        {
            Directory.Delete(DataDir, recursive: true);
        }
        catch (IOException)
        {
        }
    }
}

/// <summary>A network that can be cut, can lose answers, and can be observed.</summary>
internal sealed class FaultyNetwork(HttpMessageHandler inner) : DelegatingHandler(inner)
{
    /// <summary>True: every request fails before it reaches the server.</summary>
    public bool Offline { get; set; }

    /// <summary>Requests for which the server does its work but the answer never arrives.</summary>
    public Func<HttpRequestMessage, bool>? LoseAnswer { get; set; }

    /// <summary>Runs before a request is forwarded.</summary>
    public Func<HttpRequestMessage, Task>? Before { get; set; }

    /// <summary>Rewrites a JSON answer body.</summary>
    public Func<HttpRequestMessage, string, string>? RewriteAnswer { get; set; }

    /// <summary>Number of requests attempted, including ones that failed because the network was off.</summary>
    public int Attempts { get; private set; }

    /// <summary>Every request that reached the server, as "METHOD /path".</summary>
    public List<string> Requests { get; } = [];

    protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken ct)
    {
        Attempts++;
        if (Offline)
        {
            throw new HttpRequestException("network is unreachable (test)");
        }

        if (Before is { } before)
        {
            await before(request);
        }

        lock (Requests)
        {
            Requests.Add($"{request.Method} {request.RequestUri!.AbsolutePath}");
        }

        var lose = LoseAnswer?.Invoke(request) == true;
        var response = await base.SendAsync(request, ct);
        if (lose)
        {
            response.Dispose();
            throw new HttpRequestException("connection reset before the answer arrived (test)");
        }

        if (RewriteAnswer is { } rewrite && response.IsSuccessStatusCode)
        {
            var body = await response.Content.ReadAsStringAsync(ct);
            response.Content = new StringContent(rewrite(request, body), Encoding.UTF8, "application/json");
        }

        return response;
    }
}

/// <summary>One headless client with its own local store, secret store and network.</summary>
internal sealed class Device : IAsyncDisposable
{
    public const string Username = "bob";
    public const string Password = "correct horse battery staple";

    /// <summary>The cheapest parameters the protocol allows; the default 64 MiB would only slow the tests down.</summary>
    public static readonly KdfParams FastKdf = new(KdfParams.Argon2id13, 1, KdfParams.MinMemKiB);

    private readonly TestServer _server;
    private readonly Action<DeviceSettings>? _configure;

    private Device(TestServer server, string name, Action<DeviceSettings>? configure)
    {
        _server = server;
        _configure = configure;
        Name = name;
        Directory = Path.Combine(Path.GetTempPath(), "twonote-core-tests", "device-" + Guid.NewGuid().ToString("N"));
        System.IO.Directory.CreateDirectory(Directory);
        DatabasePath = Path.Combine(Directory, "local.db");
        Net = new FaultyNetwork(server.CreateHandler());
        Client = NewClient();
    }

    public string Name { get; }
    public string Directory { get; }
    public string DatabasePath { get; }
    public InMemorySecretStore Secrets { get; } = new();
    public FaultyNetwork Net { get; }
    public TwoNoteClient Client { get; private set; }
    public List<SyncIssue> Issues { get; } = [];
    public SyncEngine Sync => Client.Sync;

    public static Device Create(TestServer server, string name, Action<DeviceSettings>? configure = null) => new(server, name, configure);

    public Task SyncAsync() => Client.Sync.SyncNowAsync();

    /// <summary>Simulates the process dying and starting again: same files, same secret store, nothing in memory.</summary>
    public async Task RestartAsync(bool unlock = true)
    {
        await Client.DisposeAsync();
        Client = NewClient();
        if (unlock)
        {
            await Client.UnlockAsync(Password);
        }
    }

    /// <summary>Every file of the local store (database, WAL, …) as one byte array.</summary>
    public byte[] ReadLocalFiles()
    {
        using var all = new MemoryStream();
        foreach (var file in System.IO.Directory.GetFiles(Directory))
        {
            using var stream = new FileStream(file, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
            stream.CopyTo(all);
        }

        return all.ToArray();
    }

    public async ValueTask DisposeAsync()
    {
        await Client.DisposeAsync();
        SqliteConnection.ClearAllPools();
        try
        {
            System.IO.Directory.Delete(Directory, recursive: true);
        }
        catch (IOException)
        {
        }
    }

    private TwoNoteClient NewClient()
    {
        var settings = new DeviceSettings();
        _configure?.Invoke(settings);
        var client = TwoNoteClient.Open(new ClientOptions
        {
            ServerUrl = TestServer.Url,
            DatabasePath = DatabasePath,
            SecretStore = Secrets,
            HttpHandler = Net,
            WebSocketConnector = _server.Connector,
            KdfParams = FastKdf,
            CompactionThreshold = settings.CompactionThreshold,
            PollInterval = settings.PollInterval,
            PushDebounce = TimeSpan.Zero,
            InitialRetryDelay = TimeSpan.FromMilliseconds(50),
            MaxRetryDelay = TimeSpan.FromMilliseconds(200),
            PushBatchSize = settings.PushBatchSize,
            EventsPageSize = settings.EventsPageSize,
            UseWebSocket = settings.UseWebSocket,
            UndoCaptureMilliseconds = 0,
        });
        client.Sync.IssueReported += issue =>
        {
            lock (Issues)
            {
                Issues.Add(issue);
            }
        };
        return client;
    }
}

internal sealed class DeviceSettings
{
    public int CompactionThreshold { get; set; } = 200;
    public TimeSpan PollInterval { get; set; } = TimeSpan.FromHours(1);
    public int PushBatchSize { get; set; } = 200;
    public int EventsPageSize { get; set; } = 500;
    public bool UseWebSocket { get; set; } = true;
}

internal static class SyncTestExtensions
{
    /// <summary>Polls until the condition holds; fails the test after the timeout.</summary>
    public static async Task Eventually(Func<bool> condition, string what, int timeoutMs = 15_000)
    {
        var deadline = Environment.TickCount64 + timeoutMs;
        while (!condition())
        {
            Assert.True(Environment.TickCount64 < deadline, "Timed out waiting for: " + what);
            await Task.Delay(20);
        }
    }

    public static bool Contains(this byte[] haystack, string needle) =>
        haystack.AsSpan().IndexOf(Encoding.UTF8.GetBytes(needle)) >= 0
        || haystack.AsSpan().IndexOf(Encoding.Unicode.GetBytes(needle)) >= 0;

    /// <summary>The whole notebook as text: tree, then every page with formatting.</summary>
    public static string DumpNotebook(this TwoNoteClient client, string notebookId)
    {
        var tree = client.OpenNotebook(notebookId);
        var sb = new StringBuilder(Docs.Dump(tree));
        foreach (var page in tree.GetAllPages(includeDeleted: true).OrderBy(p => p.Id, StringComparer.Ordinal))
        {
            sb.Append("\n  page ").Append(page.Id).Append(": ").Append(Docs.Dump(client.OpenPage(notebookId, page.Id)));
        }

        return sb.ToString();
    }
}

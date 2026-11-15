using System.Diagnostics;
using System.Globalization;
using System.Text;
using TwoNote.Core;
using TwoNote.Core.Api;
using TwoNote.Core.Crypto;
using TwoNote.Core.Documents;
using TwoNote.Core.Storage;
using TwoNote.Core.Sync;

namespace TwoNote.E2E.Tests;

/// <summary>
/// Headless clients against a REAL server container, over real HTTP and WebSockets.
///
/// Skipped unless TWONOTE_E2E_DOCKER holds the command that reaches Docker, for example
///   "wsl -d Ubuntu -- docker"   (Docker inside WSL, driven from Windows)
///   "docker"                          (Docker on the same machine)
/// Optional: TWONOTE_E2E_IMAGE (default twonote-server:latest), TWONOTE_E2E_PORT (default 18473).
/// The image must already exist; build it from the repository root with
///   docker build -f deploy/Dockerfile -t twonote-server:latest .
/// The test starts its own container on a fresh named volume and removes both afterwards.
/// </summary>
public sealed class ContainerSyncTests(ITestOutputHelper output)
{
    private const string Username = "bob";
    private const string Password = "correct horse battery staple";

    // Everything typed into the notebook. None of it may appear in what the server stores.
    private const string NotebookTitle = "Kestrel field journal";
    private const string SectionTitle = "Marsh observations";
    private const string PageTitle = "Tuesday at the hide";
    private const string Heading = "Bittern sighting";
    private const string Body = "Booming call heard at dawn near the reedbed 🦆";
    private const string Todo = "Refill the thermos";
    private const string OfflineA = "Wrote this on the train (device A)";
    private const string OfflineB = "Scribbled in the cellar (device B)";
    private const string OfflineSection = "Owl pellets";
    private const string OfflinePageTitle = "Dissection notes";
    private const string DuringRestart = "Typed while the server was restarting";
    private const string LinkTarget = "https://example.org/bittern-survey";

    [Fact]
    public async Task Three_devices_sync_end_to_end_encrypted_through_a_real_container()
    {
        var dockerCommand = Environment.GetEnvironmentVariable("TWONOTE_E2E_DOCKER");
        Assert.SkipWhen(string.IsNullOrWhiteSpace(dockerCommand), "TWONOTE_E2E_DOCKER is not set");
        var image = Environment.GetEnvironmentVariable("TWONOTE_E2E_IMAGE") is { Length: > 0 } i ? i : "twonote-server:latest";
        var port = int.TryParse(Environment.GetEnvironmentVariable("TWONOTE_E2E_PORT"), out var p) ? p : 18473;

        var docker = new Docker(dockerCommand!, output);
        var name = "twonote-e2e-" + Guid.NewGuid().ToString("N")[..8];
        var serverUrl = new Uri($"http://localhost:{port}");
        var devices = new List<Device>();
        try
        {
            // ---- 1. a fresh container on a fresh named volume --------------------------------
            Step("1. start a fresh container");
            await docker.Run("volume", "create", name);
            await docker.Run("run", "-d", "--name", name, "-p", $"{port}:8080", "-v", $"{name}:/data", image);
            using var probe = new TwoNoteApi(serverUrl);
            await WaitUntilUp(probe);
            var status = await probe.GetStatusAsync();
            Assert.Equal(1, status.Protocol);
            Assert.True(status.RegistrationOpen);

            // ---- 2. device A registers and writes --------------------------------------------
            Step("2. device A registers, creates notebook/section/page, types formatted text");
            var a = Device.Create(serverUrl, "Device A");
            devices.Add(a);
            var secretKey = await a.Client.RegisterAsync(Username, Password, "Device A");
            Assert.False((await probe.GetStatusAsync()).RegistrationOpen);
            var treeA = a.Client.CreateNotebook(NotebookTitle);
            var notebook = treeA.NotebookId;
            var section = treeA.AddSection(SectionTitle);
            var pageA = a.Client.CreatePage(notebook, section, PageTitle);
            var pageId = pageA.DocId;
            pageA.Edit(e =>
            {
                e.Insert(0, Heading + "\n" + Body + "\n" + Todo);
                e.SetBlock(Heading.Length, "h1");
                var bodyStart = Heading.Length + 1;
                e.Format(bodyStart, 7, Attrs((PageAttributes.Bold, true)));                                  // "Booming"
                e.Format(bodyStart + 8, 4, Attrs((PageAttributes.Italic, true), (PageAttributes.Link, LinkTarget))); // "call"
                e.SetBlock(e.Length - 1, "todo", indent: 1, isChecked: true);
            });
            await a.Client.Sync.SyncNowAsync();
            Assert.Equal(0, a.Client.Sync.Status.PendingUpdates);

            // ---- 3. device B enrols ----------------------------------------------------------
            Step("3. wrong password and wrong Secret Key are rejected; device B enrols and sees the same content");
            // B never polls (one hour) and leaves compaction to A, so step 7 has exactly one snapshot author.
            var b = Device.Create(serverUrl, "Device B", pollInterval: TimeSpan.FromHours(1), compactionThreshold: 1_000_000);
            devices.Add(b);
            using (var wrongKey = SecretKey.Generate())
            {
                await Assert.ThrowsAsync<WrongCredentialsException>(() => b.Client.EnrolAsync(Username, "not the password", secretKey, "Device B"));
                await Assert.ThrowsAsync<WrongCredentialsException>(() => b.Client.EnrolAsync(Username, Password, wrongKey.Format(), "Device B"));
                Assert.Equal(ClientState.NoAccount, b.Client.State);
            }

            await b.Client.EnrolAsync(Username, Password, secretKey, "Device B");
            await b.Client.Sync.SyncNowAsync();
            Assert.Equal([notebook], b.Client.NotebookIds);
            var expected = Dump(a.Client, notebook);
            Assert.Equal(expected, Dump(b.Client, notebook));
            var treeB = b.Client.OpenNotebook(notebook);
            var pageB = b.Client.OpenPage(notebook, pageId);
            Assert.Equal(NotebookTitle, treeB.Title);
            Assert.Equal(SectionTitle, Assert.Single(treeB.GetSections()).Title);
            Assert.Equal(PageTitle, Assert.Single(treeB.GetPages(section)).Title);
            Assert.Equal(Heading + "\n" + Body + "\n" + Todo + "\n", pageB.GetText());
            Assert.Equal(
                Heading + "{}|\\n{block=\"h1\"}|Booming{bold=true}| {}|call{italic=true,link=\"" + LinkTarget + "\"}|"
                + Body[12..] + "\\n" + Todo + "{}|\\n{block=\"todo\",checked=true,indent=1}|",
                Dump(pageB));
            Assert.Equal(2, (await b.Client.Api.GetDevicesAsync()).Count);

            // ---- 4. B is told about new edits over the WebSocket ------------------------------
            Step("4. device B receives an edit through the WebSocket notification (poll interval is one hour)");
            var notifiedHeads = new List<long>();
            b.Client.Sync.HeadNotified += head =>
            {
                lock (notifiedHeads)
                {
                    notifiedHeads.Add(head);
                }
            };
            b.Client.Sync.Start();
            await Eventually(() => b.Client.Sync.Status is { WebSocketConnected: true, State: SyncState.Idle }, "B's socket to connect");
            var remoteChanges = 0;
            pageB.TextChanged += change => remoteChanges += change.Source == ChangeSource.Remote ? 1 : 0;
            pageA.Edit(e => e.Insert(0, "LIVE: "));
            await a.Client.Sync.SyncNowAsync();
            var headAfterPush = a.Client.Sync.Status.Head;
            await Eventually(() => pageB.GetText().StartsWith("LIVE: " + Heading), "A's edit to appear on B");
            lock (notifiedHeads)
            {
                Assert.Contains(headAfterPush, notifiedHeads);
            }

            Assert.Equal(1, remoteChanges);
            Assert.Equal(Dump(a.Client, notebook), Dump(b.Client, notebook));

            // ---- 5. both offline, both edit, reconnect ---------------------------------------
            Step("5. both devices go offline, edit the same page and the tree concurrently, reconnect and converge");
            await b.Client.Sync.StopAsync();
            pageA.Edit(e => e.Insert(e.Length - 1, "\n" + OfflineA));
            pageA.Edit(e => e.Format(6, Heading.Length, Attrs((PageAttributes.Underline, true))));
            pageB.Edit(e => e.Insert(e.Length - 1, "\n" + OfflineB, Attrs((PageAttributes.Code, true))));
            pageB.Edit(e => e.Delete(0, 6)); // B removes "LIVE: " while A underlines the heading next to it
            treeA.RenamePage(pageId, PageTitle + " (edited)");
            var offlineSection = treeB.AddSection(OfflineSection, index: 0);
            var offlinePage = b.Client.CreatePage(notebook, offlineSection, OfflinePageTitle);
            offlinePage.Edit(e => e.Insert(0, "pellet one: vole skull"));
            treeA.AddSection("A's section, added at the same time", index: 0);
            Assert.True(a.Client.Sync.Status.PendingUpdates > 0 && b.Client.Sync.Status.PendingUpdates > 0);
            Assert.NotEqual(Dump(a.Client, notebook), Dump(b.Client, notebook));

            await a.Client.Sync.SyncNowAsync();
            await b.Client.Sync.SyncNowAsync();
            await a.Client.Sync.SyncNowAsync();
            var merged = Dump(a.Client, notebook);
            Assert.Equal(merged, Dump(b.Client, notebook));
            var text = pageA.GetText();
            Assert.StartsWith(Heading + "\n", text);
            Assert.Contains(OfflineA, text);
            Assert.Contains(OfflineB, text);
            Assert.Equal(PageTitle + " (edited)", treeB.GetPage(pageId)!.Title);
            Assert.Equal(3, treeA.GetSections().Count);
            Assert.Equal("pellet one: vole skull\n", a.Client.OpenPage(notebook, offlinePage.DocId).GetText());
            Assert.Equal(0, a.Client.Sync.Status.PendingUpdates + b.Client.Sync.Status.PendingUpdates);

            // ---- 6. docker restart in the middle ---------------------------------------------
            Step("6. the container is restarted while A has unsent edits and B is listening; nothing is lost");
            b.Client.Sync.Start();
            await Eventually(() => b.Client.Sync.Status.WebSocketConnected, "B's socket to reconnect after going online");
            var eventsBefore = await AllEvents(a.Client.Api);
            pageA.Edit(e => e.Insert(e.Length - 1, "\n" + DuringRestart));
            await docker.Run("restart", name);
            await WaitUntilUp(probe);
            Assert.False((await probe.GetStatusAsync()).RegistrationOpen);
            var eventsAfter = await AllEvents(a.Client.Api); // the same token still works
            Assert.Equal(eventsBefore.Select(Describe), eventsAfter.Select(Describe));
            Assert.Equal(2, (await a.Client.Api.GetDevicesAsync()).Count);

            await a.Client.Sync.SyncNowAsync();
            Assert.Equal(eventsBefore[^1].Seq + 1, a.Client.Sync.Status.Head); // the counter carried on
            await Eventually(() => pageB.GetText().Contains(DuringRestart), "B to reconnect its socket and receive the edit made during the restart", 60_000);
            Assert.Equal(Dump(a.Client, notebook), Dump(b.Client, notebook));
            Assert.True(b.Client.Sync.Status.WebSocketConnected);

            // ---- 7. enough edits to trigger compaction ---------------------------------------
            Step("7. 230 more edits trigger compaction: the server holds a snapshot and drops the covered updates");
            Assert.All(await a.Client.Api.GetDocsAsync(), d => Assert.Equal(0, d.SnapshotSeq));
            for (var n = 0; n < 230; n++)
            {
                pageA.Edit(e => e.Insert(e.Length - 1, n % 40 == 0 ? "\n" : ((char)('a' + n % 26)).ToString()));
            }

            await a.Client.Sync.SyncNowAsync();
            var pageDoc = (await a.Client.Api.GetDocsAsync()).Single(d => d.DocId == pageId);
            Assert.True(pageDoc.SnapshotSeq > 0, "the page should have been snapshotted");
            var afterCompaction = await AllEvents(a.Client.Api);
            Assert.DoesNotContain(afterCompaction, e => e.Type == ServerEvent.Update && e.DocId == pageId);
            Assert.Contains(afterCompaction, e => e.Type == ServerEvent.Snapshot && e.DocId == pageId && e.CoveredSeq == pageDoc.SnapshotSeq);
            await Eventually(() => b.Client.Sync.Status.Cursor == a.Client.Sync.Status.Head, "B to catch up with the snapshot", 60_000);
            Assert.Equal(Dump(a.Client, notebook), Dump(b.Client, notebook));

            // A couple of edits after the snapshot, so a new device needs snapshot AND events.
            pageA.Edit(e => e.Insert(0, "Post-snapshot line\n"));
            treeA.RenameSection(section, SectionTitle + " (spring)");
            await a.Client.Sync.SyncNowAsync();
            await Eventually(() => pageB.GetText().StartsWith("Post-snapshot line\n"), "B to receive the post-snapshot edit");

            // ---- 8. a brand-new device -------------------------------------------------------
            Step("8. a brand-new device C enrols and rebuilds everything from snapshot + events");
            var c = Device.Create(serverUrl, "Device C");
            devices.Add(c);
            await c.Client.EnrolAsync(Username, Password, secretKey, "Device C");
            await c.Client.Sync.SyncNowAsync();
            var final = Dump(a.Client, notebook);
            Assert.Equal(final, Dump(c.Client, notebook));
            Assert.Equal(final, Dump(b.Client, notebook));
            Assert.Contains(DuringRestart, c.Client.OpenPage(notebook, pageId).GetText());
            Assert.Contains(OfflineB, c.Client.OpenPage(notebook, pageId).GetText());
            Assert.Equal(SectionTitle + " (spring)", c.Client.OpenNotebook(notebook).GetSection(section)!.Title);
            Assert.Equal(3, (await c.Client.Api.GetDevicesAsync()).Count);
            foreach (var device in devices)
            {
                Assert.Empty(device.Client.Sync.Issues);
            }

            // C really did start from the snapshot: its local store holds it, with only later updates beside it.
            await b.Client.Sync.StopAsync();
            foreach (var device in devices)
            {
                await device.Client.LockAsync();
            }

            using (var store = LocalStore.Open(c.DatabasePath))
            {
                var content = store.LoadDoc(pageId)!;
                Assert.Equal(pageDoc.SnapshotSeq, content.SnapshotSeq);
                Assert.NotNull(content.SnapshotBlob);
                Assert.Single(content.UpdateBlobs);
            }

            // Locked devices come back from local state alone and still agree.
            foreach (var device in devices)
            {
                await device.Client.UnlockAsync(Password);
                Assert.Equal(final, Dump(device.Client, notebook));
                await device.Client.LockAsync();
            }

            // ---- 9. what did the server store? -----------------------------------------------
            Step("9. the container's /data (database + WAL) contains none of the typed text or titles");
            var data = await docker.Output("cp", $"{name}:/data", "-"); // a tar stream: files are stored uncompressed
            Assert.True(data.Length > 64 * 1024, $"/data is only {data.Length} bytes");
            Assert.True(Contains(data, "twonote.db"), "the tar stream should list the database file");
            Assert.True(Contains(data, "SQLite format 3"), "the tar stream should contain the database itself");
            Assert.True(Contains(data, Username), "positive control: the (non-secret) username is stored in the clear");
            Assert.True(Contains(data, "Device C"), "positive control: device names are stored in the clear");
            var plaintexts = new[]
            {
                NotebookTitle, SectionTitle, PageTitle, Heading, Body, Todo, OfflineA, OfflineB, OfflineSection, OfflinePageTitle,
                DuringRestart, LinkTarget, "pellet one: vole skull", "Post-snapshot line", "A's section, added at the same time",
                "Booming", "Bittern", "reedbed", "thermos", "Kestrel", "Marsh",
            };
            foreach (var plaintext in plaintexts)
            {
                Assert.False(Contains(data, plaintext), $"'{plaintext}' was found in the server's data volume");
            }

            using (var key = SecretKey.Parse(secretKey))
            {
                Assert.False(Contains(data, Password));
                Assert.False(Contains(data, secretKey));
                Assert.True(data.AsSpan().IndexOf(key.Bytes) < 0, "the raw Secret Key was found in the server's data volume");
            }

            // The same goes for every device's own database, which additionally must not hold the secrets.
            foreach (var device in devices)
            {
                var local = device.ReadLocalFiles();
                Assert.True(Contains(local, Username));
                foreach (var plaintext in plaintexts.Append(Password).Append(secretKey).Append(device.Secrets.Get(SecretNames.SessionToken)!))
                {
                    Assert.False(Contains(local, plaintext), $"'{plaintext}' was found in the local store of {device.Name}");
                }
            }

            Step("done");
        }
        finally
        {
            foreach (var device in devices)
            {
                await device.DisposeAsync();
            }

            // Remove the container and its volume; the image stays.
            await docker.Run(ignoreFailure: true, "rm", "-f", name);
            await docker.Run(ignoreFailure: true, "volume", "rm", name);
        }
    }

    // ---- helpers --------------------------------------------------------------------------

    private void Step(string text) => output.WriteLine($"[{DateTime.Now:HH:mm:ss}] STEP {text}");

    private static Dictionary<string, object?> Attrs(params (string Key, object? Value)[] attributes) =>
        attributes.ToDictionary(a => a.Key, a => a.Value);

    private static string Describe(ServerEvent e) =>
        $"{e.Seq}/{e.Type}/{e.DocId}/{e.DeviceId}/{e.CoveredSeq}/{(e.Blob is null ? "" : Convert.ToHexString(e.Blob))}";

    private static bool Contains(byte[] haystack, string needle) =>
        haystack.AsSpan().IndexOf(Encoding.UTF8.GetBytes(needle)) >= 0
        || haystack.AsSpan().IndexOf(Encoding.Unicode.GetBytes(needle)) >= 0;

    private static async Task<List<ServerEvent>> AllEvents(TwoNoteApi api)
    {
        var all = new List<ServerEvent>();
        long after = 0;
        while (true)
        {
            var page = await api.GetEventsAsync(after, 2000);
            all.AddRange(page.Events);
            if (!page.More)
            {
                return all;
            }

            after = page.Events[^1].Seq;
        }
    }

    private static async Task WaitUntilUp(TwoNoteApi api)
    {
        var deadline = Environment.TickCount64 + 90_000;
        while (true)
        {
            try
            {
                await api.GetStatusAsync();
                return;
            }
            catch (ServerUnreachableException) when (Environment.TickCount64 < deadline)
            {
                await Task.Delay(300);
            }
        }
    }

    private static async Task Eventually(Func<bool> condition, string what, int timeoutMs = 30_000)
    {
        var deadline = Environment.TickCount64 + timeoutMs;
        while (!condition())
        {
            Assert.True(Environment.TickCount64 < deadline, "Timed out waiting for: " + what);
            await Task.Delay(50);
        }
    }

    /// <summary>The whole notebook as text: tree, then every page with its formatting.</summary>
    private static string Dump(TwoNoteClient client, string notebookId)
    {
        var tree = client.OpenNotebook(notebookId);
        var sb = new StringBuilder("[" + tree.Title + "]");
        foreach (var s in tree.GetSections(includeDeleted: true))
        {
            sb.Append($"\n S {s.Id} '{s.Title}' {s.Order} {s.Deleted}");
            foreach (var p in tree.GetPages(s.Id, includeDeleted: true))
            {
                sb.Append($"\n  P {p.Id} '{p.Title}' {p.Order} {p.Deleted} {p.CreatedAt.ToUnixTimeMilliseconds()} {p.UpdatedAt.ToUnixTimeMilliseconds()}");
            }
        }

        foreach (var page in tree.GetAllPages(includeDeleted: true).OrderBy(x => x.Id, StringComparer.Ordinal))
        {
            sb.Append("\n  page ").Append(page.Id).Append(": ").Append(Dump(client.OpenPage(notebookId, page.Id)));
        }

        return sb.ToString();
    }

    /// <summary>Text and formatting; adjacent runs with equal attributes are merged, attributes sorted.</summary>
    private static string Dump(PageDocument page)
    {
        var sb = new StringBuilder();
        string? last = null;
        foreach (var run in page.GetRuns())
        {
            var attrs = string.Join(",", run.Attributes.OrderBy(a => a.Key, StringComparer.Ordinal).Select(a => a.Key + "=" + a.Value switch
            {
                bool flag => flag ? "true" : "false",
                string s => "\"" + s + "\"",
                double d => d.ToString("R", CultureInfo.InvariantCulture),
                _ => "?",
            }));
            if (last is not null && attrs != last)
            {
                sb.Append('{').Append(last).Append("}|");
            }

            sb.Append(run.Text.Replace("\n", "\\n"));
            last = attrs;
        }

        return last is null ? "" : sb.Append('{').Append(last).Append("}|").ToString();
    }

    /// <summary>One headless client: its own local store on disk, its own in-memory secret store, real network.</summary>
    private sealed class Device : IAsyncDisposable
    {
        private Device(string name, string directory, TwoNoteClient client, InMemorySecretStore secrets)
        {
            Name = name;
            Directory = directory;
            Client = client;
            Secrets = secrets;
        }

        public string Name { get; }
        public string Directory { get; }
        public string DatabasePath => Path.Combine(Directory, "local.db");
        public TwoNoteClient Client { get; }
        public InMemorySecretStore Secrets { get; }

        public static Device Create(Uri serverUrl, string name, TimeSpan? pollInterval = null, int compactionThreshold = 200)
        {
            var directory = Path.Combine(Path.GetTempPath(), "twonote-e2e", Guid.NewGuid().ToString("N"));
            System.IO.Directory.CreateDirectory(directory);
            var secrets = new InMemorySecretStore();
            var client = TwoNoteClient.Open(new ClientOptions
            {
                ServerUrl = serverUrl,
                DatabasePath = Path.Combine(directory, "local.db"),
                SecretStore = secrets,
                PollInterval = pollInterval ?? TimeSpan.FromSeconds(60),
                CompactionThreshold = compactionThreshold,
                PushDebounce = TimeSpan.FromMilliseconds(50),
                MaxRetryDelay = TimeSpan.FromSeconds(2),
                HttpTimeout = TimeSpan.FromSeconds(15),
            });
            return new Device(name, directory, client, secrets);
        }

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
            try
            {
                System.IO.Directory.Delete(Directory, recursive: true);
            }
            catch (IOException)
            {
            }
        }
    }

    /// <summary>Runs docker through whatever command reaches it (see the class comment).</summary>
    private sealed class Docker(string command, ITestOutputHelper output)
    {
        private readonly string[] _prefix = command.Split(' ', StringSplitOptions.RemoveEmptyEntries);

        public Task Run(params string[] args) => Run(false, args);

        public async Task Run(bool ignoreFailure, params string[] args)
        {
            var (exit, stdout, stderr) = await Execute(args);
            output.WriteLine($"docker {string.Join(' ', args)} -> {exit} {Encoding.UTF8.GetString(stdout).Trim()} {stderr.Trim()}");
            if (!ignoreFailure)
            {
                Assert.True(exit == 0, $"docker {string.Join(' ', args)} failed with {exit}: {stderr}");
            }
        }

        /// <summary>Runs docker and returns its standard output as raw bytes.</summary>
        public async Task<byte[]> Output(params string[] args)
        {
            var (exit, stdout, stderr) = await Execute(args);
            Assert.True(exit == 0, $"docker {string.Join(' ', args)} failed with {exit}: {stderr}");
            return stdout;
        }

        private async Task<(int Exit, byte[] Stdout, string Stderr)> Execute(string[] args)
        {
            var info = new ProcessStartInfo(_prefix[0], [.. _prefix[1..], .. args])
            {
                UseShellExecute = false,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                CreateNoWindow = true,
            };
            using var process = Process.Start(info)!;
            using var stdout = new MemoryStream();
            var copy = process.StandardOutput.BaseStream.CopyToAsync(stdout);
            var stderr = process.StandardError.ReadToEndAsync();
            await process.WaitForExitAsync();
            await copy;
            return (process.ExitCode, stdout.ToArray(), await stderr);
        }
    }
}

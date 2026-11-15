using System.Text.Json.Nodes;
using TwoNote.Core.Api;
using TwoNote.Core.Crypto;
using TwoNote.Core.Documents;
using TwoNote.Core.Storage;
using TwoNote.Core.Sync;
using Xunit;

namespace TwoNote.Core.Tests;

/// <summary>
/// The account flows and the sync engine of PROTOCOL.md section 4, run against the real server
/// hosted in-process. Each test gets its own server and its own devices.
/// </summary>
public class SyncTests
{
    private static readonly Dictionary<string, object?> Bold = Docs.Attrs((PageAttributes.Bold, true));

    private sealed record World(TestServer Server, Device A, string SecretKey, string Notebook, string Section, string Page) : IAsyncDisposable
    {
        public List<Device> Others { get; } = [];

        public async Task<Device> Enrol(string name, Action<DeviceSettings>? configure = null)
        {
            var device = Device.Create(Server, name, configure);
            Others.Add(device);
            await device.Client.EnrolAsync(Device.Username, Device.Password, SecretKey, name);
            return device;
        }

        public async ValueTask DisposeAsync()
        {
            foreach (var device in Others)
            {
                await device.DisposeAsync();
            }

            await A.DisposeAsync();
            Server.Dispose();
        }
    }

    /// <summary>Device A registers and creates a notebook with one section and one page holding "Hello world" (Hello in bold).</summary>
    private static async Task<World> Start(Action<DeviceSettings>? configure = null)
    {
        var server = new TestServer();
        var a = Device.Create(server, "A", configure);
        var secretKey = await a.Client.RegisterAsync(Device.Username, Device.Password, "A");
        var tree = a.Client.CreateNotebook("Notebook");
        var section = tree.AddSection("Section");
        var page = a.Client.CreatePage(tree.NotebookId, section, "Page");
        page.Edit(e =>
        {
            e.Insert(0, "Hello world");
            e.Format(0, 5, Bold);
        });
        await a.SyncAsync();
        return new World(server, a, secretKey, tree.NotebookId, section, page.DocId);
    }

    private static async Task<List<ServerEvent>> AllEvents(Device device)
    {
        var all = new List<ServerEvent>();
        long after = 0;
        while (true)
        {
            var page = await device.Client.Api.GetEventsAsync(after, 2000);
            all.AddRange(page.Events);
            if (!page.More)
            {
                return all;
            }

            after = page.Events[^1].Seq;
        }
    }

    // ---- account flows --------------------------------------------------------------------

    [Fact]
    public async Task Register_then_enrol_a_second_device_and_see_the_same_notebook()
    {
        await using var w = await Start();
        Assert.Equal(ClientState.Unlocked, w.A.Client.State);
        Assert.Matches("^T2-[0-9A-Z]{6}-[0-9A-Z]{6}-[0-9A-Z]{6}-[0-9A-Z]{8}$", w.SecretKey);
        Assert.Equal(w.SecretKey, w.A.Client.GetSecretKeyForDisplay());
        Assert.Equal(0, w.A.Sync.Status.PendingUpdates);

        var b = Device.Create(w.Server, "B");
        w.Others.Add(b);
        Assert.Equal(ClientState.NoAccount, b.Client.State);
        await b.Client.EnrolAsync("  BOB ", Device.Password, w.SecretKey.ToLowerInvariant().Replace("-", " "), "B"); // tolerant input
        Assert.Equal(ClientState.Unlocked, b.Client.State);
        Assert.Empty(b.Client.NotebookIds);
        await b.SyncAsync();

        Assert.Equal([w.Notebook], b.Client.NotebookIds);
        var expected = w.A.Client.DumpNotebook(w.Notebook);
        Assert.Equal(expected, b.Client.DumpNotebook(w.Notebook));
        Assert.Contains("Hello{bold=true}| world\\n{}|", expected);
        Assert.Equal("Notebook", b.Client.OpenNotebook(w.Notebook).Title);
        Assert.Equal("Page", b.Client.OpenNotebook(w.Notebook).GetPage(w.Page)!.Title);

        // Two devices on the server, each with its own id.
        var devices = await b.Client.Api.GetDevicesAsync();
        Assert.Equal(2, devices.Count);
        Assert.Equal(b.Client.Account!.DeviceId, devices.Single(d => d.Current).DeviceId);
        Assert.NotEqual(w.A.Client.Account!.DeviceId, b.Client.Account!.DeviceId);
        Assert.Equal(w.A.Client.Account!.AccountId, b.Client.Account!.AccountId);
        Assert.Empty(w.A.Issues);
        Assert.Empty(b.Issues);
    }

    [Fact]
    public async Task Enrol_rejects_a_wrong_password_a_wrong_secret_key_and_an_unknown_user()
    {
        await using var w = await Start();
        var b = Device.Create(w.Server, "B");
        w.Others.Add(b);
        using var otherKey = SecretKey.Generate();

        await Assert.ThrowsAsync<WrongCredentialsException>(() => b.Client.EnrolAsync(Device.Username, "wrong password", w.SecretKey, "B"));
        await Assert.ThrowsAsync<WrongCredentialsException>(() => b.Client.EnrolAsync(Device.Username, Device.Password, otherKey.Format(), "B"));
        await Assert.ThrowsAsync<WrongCredentialsException>(() => b.Client.EnrolAsync("nobody", Device.Password, w.SecretKey, "B"));
        await Assert.ThrowsAsync<FormatException>(() => b.Client.EnrolAsync(Device.Username, Device.Password, "T2-not-a-key", "B"));

        // Nothing was left behind by the failed attempts.
        Assert.Equal(ClientState.NoAccount, b.Client.State);
        Assert.Null(b.Secrets.Get(SecretNames.SecretKey));
        Assert.Null(b.Secrets.Get(SecretNames.SessionToken));
        Assert.Single(await w.A.Client.Api.GetDevicesAsync());

        // A second registration on the same server is refused with the protocol's code.
        var c = Device.Create(w.Server, "C");
        w.Others.Add(c);
        var refused = await Assert.ThrowsAsync<ApiException>(() => c.Client.RegisterAsync("eve", "pw", "C"));
        Assert.Equal((403, "registration_closed"), (refused.Status, refused.Code));
        Assert.Null(c.Secrets.Get(SecretNames.SecretKey));

        await b.Client.EnrolAsync(Device.Username, Device.Password, w.SecretKey, "B");
        Assert.Equal(ClientState.Unlocked, b.Client.State);
    }

    [Fact]
    public async Task Lock_and_unlock_work_from_local_state_with_the_server_unreachable()
    {
        await using var w = await Start();
        var a = w.A;
        var before = a.Client.DumpNotebook(w.Notebook);

        await a.Client.LockAsync();
        Assert.Equal(ClientState.Locked, a.Client.State);
        Assert.Throws<InvalidOperationException>(() => a.Client.OpenNotebook(w.Notebook));
        Assert.Throws<InvalidOperationException>(() => a.Client.NotebookIds);
        await Assert.ThrowsAsync<InvalidOperationException>(() => a.SyncAsync());

        a.Net.Offline = true;
        var attemptsBefore = a.Net.Attempts;
        await Assert.ThrowsAsync<WrongCredentialsException>(() => a.Client.UnlockAsync("not the password"));
        Assert.Equal(ClientState.Locked, a.Client.State);
        await a.Client.UnlockAsync(Device.Password);
        Assert.Equal(ClientState.Unlocked, a.Client.State);
        Assert.Equal(before, a.Client.DumpNotebook(w.Notebook));

        // Fully usable offline, across a process restart too.
        a.Client.OpenPage(w.Notebook, w.Page).Edit(e => e.Insert(11, ", offline"));
        var second = a.Client.CreatePage(w.Notebook, w.Section, "Written offline");
        second.Edit(e => e.Insert(0, "no server needed"));
        var offlineNotebook = a.Client.CreateNotebook("Made offline");
        offlineNotebook.AddSection("s");
        await Assert.ThrowsAsync<ServerUnreachableException>(() => a.SyncAsync());
        Assert.Equal(SyncState.Offline, a.Sync.Status.State);
        var pending = a.Sync.Status.PendingUpdates;
        Assert.True(pending >= 5, $"pending = {pending}");

        await a.RestartAsync();
        Assert.Equal(pending, a.Sync.Status.PendingUpdates);
        Assert.Equal("Hello world, offline\n", a.Client.OpenPage(w.Notebook, w.Page).GetText());
        Assert.Equal("no server needed\n", a.Client.OpenPage(w.Notebook, second.DocId).GetText());
        Assert.Equal("Made offline", a.Client.OpenNotebook(offlineNotebook.NotebookId).Title);
        Assert.Equal(attemptsBefore + 1, a.Net.Attempts); // the one failed sync above; unlocking and editing asked for nothing

        // Back online: everything queued arrives at the other device.
        a.Net.Offline = false;
        await a.SyncAsync();
        Assert.Equal(0, a.Sync.Status.PendingUpdates);
        var b = await w.Enrol("B");
        await b.SyncAsync();
        Assert.Equal(2, b.Client.NotebookIds.Count);
        Assert.Equal(a.Client.DumpNotebook(w.Notebook), b.Client.DumpNotebook(w.Notebook));
        Assert.Equal(a.Client.DumpNotebook(offlineNotebook.NotebookId), b.Client.DumpNotebook(offlineNotebook.NotebookId));
    }

    [Fact]
    public async Task Password_change_rekeys_the_account_and_signs_other_devices_out_until_they_sign_in_again()
    {
        await using var w = await Start();
        var a = w.A;
        var b = await w.Enrol("B");
        await b.SyncAsync();
        const string newPassword = "a brand new passphrase";

        await Assert.ThrowsAsync<WrongCredentialsException>(() => a.Client.ChangePasswordAsync("not the current one", newPassword));
        await a.Client.ChangePasswordAsync(Device.Password, newPassword);

        // A keeps working, and from now on only the new password unlocks it.
        a.Client.OpenPage(w.Notebook, w.Page).Edit(e => e.Insert(0, "after rekey: "));
        await a.SyncAsync();
        await a.Client.LockAsync();
        await Assert.ThrowsAsync<WrongCredentialsException>(() => a.Client.UnlockAsync(Device.Password));
        await a.Client.UnlockAsync(newPassword);
        Assert.Equal(w.SecretKey, a.Client.GetSecretKeyForDisplay()); // the Secret Key did not change

        // B was signed out; its local data and its own (old) local unlock still work offline.
        b.Client.OpenPage(w.Notebook, w.Page).Edit(e => e.Insert(0, "B while signed out. "));
        var unauthorized = await Assert.ThrowsAsync<ApiException>(() => b.SyncAsync());
        Assert.Equal(401, unauthorized.Status);
        Assert.Equal(SyncState.AuthRequired, b.Sync.Status.State);
        Assert.Equal(1, b.Sync.Status.PendingUpdates);

        await Assert.ThrowsAsync<WrongCredentialsException>(() => b.Client.SignInAgainAsync(Device.Password));
        var deviceId = b.Client.Account!.DeviceId;
        await b.Client.SignInAgainAsync(newPassword);
        Assert.Equal(deviceId, b.Client.Account!.DeviceId);
        await b.SyncAsync();
        await a.SyncAsync();
        Assert.Equal(a.Client.DumpNotebook(w.Notebook), b.Client.DumpNotebook(w.Notebook));
        Assert.Contains("B while signed out. ", a.Client.OpenPage(w.Notebook, w.Page).GetText());
        Assert.Contains("after rekey: ", b.Client.OpenPage(w.Notebook, w.Page).GetText());

        await b.Client.LockAsync();
        await Assert.ThrowsAsync<WrongCredentialsException>(() => b.Client.UnlockAsync(Device.Password));
        await b.Client.UnlockAsync(newPassword);

        // A new device needs the new password and the same Secret Key.
        var c = Device.Create(w.Server, "C");
        w.Others.Add(c);
        await Assert.ThrowsAsync<WrongCredentialsException>(() => c.Client.EnrolAsync(Device.Username, Device.Password, w.SecretKey, "C"));
        await c.Client.EnrolAsync(Device.Username, newPassword, w.SecretKey, "C");
        await c.SyncAsync();
        Assert.Equal(a.Client.DumpNotebook(w.Notebook), c.Client.DumpNotebook(w.Notebook));
    }

    [Fact]
    public async Task The_password_can_be_checked_locally_and_a_device_can_be_renamed()
    {
        await using var w = await Start();
        var a = w.A;
        var b = await w.Enrol("B");

        // VerifyPasswordAsync: local only, changes nothing, works locked and unlocked, also offline.
        a.Net.Offline = true;
        var attempts = a.Net.Attempts;
        Assert.True(await a.Client.VerifyPasswordAsync(Device.Password));
        Assert.False(await a.Client.VerifyPasswordAsync("not the password"));
        Assert.Equal(ClientState.Unlocked, a.Client.State);
        await a.Client.LockAsync();
        Assert.True(await a.Client.VerifyPasswordAsync(Device.Password));
        Assert.False(await a.Client.VerifyPasswordAsync(""));
        Assert.Equal(ClientState.Locked, a.Client.State);
        Assert.Equal(attempts, a.Net.Attempts);
        a.Net.Offline = false;
        await a.Client.UnlockAsync(Device.Password);
        var fresh = Device.Create(w.Server, "C");
        w.Others.Add(fresh);
        await Assert.ThrowsAsync<InvalidOperationException>(() => fresh.Client.VerifyPasswordAsync(Device.Password));

        // RenameDeviceAsync: needs the password and the server; keeps the device id; the other device sees the name.
        var deviceId = b.Client.Account!.DeviceId;
        var token = b.Secrets.Get(SecretNames.SessionToken);
        await Assert.ThrowsAsync<WrongCredentialsException>(() => b.Client.RenameDeviceAsync("wrong password", "Laptop"));
        Assert.Equal("B", b.Client.Account!.DeviceName);
        await Assert.ThrowsAsync<ArgumentException>(() => b.Client.RenameDeviceAsync(Device.Password, "  "));
        await b.Client.RenameDeviceAsync(Device.Password, "  Laptop  ");
        Assert.Equal("Laptop", b.Client.Account!.DeviceName);
        Assert.Equal(deviceId, b.Client.Account!.DeviceId);
        Assert.NotEqual(token, b.Secrets.Get(SecretNames.SessionToken));
        Assert.Equal(ClientState.Unlocked, b.Client.State);
        var devices = await a.Client.Api.GetDevicesAsync();
        Assert.Equal(["A", "Laptop"], devices.Select(d => d.Name).Order());
        Assert.Equal(deviceId, devices.Single(d => d.Name == "Laptop").DeviceId);

        // The renamed device carries on syncing with its new token, and still unlocks locally.
        a.Client.OpenPage(w.Notebook, w.Page).Edit(e => e.Insert(0, "after the rename: "));
        await a.SyncAsync();
        await b.SyncAsync();
        Assert.Equal(a.Client.DumpNotebook(w.Notebook), b.Client.DumpNotebook(w.Notebook));
        await b.Client.LockAsync();
        await b.Client.UnlockAsync(Device.Password);
        await Assert.ThrowsAsync<InvalidOperationException>(async () =>
        {
            await b.Client.LockAsync();
            await b.Client.RenameDeviceAsync(Device.Password, "Locked");
        });
    }

    [Fact]
    public async Task Nothing_secret_and_no_plaintext_reaches_the_local_database_or_the_server()
    {
        await using var w = await Start();
        var a = w.A;
        const string title = "Quarterly zebra budget";
        const string text = "the heron lands at midnight";
        var tree = a.Client.OpenNotebook(w.Notebook);
        tree.SetTitle("Private notebook name");
        tree.RenameSection(w.Section, "Confidential section");
        tree.RenamePage(w.Page, title);
        a.Client.OpenPage(w.Notebook, w.Page).Edit(e => e.Insert(0, text));
        await a.SyncAsync();
        await a.Client.LockAsync();

        var token = a.Secrets.Get(SecretNames.SessionToken)!;
        var local = a.ReadLocalFiles();
        var server = Directory.GetFiles(w.Server.DataDir).SelectMany(ReadShared).ToArray();
        Assert.True(local.Length > 4096 && server.Length > 4096);
        using var key = SecretKey.Parse(w.SecretKey);
        foreach (var (name, bytes) in new[] { ("local store", local), ("server database", server) })
        {
            foreach (var secret in new[] { title, text, "Private notebook name", "Confidential section", "Hello world", Device.Password, w.SecretKey, token })
            {
                Assert.False(bytes.Contains(secret), $"'{secret}' found in the {name}");
            }

            Assert.True(bytes.AsSpan().IndexOf(key.Bytes) < 0, $"raw Secret Key found in the {name}");
            Assert.True(bytes.AsSpan().IndexOf(WireEncoding.FromBase64Url(token)) < 0, $"raw token found in the {name}");
        }

        // The non-secret metadata, on the other hand, is there - the scan would notice plaintext.
        Assert.True(local.Contains(Device.Username));

        static byte[] ReadShared(string path)
        {
            using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
            using var copy = new MemoryStream();
            stream.CopyTo(copy);
            return copy.ToArray();
        }
    }

    // ---- sync -----------------------------------------------------------------------------

    [Fact]
    public async Task Offline_edits_to_the_same_page_and_tree_converge_on_both_devices()
    {
        await using var w = await Start();
        var a = w.A;
        var b = await w.Enrol("B");
        await b.SyncAsync();

        // Both offline, both busy.
        var pageA = a.Client.OpenPage(w.Notebook, w.Page);
        var pageB = b.Client.OpenPage(w.Notebook, w.Page);
        pageA.Edit(e => e.Insert(0, "A: "));
        pageA.Edit(e => e.SetBlock(e.Length - 1, "h1"));
        pageB.Edit(e => e.Insert(e.Length - 1, " (B was here)", Docs.Attrs((PageAttributes.Italic, true))));
        pageB.Edit(e => e.Delete(0, 1));
        var treeA = a.Client.OpenNotebook(w.Notebook);
        var treeB = b.Client.OpenNotebook(w.Notebook);
        treeA.RenamePage(w.Page, "Renamed by A");
        var sectionB = treeB.AddSection("B's section");
        var newPageB = b.Client.CreatePage(w.Notebook, sectionB, "B's page");
        newPageB.Edit(e => e.Insert(0, "written on B"));
        var newPageA = a.Client.CreatePage(w.Notebook, w.Section, "A's second page");
        newPageA.Edit(e => e.Insert(0, "written on A"));
        treeB.MovePage(w.Page, sectionB, 0);

        await a.SyncAsync();
        await b.SyncAsync();
        await a.SyncAsync();

        var dumpA = a.Client.DumpNotebook(w.Notebook);
        Assert.Equal(dumpA, b.Client.DumpNotebook(w.Notebook));
        var text = pageA.GetText();
        Assert.StartsWith("A: ", text);
        Assert.Contains("ello world (B was here)", text);
        Assert.Equal("Renamed by A", treeB.GetPage(w.Page)!.Title);
        Assert.Equal(sectionB, treeA.GetPage(w.Page)!.SectionId);
        Assert.Equal("written on B\n", a.Client.OpenPage(w.Notebook, newPageB.DocId).GetText());
        Assert.Equal("written on A\n", b.Client.OpenPage(w.Notebook, newPageA.DocId).GetText());

        // The same holds after both forget everything and rebuild from their local ciphertext.
        await a.RestartAsync();
        await b.RestartAsync();
        Assert.Equal(dumpA, a.Client.DumpNotebook(w.Notebook));
        Assert.Equal(dumpA, b.Client.DumpNotebook(w.Notebook));
        Assert.Equal(a.Sync.Status.Cursor, b.Sync.Status.Cursor);
        Assert.Empty(a.Issues);
        Assert.Empty(b.Issues);
    }

    [Fact]
    public async Task The_outbox_is_pushed_in_the_order_the_edits_were_made_even_across_documents_and_batches()
    {
        await using var w = await Start(s => s.PushBatchSize = 3);
        var a = w.A;
        var page = a.Client.OpenPage(w.Notebook, w.Page);
        var tree = a.Client.OpenNotebook(w.Notebook);
        var other = a.Client.CreatePage(w.Notebook, w.Section, "Other");
        await a.SyncAsync();
        var seqBefore = a.Sync.Status.Cursor;

        var made = new List<string>();
        page.LocalUpdate += _ => made.Add(page.DocId);
        tree.LocalUpdate += _ => made.Add(tree.DocId);
        other.LocalUpdate += _ => made.Add(other.DocId);
        var rng = new Random(7);
        for (var i = 0; i < 40; i++)
        {
            switch (rng.Next(3))
            {
                case 0: page.Edit(e => e.Insert(0, "p")); break;
                case 1: tree.TouchPage(w.Page); break;
                default: other.Edit(e => e.Insert(0, "o")); break;
            }
        }

        Assert.Equal(40, a.Sync.Status.PendingUpdates);
        a.Net.Requests.Clear();
        await a.SyncAsync();

        var events = (await AllEvents(a)).Where(e => e.Seq > seqBefore).ToList();
        Assert.All(events, e => Assert.Equal(ServerEvent.Update, e.Type));
        Assert.Equal(made, events.Select(e => e.DocId!).ToList());                                  // exact order, by seq
        Assert.Equal(events.Select(e => e.Seq).Order().ToList(), events.Select(e => e.Seq).ToList());
        Assert.True(a.Net.Requests.Count(r => r.StartsWith("POST") && r.EndsWith("/updates")) > 13); // really was split up
        Assert.Equal(0, a.Sync.Status.PendingUpdates);
    }

    [Fact]
    public async Task Events_are_applied_page_by_page_in_seq_order_and_a_reordered_page_is_refused()
    {
        await using var w = await Start();
        var a = w.A;
        var b = await w.Enrol("B", s => s.EventsPageSize = 4);
        await b.SyncAsync();
        var page = a.Client.OpenPage(w.Notebook, w.Page);

        // Type, then delete part of what was typed: the delete only works if it arrives second.
        for (var i = 0; i < 10; i++)
        {
            page.Edit(e => e.Insert(0, "abcdef"));
            page.Edit(e => e.Delete(1, 4));
        }

        await a.SyncAsync();

        // A server (or middlebox) that hands the events out in the wrong order is not believed.
        var cursor = b.Sync.Status.Cursor;
        b.Net.RewriteAnswer = (request, body) =>
        {
            if (!request.RequestUri!.AbsolutePath.EndsWith("/events"))
            {
                return body;
            }

            var json = JsonNode.Parse(body)!;
            var events = json["events"]!.AsArray();
            var reversed = events.Reverse().Select(e => e!.DeepClone()).ToArray();
            events.Clear();
            foreach (var e in reversed)
            {
                events.Add(e);
            }

            return json.ToJsonString();
        };
        await Assert.ThrowsAsync<ProtocolViolationException>(() => b.SyncAsync());
        Assert.Equal(cursor, b.Sync.Status.Cursor);
        Assert.Equal(SyncState.Error, b.Sync.Status.State);
        Assert.Equal("Hello world\n", b.Client.OpenPage(w.Notebook, w.Page).GetText());

        // With an honest network the same events arrive in pages of four and are applied in order.
        b.Net.RewriteAnswer = null;
        b.Net.Requests.Clear();
        await b.SyncAsync();
        Assert.True(b.Net.Requests.Count(r => r == "GET /api/v1/events") >= 5);
        Assert.Equal(page.GetText(), b.Client.OpenPage(w.Notebook, w.Page).GetText());
        Assert.Equal(Docs.Dump(page), Docs.Dump(b.Client.OpenPage(w.Notebook, w.Page)));
        Assert.Equal(a.Sync.Status.Cursor, b.Sync.Status.Cursor);
        Assert.Equal(SyncState.Idle, b.Sync.Status.State);
    }

    [Fact]
    public async Task A_push_whose_answer_is_lost_is_retried_with_the_same_ids_and_never_duplicated()
    {
        await using var w = await Start();
        var a = w.A;
        var page = a.Client.OpenPage(w.Notebook, w.Page);
        var eventsBefore = (await AllEvents(a)).Count;
        for (var i = 0; i < 5; i++)
        {
            page.Edit(e => e.Insert(0, "x"));
        }

        // The server stores the updates, but the acknowledgement never arrives.
        a.Net.LoseAnswer = r => r.Method == HttpMethod.Post && r.RequestUri!.AbsolutePath.EndsWith("/updates");
        await Assert.ThrowsAsync<ServerUnreachableException>(() => a.SyncAsync());
        Assert.Equal(5, a.Sync.Status.PendingUpdates);           // nothing left the outbox without an ack
        a.Net.LoseAnswer = null;
        var onServer = (await AllEvents(a)).Count;
        Assert.Equal(eventsBefore + 5, onServer);

        // Retry: the server recognises the clientUpdateIds and hands back the original seqs.
        await a.SyncAsync();
        Assert.Equal(0, a.Sync.Status.PendingUpdates);
        Assert.Equal(onServer, (await AllEvents(a)).Count);
        await a.SyncAsync();
        Assert.Equal(onServer, (await AllEvents(a)).Count);

        var b = await w.Enrol("B");
        await b.SyncAsync();
        Assert.Equal("xxxxxHello world\n", b.Client.OpenPage(w.Notebook, w.Page).GetText());
    }

    [Fact]
    public async Task A_crash_between_push_and_acknowledgement_loses_nothing_and_duplicates_nothing()
    {
        await using var w = await Start();
        var a = w.A;
        var b = await w.Enrol("B");
        await b.SyncAsync();
        var before = (await AllEvents(b)).Count;
        var page = a.Client.OpenPage(w.Notebook, w.Page);
        page.Edit(e => e.Insert(0, "one "));
        page.Edit(e => e.Insert(4, "two "));
        a.Client.OpenNotebook(w.Notebook).RenamePage(w.Page, "renamed before the crash");

        // The first push (the two page edits) reaches the server; the process dies before it can
        // record the answer, with the rename still queued behind it.
        a.Net.LoseAnswer = r => r.Method == HttpMethod.Post;
        await Assert.ThrowsAsync<ServerUnreachableException>(() => a.SyncAsync());
        a.Net.LoseAnswer = null;
        Assert.Equal(before + 2, (await AllEvents(b)).Count);
        await a.RestartAsync();

        // The other device already has the edit (it was on the server all along).
        await b.SyncAsync();
        Assert.StartsWith("one two Hello", b.Client.OpenPage(w.Notebook, w.Page).GetText());

        // After the restart the outbox is still there, in order; the retry is recognised.
        Assert.Equal(3, a.Sync.Status.PendingUpdates);
        Assert.StartsWith("one two Hello", a.Client.OpenPage(w.Notebook, w.Page).GetText());
        a.Client.OpenPage(w.Notebook, w.Page).Edit(e => e.Insert(8, "three "));
        await a.SyncAsync();
        Assert.Equal(0, a.Sync.Status.PendingUpdates);
        var events = await AllEvents(b);
        Assert.Equal(before + 4, events.Count); // the two page edits once, plus the rename and "three"
        Assert.Equal(events.Count, events.Select(e => e.Seq).Distinct().Count());

        await b.SyncAsync();
        Assert.Equal(a.Client.DumpNotebook(w.Notebook), b.Client.DumpNotebook(w.Notebook));
        Assert.StartsWith("one two three Hello", b.Client.OpenPage(w.Notebook, w.Page).GetText());
        Assert.Equal("renamed before the crash", b.Client.OpenNotebook(w.Notebook).GetPage(w.Page)!.Title);

        // And A's own store is consistent after yet another restart.
        await a.RestartAsync();
        Assert.Equal(b.Client.DumpNotebook(w.Notebook), a.Client.DumpNotebook(w.Notebook));
    }

    [Fact]
    public async Task More_than_200_unsnapshotted_updates_are_compacted_and_a_new_device_rebuilds_from_the_snapshot()
    {
        await using var w = await Start();
        var a = w.A;
        var b = await w.Enrol("B");
        await b.SyncAsync();
        var page = a.Client.OpenPage(w.Notebook, w.Page);

        var pageB = b.Client.OpenPage(w.Notebook, w.Page);

        // Start made two updates to the page; 198 more is exactly 200, which is not "more than 200".
        for (var i = 0; i < 198; i++)
        {
            page.Edit(e => e.Insert(e.Length - 1, (i % 10).ToString()));
        }

        await a.SyncAsync();
        var docs = await a.Client.Api.GetDocsAsync();
        Assert.All(docs, d => Assert.Equal(0, d.SnapshotSeq));
        using (var store = LocalStore.Open(a.DatabasePath))
        {
            Assert.Equal(200, store.LoadDoc(w.Page)!.UpdateBlobs.Count);
        }

        // One more tips it over.
        page.Edit(e => e.Insert(0, "!"));
        await a.SyncAsync();
        var head = a.Sync.Status.Head;
        var doc = (await a.Client.Api.GetDocsAsync()).Single(d => d.DocId == w.Page);
        Assert.Equal(head - 1, doc.SnapshotSeq);                   // coveredSeq was head at the time; the snapshot event is head now
        Assert.Equal(a.Sync.Status.Cursor, head);
        var events = await AllEvents(a);
        Assert.DoesNotContain(events, e => e.Type == ServerEvent.Update && e.DocId == w.Page);
        var marker = Assert.Single(events, e => e.Type == ServerEvent.Snapshot);
        Assert.Equal((w.Page, doc.SnapshotSeq), (marker.DocId, marker.CoveredSeq!.Value));
        Assert.Equal(0, (await a.Client.Api.GetDocsAsync()).Single(d => d.DocId == w.Notebook).SnapshotSeq); // the tree was not due

        // Locally, the covered updates are gone and the snapshot is the same ciphertext the server holds.
        using (var store = LocalStore.Open(a.DatabasePath))
        {
            var content = store.LoadDoc(w.Page)!;
            Assert.Empty(content.UpdateBlobs);
            Assert.Equal(doc.SnapshotSeq, content.SnapshotSeq);
            Assert.Equal((await a.Client.Api.GetSnapshotAsync(w.Page))!.Blob, content.SnapshotBlob);
        }

        // B, which had the page open the whole time, merges the snapshot; A keeps editing afterwards.
        page.Edit(e => e.Insert(0, "after the snapshot "));
        await a.SyncAsync();
        await b.SyncAsync();
        Assert.Equal(Docs.Dump(page), Docs.Dump(pageB));
        using (var store = LocalStore.Open(b.DatabasePath))
        {
            var content = store.LoadDoc(w.Page)!;
            Assert.Equal(doc.SnapshotSeq, content.SnapshotSeq);
            Assert.Single(content.UpdateBlobs);
        }

        // A brand-new device gets snapshot + later events and ends up identical.
        var c = await w.Enrol("C");
        c.Net.Requests.Clear();
        await c.SyncAsync();
        Assert.Contains($"GET /api/v1/docs/{w.Page}/snapshot", c.Net.Requests);
        Assert.Equal(a.Client.DumpNotebook(w.Notebook), c.Client.DumpNotebook(w.Notebook));
        Assert.StartsWith("after the snapshot !Hello world0123456789", c.Client.OpenPage(w.Notebook, w.Page).GetText());
        Assert.Equal(a.Client.DumpNotebook(w.Notebook), b.Client.DumpNotebook(w.Notebook));

        // Restarting from local ciphertext (snapshot + updates) gives the same again.
        await a.RestartAsync();
        Assert.Equal(c.Client.DumpNotebook(w.Notebook), a.Client.DumpNotebook(w.Notebook));
        Assert.Empty(a.Issues);
        Assert.Empty(b.Issues);
        Assert.Empty(c.Issues);
    }

    [Fact]
    public async Task A_device_that_mostly_reads_compacts_too_and_its_snapshot_holds_everything()
    {
        await using var w = await Start(s => s.CompactionThreshold = 10);
        var a = w.A;
        var b = await w.Enrol("B", s => s.CompactionThreshold = 1000);
        await b.SyncAsync();
        var page = b.Client.OpenPage(w.Notebook, w.Page);
        for (var i = 0; i < 30; i++)
        {
            page.Edit(e => e.Insert(0, "b"));
        }

        await b.SyncAsync();                      // B's threshold is high: no snapshot
        Assert.Equal(0, (await b.Client.Api.GetDocsAsync()).Single(d => d.DocId == w.Page).SnapshotSeq);

        // A only reads these updates, and has an edit of its own queued.
        a.Client.OpenPage(w.Notebook, w.Page).Edit(e => e.Insert(0, "a"));
        await a.SyncAsync();
        var doc = (await a.Client.Api.GetDocsAsync()).Single(d => d.DocId == w.Page);
        Assert.True(doc.SnapshotSeq > 0);
        Assert.Equal(0, a.Sync.Status.PendingUpdates);

        // The snapshot A uploaded contains A's own edit and all of B's.
        var c = await w.Enrol("C");
        await c.SyncAsync();
        await b.SyncAsync();
        var text = c.Client.OpenPage(w.Notebook, w.Page).GetText();
        Assert.Equal(43, text.Length);
        Assert.EndsWith("Hello world\n", text);
        Assert.Equal((1, 30), (text.Count(ch => ch == 'a'), text.Count(ch => ch == 'b')));
        Assert.Equal(c.Client.DumpNotebook(w.Notebook), b.Client.DumpNotebook(w.Notebook));
        Assert.Equal(c.Client.DumpNotebook(w.Notebook), a.Client.DumpNotebook(w.Notebook));
    }

    [Fact]
    public async Task A_tampered_blob_is_reported_and_skipped_and_everything_else_still_applies()
    {
        await using var w = await Start();
        var a = w.A;
        var b = await w.Enrol("B");
        await b.SyncAsync();
        var pageB = b.Client.OpenPage(w.Notebook, w.Page);
        var before = Docs.Dump(pageB);

        // Somebody with a valid session (or the server itself) plants blobs that are not ours:
        // a real update with one bit flipped, a real update moved to another document, and noise.
        using var rogue = new TwoNoteApi(TestServer.Url, w.Server.CreateHandler());
        var challenge = await rogue.AuthStartAsync(Device.Username);
        using (var key = SecretKey.Parse(w.SecretKey))
        using (var keys = KeyDerivation.Derive(Device.Password, key, WireEncoding.IdFromHex(challenge.AccountId), challenge.KdfSalt, challenge.KdfParams))
        {
            rogue.Token = (await rogue.AuthFinishAsync(challenge.ChallengeId, LoginSignature.Sign(keys.AuthPrivateKey, challenge.Nonce), "rogue")).Token;
        }

        var genuine = (await AllEvents(a)).Where(e => e.Type == ServerEvent.Update).ToList();
        var flipped = (byte[])genuine.Last(e => e.DocId == w.Page).Blob!.Clone();
        flipped[^1] ^= 0x01;
        var moved = genuine.First(e => e.DocId == w.Notebook).Blob!;
        var noise = new byte[100];
        Random.Shared.NextBytes(noise);
        noise[0] = 0x01;
        var planted = await rogue.PushUpdatesAsync(w.Page, w.Notebook,
        [
            new OutgoingUpdate(Docs.NewId(), flipped),
            new OutgoingUpdate(Docs.NewId(), moved),
            new OutgoingUpdate(Docs.NewId(), noise),
        ]);

        // A genuine edit after the bad ones.
        a.Client.OpenPage(w.Notebook, w.Page).Edit(e => e.Insert(0, "still works: "));
        await a.SyncAsync();
        await b.SyncAsync();

        Assert.Equal("still works: " + "Hello world\n", pageB.GetText());
        Assert.Equal(Docs.Dump(a.Client.OpenPage(w.Notebook, w.Page)), Docs.Dump(pageB));
        Assert.NotEqual(before, Docs.Dump(pageB));
        foreach (var device in new[] { a, b })
        {
            Assert.Equal(3, device.Issues.Count);
            Assert.All(device.Issues, i => Assert.Equal((SyncIssueKind.BlobRejected, w.Page, w.Notebook), (i.Kind, i.DocId, i.NotebookId)));
            Assert.Equal(planted.Seqs.ToList(), device.Issues.Select(i => i.Seq!.Value).ToList());
            Assert.Equal(device.Issues, device.Sync.Issues.ToList());
            Assert.Equal(device.Sync.Status.Head, device.Sync.Status.Cursor); // the cursor moved past them
        }

        // The rejected blobs were not stored, and the document is never compacted from a device that has a hole.
        using (var store = LocalStore.Open(b.DatabasePath))
        {
            Assert.True(store.GetDoc(w.Page)!.Damaged);
            Assert.DoesNotContain(store.LoadDoc(w.Page)!.UpdateBlobs, blob => blob.AsSpan().SequenceEqual(flipped) || blob.AsSpan().SequenceEqual(noise));
        }

        await b.RestartAsync();
        Assert.Equal("still works: " + "Hello world\n", b.Client.OpenPage(w.Notebook, w.Page).GetText());
        Assert.Empty(b.Issues.Skip(3));
    }

    [Fact]
    public async Task A_push_to_a_deleted_document_gets_410_and_the_outbox_for_it_is_dropped()
    {
        await using var w = await Start();
        var a = w.A;
        var b = await w.Enrol("B");
        await b.SyncAsync();
        var pageB = b.Client.OpenPage(w.Notebook, w.Page);
        var keepB = b.Client.CreatePage(w.Notebook, w.Section, "kept");
        var deleted = 0;
        pageB.Deleted += () => deleted++;

        // B edits the page offline; meanwhile A removes it for good. The deletion lands on the
        // server after B's pull but before B's push, so B only learns of it from the 410.
        pageB.Edit(e => e.Insert(0, "doomed edit "));
        keepB.Edit(e => e.Insert(0, "this one survives"));
        pageB.Edit(e => e.Insert(0, "another doomed edit "));
        var purged = false;
        b.Net.Before = async request =>
        {
            if (!purged && request.Method == HttpMethod.Post && request.RequestUri!.AbsolutePath.EndsWith("/updates"))
            {
                purged = true;
                a.Client.OpenNotebook(w.Notebook).SetPageDeleted(w.Page);
                await a.Client.PurgePageAsync(w.Notebook, w.Page);
            }
        };
        await b.SyncAsync();
        b.Net.Before = null;

        Assert.True(purged);
        Assert.Contains($"POST /api/v1/docs/{w.Page}/updates", b.Net.Requests);
        var issue = Assert.Single(b.Issues);
        Assert.Equal((SyncIssueKind.EditsDropped, w.Page), (issue.Kind, issue.DocId));
        Assert.Equal(0, b.Sync.Status.PendingUpdates);           // dropped, and the rest went out
        Assert.True(pageB.IsDeleted);
        Assert.Equal(1, deleted);

        // The server did not resurrect the document, and B has forgotten it.
        var docs = await b.Client.Api.GetDocsAsync();
        Assert.DoesNotContain(docs, d => d.DocId == w.Page);
        Assert.Contains(docs, d => d.DocId == keepB.DocId);
        using (var store = LocalStore.Open(b.DatabasePath))
        {
            Assert.Null(store.GetDoc(w.Page));
            Assert.Null(store.LoadDoc(w.Page));
        }

        // Later edits to the dead document go nowhere; the rest of the notebook syncs on.
        pageB.Edit(e => e.Insert(0, "into the void"));
        Assert.Equal(0, b.Sync.Status.PendingUpdates);
        await a.SyncAsync();
        await b.SyncAsync();
        Assert.Equal("this one survives\n", a.Client.OpenPage(w.Notebook, keepB.DocId).GetText());
        Assert.True(b.Client.OpenNotebook(w.Notebook).GetPage(w.Page)!.Deleted);
        Assert.DoesNotContain(await b.Client.Api.GetDocsAsync(), d => d.DocId == w.Page);
    }

    [Fact]
    public async Task A_docDeleted_event_drops_the_local_document_and_its_unsent_edits()
    {
        await using var w = await Start();
        var a = w.A;
        var b = await w.Enrol("B");
        await b.SyncAsync();
        var pageB = b.Client.OpenPage(w.Notebook, w.Page);
        pageB.Edit(e => e.Insert(0, "unsent "));
        var pageA = a.Client.OpenPage(w.Notebook, w.Page);
        await a.Client.PurgePageAsync(w.Notebook, w.Page);
        Assert.True(pageA.IsDeleted);

        b.Net.Requests.Clear();
        await b.SyncAsync();
        Assert.True(pageB.IsDeleted);
        Assert.Equal(0, b.Sync.Status.PendingUpdates);
        Assert.DoesNotContain(b.Net.Requests, r => r.EndsWith("/updates")); // the pull came first: nothing was pushed
        using var store = LocalStore.Open(b.DatabasePath);
        Assert.Null(store.GetDoc(w.Page));
        Assert.DoesNotContain(await b.Client.Api.GetDocsAsync(), d => d.DocId == w.Page);
    }

    [Fact]
    public async Task Notebooks_created_and_deleted_elsewhere_appear_and_disappear()
    {
        await using var w = await Start();
        var a = w.A;
        var b = await w.Enrol("B");
        await b.SyncAsync();
        var changes = 0;
        b.Sync.NotebooksChanged += () => changes++;

        var second = a.Client.CreateNotebook("Second");
        var section = second.AddSection("s");
        a.Client.CreatePage(second.NotebookId, section, "p").Edit(e => e.Insert(0, "in the second notebook"));
        await a.SyncAsync();
        await b.SyncAsync();
        Assert.Equal(2, b.Client.NotebookIds.Count);
        Assert.True(changes >= 1);
        Assert.Equal(a.Client.DumpNotebook(second.NotebookId), b.Client.DumpNotebook(second.NotebookId));

        // B has unsent edits in the first notebook when A deletes it.
        var treeB = b.Client.OpenNotebook(w.Notebook);
        var pageB = b.Client.OpenPage(w.Notebook, w.Page);
        pageB.Edit(e => e.Insert(0, "lost with the notebook "));
        await a.Client.DeleteNotebookAsync(w.Notebook);
        Assert.Equal([second.NotebookId], a.Client.NotebookIds);
        Assert.Throws<KeyNotFoundException>(() => a.Client.OpenNotebook(w.Notebook));

        await b.SyncAsync();
        Assert.Equal([second.NotebookId], b.Client.NotebookIds);
        Assert.True(treeB.IsDeleted);
        Assert.True(pageB.IsDeleted);
        Assert.Equal(0, b.Sync.Status.PendingUpdates);
        Assert.Throws<KeyNotFoundException>(() => b.Client.OpenNotebook(w.Notebook));
        using (var store = LocalStore.Open(b.DatabasePath))
        {
            Assert.Equal([second.NotebookId], store.GetNotebooks().Select(n => n.NotebookId));
            Assert.All(store.GetDocs(), d => Assert.Equal(second.NotebookId, d.NotebookId));
        }

        // A notebook that never left the device is deleted without the server.
        b.Net.Offline = true;
        var local = b.Client.CreateNotebook("never synced");
        await b.Client.DeleteNotebookAsync(local.NotebookId);
        Assert.Equal([second.NotebookId], b.Client.NotebookIds);
        Assert.Equal(0, b.Sync.Status.PendingUpdates);
    }

    [Fact]
    public async Task The_background_loop_is_woken_by_the_websocket_and_by_local_edits_and_survives_an_outage()
    {
        // Poll interval of an hour: only a wake-up can explain an update arriving.
        await using var w = await Start();
        var a = w.A;
        var b = await w.Enrol("B");
        var heads = new List<long>();
        b.Sync.HeadNotified += head =>
        {
            lock (heads)
            {
                heads.Add(head);
            }
        };

        b.Sync.Start();
        Assert.True(b.Sync.IsRunning);
        await SyncTestExtensions.Eventually(() => b.Sync.Status is { WebSocketConnected: true, State: SyncState.Idle } && b.Client.NotebookIds.Count == 1, "B's first sync");
        var pageB = b.Client.OpenPage(w.Notebook, w.Page);
        Assert.Equal("Hello world\n", pageB.GetText());

        // A pushes; B is told over the socket and pulls.
        var remote = new List<TextChange>();
        pageB.TextChanged += remote.Add;
        var pageA = a.Client.OpenPage(w.Notebook, w.Page);
        pageA.Edit(e => e.Insert(0, "pushed by A: "));
        await a.SyncAsync();
        var headAfterPush = a.Sync.Status.Head;
        await SyncTestExtensions.Eventually(() => pageB.GetText() == "pushed by A: Hello world\n", "the edit to reach B");
        lock (heads)
        {
            Assert.Contains(headAfterPush, heads);
        }

        var change = Assert.Single(remote);
        Assert.Equal(ChangeSource.Remote, change.Source);
        Assert.Equal((DeltaKind.Insert, "pushed by A: "), (change.Delta[0].Kind, change.Delta[0].Text));

        // A local edit on B wakes its loop too: A sees it without B being asked to sync.
        pageB.Edit(e => e.Insert(0, "B answers. "));
        await SyncTestExtensions.Eventually(() => b.Sync.Status.PendingUpdates == 0, "B's edit to be pushed");
        await a.SyncAsync();
        Assert.StartsWith("B answers. pushed by A: ", pageA.GetText());

        // An outage: B goes offline, keeps the edit, and delivers it once the network is back.
        b.Net.Offline = true;
        pageB.Edit(e => e.Insert(0, "during the outage. "));
        await SyncTestExtensions.Eventually(() => b.Sync.Status.State == SyncState.Offline, "B to notice the outage");
        Assert.Equal(1, b.Sync.Status.PendingUpdates);
        b.Net.Offline = false;
        await SyncTestExtensions.Eventually(() => b.Sync.Status is { PendingUpdates: 0, State: SyncState.Idle }, "B to recover");
        await a.SyncAsync();
        Assert.StartsWith("during the outage. B answers. ", pageA.GetText());

        // Stopped means stopped.
        await b.Sync.StopAsync();
        Assert.False(b.Sync.IsRunning);
        Assert.False(b.Sync.Status.WebSocketConnected);
        pageA.Edit(e => e.Insert(0, "unseen "));
        await a.SyncAsync();
        await Task.Delay(300);
        Assert.StartsWith("during the outage. ", pageB.GetText());
        await b.SyncAsync();
        Assert.Equal(pageA.GetText(), pageB.GetText());
    }

    [Fact]
    public async Task Remote_changes_are_applied_through_the_dispatcher()
    {
        using var server = new TestServer();
        await using var a = Device.Create(server, "A");
        var secretKey = await a.Client.RegisterAsync(Device.Username, Device.Password, "A");
        var tree = a.Client.CreateNotebook("N");
        var page = a.Client.CreatePage(tree.NotebookId, tree.AddSection("s"), "p");
        await a.SyncAsync();

        var dispatched = 0;
        var dir = Path.Combine(Path.GetTempPath(), "twonote-core-tests", "device-" + Guid.NewGuid().ToString("N"));
        await using (var b = TwoNoteClient.Open(new ClientOptions
                     {
                         ServerUrl = TestServer.Url,
                         DatabasePath = Path.Combine(dir, "local.db"),
                         SecretStore = new InMemorySecretStore(),
                         HttpHandler = server.CreateHandler(),
                         UseWebSocket = false,
                         KdfParams = Device.FastKdf,
                         Dispatcher = action =>
                         {
                             dispatched++;
                             action();
                             return Task.CompletedTask;
                         },
                     }))
        {
            await b.EnrolAsync(Device.Username, Device.Password, secretKey, "B");
            await b.Sync.SyncNowAsync();
            var pageB = b.OpenPage(tree.NotebookId, page.DocId);
            Assert.Equal(0, dispatched); // nothing was open, so nothing had to be applied in memory
            page.Edit(e => e.Insert(0, "x"));
            await a.SyncAsync();
            await b.Sync.SyncNowAsync();
            Assert.Equal(1, dispatched);
            Assert.Equal("x\n", pageB.GetText());
        }

        Microsoft.Data.Sqlite.SqliteConnection.ClearAllPools();
        Directory.Delete(dir, recursive: true);
    }
}

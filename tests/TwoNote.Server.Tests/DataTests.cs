using System.Text.Json;

namespace TwoNote.Server.Tests;

public class DataTests
{
    private static async Task<(TestApp App, Api Api, string Token, string DeviceId)> Start(Action<TwoNoteOptions>? configure = null)
    {
        var app = new TestApp(configure: configure);
        var (deviceId, token) = await new TestAccount().Register(app.Api);
        return (app, app.Api, token, deviceId);
    }

    private static long Seq(JsonElement e) => e.GetProperty("seq").GetInt64();
    private static string Type(JsonElement e) => e.GetProperty("type").GetString()!;

    [Fact]
    public async Task Notebooks_can_be_created_replaced_listed_and_deleted()
    {
        var (app, api, token, _) = await Start();
        using var _ = app;

        Assert.Equal(0, (await api.GetJson("/notebooks", token)).GetArrayLength());

        var id = T.NewId();
        var key1 = T.B64(T.Blob(73));
        var key2 = T.B64(T.Blob(73));

        Assert.Equal(1, (await api.PutJson($"/notebooks/{id}", new { wrappedKey = key1 }, token)).GetProperty("head").GetInt64());
        var listed = Assert.Single((await api.GetJson("/notebooks", token)).EnumerateArray());
        Assert.Equal(["notebookId", "wrappedKey"], T.Names(listed));
        Assert.Equal(id, listed.GetProperty("notebookId").GetString());
        Assert.Equal(key1, listed.GetProperty("wrappedKey").GetString());

        // Replace.
        Assert.Equal(2, (await api.PutJson($"/notebooks/{id}", new { wrappedKey = key2 }, token)).GetProperty("head").GetInt64());
        Assert.Equal(key2, Assert.Single((await api.GetJson("/notebooks", token)).EnumerateArray()).GetProperty("wrappedKey").GetString());

        // An identical retry is a no-op.
        Assert.Equal(2, (await api.PutJson($"/notebooks/{id}", new { wrappedKey = key2 }, token)).GetProperty("head").GetInt64());

        // A second notebook, then delete the first.
        var other = await T.Notebook(api, token);
        Assert.Equal(4, (await api.DeleteJson($"/notebooks/{id}", token)).GetProperty("head").GetInt64());
        Assert.Equal(other, Assert.Single((await api.GetJson("/notebooks", token)).EnumerateArray()).GetProperty("notebookId").GetString());
        await api.Error(HttpMethod.Delete, $"/notebooks/{id}", 404, "unknown_notebook", token: token);

        // Every change announced itself.
        var events = await T.AllEvents(api, token);
        Assert.Equal([1L, 2L, 3L, 4L], events.Select(Seq));
        Assert.All(events, e => Assert.Equal(["seq", "type"], T.Names(e)));
        Assert.All(events, e => Assert.Equal("notebooksChanged", Type(e)));

        // Validation.
        await api.Error(HttpMethod.Put, "/notebooks/XYZ", 400, "invalid_request", new { wrappedKey = key1 }, token);
        await api.Error(HttpMethod.Put, $"/notebooks/{T.NewId()}", 400, "invalid_request", new { }, token);
        await api.Error(HttpMethod.Put, $"/notebooks/{T.NewId()}", 400, "invalid_request", new { wrappedKey = "a+b/" }, token);
    }

    [Fact]
    public async Task Pushed_updates_get_strictly_increasing_account_wide_seqs()
    {
        var (app, api, token, deviceId) = await Start();
        using var _ = app;
        var notebook = await T.Notebook(api, token);                 // seq 1
        var docA = T.NewId();
        var docB = T.NewId();
        var blobs = Enumerable.Range(0, 5).Select(i => T.Blob(20 + i)).ToArray();

        var first = await api.PostJson($"/docs/{docA}/updates",
            new { notebookId = notebook, updates = new[] { T.Update(blobs[0]), T.Update(blobs[1]) } }, token);
        Assert.Equal(["head", "seqs"], T.Names(first));
        Assert.Equal([2L, 3L], first.GetProperty("seqs").EnumerateArray().Select(s => s.GetInt64()));
        Assert.Equal(3, first.GetProperty("head").GetInt64());

        Assert.Equal(new long[] { 4L }, await T.Push(api, token, docB, notebook, blobs[2]));          // one counter across documents
        Assert.Equal(new long[] { 5L, 6L }, await T.Push(api, token, docA, notebook, blobs[3], blobs[4]));

        // The document was created on first use.
        var docs = await api.GetJson("/docs", token);
        Assert.Equal(2, docs.GetArrayLength());
        foreach (var d in docs.EnumerateArray())
        {
            Assert.Equal(["docId", "notebookId", "snapshotSeq"], T.Names(d));
            Assert.Equal(notebook, d.GetProperty("notebookId").GetString());
            Assert.Equal(0, d.GetProperty("snapshotSeq").GetInt64());
        }

        var page = await api.GetJson("/events", token);
        Assert.Equal(["events", "head", "more"], T.Names(page));
        Assert.Equal(6, page.GetProperty("head").GetInt64());
        Assert.False(page.GetProperty("more").GetBoolean());
        var updates = page.GetProperty("events").EnumerateArray().Where(e => Type(e) == "update").ToList();
        Assert.Equal([2L, 3L, 4L, 5L, 6L], updates.Select(Seq));
        Assert.Equal([docA, docA, docB, docA, docA], updates.Select(e => e.GetProperty("docId").GetString()));
        Assert.Equal(blobs.Select(b => T.B64(b)), updates.Select(e => e.GetProperty("blob").GetString()));
        Assert.All(updates, e =>
        {
            Assert.Equal(["blob", "deviceId", "docId", "notebookId", "seq", "type"], T.Names(e));
            Assert.Equal(deviceId, e.GetProperty("deviceId").GetString());
            Assert.Equal(notebook, e.GetProperty("notebookId").GetString());
            Assert.DoesNotContain('=', e.GetProperty("blob").GetString()!);
        });
    }

    [Fact]
    public async Task Concurrent_pushes_never_share_or_skip_a_seq()
    {
        var (app, api, token, _) = await Start();
        using var _ = app;
        var notebook = await T.Notebook(api, token);

        var results = await Task.WhenAll(Enumerable.Range(0, 20).Select(i =>
            T.Push(api, token, T.NewId(), notebook, T.Blob(), T.Blob(), T.Blob())));

        Assert.All(results, seqs => Assert.Equal([seqs[0], seqs[0] + 1, seqs[0] + 2], seqs)); // each request is one transaction
        Assert.Equal(Enumerable.Range(2, 60).Select(i => (long)i), results.SelectMany(s => s).Order());
    }

    [Fact]
    public async Task Push_is_idempotent_per_client_update_id()
    {
        var (app, api, token, _) = await Start();
        using var _ = app;
        var notebook = await T.Notebook(api, token);
        var doc = T.NewId();
        var (id1, id2, id3) = (T.NewId(), T.NewId(), T.NewId());
        var blob = T.Blob();

        var body = new { notebookId = notebook, updates = new[] { T.Update(blob, id1), T.Update(T.Blob(), id2) } };
        var first = await api.PostJson($"/docs/{doc}/updates", body, token);
        var repeat = await api.PostJson($"/docs/{doc}/updates", body, token);
        Assert.Equal(first.GetRawText(), repeat.GetRawText());

        // A batch mixing a repeat with a new update: the repeat keeps its seq, the new one gets the next.
        var mixed = await api.PostJson($"/docs/{doc}/updates",
            new { notebookId = notebook, updates = new[] { T.Update(T.Blob(), id2), T.Update(T.Blob(), id3), T.Update(T.Blob(), id3) } }, token);
        Assert.Equal([3L, 4L, 4L], mixed.GetProperty("seqs").EnumerateArray().Select(s => s.GetInt64()));
        Assert.Equal(4, mixed.GetProperty("head").GetInt64());

        // Nothing was stored twice, and the original blob was kept.
        var updates = (await T.AllEvents(api, token)).Where(e => Type(e) == "update").ToList();
        Assert.Equal([2L, 3L, 4L], updates.Select(Seq));
        Assert.Equal(T.B64(blob), updates[0].GetProperty("blob").GetString());

        // The same id on a different document is a client bug, not a repeat.
        await api.Error(HttpMethod.Post, $"/docs/{T.NewId()}/updates", 409, "update_id_conflict",
            new { notebookId = notebook, updates = new[] { T.Update(T.Blob(), id1) } }, token);
    }

    [Fact]
    public async Task Push_validates_notebook_ids_and_blobs()
    {
        var (app, api, token, _) = await Start();
        using var _ = app;
        var notebook = await T.Notebook(api, token);
        var otherNotebook = await T.Notebook(api, token);
        var doc = T.NewId();
        await T.Push(api, token, doc, notebook, T.Blob());

        await api.Error(HttpMethod.Post, $"/docs/{T.NewId()}/updates", 404, "unknown_notebook",
            new { notebookId = T.NewId(), updates = new[] { T.Update(T.Blob()) } }, token);
        await api.Error(HttpMethod.Post, $"/docs/{doc}/updates", 409, "notebook_mismatch",
            new { notebookId = otherNotebook, updates = new[] { T.Update(T.Blob()) } }, token);

        await api.Error(HttpMethod.Post, $"/docs/{doc.ToUpperInvariant()}/updates", 400, "invalid_request",
            new { notebookId = notebook, updates = new[] { T.Update(T.Blob()) } }, token);
        await api.Error(HttpMethod.Post, $"/docs/{doc}/updates", 400, "invalid_request",
            new { notebookId = notebook, updates = Array.Empty<object>() }, token);
        await api.Error(HttpMethod.Post, $"/docs/{doc}/updates", 400, "invalid_request",
            new { notebookId = notebook, updates = new[] { new { clientUpdateId = "short", blob = "AAAA" } } }, token);
        await api.Error(HttpMethod.Post, $"/docs/{doc}/updates", 400, "invalid_request",
            new { notebookId = notebook, updates = new[] { new { clientUpdateId = T.NewId(), blob = "AAA=" } } }, token); // padding
        await api.Error(HttpMethod.Post, $"/docs/{doc}/updates", 400, "invalid_request",
            new { notebookId = notebook, updates = new[] { new { clientUpdateId = T.NewId(), blob = "" } } }, token);
        await api.Error(HttpMethod.Post, $"/docs/{doc}/updates", 400, "invalid_request", "{\"notebookId\":", token);

        // A failed request leaves nothing behind, even when its first update was fine.
        await api.Error(HttpMethod.Post, $"/docs/{doc}/updates", 400, "invalid_request",
            new { notebookId = notebook, updates = new[] { T.Update(T.Blob()), new { clientUpdateId = T.NewId(), blob = "!!!!" } } }, token);
        Assert.Equal(3, (await api.GetJson("/events", token)).GetProperty("head").GetInt64());
    }

    [Fact]
    public async Task Blobs_over_8_MiB_are_rejected_with_413()
    {
        var (app, api, token, _) = await Start();
        using var _ = app;
        var notebook = await T.Notebook(api, token);
        var doc = T.NewId();
        const int limit = 8 * 1024 * 1024;

        await api.Error(HttpMethod.Post, $"/docs/{doc}/updates", 413, "blob_too_large",
            new { notebookId = notebook, updates = new[] { T.Update(new byte[limit + 1]) } }, token);
        Assert.Equal(0, (await api.GetJson("/docs", token)).GetArrayLength());

        // Exactly at the limit is accepted and comes back intact.
        var big = T.Blob(limit);
        var seqs = await T.Push(api, token, doc, notebook, big);
        await api.Error(HttpMethod.Put, $"/docs/{doc}/snapshot", 413, "blob_too_large",
            new { coveredSeq = seqs[0], blob = T.B64(new byte[limit + 1]) }, token);
        var stored = Assert.Single(await T.AllEvents(api, token), e => Type(e) == "update");
        Assert.Equal(big, T.FromB64(stored.GetProperty("blob").GetString()!));
    }

    [Fact]
    public async Task Events_are_paged_in_seq_order_with_a_more_flag()
    {
        var (app, api, token, _) = await Start();
        using var _ = app;
        var notebook = await T.Notebook(api, token);                                     // seq 1
        await T.Push(api, token, T.NewId(), notebook, T.Blob(), T.Blob(), T.Blob(), T.Blob()); // seqs 2-5

        async Task Page(string query, long[] seqs, bool more)
        {
            var p = await api.GetJson("/events" + query, token);
            Assert.Equal(seqs, p.GetProperty("events").EnumerateArray().Select(Seq).ToArray());
            Assert.Equal(more, p.GetProperty("more").GetBoolean());
            Assert.Equal(5, p.GetProperty("head").GetInt64());
        }

        await Page("", [1, 2, 3, 4, 5], false);
        await Page("?limit=2", [1, 2], true);
        await Page("?after=2&limit=2", [3, 4], true);
        await Page("?after=4&limit=2", [5], false);
        await Page("?after=0&limit=5", [1, 2, 3, 4, 5], false); // exactly full is not "more"
        await Page("?after=5", [], false);
        await Page("?after=999", [], false);
        await Page("?limit=100000", [1, 2, 3, 4, 5], false);    // clamped, not refused

        Assert.Equal([1L, 2L, 3L, 4L, 5L], (await T.AllEvents(api, token, limit: 2)).Select(Seq));

        await api.Error(HttpMethod.Get, "/events?limit=0", 400, "invalid_request", token: token);
        await api.Error(HttpMethod.Get, "/events?after=-1", 400, "invalid_request", token: token);
        await api.Error(HttpMethod.Get, "/events?after=abc", 400, "invalid_request", token: token);
    }

    [Fact]
    public async Task Events_limit_defaults_to_500_and_is_capped_at_2000()
    {
        var (app, api, token, _) = await Start();
        using var _ = app;
        var notebook = await T.Notebook(api, token); // seq 1
        var doc = T.NewId();
        for (var batch = 0; batch < 3; batch++)
            await api.PostJson($"/docs/{doc}/updates",
                new { notebookId = notebook, updates = Enumerable.Range(0, 700).Select(_ => T.Update(T.Blob(4))).ToArray() }, token);

        var byDefault = await api.GetJson("/events", token);
        Assert.Equal(500, byDefault.GetProperty("events").GetArrayLength());
        Assert.True(byDefault.GetProperty("more").GetBoolean());
        Assert.Equal(2101, byDefault.GetProperty("head").GetInt64());

        var capped = await api.GetJson("/events?limit=5000", token);
        Assert.Equal(2000, capped.GetProperty("events").GetArrayLength());
        Assert.True(capped.GetProperty("more").GetBoolean());

        var rest = await api.GetJson("/events?after=2000&limit=2000", token);
        Assert.Equal(101, rest.GetProperty("events").GetArrayLength());
        Assert.False(rest.GetProperty("more").GetBoolean());
    }

    [Fact]
    public async Task Events_pages_are_cut_short_by_the_byte_budget_but_never_empty()
    {
        var (app, api, token, _) = await Start(o => o.EventsPageByteBudget = 100);
        using var _ = app;
        var notebook = await T.Notebook(api, token);
        await T.Push(api, token, T.NewId(), notebook, T.Blob(60), T.Blob(60), T.Blob(500), T.Blob(10));

        var page = await api.GetJson("/events", token);
        Assert.Equal([1L, 2L], page.GetProperty("events").EnumerateArray().Select(Seq)); // 60 + 60 would exceed 100
        Assert.True(page.GetProperty("more").GetBoolean());

        Assert.Equal([1L, 2L, 3L, 4L, 5L], (await T.AllEvents(api, token)).Select(Seq));  // the 500-byte one still arrives
    }

    [Fact]
    public async Task Snapshot_compacts_covered_updates_and_appends_a_snapshot_event()
    {
        var (app, api, token, _) = await Start();
        using var _ = app;
        var notebook = await T.Notebook(api, token);                                  // 1
        var docA = T.NewId();
        var docB = T.NewId();
        var idA1 = T.NewId();
        await api.PostJson($"/docs/{docA}/updates", new { notebookId = notebook, updates = new[] { T.Update(T.Blob(), idA1) } }, token); // 2
        await T.Push(api, token, docA, notebook, T.Blob());                           // 3
        await T.Push(api, token, docB, notebook, T.Blob());                           // 4
        var late = T.Blob();
        await T.Push(api, token, docA, notebook, late);                               // 5

        await api.Error(HttpMethod.Get, $"/docs/{docA}/snapshot", 404, "no_snapshot", token: token);

        var snapshot = T.Blob(200);
        var put = await api.PutJson($"/docs/{docA}/snapshot", new { coveredSeq = 4, blob = T.B64(snapshot) }, token);
        Assert.Equal(6, put.GetProperty("seq").GetInt64());
        Assert.Equal(6, put.GetProperty("head").GetInt64());

        var got = await api.GetJson($"/docs/{docA}/snapshot", token);
        Assert.Equal(["blob", "coveredSeq"], T.Names(got));
        Assert.Equal(4, got.GetProperty("coveredSeq").GetInt64());
        Assert.Equal(T.B64(snapshot), got.GetProperty("blob").GetString());

        // docA's updates at seq <= 4 are gone; its later update and docB's update stay.
        var events = await T.AllEvents(api, token);
        Assert.Equal([1L, 4L, 5L, 6L], events.Select(Seq));
        Assert.Equal(docB, events[1].GetProperty("docId").GetString());
        Assert.Equal(T.B64(late), events[2].GetProperty("blob").GetString());
        var marker = events[3];
        Assert.Equal(["coveredSeq", "docId", "notebookId", "seq", "type"], T.Names(marker));
        Assert.Equal("snapshot", Type(marker));
        Assert.Equal(docA, marker.GetProperty("docId").GetString());
        Assert.Equal(notebook, marker.GetProperty("notebookId").GetString());
        Assert.Equal(4, marker.GetProperty("coveredSeq").GetInt64());

        var docs = (await api.GetJson("/docs", token)).EnumerateArray().ToDictionary(d => d.GetProperty("docId").GetString()!, d => d.GetProperty("snapshotSeq").GetInt64());
        Assert.Equal(4, docs[docA]);
        Assert.Equal(0, docs[docB]);

        // A snapshot that covers less than the stored one is refused.
        await api.Error(HttpMethod.Put, $"/docs/{docA}/snapshot", 409, "stale_snapshot", new { coveredSeq = 3, blob = T.B64(T.Blob()) }, token);
        Assert.Equal(T.B64(snapshot), (await api.GetJson($"/docs/{docA}/snapshot", token)).GetProperty("blob").GetString());

        // A later one replaces it, removes the remaining covered update and the old marker.
        var snapshot2 = T.Blob(210);
        var put2 = await api.PutJson($"/docs/{docA}/snapshot", new { coveredSeq = 6, blob = T.B64(snapshot2) }, token);
        Assert.Equal(7, put2.GetProperty("seq").GetInt64());
        events = await T.AllEvents(api, token);
        Assert.Equal([1L, 4L, 7L], events.Select(Seq));
        Assert.Equal(6, events[2].GetProperty("coveredSeq").GetInt64());
        Assert.Equal(T.B64(snapshot2), (await api.GetJson($"/docs/{docA}/snapshot", token)).GetProperty("blob").GetString());

        // A repeat of an update that was compacted away still returns its original seq.
        var repeat = await api.PostJson($"/docs/{docA}/updates", new { notebookId = notebook, updates = new[] { T.Update(T.Blob(), idA1) } }, token);
        Assert.Equal([2L], repeat.GetProperty("seqs").EnumerateArray().Select(s => s.GetInt64()));
        Assert.Equal(7, repeat.GetProperty("head").GetInt64());

        // New updates continue after the marker.
        Assert.Equal(new long[] { 8L }, await T.Push(api, token, docA, notebook, T.Blob()));

        // Validation.
        await api.Error(HttpMethod.Put, $"/docs/{T.NewId()}/snapshot", 404, "unknown_doc", new { coveredSeq = 1, blob = T.B64(T.Blob()) }, token);
        await api.Error(HttpMethod.Get, $"/docs/{T.NewId()}/snapshot", 404, "no_snapshot", token: token);
        await api.Error(HttpMethod.Put, $"/docs/{docA}/snapshot", 400, "invalid_request", new { coveredSeq = 9999, blob = T.B64(T.Blob()) }, token);
        await api.Error(HttpMethod.Put, $"/docs/{docA}/snapshot", 400, "invalid_request", new { coveredSeq = 0, blob = T.B64(T.Blob()) }, token);
        await api.Error(HttpMethod.Put, $"/docs/{docA}/snapshot", 400, "invalid_request", new { blob = T.B64(T.Blob()) }, token);
        await api.Error(HttpMethod.Put, $"/docs/{docA}/snapshot", 400, "invalid_request", new { coveredSeq = 8 }, token);
    }

    [Fact]
    public async Task Deleting_a_document_removes_it_and_appends_docDeleted()
    {
        var (app, api, token, _) = await Start();
        using var _ = app;
        var notebook = await T.Notebook(api, token);                 // 1
        var doc = T.NewId();
        var keep = T.NewId();
        await T.Push(api, token, doc, notebook, T.Blob(), T.Blob()); // 2, 3
        await T.Push(api, token, keep, notebook, T.Blob());          // 4
        await api.PutJson($"/docs/{doc}/snapshot", new { coveredSeq = 2, blob = T.B64(T.Blob()) }, token); // 5

        Assert.Equal(6, (await api.DeleteJson($"/docs/{doc}", token)).GetProperty("head").GetInt64());

        Assert.Equal(keep, Assert.Single((await api.GetJson("/docs", token)).EnumerateArray()).GetProperty("docId").GetString());
        await api.Error(HttpMethod.Get, $"/docs/{doc}/snapshot", 404, "no_snapshot", token: token);
        await api.Error(HttpMethod.Delete, $"/docs/{doc}", 404, "unknown_doc", token: token);

        var events = await T.AllEvents(api, token);
        Assert.Equal([1L, 4L, 6L], events.Select(Seq));
        var deleted = events[2];
        Assert.Equal(["docId", "notebookId", "seq", "type"], T.Names(deleted));
        Assert.Equal("docDeleted", Type(deleted));
        Assert.Equal(doc, deleted.GetProperty("docId").GetString());
        Assert.Equal(notebook, deleted.GetProperty("notebookId").GetString());
    }

    [Fact]
    public async Task A_push_to_a_deleted_document_is_refused_with_410_and_never_recreates_it()
    {
        var dir = TestApp.NewDataDir();
        try
        {
            var doc = T.NewId();
            var other = T.NewId();
            var knownUpdate = T.NewId();
            string token, notebook;
            using (var app = new TestApp(dir))
            {
                var api = app.Api;
                (_, token) = await new TestAccount().Register(api);
                notebook = await T.Notebook(api, token);                                 // 1
                await api.PostJson($"/docs/{doc}/updates",
                    new { notebookId = notebook, updates = new[] { T.Update(T.Blob(), knownUpdate) } }, token); // 2
                await api.DeleteJson($"/docs/{doc}", token);                             // 3

                // New updates and a retry of an already acknowledged one are both refused.
                await api.Error(HttpMethod.Post, $"/docs/{doc}/updates", 410, "doc_deleted",
                    new { notebookId = notebook, updates = new[] { T.Update(T.Blob()) } }, token);
                await api.Error(HttpMethod.Post, $"/docs/{doc}/updates", 410, "doc_deleted",
                    new { notebookId = notebook, updates = new[] { T.Update(T.Blob(), knownUpdate) } }, token);

                // Nothing was created and nothing was appended.
                Assert.Equal(0, (await api.GetJson("/docs", token)).GetArrayLength());
                Assert.Equal([1L, 3L], (await T.AllEvents(api, token)).Select(Seq));
                await api.Error(HttpMethod.Put, $"/docs/{doc}/snapshot", 404, "unknown_doc", new { coveredSeq = 3, blob = T.B64(T.Blob()) }, token);
                await api.Error(HttpMethod.Delete, $"/docs/{doc}", 404, "unknown_doc", token: token);

                // Other documents of the notebook are unaffected.
                Assert.Equal(new long[] { 4L }, await T.Push(api, token, other, notebook, T.Blob()));
            }

            // The tombstone is persistent.
            using (var app = new TestApp(dir))
            {
                await app.Api.Error(HttpMethod.Post, $"/docs/{doc}/updates", 410, "doc_deleted",
                    new { notebookId = notebook, updates = new[] { T.Update(T.Blob()) } }, token);
                Assert.Equal(new long[] { 5L }, await T.Push(app.Api, token, other, notebook, T.Blob()));

                // Once the notebook itself is gone the answer is unknown_notebook.
                await app.Api.DeleteJson($"/notebooks/{notebook}", token);
                await app.Api.Error(HttpMethod.Post, $"/docs/{doc}/updates", 404, "unknown_notebook",
                    new { notebookId = notebook, updates = new[] { T.Update(T.Blob()) } }, token);
            }
        }
        finally
        {
            TestApp.DeleteDataDir(dir);
        }
    }

    [Fact]
    public async Task A_version_1_database_is_migrated_and_gains_tombstones()
    {
        var dir = TestApp.NewDataDir();
        try
        {
            string token, notebook;
            var doc = T.NewId();
            using (var app = new TestApp(dir))
            {
                (_, token) = await new TestAccount().Register(app.Api);
                notebook = await T.Notebook(app.Api, token);
                await T.Push(app.Api, token, doc, notebook, T.Blob());
            }

            // Wind the file back to what a v1 server left behind.
            Microsoft.Data.Sqlite.SqliteConnection.ClearAllPools();
            await using (var db = new Microsoft.Data.Sqlite.SqliteConnection($"Data Source={Path.Combine(dir, "twonote.db")};Pooling=False"))
            {
                db.Open();
                await using var cmd = db.CreateCommand();
                cmd.CommandText = "DROP TABLE deleted_docs; UPDATE schema_version SET version = 1";
                cmd.ExecuteNonQuery();
            }

            using (var app = new TestApp(dir))
            {
                Assert.Equal(2, (await T.AllEvents(app.Api, token)).Count);
                await app.Api.DeleteJson($"/docs/{doc}", token);
                await app.Api.Error(HttpMethod.Post, $"/docs/{doc}/updates", 410, "doc_deleted",
                    new { notebookId = notebook, updates = new[] { T.Update(T.Blob()) } }, token);
            }
        }
        finally
        {
            TestApp.DeleteDataDir(dir);
        }
    }

    [Fact]
    public async Task Deleting_a_notebook_removes_its_documents_and_their_events()
    {
        var (app, api, token, _) = await Start();
        using var _ = app;
        var doomed = await T.Notebook(api, token);                     // 1
        var kept = await T.Notebook(api, token);                       // 2
        var doomedDoc = T.NewId();
        var keptDoc = T.NewId();
        await T.Push(api, token, doomedDoc, doomed, T.Blob(), T.Blob()); // 3, 4
        await T.Push(api, token, keptDoc, kept, T.Blob());               // 5
        await api.PutJson($"/docs/{doomedDoc}/snapshot", new { coveredSeq = 3, blob = T.B64(T.Blob()) }, token); // 6

        Assert.Equal(7, (await api.DeleteJson($"/notebooks/{doomed}", token)).GetProperty("head").GetInt64());

        Assert.Equal(kept, Assert.Single((await api.GetJson("/notebooks", token)).EnumerateArray()).GetProperty("notebookId").GetString());
        Assert.Equal(keptDoc, Assert.Single((await api.GetJson("/docs", token)).EnumerateArray()).GetProperty("docId").GetString());
        await api.Error(HttpMethod.Get, $"/docs/{doomedDoc}/snapshot", 404, "no_snapshot", token: token);

        var events = await T.AllEvents(api, token);
        Assert.Equal([1L, 2L, 5L, 7L], events.Select(Seq));
        Assert.Equal(["notebooksChanged", "notebooksChanged", "update", "notebooksChanged"], events.Select(Type));

        // The notebook is really gone: pushing to it is refused.
        await api.Error(HttpMethod.Post, $"/docs/{doomedDoc}/updates", 404, "unknown_notebook",
            new { notebookId = doomed, updates = new[] { T.Update(T.Blob()) } }, token);
    }
}

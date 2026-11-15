using Microsoft.Data.Sqlite;
using TwoNote.Core.Storage;
using Xunit;
using KdfParams = TwoNote.Core.Crypto.KdfParams;

namespace TwoNote.Core.Tests;

public sealed class LocalStoreTests : IDisposable
{
    private readonly string _dir = Path.Combine(Path.GetTempPath(), "twonote-core-tests", "store-" + Guid.NewGuid().ToString("N"));
    private readonly string _path;

    public LocalStoreTests()
    {
        _path = Path.Combine(_dir, "sub", "local.db"); // the directory is created on demand
    }

    public void Dispose()
    {
        SqliteConnection.ClearAllPools();
        try
        {
            Directory.Delete(_dir, recursive: true);
        }
        catch (IOException)
        {
        }
    }

    private static byte[] Blob(int seed, int length = 60)
    {
        var blob = new byte[length];
        new Random(seed).NextBytes(blob);
        return blob;
    }

    [Fact]
    public void A_new_store_is_empty_and_everything_survives_reopening()
    {
        var nb = Docs.NewId();
        var doc = Docs.NewId();
        var account = new AccountRecord("bob", Docs.NewId(), Docs.NewId(), "laptop", Blob(1, 16), KdfParams.Default, Blob(2, 73));
        using (var store = LocalStore.Open(_path))
        {
            Assert.Null(store.GetAccount());
            Assert.Equal(0, store.Cursor);
            Assert.False(store.FirstSyncDone);
            Assert.Empty(store.GetNotebooks());
            Assert.Empty(store.GetDocs());
            Assert.Equal(0, store.OutboxCount);
            Assert.Null(store.LoadDoc(doc));

            store.SaveAccount(account);
            store.AddLocalNotebook(nb, Blob(3, 73));
            store.AppendLocalUpdate(doc, nb, Docs.NewId(), Blob(4));
            store.Apply(b =>
            {
                b.AddRemoteUpdate(doc, nb, 7, Blob(5));
                b.SetCursor(7);
                b.SetFirstSyncDone();
            });
        }

        using (var store = LocalStore.Open(_path))
        {
            var loaded = store.GetAccount()!;
            Assert.Equal(account with { KdfSalt = loaded.KdfSalt, WrappedVaultKey = loaded.WrappedVaultKey }, loaded);
            Assert.Equal(account.KdfSalt, loaded.KdfSalt);
            Assert.Equal(account.WrappedVaultKey, loaded.WrappedVaultKey);
            Assert.Equal(7, store.Cursor);
            Assert.True(store.FirstSyncDone);
            var notebook = Assert.Single(store.GetNotebooks());
            Assert.Equal((nb, true), (notebook.NotebookId, notebook.PendingPut));
            Assert.Equal(1, store.OutboxCount);
            var content = store.LoadDoc(doc)!;
            Assert.Equal(nb, content.NotebookId);
            Assert.Null(content.SnapshotBlob);
            Assert.Equal([Blob(4), Blob(5)], content.UpdateBlobs); // arrival order
        }

        // A file written by a newer version is refused rather than misread.
        using (var db = new SqliteConnection($"Data Source={_path};Pooling=False"))
        {
            db.Open();
            using var cmd = db.CreateCommand();
            cmd.CommandText = "PRAGMA user_version = 99";
            cmd.ExecuteNonQuery();
        }

        Assert.Throws<InvalidOperationException>(() => LocalStore.Open(_path));
    }

    [Fact]
    public void The_outbox_hands_out_edits_in_the_order_they_were_made_one_document_at_a_time()
    {
        using var store = LocalStore.Open(_path);
        var nb = Docs.NewId();
        var (x, y) = (Docs.NewId(), Docs.NewId());
        var ids = new List<long>
        {
            store.AppendLocalUpdate(x, nb, Docs.NewId(), Blob(1)),
            store.AppendLocalUpdate(x, nb, Docs.NewId(), Blob(2)),
            store.AppendLocalUpdate(y, nb, Docs.NewId(), Blob(3)),
            store.AppendLocalUpdate(x, nb, Docs.NewId(), Blob(4)),
        };
        Assert.Equal(ids.Order(), ids);

        // x, x - then y must go before the last x.
        var first = store.PeekOutbox(10, long.MaxValue);
        Assert.Equal([ids[0], ids[1]], first.Select(e => e.LocalId));
        Assert.All(first, e => Assert.Equal((x, nb), (e.DocId, e.NotebookId)));
        Assert.Equal(first.Select(e => e.LocalId), store.PeekOutbox(10, long.MaxValue).Select(e => e.LocalId)); // peeking removes nothing

        // Count and byte limits cut the batch but never below one entry.
        Assert.Single(store.PeekOutbox(1, long.MaxValue));
        Assert.Single(store.PeekOutbox(10, 100));
        Assert.Single(store.PeekOutbox(10, 1));

        store.AcknowledgeOutbox([(ids[0], 11), (ids[1], 12)]);
        Assert.Equal(2, store.OutboxCount);
        Assert.Equal([ids[2]], store.PeekOutbox(10, long.MaxValue).Select(e => e.LocalId));
        store.AcknowledgeOutbox([(ids[2], 13)]);
        Assert.Equal([ids[3]], store.PeekOutbox(10, long.MaxValue).Select(e => e.LocalId));
        store.AcknowledgeOutbox([(ids[3], 14)]);
        Assert.Equal(0, store.OutboxCount);
        Assert.Empty(store.PeekOutbox(10, long.MaxValue));

        // Acknowledged updates stay part of the document.
        Assert.Equal(3, store.LoadDoc(x)!.UpdateBlobs.Count);

        // An acknowledgement for a seq that is already stored (the update also came in through
        // /events) removes the duplicate instead of failing.
        var again = store.AppendLocalUpdate(y, nb, Docs.NewId(), Blob(3));
        store.Apply(b => b.AddRemoteUpdate(y, nb, 20, Blob(3)));
        store.AcknowledgeOutbox([(again, 20)]);
        Assert.Equal(0, store.OutboxCount);
        Assert.Equal(2, store.LoadDoc(y)!.UpdateBlobs.Count);
    }

    [Fact]
    public void A_batch_is_all_or_nothing_including_the_cursor()
    {
        using var store = LocalStore.Open(_path);
        var nb = Docs.NewId();
        var doc = Docs.NewId();
        store.Apply(b =>
        {
            b.AddRemoteUpdate(doc, nb, 1, Blob(1));
            b.SetCursor(1);
        });

        Assert.Throws<InvalidOperationException>(() => store.Apply(b =>
        {
            b.AddRemoteUpdate(doc, nb, 2, Blob(2));
            b.AddRemoteUpdate(Docs.NewId(), nb, 3, Blob(3));
            b.SetCursor(3);
            throw new InvalidOperationException("crash in the middle of applying a page");
        }));

        Assert.Equal(1, store.Cursor);
        Assert.Single(store.GetDocs());
        Assert.Single(store.LoadDoc(doc)!.UpdateBlobs);

        // The same events again (as after a restart) apply cleanly, and a repeat is harmless.
        for (var i = 0; i < 2; i++)
        {
            store.Apply(b =>
            {
                b.AddRemoteUpdate(doc, nb, 2, Blob(2));
                b.SetCursor(2);
            });
        }

        Assert.Equal(2, store.Cursor);
        Assert.Equal(2, store.LoadDoc(doc)!.UpdateBlobs.Count);

        // The cursor never moves backwards.
        store.Apply(b => b.SetCursor(1));
        Assert.Equal(2, store.Cursor);
    }

    [Fact]
    public void A_snapshot_replaces_the_acknowledged_updates_it_covers_and_nothing_else()
    {
        using var store = LocalStore.Open(_path);
        var nb = Docs.NewId();
        var doc = Docs.NewId();
        var other = Docs.NewId();
        store.Apply(b =>
        {
            b.AddRemoteUpdate(doc, nb, 1, Blob(1));
            b.AddRemoteUpdate(other, nb, 2, Blob(2));
            b.AddRemoteUpdate(doc, nb, 3, Blob(3));
            b.AddRemoteUpdate(doc, nb, 5, Blob(5));
        });
        store.AppendLocalUpdate(doc, nb, Docs.NewId(), Blob(9));

        store.Apply(b => b.SetSnapshot(doc, nb, 3, Blob(100, 500)));
        var content = store.LoadDoc(doc)!;
        Assert.Equal(3, content.SnapshotSeq);
        Assert.Equal(Blob(100, 500), content.SnapshotBlob);
        Assert.Equal([Blob(5), Blob(9)], content.UpdateBlobs); // the later update and the outbox entry stay
        Assert.Equal(1, store.OutboxCount);
        Assert.Single(store.LoadDoc(other)!.UpdateBlobs);

        // An older snapshot never replaces a newer one; an equal or newer one does.
        store.Apply(b =>
        {
            b.SetSnapshot(doc, nb, 2, Blob(101));
            Assert.Equal(3, b.GetSnapshotSeq(doc));
            Assert.Null(b.GetSnapshotSeq(Docs.NewId()));
        });
        Assert.Equal(Blob(100, 500), store.LoadDoc(doc)!.SnapshotBlob);
        store.Apply(b => b.SetSnapshot(doc, nb, 6, Blob(102)));
        Assert.Equal([Blob(9)], store.LoadDoc(doc)!.UpdateBlobs);

        // A snapshot can also be the first thing known about a document (first sync).
        var fresh = Docs.NewId();
        store.Apply(b => b.SetSnapshot(fresh, nb, 4, Blob(103)));
        Assert.Equal(4, store.GetDoc(fresh)!.SnapshotSeq);

        store.Apply(b => b.DropDoc(doc));
        Assert.Null(store.LoadDoc(doc));
        Assert.Equal(0, store.OutboxCount);
    }

    [Fact]
    public void Compaction_candidates_count_acknowledged_updates_only_and_skip_damaged_documents()
    {
        using var store = LocalStore.Open(_path);
        var nb = Docs.NewId();
        var (busy, quiet, damaged, unsent) = (Docs.NewId(), Docs.NewId(), Docs.NewId(), Docs.NewId());
        store.Apply(b =>
        {
            for (var i = 1; i <= 5; i++)
            {
                b.AddRemoteUpdate(busy, nb, i, Blob(i));
                b.AddRemoteUpdate(damaged, nb, 100 + i, Blob(i));
            }

            b.AddRemoteUpdate(quiet, nb, 50, Blob(50));
            b.MarkDamaged(damaged, nb);
        });
        for (var i = 0; i < 5; i++)
        {
            store.AppendLocalUpdate(unsent, nb, Docs.NewId(), Blob(i));
        }

        Assert.Equal([busy], store.GetDocsToCompact(4).Select(d => d.DocId));
        Assert.Empty(store.GetDocsToCompact(5)); // "more than", not "at least"
        Assert.True(store.GetDoc(damaged)!.Damaged);
        Assert.False(store.GetDoc(busy)!.Damaged);
    }

    [Fact]
    public void Replacing_the_notebook_list_removes_vanished_notebooks_but_keeps_unpushed_local_ones()
    {
        using var store = LocalStore.Open(_path);
        var (kept, gone, local, added) = (Docs.NewId(), Docs.NewId(), Docs.NewId(), Docs.NewId());
        var (keptDoc, goneDoc, localDoc) = (Docs.NewId(), Docs.NewId(), Docs.NewId());
        store.Apply(b =>
        {
            b.ReplaceServerNotebooks([(kept, Blob(1)), (gone, Blob(2))]);
            b.AddRemoteUpdate(keptDoc, kept, 1, Blob(3));
            b.AddRemoteUpdate(goneDoc, gone, 2, Blob(4));
        });
        store.AddLocalNotebook(local, Blob(5));
        store.AppendLocalUpdate(localDoc, local, Docs.NewId(), Blob(6));
        store.AppendLocalUpdate(goneDoc, gone, Docs.NewId(), Blob(7));
        Assert.Equal([local], store.GetPendingNotebooks().Select(n => n.NotebookId));

        IReadOnlyList<(string NotebookId, IReadOnlyList<string> DocIds)> removed = [];
        store.Apply(b => removed = b.ReplaceServerNotebooks([(kept, Blob(8)), (added, Blob(9))]));

        var (removedNotebook, removedDocs) = Assert.Single(removed);
        Assert.Equal(gone, removedNotebook);
        Assert.Equal([goneDoc], removedDocs);
        Assert.Equal(new[] { kept, local, added }.Order(StringComparer.Ordinal), store.GetNotebooks().Select(n => n.NotebookId));
        Assert.Equal(Blob(8), store.GetNotebooks().Single(n => n.NotebookId == kept).WrappedKey); // replaced key
        Assert.Null(store.LoadDoc(goneDoc));
        Assert.Equal(1, store.OutboxCount); // the edit to the vanished notebook went with it
        Assert.NotNull(store.LoadDoc(keptDoc));
        Assert.NotNull(store.LoadDoc(localDoc));

        // Once pushed, the local notebook is an ordinary one: if the server drops it, so do we.
        store.MarkNotebookPushed(local);
        Assert.Empty(store.GetPendingNotebooks());
        store.Apply(b => b.ReplaceServerNotebooks([(kept, Blob(8))]));
        Assert.Equal([kept], store.GetNotebooks().Select(n => n.NotebookId));
        Assert.Equal(0, store.OutboxCount);
    }

    [Fact]
    public void A_closed_store_refuses_work()
    {
        var store = LocalStore.Open(_path);
        store.Dispose();
        store.Dispose();
        Assert.Throws<ObjectDisposedException>(() => store.Cursor);
        Assert.Throws<ObjectDisposedException>(() => store.Apply(_ => { }));
    }
}

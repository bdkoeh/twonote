using TwoNote.Core.Crypto;
using TwoNote.Core.Documents;
using TwoNote.Core.Storage;

namespace TwoNote.Core.Sync;

/// <summary>
/// What exists only while the account is unlocked: the vault key, the notebook keys, and the
/// documents that are open in memory. Bridges documents to the local store: every local edit
/// is sealed and written to the outbox before the editing call returns.
/// </summary>
internal sealed class Vault : IDisposable
{
    private readonly LocalStore _store;
    private readonly SecretBytes _vaultKey;
    private readonly Dictionary<string, SecretBytes> _keys = [];
    private readonly Dictionary<string, CrdtDocument> _live = [];
    private readonly Action<SyncIssue> _report;
    private readonly Action _localChange;
    private readonly Func<Action, Task>? _dispatcher;
    private readonly int _undoCaptureMilliseconds;
    private bool _disposed;

    public Vault(
        LocalStore store, SecretBytes vaultKey, Action<SyncIssue> report, Action localChange,
        Func<Action, Task>? dispatcher, int undoCaptureMilliseconds)
    {
        _store = store;
        _vaultKey = vaultKey;
        _report = report;
        _localChange = localChange;
        _dispatcher = dispatcher;
        _undoCaptureMilliseconds = undoCaptureMilliseconds;
        foreach (var notebook in store.GetNotebooks())
        {
            AddKey(notebook.NotebookId, notebook.WrappedKey);
        }
    }

    /// <summary>
    /// Guards the pairing of "what is in the store" with "which documents are open": a document
    /// is loaded and registered under it, and the sync engine commits a batch and picks the open
    /// documents to update under it, so an update can never fall between the two.
    /// </summary>
    public object Gate { get; } = new();

    public SecretBytes VaultKey => _vaultKey;

    public IReadOnlyList<string> NotebookIds
    {
        get
        {
            lock (Gate)
            {
                return [.. _keys.Keys.Order(StringComparer.Ordinal)];
            }
        }
    }

    public bool HasKey(string notebookId)
    {
        lock (Gate)
        {
            return _keys.ContainsKey(notebookId);
        }
    }

    /// <summary>Unwraps and remembers the keys of the given notebooks. A key that does not open is reported and skipped.</summary>
    public void AddKeys(IEnumerable<(string NotebookId, byte[] WrappedKey)> notebooks)
    {
        foreach (var (id, wrappedKey) in notebooks)
        {
            AddKey(id, wrappedKey);
        }
    }

    public void RemoveKey(string notebookId)
    {
        lock (Gate)
        {
            if (_keys.Remove(notebookId, out var key))
            {
                key.Dispose();
            }
        }
    }

    /// <summary>Opens a blob of this notebook; null when there is no key or the blob does not authenticate.</summary>
    public byte[]? TryOpen(string notebookId, BlobKind kind, string docId, byte[] blob)
    {
        lock (Gate)
        {
            if (_disposed || !_keys.TryGetValue(notebookId, out var key) || !WireEncoding.TryIdFromHex(docId, out var id))
            {
                return null;
            }

            return SealedBlob.TryOpen(key.Span, kind, id, blob, out var plaintext) ? plaintext : null;
        }
    }

    public byte[] Seal(string notebookId, BlobKind kind, string docId, byte[] plaintext)
    {
        lock (Gate)
        {
            ObjectDisposedException.ThrowIf(_disposed, this);
            if (!_keys.TryGetValue(notebookId, out var key))
            {
                throw new InvalidOperationException("The notebook key is not available.");
            }

            return SealedBlob.Seal(key.Span, kind, WireEncoding.IdFromHex(docId), plaintext);
        }
    }

    // ---- documents ------------------------------------------------------------------------

    public NotebookTree CreateNotebook(string title)
    {
        var idBytes = WireEncoding.NewId();
        var id = WireEncoding.IdToHex(idBytes);
        lock (Gate)
        {
            ObjectDisposedException.ThrowIf(_disposed, this);
            var key = KeyHierarchy.CreateNotebookKey();
            _store.AddLocalNotebook(id, KeyHierarchy.WrapNotebookKey(_vaultKey.Span, idBytes, key.Span));
            _keys[id] = key;
            var tree = new NotebookTree(id);
            Register(tree, id);
            tree.Initialize(title);
            return tree;
        }
    }

    public NotebookTree OpenNotebook(string notebookId) =>
        (NotebookTree)Open(notebookId, notebookId, () => new NotebookTree(notebookId));

    public PageDocument CreatePage(string notebookId, string pageId)
    {
        lock (Gate)
        {
            RequireKey(notebookId);
            if (_live.ContainsKey(pageId) || _store.GetDoc(pageId) is not null)
            {
                throw new InvalidOperationException("The page already exists.");
            }

            var page = new PageDocument(pageId, _undoCaptureMilliseconds);
            Register(page, notebookId);
            page.Initialize();
            return page;
        }
    }

    public PageDocument OpenPage(string notebookId, string pageId) =>
        (PageDocument)Open(pageId, notebookId, () => new PageDocument(pageId, _undoCaptureMilliseconds));

    public void Close(string docId)
    {
        CrdtDocument? doc;
        lock (Gate)
        {
            _live.Remove(docId, out doc);
        }

        doc?.Dispose();
    }

    /// <summary>The open document with this id, if any. Call under <see cref="Gate"/> to pair it with a store commit.</summary>
    public CrdtDocument? Live(string docId)
    {
        lock (Gate)
        {
            return _live.GetValueOrDefault(docId);
        }
    }

    /// <summary>Takes the open documents with these ids out of the registry so they can be told they were deleted.</summary>
    public List<CrdtDocument> Detach(IEnumerable<string> docIds)
    {
        var list = new List<CrdtDocument>();
        lock (Gate)
        {
            foreach (var id in docIds)
            {
                if (_live.Remove(id, out var doc))
                {
                    list.Add(doc);
                }
            }
        }

        return list;
    }

    /// <summary>
    /// The full state of a document as one Yjs update, for a snapshot. Null when the document
    /// cannot be rebuilt completely (missing key, or a stored blob that does not open or apply).
    /// </summary>
    public byte[]? EncodeFullState(string docId, string notebookId)
    {
        CrdtDocument? open;
        lock (Gate)
        {
            if (_disposed)
            {
                return null;
            }

            if (!_live.TryGetValue(docId, out open))
            {
                // Not open: rebuild it in a scratch document. The concrete type does not matter for merging.
                using var scratch = new NotebookTree(docId);
                return Load(scratch, notebookId, report: false) ? scratch.EncodeState() : null;
            }
        }

        // Outside the gate: an edit in progress holds the document's lock and then wants the gate.
        try
        {
            return open.IsDeleted ? null : open.EncodeState();
        }
        catch (ObjectDisposedException)
        {
            return null;
        }
    }

    public Task DispatchAsync(Action action)
    {
        if (_dispatcher is not null)
        {
            return _dispatcher(action);
        }

        action();
        return Task.CompletedTask;
    }

    public void Dispose()
    {
        List<CrdtDocument> docs;
        lock (Gate)
        {
            if (_disposed)
            {
                return;
            }

            _disposed = true;
            docs = [.. _live.Values];
            _live.Clear();
            foreach (var key in _keys.Values)
            {
                key.Dispose();
            }

            _keys.Clear();
            _vaultKey.Dispose();
        }

        foreach (var doc in docs)
        {
            doc.Dispose();
        }
    }

    private void AddKey(string notebookId, byte[] wrappedKey)
    {
        if (!WireEncoding.TryIdFromHex(notebookId, out var id))
        {
            return;
        }

        lock (Gate)
        {
            if (_disposed)
            {
                return;
            }

            if (!KeyHierarchy.TryUnwrapNotebookKey(_vaultKey.Span, id, wrappedKey, out var key))
            {
                if (!_keys.ContainsKey(notebookId))
                {
                    _report(new SyncIssue(SyncIssueKind.NotebookKeyRejected, notebookId, null, null, "The notebook key did not open with this account's vault key."));
                }

                return;
            }

            if (_keys.Remove(notebookId, out var old))
            {
                old.Dispose();
            }

            _keys[notebookId] = key!;
        }
    }

    private void RequireKey(string notebookId)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        if (!_keys.ContainsKey(notebookId))
        {
            throw new KeyNotFoundException("No such notebook on this device.");
        }
    }

    private CrdtDocument Open(string docId, string notebookId, Func<CrdtDocument> create)
    {
        lock (Gate)
        {
            RequireKey(notebookId);
            if (_live.TryGetValue(docId, out var existing))
            {
                return existing;
            }

            var doc = create();
            try
            {
                if (!Load(doc, notebookId, report: true))
                {
                    // The local history has a hole, so this device must not snapshot the document.
                    _store.Apply(batch => batch.MarkDamaged(docId, notebookId));
                }
            }
            catch
            {
                doc.Dispose();
                throw;
            }

            Register(doc, notebookId);
            return doc;
        }
    }

    /// <summary>Fills a document from the store. Returns false if any stored blob had to be skipped.</summary>
    private bool Load(CrdtDocument doc, string notebookId, bool report)
    {
        var content = _store.LoadDoc(doc.DocId);
        if (content is null)
        {
            return true;
        }

        if (content.NotebookId != notebookId)
        {
            throw new InvalidOperationException("The document belongs to a different notebook.");
        }

        var complete = true;
        void Merge(BlobKind kind, byte[] blob)
        {
            var plaintext = TryOpen(notebookId, kind, doc.DocId, blob);
            if (plaintext is not null && doc.ApplyUpdate(plaintext))
            {
                return;
            }

            complete = false;
            if (report)
            {
                _report(new SyncIssue(
                    plaintext is null ? SyncIssueKind.BlobRejected : SyncIssueKind.UpdateRejected, notebookId, doc.DocId, null,
                    "A stored blob could not be used and was skipped."));
            }
        }

        if (content.SnapshotBlob is not null)
        {
            Merge(BlobKind.Snapshot, content.SnapshotBlob);
        }

        foreach (var blob in content.UpdateBlobs)
        {
            Merge(BlobKind.Update, blob);
        }

        return complete;
    }

    private void Register(CrdtDocument doc, string notebookId)
    {
        doc.LocalUpdate += update =>
        {
            // Runs inside the editing call, under the document's lock: when Edit returns, the
            // sealed update is in the outbox.
            if (doc.IsDeleted)
            {
                return;
            }

            byte[] blob;
            lock (Gate)
            {
                if (_disposed || !_keys.ContainsKey(notebookId))
                {
                    return;
                }

                blob = Seal(notebookId, BlobKind.Update, doc.DocId, update);
            }

            _store.AppendLocalUpdate(doc.DocId, notebookId, WireEncoding.IdToHex(WireEncoding.NewId()), blob);
            _localChange();
        };
        _live[doc.DocId] = doc;
    }
}

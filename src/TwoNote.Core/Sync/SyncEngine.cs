using TwoNote.Core.Api;
using TwoNote.Core.Crypto;
using TwoNote.Core.Documents;
using TwoNote.Core.Storage;

namespace TwoNote.Core.Sync;

/// <summary>How the last sync attempt ended.</summary>
public enum SyncState
{
    /// <summary>Nothing has failed; the device is waiting for something to do.</summary>
    Idle,

    /// <summary>A sync cycle is running.</summary>
    Syncing,

    /// <summary>The server could not be reached. Edits keep queueing locally.</summary>
    Offline,

    /// <summary>The server refused the session token (revoked, or the password was changed elsewhere). Call <see cref="TwoNoteClient.SignInAgainAsync"/>.</summary>
    AuthRequired,

    /// <summary>The last cycle failed for another reason; see <see cref="SyncStatus.LastError"/>.</summary>
    Error,
}

/// <summary>A snapshot of the sync engine for the UI.</summary>
/// <param name="State">How the last attempt ended.</param>
/// <param name="Running">True while the background loop is started.</param>
/// <param name="Cursor">Seq of the last server event this device has applied.</param>
/// <param name="Head">Highest server seq this device has heard of.</param>
/// <param name="PendingUpdates">Local edits not yet acknowledged by the server.</param>
/// <param name="WebSocketConnected">True while the head listener socket is open.</param>
/// <param name="LastSyncedAt">When a cycle last completed.</param>
/// <param name="LastError">Human-readable reason for <see cref="SyncState.Error"/> (never contains secrets or content).</param>
public sealed record SyncStatus(
    SyncState State, bool Running, long Cursor, long Head, int PendingUpdates, bool WebSocketConnected,
    DateTimeOffset? LastSyncedAt, string? LastError);

/// <summary>What kind of problem a <see cref="SyncIssue"/> describes.</summary>
public enum SyncIssueKind
{
    /// <summary>A sealed blob (update or snapshot) did not open. It was discarded, never applied.</summary>
    BlobRejected,

    /// <summary>A blob opened but its content is not a valid Yjs update. It was not applied.</summary>
    UpdateRejected,

    /// <summary>A wrapped notebook key did not open with the vault key; the notebook is unusable on this device.</summary>
    NotebookKeyRejected,

    /// <summary>A document is too large to snapshot within the server's blob limit.</summary>
    SnapshotTooLarge,

    /// <summary>Local edits were dropped because the server had deleted their document or notebook.</summary>
    EditsDropped,
}

/// <summary>A problem the sync engine worked around and wants reported. Carries ids only, never content.</summary>
public sealed record SyncIssue(SyncIssueKind Kind, string? NotebookId, string? DocId, long? Seq, string Message);

/// <summary>
/// The client side of PROTOCOL.md section 4: first sync, incremental pull strictly in seq
/// order, ordered and idempotent push of the outbox, snapshots, deletions, compaction, and
/// waking on the WebSocket. Obtain it from <see cref="TwoNoteClient.Sync"/>.
/// </summary>
public sealed class SyncEngine : IAsyncDisposable
{
    private const int MaxBlobBytes = 8 * 1024 * 1024;
    private const long PushByteBudget = 16L * 1024 * 1024;

    private readonly TwoNoteApi _api;
    private readonly LocalStore _store;
    private readonly ClientOptions _options;
    private readonly HeadListener? _listener;
    private readonly SemaphoreSlim _cycleLock = new(1, 1);
    private readonly SemaphoreSlim _wake = new(0, 1);
    private readonly Lock _stateLock = new();
    private readonly List<SyncIssue> _issues = [];
    private Vault? _vault;
    private string? _deviceId;
    private CancellationTokenSource? _loopCts;
    private Task? _loop;
    private long _head;
    private volatile bool _localEditPending;
    private SyncState _state = SyncState.Idle;
    private DateTimeOffset? _lastSyncedAt;
    private string? _lastError;

    internal SyncEngine(TwoNoteApi api, LocalStore store, ClientOptions options)
    {
        _api = api;
        _store = store;
        _options = options;
        if (options.UseWebSocket)
        {
            _listener = new HeadListener(api.WebSocketUrl, () => api.Token, options.WebSocketConnector, options.InitialRetryDelay, options.MaxRetryDelay);
            _listener.HeadReceived += OnHead;
            _listener.ConnectionChanged += connected =>
            {
                if (connected)
                {
                    Wake();
                }

                RaiseStatus();
            };
        }
    }

    /// <summary>Raised whenever <see cref="Status"/> changes. May be raised on any thread.</summary>
    public event Action<SyncStatus>? StatusChanged;

    /// <summary>Raised when a blob was rejected or local edits had to be dropped. May be raised on any thread.</summary>
    public event Action<SyncIssue>? IssueReported;

    /// <summary>Raised when the server announced a new head over the WebSocket (before the pull it triggers).</summary>
    public event Action<long>? HeadNotified;

    /// <summary>Raised after a pull or push changed the set of notebooks on this device.</summary>
    public event Action? NotebooksChanged;

    /// <summary>The current state.</summary>
    public SyncStatus Status
    {
        get
        {
            lock (_stateLock)
            {
                return new SyncStatus(
                    _state, _loop is not null, _store.Cursor, Math.Max(_head, _store.Cursor), _store.OutboxCount,
                    _listener?.IsConnected ?? false, _lastSyncedAt, _lastError);
            }
        }
    }

    /// <summary>The issues reported since the account was unlocked (most recent last, at most 200).</summary>
    public IReadOnlyList<SyncIssue> Issues
    {
        get
        {
            lock (_issues)
            {
                return [.. _issues];
            }
        }
    }

    /// <summary>True while the background loop is started.</summary>
    public bool IsRunning => _loop is not null;

    /// <summary>
    /// Runs one complete sync cycle now: pull, push, pull again, compact. Throws what stopped it
    /// (<see cref="ServerUnreachableException"/>, <see cref="ApiException"/>, …); the outbox is
    /// untouched by a failure and the next cycle resumes where this one stopped.
    /// </summary>
    public Task SyncNowAsync(CancellationToken ct = default) => RunCycleAsync(ct);

    /// <summary>
    /// Starts syncing in the background: once now, then whenever a local edit is made, the
    /// server announces a new head over the WebSocket, or the poll interval elapses. Failures
    /// are retried with backoff. Requires an unlocked account.
    /// </summary>
    public void Start()
    {
        lock (_stateLock)
        {
            if (_loop is not null)
            {
                return;
            }

            if (_vault is null)
            {
                throw new InvalidOperationException("The account is locked.");
            }

            _loopCts = new CancellationTokenSource();
            var ct = _loopCts.Token;
            _loop = Task.Run(() => LoopAsync(ct), CancellationToken.None);
        }

        _listener?.Start();
        RaiseStatus();
    }

    /// <summary>Asks the background loop to sync as soon as it can. Does nothing if the loop is not started.</summary>
    public void RequestSync() => Wake();

    /// <summary>Stops the background loop and the WebSocket ("go offline"). Local edits keep queueing.</summary>
    public async Task StopAsync()
    {
        Task? loop;
        CancellationTokenSource? cts;
        lock (_stateLock)
        {
            loop = _loop;
            cts = _loopCts;
            _loop = null;
            _loopCts = null;
        }

        if (_listener is not null)
        {
            await _listener.StopAsync().ConfigureAwait(false);
        }

        if (loop is not null)
        {
            cts!.Cancel();
            try
            {
                await loop.ConfigureAwait(false);
            }
            catch (OperationCanceledException)
            {
            }

            cts.Dispose();
        }

        RaiseStatus();
    }

    /// <inheritdoc />
    public async ValueTask DisposeAsync()
    {
        await StopAsync().ConfigureAwait(false);
        if (_listener is not null)
        {
            await _listener.DisposeAsync().ConfigureAwait(false);
        }
    }

    // ---- wiring from TwoNoteClient --------------------------------------------------------

    internal void Attach(Vault vault, string deviceId)
    {
        lock (_stateLock)
        {
            _vault = vault;
            _deviceId = deviceId;
            _state = SyncState.Idle;
            _lastError = null;
        }

        lock (_issues)
        {
            _issues.Clear();
        }
    }

    /// <summary>Stops everything and waits for a running cycle to finish before the vault goes away.</summary>
    internal async Task DetachAsync()
    {
        await StopAsync().ConfigureAwait(false);
        await _cycleLock.WaitAsync().ConfigureAwait(false);
        try
        {
            lock (_stateLock)
            {
                _vault = null;
            }
        }
        finally
        {
            _cycleLock.Release();
        }
    }

    internal void Report(SyncIssue issue)
    {
        lock (_issues)
        {
            if (_issues.Count >= 200)
            {
                _issues.RemoveAt(0);
            }

            _issues.Add(issue);
        }

        IssueReported?.Invoke(issue);
    }

    /// <summary>A local edit reached the outbox.</summary>
    internal void NotifyLocalChange()
    {
        _localEditPending = true;
        Wake();
    }

    internal void RaiseNotebooksChanged() => NotebooksChanged?.Invoke();

    /// <summary>Runs <paramref name="action"/> while no sync cycle is in progress.</summary>
    internal async Task<T> ExclusiveAsync<T>(Func<Task<T>> action, CancellationToken ct)
    {
        await _cycleLock.WaitAsync(ct).ConfigureAwait(false);
        try
        {
            return await action().ConfigureAwait(false);
        }
        finally
        {
            _cycleLock.Release();
        }
    }

    // ---- loop -----------------------------------------------------------------------------

    private void OnHead(long head)
    {
        InterlockedMax(ref _head, head);
        HeadNotified?.Invoke(head);
        if (head > _store.Cursor)
        {
            Wake();
        }

        RaiseStatus();
    }

    private void Wake()
    {
        lock (_wake)
        {
            if (_wake.CurrentCount == 0)
            {
                _wake.Release();
            }
        }
    }

    private async Task LoopAsync(CancellationToken ct)
    {
        var failures = 0;
        while (!ct.IsCancellationRequested)
        {
            TimeSpan wait;
            try
            {
                _localEditPending = false;
                await RunCycleAsync(ct).ConfigureAwait(false);
                failures = 0;
                wait = _options.PollInterval;
            }
            catch (OperationCanceledException) when (ct.IsCancellationRequested)
            {
                break;
            }
            catch (ApiException e) when (e.Status == 401)
            {
                // Retrying cannot help until the user signs in again (which wakes the loop).
                wait = _options.PollInterval;
            }
            catch (Exception)
            {
                // RunCycleAsync has already recorded why. Retry with backoff; a wake-up retries at once.
                failures++;
                var delay = _options.InitialRetryDelay.Ticks * (1L << Math.Min(failures - 1, 20));
                wait = TimeSpan.FromTicks(Math.Min(_options.MaxRetryDelay.Ticks, delay));
            }

            try
            {
                var woken = await _wake.WaitAsync(wait, ct).ConfigureAwait(false);
                if (woken && _localEditPending && _options.PushDebounce > TimeSpan.Zero)
                {
                    await Task.Delay(_options.PushDebounce, ct).ConfigureAwait(false);
                }
            }
            catch (OperationCanceledException)
            {
                break;
            }
        }
    }

    private async Task RunCycleAsync(CancellationToken ct)
    {
        await _cycleLock.WaitAsync(ct).ConfigureAwait(false);
        try
        {
            var vault = _vault ?? throw new InvalidOperationException("The account is locked.");
            SetState(SyncState.Syncing, null);
            try
            {
                await CycleAsync(vault, ct).ConfigureAwait(false);
            }
            catch (OperationCanceledException) when (ct.IsCancellationRequested)
            {
                SetState(SyncState.Idle, null);
                throw;
            }
            catch (ServerUnreachableException)
            {
                SetState(SyncState.Offline, null);
                throw;
            }
            catch (ApiException e) when (e.Status == 401)
            {
                SetState(SyncState.AuthRequired, null);
                throw;
            }
            catch (ApiException e)
            {
                SetState(SyncState.Error, $"The server answered {e.Status} {e.Code}.");
                throw;
            }
            catch (Exception e)
            {
                // Only the type: exception messages from lower layers are not vetted for content.
                SetState(SyncState.Error, $"Sync failed ({e.GetType().Name}).");
                throw;
            }

            lock (_stateLock)
            {
                _lastSyncedAt = DateTimeOffset.UtcNow;
            }

            SetState(SyncState.Idle, null);
        }
        finally
        {
            _cycleLock.Release();
        }
    }

    // ---- the algorithm of PROTOCOL.md section 4 -------------------------------------------

    private async Task CycleAsync(Vault vault, CancellationToken ct)
    {
        if (!_store.FirstSyncDone)
        {
            await FirstSyncAsync(vault, ct).ConfigureAwait(false);
        }

        // Pull before push, so deletions made elsewhere are known before stale edits go out; then
        // pull again after a push to move the cursor past this device's own events.
        for (var round = 0; round < 100; round++)
        {
            await PullAsync(vault, ct).ConfigureAwait(false);
            if (!await PushAsync(vault, ct).ConfigureAwait(false))
            {
                break;
            }
        }

        if (await CompactAsync(vault, ct).ConfigureAwait(false))
        {
            await PullAsync(vault, ct).ConfigureAwait(false);
        }
    }

    /// <summary>Step 1: notebooks, documents, every snapshot; the events from 0 follow in <see cref="PullAsync"/>.</summary>
    private async Task FirstSyncAsync(Vault vault, CancellationToken ct)
    {
        var notebooks = await _api.GetNotebooksAsync(ct).ConfigureAwait(false);
        var docs = await _api.GetDocsAsync(ct).ConfigureAwait(false);
        vault.AddKeys(notebooks.Select(n => (n.NotebookId, n.WrappedKey)));

        var work = new List<PendingChange>();
        foreach (var doc in docs)
        {
            if (doc.SnapshotSeq <= 0 || !IsId(doc.DocId) || !IsId(doc.NotebookId))
            {
                continue;
            }

            var snapshot = await _api.GetSnapshotAsync(doc.DocId, ct).ConfigureAwait(false);
            if (snapshot is not null)
            {
                work.Add(OpenSnapshot(vault, doc.DocId, doc.NotebookId, snapshot, seq: null));
            }
        }

        await CommitAsync(vault, notebooks, work, newCursor: null, firstSyncDone: true).ConfigureAwait(false);
    }

    /// <summary>Step 2: read <c>/events</c> from the cursor until there are no more, applying each page atomically and in seq order.</summary>
    private async Task PullAsync(Vault vault, CancellationToken ct)
    {
        while (true)
        {
            ct.ThrowIfCancellationRequested();
            var cursor = _store.Cursor;
            var page = await _api.GetEventsAsync(cursor, _options.EventsPageSize, ct).ConfigureAwait(false);
            InterlockedMax(ref _head, page.Head);

            if (page.Events.Count == 0)
            {
                if (page.More)
                {
                    throw new ProtocolViolationException("The server announced more events but sent none.");
                }

                if (page.Head > cursor)
                {
                    // Everything between the cursor and head was removed by a snapshot or a deletion.
                    _store.Apply(batch => batch.SetCursor(page.Head));
                }

                return;
            }

            IReadOnlyList<NotebookEntry>? notebooks = null;
            if (page.Events.Any(e => e.Type == ServerEvent.NotebooksChanged))
            {
                // The list read now is at least as new as the event, which is all that matters.
                notebooks = await _api.GetNotebooksAsync(ct).ConfigureAwait(false);
                vault.AddKeys(notebooks.Select(n => (n.NotebookId, n.WrappedKey)));
            }

            var work = new List<PendingChange>();
            foreach (var e in page.Events)
            {
                switch (e.Type)
                {
                    case ServerEvent.Update when IsId(e.DocId) && IsId(e.NotebookId) && e.Blob is not null:
                        if (e.DeviceId == _deviceId)
                        {
                            break; // this device's own edit: already in the local store
                        }

                        var plaintext = vault.TryOpen(e.NotebookId!, BlobKind.Update, e.DocId!, e.Blob);
                        work.Add(plaintext is null
                            ? PendingChange.Rejected(e.DocId!, e.NotebookId!, e.Seq)
                            : PendingChange.Update(e.DocId!, e.NotebookId!, e.Seq, e.Blob, plaintext));
                        break;

                    case ServerEvent.Snapshot when IsId(e.DocId) && IsId(e.NotebookId):
                        if ((_store.GetDoc(e.DocId!)?.SnapshotSeq ?? 0) >= (e.CoveredSeq ?? long.MaxValue))
                        {
                            break; // already stored (for instance, this device uploaded it)
                        }

                        var snapshot = await _api.GetSnapshotAsync(e.DocId!, ct).ConfigureAwait(false);
                        if (snapshot is not null)
                        {
                            work.Add(OpenSnapshot(vault, e.DocId!, e.NotebookId!, snapshot, e.Seq));
                        }

                        break;

                    case ServerEvent.DocDeleted when IsId(e.DocId):
                        work.Add(PendingChange.Deleted(e.DocId!, e.Seq));
                        break;

                    // notebooksChanged was handled above; unknown event types are skipped.
                }
            }

            var newCursor = page.More ? page.Events[^1].Seq : Math.Max(page.Events[^1].Seq, page.Head);
            await CommitAsync(vault, notebooks, work, newCursor, firstSyncDone: false).ConfigureAwait(false);
            RaiseStatus();

            if (!page.More)
            {
                return;
            }
        }
    }

    private static PendingChange OpenSnapshot(Vault vault, string docId, string notebookId, SnapshotEntry snapshot, long? seq)
    {
        var plaintext = snapshot.Blob is null ? null : vault.TryOpen(notebookId, BlobKind.Snapshot, docId, snapshot.Blob);
        return plaintext is null
            ? PendingChange.Rejected(docId, notebookId, seq)
            : PendingChange.Snapshot(docId, notebookId, seq, snapshot.CoveredSeq, snapshot.Blob!, plaintext);
    }

    /// <summary>
    /// Stores one batch of changes and the new cursor in a single local transaction, then brings
    /// the open documents up to date in the same order.
    /// </summary>
    private async Task CommitAsync(
        Vault vault, IReadOnlyList<NotebookEntry>? notebooks, List<PendingChange> work, long? newCursor, bool firstSyncDone)
    {
        var memory = new List<(CrdtDocument Doc, PendingChange Change)>();
        var deleted = new List<CrdtDocument>();
        var removedNotebooks = new List<string>();
        var removedDocs = new List<string>();
        var issues = new List<SyncIssue>();

        lock (vault.Gate)
        {
            _store.Apply(batch =>
            {
                if (notebooks is not null)
                {
                    foreach (var (notebookId, docIds) in batch.ReplaceServerNotebooks(
                                 notebooks.Where(n => IsId(n.NotebookId) && n.WrappedKey is not null).Select(n => (n.NotebookId, n.WrappedKey)).ToList()))
                    {
                        removedNotebooks.Add(notebookId);
                        removedDocs.AddRange(docIds.Append(notebookId));
                    }
                }

                foreach (var change in work)
                {
                    switch (change.Kind)
                    {
                        case PendingKind.Update:
                            batch.AddRemoteUpdate(change.DocId, change.NotebookId, change.Seq!.Value, change.Blob!);
                            break;
                        case PendingKind.Snapshot:
                            batch.SetSnapshot(change.DocId, change.NotebookId, change.CoveredSeq, change.Blob!);
                            break;
                        case PendingKind.Deleted:
                            batch.DropDoc(change.DocId);
                            break;
                        case PendingKind.Rejected:
                            batch.MarkDamaged(change.DocId, change.NotebookId);
                            issues.Add(new SyncIssue(SyncIssueKind.BlobRejected, change.NotebookId, change.DocId, change.Seq,
                                "A blob from the server did not open; it was discarded."));
                            break;
                    }
                }

                if (newCursor is { } cursor)
                {
                    batch.SetCursor(cursor);
                }

                if (firstSyncDone)
                {
                    batch.SetFirstSyncDone();
                }
            });

            // Still under the gate: whoever opens a document from now on reads the committed state.
            deleted.AddRange(vault.Detach(removedDocs));
            foreach (var change in work)
            {
                if (change.Kind == PendingKind.Deleted)
                {
                    deleted.AddRange(vault.Detach([change.DocId]));
                }
                else if (change.Plaintext is not null && vault.Live(change.DocId) is { } doc)
                {
                    memory.Add((doc, change));
                }
            }
        }

        foreach (var notebookId in removedNotebooks)
        {
            vault.RemoveKey(notebookId);
        }

        if (memory.Count > 0 || deleted.Count > 0)
        {
            await vault.DispatchAsync(() =>
            {
                foreach (var (doc, change) in memory)
                {
                    if (!doc.ApplyUpdate(change.Plaintext!))
                    {
                        issues.Add(new SyncIssue(SyncIssueKind.UpdateRejected, change.NotebookId, change.DocId, change.Seq,
                            "A decrypted update was not valid and was not applied."));
                    }
                }

                foreach (var doc in deleted)
                {
                    doc.MarkDeleted();
                }
            }).ConfigureAwait(false);
        }

        foreach (var issue in issues)
        {
            Report(issue);
        }

        if (notebooks is not null)
        {
            NotebooksChanged?.Invoke();
        }
    }

    /// <summary>Step 3: send the outbox in the order the edits were made. Returns true if anything was sent.</summary>
    private async Task<bool> PushAsync(Vault vault, CancellationToken ct)
    {
        var sent = false;
        foreach (var notebook in _store.GetPendingNotebooks())
        {
            var head = await _api.PutNotebookAsync(notebook.NotebookId, notebook.WrappedKey, ct).ConfigureAwait(false);
            _store.MarkNotebookPushed(notebook.NotebookId);
            InterlockedMax(ref _head, head);
            sent = true;
        }

        while (true)
        {
            ct.ThrowIfCancellationRequested();
            var batch = _store.PeekOutbox(_options.PushBatchSize, PushByteBudget);
            if (batch.Count == 0)
            {
                return sent;
            }

            var docId = batch[0].DocId;
            var notebookId = batch[0].NotebookId;
            try
            {
                var result = await _api.PushUpdatesAsync(
                    docId, notebookId, batch.Select(e => new OutgoingUpdate(e.ClientUpdateId, e.Blob)).ToList(), ct).ConfigureAwait(false);

                // Only now, with the server's acknowledgement stored, do the updates leave the outbox.
                _store.AcknowledgeOutbox(batch.Select((e, i) => (e.LocalId, result.Seqs[i])).ToList());
                InterlockedMax(ref _head, result.Head);
                sent = true;
            }
            catch (ApiException e) when (e.Code == ErrorCodes.DocDeleted)
            {
                await DropLocallyAsync(vault, [docId], notebookId, notebookGone: false,
                    "The document was deleted on the server; unsent edits to it were dropped.").ConfigureAwait(false);
            }
            catch (ApiException e) when (e.Code == ErrorCodes.UnknownNotebook)
            {
                var notebooks = await _api.GetNotebooksAsync(ct).ConfigureAwait(false);
                if (notebooks.Any(n => n.NotebookId == notebookId))
                {
                    throw; // the server contradicts itself; do not destroy anything on its word
                }

                await DropLocallyAsync(vault, [], notebookId, notebookGone: true,
                    "The notebook was deleted on the server; unsent edits to it were dropped.").ConfigureAwait(false);
            }

            RaiseStatus();
        }
    }

    /// <summary>Removes documents (or a whole notebook) from the local store and tells the open documents.</summary>
    internal async Task DropLocallyAsync(Vault vault, IReadOnlyList<string> docIds, string notebookId, bool notebookGone, string? issueMessage)
    {
        List<CrdtDocument> open;
        lock (vault.Gate)
        {
            var dropped = new List<string>(docIds);
            _store.Apply(batch =>
            {
                if (notebookGone)
                {
                    dropped.AddRange(batch.RemoveNotebook(notebookId));
                    dropped.Add(notebookId);
                }
                else
                {
                    foreach (var docId in docIds)
                    {
                        batch.DropDoc(docId);
                    }
                }
            });
            open = vault.Detach(dropped);
        }

        if (notebookGone)
        {
            vault.RemoveKey(notebookId);
        }

        if (open.Count > 0)
        {
            await vault.DispatchAsync(() =>
            {
                foreach (var doc in open)
                {
                    doc.MarkDeleted();
                }
            }).ConfigureAwait(false);
        }

        if (issueMessage is not null)
        {
            Report(new SyncIssue(SyncIssueKind.EditsDropped, notebookId, docIds.Count == 1 ? docIds[0] : null, null, issueMessage));
        }

        if (notebookGone)
        {
            NotebooksChanged?.Invoke();
        }
    }

    /// <summary>
    /// Step 4: a document with more than the threshold of un-snapshotted updates gets a snapshot
    /// with <c>coveredSeq = head</c> - but only while this device has applied every event up to
    /// head and has nothing left to push. Returns true if a snapshot was uploaded.
    /// </summary>
    private async Task<bool> CompactAsync(Vault vault, CancellationToken ct)
    {
        var uploaded = false;
        foreach (var doc in _store.GetDocsToCompact(_options.CompactionThreshold))
        {
            ct.ThrowIfCancellationRequested();
            var cursor = _store.Cursor;
            if (_store.OutboxCount > 0 || cursor < Interlocked.Read(ref _head) || cursor < 1)
            {
                return uploaded; // not caught up (any more); the next cycle tries again
            }

            if (!vault.HasKey(doc.NotebookId))
            {
                continue;
            }

            var state = vault.EncodeFullState(doc.DocId, doc.NotebookId);
            if (state is null)
            {
                _store.Apply(batch => batch.MarkDamaged(doc.DocId, doc.NotebookId));
                continue;
            }

            if (state.Length + SealedBlob.Overhead > MaxBlobBytes)
            {
                Report(new SyncIssue(SyncIssueKind.SnapshotTooLarge, doc.NotebookId, doc.DocId, null,
                    "The document is too large to snapshot; its update log keeps growing."));
                continue;
            }

            var blob = vault.Seal(doc.NotebookId, BlobKind.Snapshot, doc.DocId, state);
            try
            {
                var result = await _api.PutSnapshotAsync(doc.DocId, cursor, blob, ct).ConfigureAwait(false);
                _store.Apply(batch => batch.SetSnapshot(doc.DocId, doc.NotebookId, cursor, blob));
                InterlockedMax(ref _head, result.Head);
                uploaded = true;
            }
            catch (ApiException e) when (e.Code is ErrorCodes.StaleSnapshot or ErrorCodes.UnknownDoc or ErrorCodes.DocDeleted)
            {
                // Another device got there first, or the document is gone; the event log will say which.
            }
        }

        return uploaded;
    }

    // ---- helpers --------------------------------------------------------------------------

    private static bool IsId(string? id) => WireEncoding.TryIdFromHex(id, out _);

    private static void InterlockedMax(ref long target, long value)
    {
        long current;
        while (value > (current = Interlocked.Read(ref target)))
        {
            Interlocked.CompareExchange(ref target, value, current);
        }
    }

    private void SetState(SyncState state, string? error)
    {
        lock (_stateLock)
        {
            _state = state;
            _lastError = error;
        }

        RaiseStatus();
    }

    private void RaiseStatus()
    {
        var handler = StatusChanged;
        if (handler is null)
        {
            return;
        }

        try
        {
            handler(Status);
        }
        catch (ObjectDisposedException)
        {
            // The store was closed while a late notification was on its way.
        }
    }

    private enum PendingKind
    {
        Update,
        Snapshot,
        Deleted,
        Rejected,
    }

    /// <summary>One event of a page, already decrypted, waiting to be committed.</summary>
    private sealed record PendingChange(
        PendingKind Kind, string DocId, string NotebookId, long? Seq, long CoveredSeq, byte[]? Blob, byte[]? Plaintext)
    {
        public static PendingChange Update(string docId, string notebookId, long seq, byte[] blob, byte[] plaintext) =>
            new(PendingKind.Update, docId, notebookId, seq, 0, blob, plaintext);

        public static PendingChange Snapshot(string docId, string notebookId, long? seq, long coveredSeq, byte[] blob, byte[] plaintext) =>
            new(PendingKind.Snapshot, docId, notebookId, seq, coveredSeq, blob, plaintext);

        public static PendingChange Deleted(string docId, long seq) =>
            new(PendingKind.Deleted, docId, "", seq, 0, null, null);

        public static PendingChange Rejected(string docId, string notebookId, long? seq) =>
            new(PendingKind.Rejected, docId, notebookId, seq, 0, null, null);
    }
}

using System.Security.Cryptography;
using YDotNet.Document;
using YDotNet.Document.Cells;
using YDotNet.Document.Options;
using YDotNet.Document.Transactions;

namespace TwoNote.Core.Documents;

/// <summary>Who caused a change to a document.</summary>
public enum ChangeSource
{
    /// <summary>An edit made through this object.</summary>
    Local,

    /// <summary>An update that arrived from another replica (or was loaded from the local store).</summary>
    Remote,

    /// <summary>Undo or redo of this replica's own edits.</summary>
    Undo,
}

/// <summary>
/// Base of the two Yjs documents of PROTOCOL.md section 5. Wraps one Yrs document with UTF-16
/// text offsets. Every member may be called from any thread: calls are serialised by
/// <see cref="SyncRoot"/>, and events are raised while it is held, on the calling thread, after
/// the transaction has committed (so handlers may read the document, and see exactly the state
/// the event describes).
/// </summary>
public abstract class CrdtDocument : IDisposable
{
    /// <summary>Transaction origin of user edits; the undo manager tracks only this one.</summary>
    private protected static readonly byte[] LocalOrigin = "local"u8.ToArray();

    /// <summary>Transaction origin of this client's own housekeeping writes (initialisation); never undone.</summary>
    private protected static readonly byte[] SystemOrigin = "system"u8.ToArray();

    private static readonly byte[] RemoteOrigin = "remote"u8.ToArray();

    private readonly List<byte[]> _producedUpdates = [];
    private readonly IDisposable _updateSubscription;
    private ChangeSource? _current;
    private bool _changed;
    private bool _disposed;

    private protected CrdtDocument(string docId)
    {
        if (!WireEncoding.TryIdFromHex(docId, out _))
        {
            throw new ArgumentException("A document id is exactly 32 lowercase hex characters.", nameof(docId));
        }

        DocId = docId;

        // A fresh client id per session: re-using one after losing local state would corrupt the
        // document. 53 bits so that JavaScript Yjs peers can represent it.
        Span<byte> random = stackalloc byte[8];
        RandomNumberGenerator.Fill(random);
        var clientId = (BitConverter.ToUInt64(random) & ((1UL << 53) - 1)) | 1UL;
        Doc = new Doc(new DocOptions { Id = clientId, Encoding = DocEncoding.Utf16 });

        _updateSubscription = Doc.ObserveUpdatesV1(e =>
        {
            // Observers run inside Commit, on the committing thread, so _current says who is writing.
            if (e.Update.Length <= 2)
            {
                return; // an update that carries nothing
            }

            _changed = true;
            if (_current is ChangeSource.Local or ChangeSource.Undo)
            {
                _producedUpdates.Add(e.Update);
            }
        });
    }

    /// <summary>The 32-character hex id this document is stored and encrypted under.</summary>
    public string DocId { get; }

    /// <summary>The lock that serialises access. Hold it to make several calls atomic.</summary>
    public object SyncRoot { get; } = new();

    /// <summary>True once the server deleted this document (or its notebook); further edits are not synced.</summary>
    public bool IsDeleted { get; private set; }

    /// <summary>
    /// A Yjs v1 update produced by this replica (edit, undo or redo) that has to reach the other
    /// replicas. The sync layer seals it into the outbox before the editing call returns.
    /// </summary>
    public event Action<byte[]>? LocalUpdate;

    /// <summary>The document content changed, for whatever reason. Raised once per transaction.</summary>
    public event Action<ChangeSource>? Changed;

    /// <summary>Raised when <see cref="IsDeleted"/> becomes true.</summary>
    public event Action? Deleted;

    private protected Doc Doc { get; }

    /// <summary>
    /// Merges a Yjs v1 update from another replica. Merging is idempotent and commutative.
    /// Returns false, leaving the document untouched, when the bytes are not a valid update.
    /// </summary>
    public bool ApplyUpdate(byte[] update)
    {
        ArgumentNullException.ThrowIfNull(update);
        lock (SyncRoot)
        {
            if (_disposed)
            {
                return true;
            }

            var ok = true;
            Run(ChangeSource.Remote, () =>
            {
                using var txn = Doc.WriteTransaction(RemoteOrigin);
                ok = txn.ApplyV1(update) == TransactionUpdateResult.Ok;
            });
            return ok;
        }
    }

    /// <summary>The whole document as one Yjs v1 update (the plaintext of a <c>snapshot</c> blob).</summary>
    public byte[] EncodeState() => EncodeDiff(null);

    /// <summary>This replica's Yjs state vector (v1).</summary>
    public byte[] EncodeStateVector()
    {
        lock (SyncRoot)
        {
            ThrowIfDisposed();
            ThrowIfWriting();
            using var txn = Doc.ReadTransaction();
            return txn.StateVectorV1();
        }
    }

    /// <summary>Everything this replica has that a replica with <paramref name="remoteStateVector"/> lacks, as a v1 update.</summary>
    public byte[] EncodeDiff(byte[]? remoteStateVector)
    {
        lock (SyncRoot)
        {
            ThrowIfDisposed();
            ThrowIfWriting();
            using var txn = Doc.ReadTransaction();
            return txn.StateDiffV1(remoteStateVector);
        }
    }

    /// <summary>Marks the document as deleted on the server. Called by the sync layer.</summary>
    internal void MarkDeleted()
    {
        lock (SyncRoot)
        {
            if (IsDeleted)
            {
                return;
            }

            IsDeleted = true;
            Deleted?.Invoke();
        }
    }

    /// <inheritdoc />
    public void Dispose()
    {
        lock (SyncRoot)
        {
            if (_disposed)
            {
                return;
            }

            _disposed = true;
            DisposeCore();
            _updateSubscription.Dispose();
            Doc.Dispose();
        }

        GC.SuppressFinalize(this);
    }

    /// <summary>Releases observers and helpers of the derived class, before the document itself.</summary>
    private protected virtual void DisposeCore()
    {
    }

    /// <summary>Called after a transaction that changed something, before <see cref="Changed"/>.</summary>
    private protected virtual void OnCommitted(ChangeSource source)
    {
    }

    private protected void ThrowIfDisposed() => ObjectDisposedException.ThrowIf(_disposed, this);

    /// <summary>Yrs allows one transaction at a time; reading while this thread is writing would fail inside the native library.</summary>
    private void ThrowIfWriting()
    {
        if (_current is not null)
        {
            throw new InvalidOperationException("The document cannot be read from inside its own edit; use the editor passed to the edit instead.");
        }
    }

    /// <summary>Runs a read transaction.</summary>
    private protected T Read<T>(Func<Transaction, T> body)
    {
        lock (SyncRoot)
        {
            ThrowIfDisposed();
            ThrowIfWriting();
            using var txn = Doc.ReadTransaction();
            return body(txn);
        }
    }

    /// <summary>Runs a write transaction as a user edit (<paramref name="system"/> false) or as housekeeping.</summary>
    private protected void Write(Action<Transaction, InputScope> body, bool system = false)
    {
        lock (SyncRoot)
        {
            ThrowIfDisposed();
            Run(ChangeSource.Local, () =>
            {
                var scope = new InputScope();
                try
                {
                    using var txn = Doc.WriteTransaction(system ? SystemOrigin : LocalOrigin);
                    body(txn, scope);
                }
                finally
                {
                    // Inputs own native memory that Yrs reads until the transaction has committed.
                    GC.KeepAlive(scope);
                }
            });
        }
    }

    /// <summary>Runs <paramref name="action"/> (which commits one or more transactions) and then raises the events.</summary>
    private protected void Run(ChangeSource source, Action action)
    {
        lock (SyncRoot)
        {
            if (_current is not null)
            {
                throw new InvalidOperationException("A document cannot be changed from inside one of its own change handlers.");
            }

            _current = source;
            _changed = false;
            _producedUpdates.Clear();
            byte[][] produced;
            bool changed;
            try
            {
                action();
            }
            finally
            {
                produced = [.. _producedUpdates];
                _producedUpdates.Clear();
                changed = _changed;
                _current = null;
            }

            // Updates first: the edit is in the outbox before anyone is told about it.
            foreach (var update in produced)
            {
                LocalUpdate?.Invoke(update);
            }

            if (changed)
            {
                OnCommitted(source);
                Changed?.Invoke(source);
            }
        }
    }

    /// <summary>Converts an attribute or field value to a Yrs input. Numbers are always written as doubles (PROTOCOL.md 5.2).</summary>
    private protected static Input ToInput(object? value, InputScope scope) => scope.Add(value switch
    {
        null => Input.Null(),
        bool b => Input.Boolean(b),
        string s => Input.String(s),
        double d => Input.Double(d),
        float f => Input.Double(f),
        int i => Input.Double(i),
        long l => Input.Double(l),
        _ => throw new ArgumentException($"Unsupported value type {value.GetType().Name}; use bool, string or a number."),
    });

    /// <summary>Reads a scalar the way it is exposed to callers: bool, string or double; anything else is null.</summary>
    private protected static object? FromOutput(Output? output) => output?.Tag switch
    {
        OutputTag.Boolean => output.Boolean,
        OutputTag.String => output.String,
        OutputTag.Double => output.Double,
        OutputTag.Long => (double)output.Long, // a BigInt written by a client that broke the rules
        _ => null,
    };
}

/// <summary>Keeps every <see cref="Input"/> of one transaction reachable until it has committed.</summary>
internal sealed class InputScope
{
    private readonly List<Input> _inputs = [];

    public Input Add(Input input)
    {
        _inputs.Add(input);
        return input;
    }

    public Input Object(IDictionary<string, Input> fields) => Add(Input.Object(fields));

    public Input Map(IDictionary<string, Input> fields) => Add(Input.Map(fields));
}

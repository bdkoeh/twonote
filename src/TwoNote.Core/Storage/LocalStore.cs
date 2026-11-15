using System.Text.Json;
using Microsoft.Data.Sqlite;
using TwoNote.Core.Crypto;

namespace TwoNote.Core.Storage;

/// <summary>
/// The non-secret facts a device remembers about its account. The Secret Key and the session
/// token are deliberately not here: they live in the <see cref="ISecretStore"/>.
/// </summary>
public sealed record AccountRecord(
    string Username, string AccountId, string DeviceId, string DeviceName, byte[] KdfSalt, KdfParams KdfParams, byte[] WrappedVaultKey);

/// <summary>A notebook as stored locally: its wrapped key, and whether the server has it yet.</summary>
public sealed record StoredNotebook(string NotebookId, byte[] WrappedKey, bool PendingPut);

/// <summary>A document row of the local store.</summary>
public sealed record StoredDoc(string DocId, string NotebookId, long SnapshotSeq, bool Damaged);

/// <summary>The ciphertext a document is rebuilt from: the snapshot (if any) and every update after it, in arrival order.</summary>
public sealed record StoredDocContent(string DocId, string NotebookId, long SnapshotSeq, byte[]? SnapshotBlob, IReadOnlyList<byte[]> UpdateBlobs);

/// <summary>A sealed local edit that the server has not acknowledged yet.</summary>
public sealed record OutboxEntry(long LocalId, string DocId, string NotebookId, string ClientUpdateId, byte[] Blob);

/// <summary>
/// The per-device SQLite file. It holds only what the server may also hold - sealed updates
/// and snapshots, wrapped keys - plus the outbox, the event cursor and non-secret account
/// metadata. Nothing in it is readable without the vault key.
/// Thread safe: every call takes one lock around one connection.
/// </summary>
public sealed class LocalStore : IDisposable
{
    private const int SchemaVersion = 1;

    private const string Schema =
        """
        CREATE TABLE meta (key TEXT PRIMARY KEY, value) WITHOUT ROWID;
        CREATE TABLE notebooks (
            notebook_id TEXT PRIMARY KEY,
            wrapped_key BLOB NOT NULL,
            pending_put INTEGER NOT NULL) WITHOUT ROWID;
        CREATE TABLE docs (
            doc_id TEXT PRIMARY KEY,
            notebook_id TEXT NOT NULL,
            snapshot_seq INTEGER NOT NULL DEFAULT 0,
            snapshot_blob BLOB,
            damaged INTEGER NOT NULL DEFAULT 0);
        CREATE INDEX docs_notebook ON docs (notebook_id);
        -- One row per sealed update, in the order this device learned of it. seq is the server's
        -- sequence number; NULL means the row is still in the outbox.
        CREATE TABLE updates (
            local_id INTEGER PRIMARY KEY AUTOINCREMENT,
            doc_id TEXT NOT NULL,
            seq INTEGER,
            client_update_id TEXT,
            blob BLOB NOT NULL);
        CREATE INDEX updates_doc ON updates (doc_id, local_id);
        CREATE UNIQUE INDEX updates_seq ON updates (seq) WHERE seq IS NOT NULL;
        CREATE INDEX updates_outbox ON updates (local_id) WHERE seq IS NULL;
        """;

    private static readonly JsonSerializerOptions JsonOptions = Api.WireJson.Options;

    private readonly Lock _lock = new();
    private readonly SqliteConnection _connection;
    private bool _disposed;

    private LocalStore(SqliteConnection connection) => _connection = connection;

    /// <summary>Opens (creating if necessary) the store at <paramref name="path"/>.</summary>
    public static LocalStore Open(string path)
    {
        ArgumentException.ThrowIfNullOrEmpty(path);
        var directory = Path.GetDirectoryName(Path.GetFullPath(path));
        if (!string.IsNullOrEmpty(directory))
        {
            Directory.CreateDirectory(directory);
        }

        var connection = new SqliteConnection(new SqliteConnectionStringBuilder
        {
            DataSource = path,
            Mode = SqliteOpenMode.ReadWriteCreate,
            Pooling = false,
        }.ToString());
        connection.Open();
        try
        {
            var store = new LocalStore(connection);
            store.Exec(null, "PRAGMA journal_mode = WAL");
            store.Exec(null, "PRAGMA synchronous = NORMAL");
            store.Migrate();
            return store;
        }
        catch
        {
            connection.Dispose();
            throw;
        }
    }

    // ---- account and cursor ---------------------------------------------------------------

    /// <summary>The enrolled account, or null on a device that has none yet.</summary>
    public AccountRecord? GetAccount() => Locked(() =>
        GetMeta(null, "account") is string json ? JsonSerializer.Deserialize<AccountRecord>(json, JsonOptions) : null);

    /// <summary>Stores or replaces the account record.</summary>
    public void SaveAccount(AccountRecord account)
    {
        ArgumentNullException.ThrowIfNull(account);
        Locked(() => SetMeta(null, "account", JsonSerializer.Serialize(account, JsonOptions)));
    }

    /// <summary>The seq of the last event this device has applied (0 before the first sync).</summary>
    public long Cursor => Locked(() => GetMeta(null, "cursor") is long v ? v : 0);

    /// <summary>True once the first sync of PROTOCOL.md section 4 step 1 has completed.</summary>
    public bool FirstSyncDone => Locked(() => GetMeta(null, "first_sync_done") is long v && v != 0);

    // ---- notebooks ------------------------------------------------------------------------

    /// <summary>Every notebook known locally.</summary>
    public IReadOnlyList<StoredNotebook> GetNotebooks() => Locked(() => ReadNotebooks(null));

    /// <summary>Stores a notebook created on this device; it is sent to the server by the next sync.</summary>
    public void AddLocalNotebook(string notebookId, byte[] wrappedKey) => Locked(() =>
        Exec(null, "INSERT INTO notebooks (notebook_id, wrapped_key, pending_put) VALUES ($n, $w, 1)", ("$n", notebookId), ("$w", wrappedKey)));

    /// <summary>Records that the server now has this notebook.</summary>
    public void MarkNotebookPushed(string notebookId) => Locked(() =>
        Exec(null, "UPDATE notebooks SET pending_put = 0 WHERE notebook_id = $n", ("$n", notebookId)));

    // ---- documents ------------------------------------------------------------------------

    /// <summary>Every document known locally.</summary>
    public IReadOnlyList<StoredDoc> GetDocs() => Locked(() =>
    {
        var list = new List<StoredDoc>();
        using var cmd = Cmd(null, "SELECT doc_id, notebook_id, snapshot_seq, damaged FROM docs ORDER BY doc_id");
        using var r = cmd.ExecuteReader();
        while (r.Read())
        {
            list.Add(new StoredDoc(r.GetString(0), r.GetString(1), r.GetInt64(2), r.GetInt64(3) != 0));
        }

        return list;
    });

    /// <summary>One document row, or null.</summary>
    public StoredDoc? GetDoc(string docId) => Locked(() => ReadDoc(null, docId));

    /// <summary>The ciphertext of one document, or null if nothing is stored for it.</summary>
    public StoredDocContent? LoadDoc(string docId) => Locked(() =>
    {
        using var tx = _connection.BeginTransaction(deferred: true);
        string notebookId;
        long snapshotSeq;
        byte[]? snapshot;
        using (var cmd = Cmd(tx, "SELECT notebook_id, snapshot_seq, snapshot_blob FROM docs WHERE doc_id = $d", ("$d", docId)))
        using (var r = cmd.ExecuteReader())
        {
            if (!r.Read())
            {
                return null;
            }

            notebookId = r.GetString(0);
            snapshotSeq = r.GetInt64(1);
            snapshot = r.IsDBNull(2) ? null : (byte[])r[2];
        }

        var updates = new List<byte[]>();
        using (var cmd = Cmd(tx, "SELECT blob FROM updates WHERE doc_id = $d ORDER BY local_id", ("$d", docId)))
        using (var r = cmd.ExecuteReader())
        {
            while (r.Read())
            {
                updates.Add((byte[])r[0]);
            }
        }

        return new StoredDocContent(docId, notebookId, snapshotSeq, snapshot, updates);
    });

    /// <summary>Documents with more than <paramref name="threshold"/> acknowledged updates since their last snapshot, and no damage.</summary>
    public IReadOnlyList<StoredDoc> GetDocsToCompact(int threshold) => Locked(() =>
    {
        var list = new List<StoredDoc>();
        using var cmd = Cmd(null,
            """
            SELECT d.doc_id, d.notebook_id, d.snapshot_seq FROM docs d
            WHERE d.damaged = 0
              AND (SELECT count(*) FROM updates u WHERE u.doc_id = d.doc_id AND u.seq IS NOT NULL) > $t
            ORDER BY d.doc_id
            """, ("$t", threshold));
        using var r = cmd.ExecuteReader();
        while (r.Read())
        {
            list.Add(new StoredDoc(r.GetString(0), r.GetString(1), r.GetInt64(2), false));
        }

        return list;
    });

    // ---- outbox ---------------------------------------------------------------------------

    /// <summary>
    /// Appends a sealed local edit to the outbox (creating the document row on first use).
    /// Returns once the row is committed.
    /// </summary>
    public long AppendLocalUpdate(string docId, string notebookId, string clientUpdateId, byte[] blob) => Locked(() =>
    {
        using var tx = _connection.BeginTransaction();
        Exec(tx, "INSERT OR IGNORE INTO docs (doc_id, notebook_id) VALUES ($d, $n)", ("$d", docId), ("$n", notebookId));
        var id = Scalar<long>(tx,
            "INSERT INTO updates (doc_id, seq, client_update_id, blob) VALUES ($d, NULL, $c, $b) RETURNING local_id",
            ("$d", docId), ("$c", clientUpdateId), ("$b", blob));
        tx.Commit();
        return id;
    });

    /// <summary>Number of updates waiting in the outbox.</summary>
    public int OutboxCount => Locked(() => (int)Scalar<long>(null, "SELECT count(*) FROM updates WHERE seq IS NULL"));

    /// <summary>Notebooks created locally that the server does not have yet.</summary>
    public IReadOnlyList<StoredNotebook> GetPendingNotebooks() => Locked(() => ReadNotebooks(null).Where(n => n.PendingPut).ToList());

    /// <summary>
    /// The next push: the oldest outbox entries that belong to one document, in the order they
    /// were made, up to <paramref name="maxCount"/> entries and (beyond the first) <paramref name="maxBytes"/> of blobs.
    /// </summary>
    public IReadOnlyList<OutboxEntry> PeekOutbox(int maxCount, long maxBytes) => Locked(() =>
    {
        var list = new List<OutboxEntry>();
        long bytes = 0;
        using var cmd = Cmd(null,
            """
            SELECT u.local_id, u.doc_id, d.notebook_id, u.client_update_id, u.blob
            FROM updates u JOIN docs d ON d.doc_id = u.doc_id
            WHERE u.seq IS NULL ORDER BY u.local_id LIMIT $l
            """, ("$l", maxCount));
        using var r = cmd.ExecuteReader();
        while (r.Read())
        {
            var entry = new OutboxEntry(r.GetInt64(0), r.GetString(1), r.GetString(2), r.GetString(3), (byte[])r[4]);
            if (list.Count > 0 && (entry.DocId != list[0].DocId || bytes + entry.Blob.Length > maxBytes))
            {
                break;
            }

            bytes += entry.Blob.Length;
            list.Add(entry);
        }

        return list;
    });

    /// <summary>Records the seqs the server assigned; the entries leave the outbox in one transaction.</summary>
    public void AcknowledgeOutbox(IReadOnlyList<(long LocalId, long Seq)> acknowledged) => Locked(() =>
    {
        using var tx = _connection.BeginTransaction();
        foreach (var (localId, seq) in acknowledged)
        {
            // If the same seq is already stored (the update also came back through /events), the copy goes.
            if (Exec(tx, "UPDATE OR IGNORE updates SET seq = $s WHERE local_id = $i AND seq IS NULL", ("$s", seq), ("$i", localId)) == 0)
            {
                Exec(tx, "DELETE FROM updates WHERE local_id = $i AND seq IS NULL", ("$i", localId));
            }
        }

        tx.Commit();
    });

    // ---- batches --------------------------------------------------------------------------

    /// <summary>
    /// Runs <paramref name="body"/> in one transaction: either everything it does (including the
    /// cursor it sets) is stored, or nothing is.
    /// </summary>
    public void Apply(Action<Batch> body)
    {
        ArgumentNullException.ThrowIfNull(body);
        Locked(() =>
        {
            using var tx = _connection.BeginTransaction();
            body(new Batch(this, tx));
            tx.Commit();
        });
    }

    /// <summary>The operations available inside <see cref="Apply"/>.</summary>
    public sealed class Batch
    {
        private readonly LocalStore _store;
        private readonly SqliteTransaction _tx;

        internal Batch(LocalStore store, SqliteTransaction tx)
        {
            _store = store;
            _tx = tx;
        }

        /// <summary>Stores an update event received from the server. A seq that is already stored is ignored.</summary>
        public void AddRemoteUpdate(string docId, string notebookId, long seq, byte[] blob)
        {
            _store.Exec(_tx, "INSERT OR IGNORE INTO docs (doc_id, notebook_id) VALUES ($d, $n)", ("$d", docId), ("$n", notebookId));
            _store.Exec(_tx, "INSERT OR IGNORE INTO updates (doc_id, seq, client_update_id, blob) VALUES ($d, $s, NULL, $b)",
                ("$d", docId), ("$s", seq), ("$b", blob));
        }

        /// <summary>
        /// Stores a snapshot and drops the acknowledged updates it covers. Outbox entries stay.
        /// An older snapshot than the stored one is ignored.
        /// </summary>
        public void SetSnapshot(string docId, string notebookId, long coveredSeq, byte[] blob)
        {
            _store.Exec(_tx, "INSERT OR IGNORE INTO docs (doc_id, notebook_id) VALUES ($d, $n)", ("$d", docId), ("$n", notebookId));
            if (_store.Exec(_tx, "UPDATE docs SET snapshot_seq = $c, snapshot_blob = $b WHERE doc_id = $d AND snapshot_seq <= $c",
                    ("$c", coveredSeq), ("$b", blob), ("$d", docId)) > 0)
            {
                _store.Exec(_tx, "DELETE FROM updates WHERE doc_id = $d AND seq IS NOT NULL AND seq <= $c", ("$d", docId), ("$c", coveredSeq));
            }
        }

        /// <summary>The stored snapshot's coveredSeq (0 when none), or null if the document is unknown.</summary>
        public long? GetSnapshotSeq(string docId) => _store.ReadDoc(_tx, docId)?.SnapshotSeq;

        /// <summary>Removes a document with its snapshot, updates and outbox entries.</summary>
        public void DropDoc(string docId)
        {
            _store.Exec(_tx, "DELETE FROM updates WHERE doc_id = $d", ("$d", docId));
            _store.Exec(_tx, "DELETE FROM docs WHERE doc_id = $d", ("$d", docId));
        }

        /// <summary>Flags a document whose stored history has a hole (a blob that did not open); it is never compacted from this device.</summary>
        public void MarkDamaged(string docId, string notebookId)
        {
            _store.Exec(_tx, "INSERT OR IGNORE INTO docs (doc_id, notebook_id) VALUES ($d, $n)", ("$d", docId), ("$n", notebookId));
            _store.Exec(_tx, "UPDATE docs SET damaged = 1 WHERE doc_id = $d", ("$d", docId));
        }

        /// <summary>
        /// Replaces the notebook list with the server's. Notebooks the server no longer has are
        /// removed together with their documents - except ones created here that were never
        /// pushed. Returns the removed notebooks with the ids of their documents.
        /// </summary>
        public IReadOnlyList<(string NotebookId, IReadOnlyList<string> DocIds)> ReplaceServerNotebooks(
            IReadOnlyList<(string NotebookId, byte[] WrappedKey)> serverNotebooks)
        {
            var onServer = serverNotebooks.Select(n => n.NotebookId).ToHashSet();
            var removed = new List<(string, IReadOnlyList<string>)>();
            foreach (var local in _store.ReadNotebooks(_tx))
            {
                if (!onServer.Contains(local.NotebookId) && !local.PendingPut)
                {
                    removed.Add((local.NotebookId, RemoveNotebook(local.NotebookId)));
                }
            }

            foreach (var (id, wrappedKey) in serverNotebooks)
            {
                _store.Exec(_tx,
                    """
                    INSERT INTO notebooks (notebook_id, wrapped_key, pending_put) VALUES ($n, $w, 0)
                    ON CONFLICT (notebook_id) DO UPDATE SET wrapped_key = excluded.wrapped_key, pending_put = 0
                    """, ("$n", id), ("$w", wrappedKey));
            }

            return removed;
        }

        /// <summary>Removes a notebook and every document in it. Returns the ids of those documents.</summary>
        public IReadOnlyList<string> RemoveNotebook(string notebookId)
        {
            var docs = new List<string>();
            using (var cmd = _store.Cmd(_tx, "SELECT doc_id FROM docs WHERE notebook_id = $n", ("$n", notebookId)))
            using (var r = cmd.ExecuteReader())
            {
                while (r.Read())
                {
                    docs.Add(r.GetString(0));
                }
            }

            _store.Exec(_tx, "DELETE FROM updates WHERE doc_id IN (SELECT doc_id FROM docs WHERE notebook_id = $n)", ("$n", notebookId));
            _store.Exec(_tx, "DELETE FROM docs WHERE notebook_id = $n", ("$n", notebookId));
            _store.Exec(_tx, "DELETE FROM notebooks WHERE notebook_id = $n", ("$n", notebookId));
            return docs;
        }

        /// <summary>Ids of the documents stored for a notebook.</summary>
        public IReadOnlyList<string> GetDocIds(string notebookId)
        {
            var docs = new List<string>();
            using var cmd = _store.Cmd(_tx, "SELECT doc_id FROM docs WHERE notebook_id = $n", ("$n", notebookId));
            using var r = cmd.ExecuteReader();
            while (r.Read())
            {
                docs.Add(r.GetString(0));
            }

            return docs;
        }

        /// <summary>Advances the event cursor (it never moves backwards).</summary>
        public void SetCursor(long seq)
        {
            if (seq > (_store.GetMeta(_tx, "cursor") is long current ? current : 0))
            {
                _store.SetMeta(_tx, "cursor", seq);
            }
        }

        /// <summary>Records that the first sync has completed.</summary>
        public void SetFirstSyncDone() => _store.SetMeta(_tx, "first_sync_done", 1L);
    }

    /// <inheritdoc />
    public void Dispose()
    {
        lock (_lock)
        {
            if (_disposed)
            {
                return;
            }

            _disposed = true;
            _connection.Dispose();
        }
    }

    // ---- plumbing -------------------------------------------------------------------------

    private void Migrate()
    {
        using var tx = _connection.BeginTransaction();
        var version = (int)Scalar<long>(tx, "PRAGMA user_version");
        if (version > SchemaVersion)
        {
            throw new InvalidOperationException($"The local store has schema v{version}; this version of TwoNote understands v{SchemaVersion}.");
        }

        if (version == 0)
        {
            Exec(tx, Schema);
            Exec(tx, $"PRAGMA user_version = {SchemaVersion}");
        }

        tx.Commit();
    }

    private T Locked<T>(Func<T> body)
    {
        lock (_lock)
        {
            ObjectDisposedException.ThrowIf(_disposed, this);
            return body();
        }
    }

    private void Locked(Action body)
    {
        lock (_lock)
        {
            ObjectDisposedException.ThrowIf(_disposed, this);
            body();
        }
    }

    private SqliteCommand Cmd(SqliteTransaction? tx, string sql, params (string Name, object? Value)[] parameters)
    {
        var cmd = _connection.CreateCommand();
        cmd.Transaction = tx;
        cmd.CommandText = sql;
        foreach (var (name, value) in parameters)
        {
            cmd.Parameters.AddWithValue(name, value ?? DBNull.Value);
        }

        return cmd;
    }

    private int Exec(SqliteTransaction? tx, string sql, params (string Name, object? Value)[] parameters)
    {
        using var cmd = Cmd(tx, sql, parameters);
        return cmd.ExecuteNonQuery();
    }

    private T Scalar<T>(SqliteTransaction? tx, string sql, params (string Name, object? Value)[] parameters)
    {
        using var cmd = Cmd(tx, sql, parameters);
        return (T)Convert.ChangeType(cmd.ExecuteScalar()!, typeof(T));
    }

    private object? GetMeta(SqliteTransaction? tx, string key)
    {
        using var cmd = Cmd(tx, "SELECT value FROM meta WHERE key = $k", ("$k", key));
        var value = cmd.ExecuteScalar();
        return value is DBNull ? null : value;
    }

    private void SetMeta(SqliteTransaction? tx, string key, object value) =>
        Exec(tx, "INSERT INTO meta (key, value) VALUES ($k, $v) ON CONFLICT (key) DO UPDATE SET value = excluded.value", ("$k", key), ("$v", value));

    private List<StoredNotebook> ReadNotebooks(SqliteTransaction? tx)
    {
        var list = new List<StoredNotebook>();
        using var cmd = Cmd(tx, "SELECT notebook_id, wrapped_key, pending_put FROM notebooks ORDER BY notebook_id");
        using var r = cmd.ExecuteReader();
        while (r.Read())
        {
            list.Add(new StoredNotebook(r.GetString(0), (byte[])r[1], r.GetInt64(2) != 0));
        }

        return list;
    }

    private StoredDoc? ReadDoc(SqliteTransaction? tx, string docId)
    {
        using var cmd = Cmd(tx, "SELECT doc_id, notebook_id, snapshot_seq, damaged FROM docs WHERE doc_id = $d", ("$d", docId));
        using var r = cmd.ExecuteReader();
        return r.Read() ? new StoredDoc(r.GetString(0), r.GetString(1), r.GetInt64(2), r.GetInt64(3) != 0) : null;
    }
}

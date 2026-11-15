using System.Security.Cryptography;
using System.Text.Json;
using Microsoft.Data.Sqlite;

namespace TwoNote.Server;

public sealed record AccountRow(
    string Username, string AccountId, byte[] KdfSalt, KdfParams KdfParams, byte[] AuthPublicKey, byte[] WrappedVaultKey);

public sealed record DeviceRow(string DeviceId, string Name, byte[] TokenHash, long CreatedAt, long LastSeenAt);

public sealed record EventRow(
    long Seq, string Type, string? DocId, string? NotebookId, string? DeviceId, long? CoveredSeq, byte[]? Blob);

/// <summary>
/// All persistence. SQLite in WAL mode; every write runs in one immediate transaction, and
/// writes are additionally serialised in-process so that seq assignment and head
/// notifications happen in commit order.
/// </summary>
public sealed class Store
{
    private const int CurrentSchemaVersion = 2;

    private static readonly string[] Migrations =
    [
        // v1
        """
        CREATE TABLE meta (key TEXT PRIMARY KEY, value BLOB NOT NULL) WITHOUT ROWID;
        CREATE TABLE state (id INTEGER PRIMARY KEY CHECK (id = 1), head INTEGER NOT NULL);
        INSERT INTO state (id, head) VALUES (1, 0);
        CREATE TABLE account (
            id INTEGER PRIMARY KEY CHECK (id = 1),
            username TEXT NOT NULL,
            account_id TEXT NOT NULL,
            kdf_salt BLOB NOT NULL,
            kdf_params TEXT NOT NULL,
            auth_public_key BLOB NOT NULL,
            wrapped_vault_key BLOB NOT NULL,
            created_at INTEGER NOT NULL);
        CREATE TABLE devices (
            device_id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            token_hash BLOB NOT NULL UNIQUE,
            created_at INTEGER NOT NULL,
            last_seen_at INTEGER NOT NULL) WITHOUT ROWID;
        CREATE TABLE notebooks (notebook_id TEXT PRIMARY KEY, wrapped_key BLOB NOT NULL) WITHOUT ROWID;
        CREATE TABLE docs (
            doc_id TEXT PRIMARY KEY,
            notebook_id TEXT NOT NULL,
            snapshot_seq INTEGER NOT NULL DEFAULT 0,
            snapshot_blob BLOB);
        CREATE INDEX docs_notebook ON docs (notebook_id);
        CREATE TABLE events (
            seq INTEGER PRIMARY KEY,
            type TEXT NOT NULL,
            doc_id TEXT,
            notebook_id TEXT,
            device_id TEXT,
            covered_seq INTEGER,
            blob BLOB);
        CREATE INDEX events_doc ON events (doc_id, seq);
        CREATE INDEX events_notebook ON events (notebook_id);
        CREATE TABLE update_ids (
            client_update_id TEXT PRIMARY KEY,
            doc_id TEXT NOT NULL,
            seq INTEGER NOT NULL) WITHOUT ROWID;
        CREATE INDEX update_ids_doc ON update_ids (doc_id);
        """,
        // v2: tombstones, so a push to a deleted document is refused instead of re-creating it.
        """
        CREATE TABLE deleted_docs (
            doc_id TEXT PRIMARY KEY,
            notebook_id TEXT NOT NULL,
            deleted_seq INTEGER NOT NULL) WITHOUT ROWID;
        CREATE INDEX deleted_docs_notebook ON deleted_docs (notebook_id);
        """,
    ];

    private readonly string _connectionString;
    private readonly HeadHub _hub;
    private readonly TimeProvider _time;
    private readonly Lock _writeLock = new();

    public byte[] ServerSecret { get; }

    public Store(TwoNoteOptions options, HeadHub hub, TimeProvider time, ILogger<Store> logger)
    {
        _hub = hub;
        _time = time;
        Directory.CreateDirectory(options.DataDir);
        _connectionString = new SqliteConnectionStringBuilder
        {
            DataSource = options.DatabasePath,
            Mode = SqliteOpenMode.ReadWriteCreate,
            Pooling = true,
        }.ToString();

        SqliteConnection first;
        try
        {
            first = Open();
        }
        catch (SqliteException e)
        {
            throw new InvalidOperationException(
                $"Cannot open {options.DatabasePath}: {e.Message}. Check that the data directory exists and is writable by the user the server runs as.", e);
        }

        using (var c = first)
        {
            var mode = Scalar<string>(c, null, "PRAGMA journal_mode = WAL");
            if (!string.Equals(mode, "wal", StringComparison.OrdinalIgnoreCase))
                logger.LogWarning("SQLite journal mode is {Mode}, expected WAL", mode);
        }

        var version = Migrate();
        ServerSecret = LoadOrCreateSecret();
        using (var c = Open()) _hub.Publish(Scalar<long>(c, null, "SELECT head FROM state"));
        logger.LogInformation("Database ready at {Path} (schema v{Version}, head {Head})",
            options.DatabasePath, version, _hub.Head);
    }

    // ---- plumbing -------------------------------------------------------------------------

    private SqliteConnection Open()
    {
        var c = new SqliteConnection(_connectionString);
        c.Open();
        return c;
    }

    private static SqliteCommand Cmd(SqliteConnection c, SqliteTransaction? tx, string sql, params (string Name, object? Value)[] ps)
    {
        var cmd = c.CreateCommand();
        cmd.Transaction = tx;
        cmd.CommandText = sql;
        foreach (var (name, value) in ps) cmd.Parameters.AddWithValue(name, value ?? DBNull.Value);
        return cmd;
    }

    private static int Exec(SqliteConnection c, SqliteTransaction? tx, string sql, params (string Name, object? Value)[] ps)
    {
        using var cmd = Cmd(c, tx, sql, ps);
        return cmd.ExecuteNonQuery();
    }

    private static T? Scalar<T>(SqliteConnection c, SqliteTransaction? tx, string sql, params (string Name, object? Value)[] ps)
    {
        using var cmd = Cmd(c, tx, sql, ps);
        var value = cmd.ExecuteScalar();
        return value is null or DBNull ? default : (T)Convert.ChangeType(value, Nullable.GetUnderlyingType(typeof(T)) ?? typeof(T));
    }

    private T Write<T>(Func<SqliteConnection, SqliteTransaction, T> body)
    {
        lock (_writeLock)
        {
            using var c = Open();
            using var tx = c.BeginTransaction(deferred: false);
            var result = body(c, tx);
            var head = Scalar<long>(c, tx, "SELECT head FROM state");
            tx.Commit();
            _hub.Publish(head);
            return result;
        }
    }

    private T Read<T>(Func<SqliteConnection, SqliteTransaction, T> body)
    {
        using var c = Open();
        using var tx = c.BeginTransaction(deferred: true);
        return body(c, tx);
    }

    private int Migrate()
    {
        lock (_writeLock)
        {
            using var c = Open();
            using var tx = c.BeginTransaction(deferred: false);
            Exec(c, tx, "CREATE TABLE IF NOT EXISTS schema_version (version INTEGER NOT NULL)");
            var version = Scalar<int?>(c, tx, "SELECT max(version) FROM schema_version") ?? 0;
            if (version > CurrentSchemaVersion)
                throw new InvalidOperationException(
                    $"Database schema v{version} is newer than this server understands (v{CurrentSchemaVersion}).");
            for (var v = version; v < CurrentSchemaVersion; v++) Exec(c, tx, Migrations[v]);
            if (version != CurrentSchemaVersion)
            {
                Exec(c, tx, "DELETE FROM schema_version");
                Exec(c, tx, "INSERT INTO schema_version (version) VALUES ($v)", ("$v", CurrentSchemaVersion));
            }
            tx.Commit();
            return CurrentSchemaVersion;
        }
    }

    private byte[] LoadOrCreateSecret() => Write((c, tx) =>
    {
        using (var cmd = Cmd(c, tx, "SELECT value FROM meta WHERE key = 'server_secret'"))
            if (cmd.ExecuteScalar() is byte[] existing) return existing;
        var secret = RandomNumberGenerator.GetBytes(32);
        Exec(c, tx, "INSERT INTO meta (key, value) VALUES ('server_secret', $v)", ("$v", secret));
        return secret;
    });

    private long Now => _time.GetUtcNow().ToUnixTimeMilliseconds();

    private static long NextSeq(SqliteConnection c, SqliteTransaction tx) =>
        Scalar<long>(c, tx, "UPDATE state SET head = head + 1 WHERE id = 1 RETURNING head");

    private static long AppendEvent(SqliteConnection c, SqliteTransaction tx, string type,
        string? docId = null, string? notebookId = null, string? deviceId = null, long? coveredSeq = null, byte[]? blob = null)
    {
        var seq = NextSeq(c, tx);
        Exec(c, tx,
            "INSERT INTO events (seq, type, doc_id, notebook_id, device_id, covered_seq, blob) VALUES ($s, $t, $d, $n, $dev, $c, $b)",
            ("$s", seq), ("$t", type), ("$d", docId), ("$n", notebookId), ("$dev", deviceId), ("$c", coveredSeq), ("$b", blob));
        return seq;
    }

    private static long HeadOf(SqliteConnection c, SqliteTransaction tx) => Scalar<long>(c, tx, "SELECT head FROM state");

    // ---- account and devices --------------------------------------------------------------

    public bool HasAccount() => Read((c, tx) => Scalar<long>(c, tx, "SELECT count(*) FROM account") > 0);

    public AccountRow? GetAccount() => Read((c, tx) =>
    {
        using var cmd = Cmd(c, tx,
            "SELECT username, account_id, kdf_salt, kdf_params, auth_public_key, wrapped_vault_key FROM account WHERE id = 1");
        using var r = cmd.ExecuteReader();
        if (!r.Read()) return null;
        return new AccountRow(r.GetString(0), r.GetString(1), (byte[])r[2],
            JsonSerializer.Deserialize<KdfParams>(r.GetString(3), Json.Options)!, (byte[])r[4], (byte[])r[5]);
    });

    /// <summary>Creates the account and its first device; 403 once an account exists.</summary>
    public string Register(AccountRow account, string deviceName, byte[] tokenHash) => Write((c, tx) =>
    {
        if (Scalar<long>(c, tx, "SELECT count(*) FROM account") > 0)
            throw new ApiException(403, "registration_closed", "An account already exists on this server");
        var now = Now;
        Exec(c, tx,
            """
            INSERT INTO account (id, username, account_id, kdf_salt, kdf_params, auth_public_key, wrapped_vault_key, created_at)
            VALUES (1, $u, $a, $s, $p, $k, $w, $now)
            """,
            ("$u", account.Username), ("$a", account.AccountId), ("$s", account.KdfSalt),
            ("$p", JsonSerializer.Serialize(account.KdfParams, Json.Options)), ("$k", account.AuthPublicKey),
            ("$w", account.WrappedVaultKey), ("$now", now));
        var deviceId = Codec.NewId();
        Exec(c, tx,
            "INSERT INTO devices (device_id, name, token_hash, created_at, last_seen_at) VALUES ($d, $n, $h, $now, $now)",
            ("$d", deviceId), ("$n", deviceName), ("$h", tokenHash), ("$now", now));
        return deviceId;
    });

    /// <summary>Issues a token for a new device, or replaces the token of the given one.</summary>
    public string Login(string? deviceId, string deviceName, byte[] tokenHash) => Write((c, tx) =>
    {
        var id = deviceId ?? Codec.NewId();
        var now = Now;
        Exec(c, tx,
            """
            INSERT INTO devices (device_id, name, token_hash, created_at, last_seen_at) VALUES ($d, $n, $h, $now, $now)
            ON CONFLICT (device_id) DO UPDATE SET name = excluded.name, token_hash = excluded.token_hash, last_seen_at = excluded.last_seen_at
            """,
            ("$d", id), ("$n", deviceName), ("$h", tokenHash), ("$now", now));
        return id;
    });

    public DeviceRow? FindDevice(byte[] tokenHash) => Read((c, tx) =>
    {
        using var cmd = Cmd(c, tx,
            "SELECT device_id, name, token_hash, created_at, last_seen_at FROM devices WHERE token_hash = $h", ("$h", tokenHash));
        using var r = cmd.ExecuteReader();
        if (!r.Read()) return null;
        var row = new DeviceRow(r.GetString(0), r.GetString(1), (byte[])r[2], r.GetInt64(3), r.GetInt64(4));
        return CryptographicOperations.FixedTimeEquals(row.TokenHash, tokenHash) ? row : null;
    });

    public void TouchDevice(string deviceId) => Write((c, tx) =>
        Exec(c, tx, "UPDATE devices SET last_seen_at = $now WHERE device_id = $d", ("$now", Now), ("$d", deviceId)));

    public List<DeviceRow> ListDevices() => Read((c, tx) =>
    {
        var list = new List<DeviceRow>();
        using var cmd = Cmd(c, tx,
            "SELECT device_id, name, token_hash, created_at, last_seen_at FROM devices ORDER BY created_at, device_id");
        using var r = cmd.ExecuteReader();
        while (r.Read()) list.Add(new DeviceRow(r.GetString(0), r.GetString(1), (byte[])r[2], r.GetInt64(3), r.GetInt64(4)));
        return list;
    });

    public void DeleteDevice(string deviceId)
    {
        var removed = Write((c, tx) => Exec(c, tx, "DELETE FROM devices WHERE device_id = $d", ("$d", deviceId)));
        if (removed == 0) throw new ApiException(404, "unknown_device", "No such device");
        _hub.Revoke([deviceId]);
    }

    /// <summary>Replaces the credentials and revokes every device except the caller.</summary>
    public void Rekey(byte[] kdfSalt, KdfParams kdfParams, byte[] authPublicKey, byte[] wrappedVaultKey, string keepDeviceId)
    {
        var revoked = Write((c, tx) =>
        {
            Exec(c, tx,
                "UPDATE account SET kdf_salt = $s, kdf_params = $p, auth_public_key = $k, wrapped_vault_key = $w WHERE id = 1",
                ("$s", kdfSalt), ("$p", JsonSerializer.Serialize(kdfParams, Json.Options)), ("$k", authPublicKey), ("$w", wrappedVaultKey));
            var ids = new List<string>();
            using var cmd = Cmd(c, tx, "DELETE FROM devices WHERE device_id <> $d RETURNING device_id", ("$d", keepDeviceId));
            using var r = cmd.ExecuteReader();
            while (r.Read()) ids.Add(r.GetString(0));
            return ids;
        });
        _hub.Revoke(revoked);
    }

    // ---- notebooks ------------------------------------------------------------------------

    public List<(string NotebookId, byte[] WrappedKey)> ListNotebooks() => Read((c, tx) =>
    {
        var list = new List<(string, byte[])>();
        using var cmd = Cmd(c, tx, "SELECT notebook_id, wrapped_key FROM notebooks ORDER BY notebook_id");
        using var r = cmd.ExecuteReader();
        while (r.Read()) list.Add((r.GetString(0), (byte[])r[1]));
        return list;
    });

    public long PutNotebook(string notebookId, byte[] wrappedKey) => Write((c, tx) =>
    {
        using (var cmd = Cmd(c, tx, "SELECT wrapped_key FROM notebooks WHERE notebook_id = $n", ("$n", notebookId)))
            if (cmd.ExecuteScalar() is byte[] existing && existing.AsSpan().SequenceEqual(wrappedKey))
                return HeadOf(c, tx); // an identical retry changes nothing and tells nobody
        Exec(c, tx,
            "INSERT INTO notebooks (notebook_id, wrapped_key) VALUES ($n, $w) ON CONFLICT (notebook_id) DO UPDATE SET wrapped_key = excluded.wrapped_key",
            ("$n", notebookId), ("$w", wrappedKey));
        return AppendEvent(c, tx, "notebooksChanged");
    });

    public long DeleteNotebook(string notebookId) => Write((c, tx) =>
    {
        if (Exec(c, tx, "DELETE FROM notebooks WHERE notebook_id = $n", ("$n", notebookId)) == 0)
            throw new ApiException(404, "unknown_notebook", "No such notebook");
        Exec(c, tx, "DELETE FROM update_ids WHERE doc_id IN (SELECT doc_id FROM docs WHERE notebook_id = $n)", ("$n", notebookId));
        Exec(c, tx, "DELETE FROM events WHERE notebook_id = $n", ("$n", notebookId));
        Exec(c, tx, "DELETE FROM docs WHERE notebook_id = $n", ("$n", notebookId));
        // Pushes to this notebook now fail with unknown_notebook, so its tombstones are not needed.
        Exec(c, tx, "DELETE FROM deleted_docs WHERE notebook_id = $n", ("$n", notebookId));
        return AppendEvent(c, tx, "notebooksChanged");
    });

    // ---- documents ------------------------------------------------------------------------

    public List<(string DocId, string NotebookId, long SnapshotSeq)> ListDocs() => Read((c, tx) =>
    {
        var list = new List<(string, string, long)>();
        using var cmd = Cmd(c, tx, "SELECT doc_id, notebook_id, snapshot_seq FROM docs ORDER BY doc_id");
        using var r = cmd.ExecuteReader();
        while (r.Read()) list.Add((r.GetString(0), r.GetString(1), r.GetInt64(2)));
        return list;
    });

    public (List<long> Seqs, long Head) PushUpdates(
        string docId, string notebookId, string deviceId, IReadOnlyList<(string ClientUpdateId, byte[] Blob)> updates) =>
        Write((c, tx) =>
        {
            if (Scalar<long>(c, tx, "SELECT count(*) FROM notebooks WHERE notebook_id = $n", ("$n", notebookId)) == 0)
                throw new ApiException(404, "unknown_notebook", "No such notebook");

            if (Scalar<long>(c, tx, "SELECT count(*) FROM deleted_docs WHERE doc_id = $d", ("$d", docId)) > 0)
                throw new ApiException(410, "doc_deleted", "The document was deleted");

            var owner = Scalar<string>(c, tx, "SELECT notebook_id FROM docs WHERE doc_id = $d", ("$d", docId));
            if (owner is null)
                Exec(c, tx, "INSERT INTO docs (doc_id, notebook_id) VALUES ($d, $n)", ("$d", docId), ("$n", notebookId));
            else if (owner != notebookId)
                throw new ApiException(409, "notebook_mismatch", "The document belongs to a different notebook");

            var seqs = new List<long>(updates.Count);
            foreach (var (clientUpdateId, blob) in updates)
            {
                long? known = null;
                using (var cmd = Cmd(c, tx, "SELECT doc_id, seq FROM update_ids WHERE client_update_id = $u", ("$u", clientUpdateId)))
                using (var r = cmd.ExecuteReader())
                {
                    if (r.Read())
                    {
                        if (r.GetString(0) != docId)
                            throw new ApiException(409, "update_id_conflict", "clientUpdateId was already used for another document");
                        known = r.GetInt64(1);
                    }
                }

                if (known is { } original)
                {
                    seqs.Add(original);
                    continue;
                }

                var seq = AppendEvent(c, tx, "update", docId, notebookId, deviceId, blob: blob);
                Exec(c, tx, "INSERT INTO update_ids (client_update_id, doc_id, seq) VALUES ($u, $d, $s)",
                    ("$u", clientUpdateId), ("$d", docId), ("$s", seq));
                seqs.Add(seq);
            }

            return (seqs, HeadOf(c, tx));
        });

    public (long CoveredSeq, byte[] Blob)? GetSnapshot(string docId) => Read<(long, byte[])?>((c, tx) =>
    {
        using var cmd = Cmd(c, tx, "SELECT snapshot_seq, snapshot_blob FROM docs WHERE doc_id = $d", ("$d", docId));
        using var r = cmd.ExecuteReader();
        if (!r.Read() || r.IsDBNull(1)) return null;
        return (r.GetInt64(0), (byte[])r[1]);
    });

    public (long Seq, long Head) PutSnapshot(string docId, long coveredSeq, byte[] blob) => Write((c, tx) =>
    {
        string notebookId;
        long stored;
        using (var cmd = Cmd(c, tx, "SELECT notebook_id, snapshot_seq FROM docs WHERE doc_id = $d", ("$d", docId)))
        using (var r = cmd.ExecuteReader())
        {
            if (!r.Read()) throw new ApiException(404, "unknown_doc", "No such document");
            notebookId = r.GetString(0);
            stored = r.GetInt64(1);
        }

        if (coveredSeq < stored)
            throw new ApiException(409, "stale_snapshot", $"A snapshot covering seq {stored} is already stored");
        if (coveredSeq > HeadOf(c, tx))
            throw ApiException.Invalid("coveredSeq is beyond head");

        // The covered updates go, and so do earlier snapshot markers for this document: the
        // new marker has a higher seq, so every cursor still passes one.
        Exec(c, tx,
            "DELETE FROM events WHERE doc_id = $d AND ((type = 'update' AND seq <= $c) OR type = 'snapshot')",
            ("$d", docId), ("$c", coveredSeq));
        Exec(c, tx, "UPDATE docs SET snapshot_seq = $c, snapshot_blob = $b WHERE doc_id = $d",
            ("$c", coveredSeq), ("$b", blob), ("$d", docId));
        var seq = AppendEvent(c, tx, "snapshot", docId, notebookId, coveredSeq: coveredSeq);
        return (seq, seq);
    });

    public long DeleteDoc(string docId) => Write((c, tx) =>
    {
        var notebookId = Scalar<string>(c, tx, "SELECT notebook_id FROM docs WHERE doc_id = $d", ("$d", docId))
            ?? throw new ApiException(404, "unknown_doc", "No such document");
        Exec(c, tx, "DELETE FROM events WHERE doc_id = $d", ("$d", docId));
        Exec(c, tx, "DELETE FROM update_ids WHERE doc_id = $d", ("$d", docId));
        Exec(c, tx, "DELETE FROM docs WHERE doc_id = $d", ("$d", docId));
        var seq = AppendEvent(c, tx, "docDeleted", docId, notebookId);
        Exec(c, tx, "INSERT INTO deleted_docs (doc_id, notebook_id, deleted_seq) VALUES ($d, $n, $s)",
            ("$d", docId), ("$n", notebookId), ("$s", seq));
        return seq;
    });

    // ---- events ---------------------------------------------------------------------------

    public (List<EventRow> Events, long Head, bool More) GetEvents(long after, int limit, long byteBudget) => Read((c, tx) =>
    {
        var head = HeadOf(c, tx);
        var events = new List<EventRow>();
        var more = false;
        long bytes = 0;
        using var cmd = Cmd(c, tx,
            "SELECT seq, type, doc_id, notebook_id, device_id, covered_seq, blob FROM events WHERE seq > $a ORDER BY seq LIMIT $l",
            ("$a", after), ("$l", limit + 1));
        using var r = cmd.ExecuteReader();
        while (r.Read())
        {
            var blobLength = r.IsDBNull(6) ? 0 : r.GetBytes(6, 0, null, 0, 0);
            if (events.Count == limit || (events.Count > 0 && bytes + blobLength > byteBudget))
            {
                more = true;
                break;
            }

            bytes += blobLength;
            events.Add(new EventRow(
                r.GetInt64(0), r.GetString(1),
                r.IsDBNull(2) ? null : r.GetString(2),
                r.IsDBNull(3) ? null : r.GetString(3),
                r.IsDBNull(4) ? null : r.GetString(4),
                r.IsDBNull(5) ? null : r.GetInt64(5),
                r.IsDBNull(6) ? null : (byte[])r[6]));
        }

        return (events, head, more);
    });
}

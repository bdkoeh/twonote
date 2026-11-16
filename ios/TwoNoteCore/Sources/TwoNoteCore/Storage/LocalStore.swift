import Foundation
import SQLite3
import TwoNoteCrypto

/// The non-secret facts a device remembers about its account. The Secret Key and the session
/// token are deliberately not here: they live in the `SecretStore`.
public struct AccountRecord: Codable, Equatable, Sendable {
    public var username: String
    public var accountId: String
    public var deviceId: String
    public var deviceName: String
    @Base64URL public var kdfSalt: Data
    public var kdfParams: KdfParams
    @Base64URL public var wrappedVaultKey: Data

    public init(
        username: String, accountId: String, deviceId: String, deviceName: String, kdfSalt: Data, kdfParams: KdfParams,
        wrappedVaultKey: Data
    ) {
        self.username = username
        self.accountId = accountId
        self.deviceId = deviceId
        self.deviceName = deviceName
        self.kdfSalt = kdfSalt
        self.kdfParams = kdfParams
        self.wrappedVaultKey = wrappedVaultKey
    }
}

/// A notebook as stored locally: its wrapped key, and whether the server has it yet.
public struct StoredNotebook: Equatable, Sendable {
    public var notebookId: String
    public var wrappedKey: Data
    public var pendingPut: Bool
}

/// A document row of the local store.
public struct StoredDoc: Equatable, Sendable {
    public var docId: String
    public var notebookId: String
    public var snapshotSeq: Int64
    public var damaged: Bool
}

/// The ciphertext a document is rebuilt from: the snapshot (if any) and every update after it, in arrival order.
public struct StoredDocContent: Equatable, Sendable {
    public var docId: String
    public var notebookId: String
    public var snapshotSeq: Int64
    public var snapshotBlob: Data?
    public var updateBlobs: [Data]
}

/// A stamp of a stored document's content: equal stamps mean nothing was added or replaced.
public struct DocumentVersion: Hashable, Sendable {
    public var snapshotSeq: Int64
    public var lastUpdate: Int64
    public var updates: Int64
}

/// A sealed local edit that the server has not acknowledged yet.
public struct OutboxEntry: Equatable, Sendable {
    public var localId: Int64
    public var docId: String
    public var notebookId: String
    public var clientUpdateId: String
    public var blob: Data
}

/// SQLite reported an error. The message is SQLite's own and never contains stored values.
public struct LocalStoreError: Error, Equatable, Sendable, CustomStringConvertible {
    public let code: Int32
    public let message: String

    public var description: String { "SQLite error \(code): \(message)" }
}

/// The store was used after `close()`.
public struct LocalStoreClosedError: Error, Sendable {}

/// The per-device SQLite file. It holds only what the server may also hold - sealed updates and
/// snapshots, wrapped keys - plus the outbox, the event cursor and non-secret account metadata.
/// Nothing in it is readable without the vault key; decrypted content never reaches it.
///
/// Schema (version 1, the same tables as the Windows client's store):
///
///     meta(key TEXT PRIMARY KEY, value)            "account" (JSON), "cursor", "first_sync_done"
///     notebooks(notebook_id PK, wrapped_key BLOB, pending_put INTEGER)
///     docs(doc_id PK, notebook_id, snapshot_seq INTEGER, snapshot_blob BLOB, damaged INTEGER)
///     updates(local_id INTEGER PK AUTOINCREMENT, doc_id, seq INTEGER, client_update_id, blob BLOB)
///
/// `updates` holds one row per sealed update in the order this device learned of it. `seq` is
/// the server's sequence number; NULL means the row is still in the outbox, and a row leaves
/// the outbox only by getting its seq from an acknowledgement.
///
/// Thread safe: every call takes one lock around one connection. All calls block on disk I/O,
/// so the sync layer makes them off the main actor.
public final class LocalStore: @unchecked Sendable {
    private static let schemaVersion: Int64 = 1

    private static let schema = """
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
        CREATE TABLE updates (
            local_id INTEGER PRIMARY KEY AUTOINCREMENT,
            doc_id TEXT NOT NULL,
            seq INTEGER,
            client_update_id TEXT,
            blob BLOB NOT NULL);
        CREATE INDEX updates_doc ON updates (doc_id, local_id);
        CREATE UNIQUE INDEX updates_seq ON updates (seq) WHERE seq IS NOT NULL;
        CREATE INDEX updates_outbox ON updates (local_id) WHERE seq IS NULL;
        """

    private let lock = NSLock()
    private var db: Database?

    private init(db: Database) {
        self.db = db
    }

    deinit {
        db?.close()
    }

    /// Opens (creating if necessary) the store at `path`.
    public static func open(path: String) throws -> LocalStore {
        let directory = URL(fileURLWithPath: path).deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let db = try Database(path: path)
        do {
            try db.exec("PRAGMA journal_mode = WAL")
            try db.exec("PRAGMA synchronous = NORMAL")
            try db.transaction {
                let version = try db.scalar("PRAGMA user_version") ?? 0
                if version > schemaVersion {
                    throw LocalStoreError(
                        code: SQLITE_ERROR,
                        message: "The local store has schema v\(version); this version of TwoNote understands v\(schemaVersion).")
                }
                if version == 0 {
                    try db.exec(schema)
                    try db.exec("PRAGMA user_version = \(schemaVersion)")
                }
            }
        } catch {
            db.close()
            throw error
        }
        return LocalStore(db: db)
    }

    /// Closes the file. Every later call throws `LocalStoreClosedError`.
    public func close() {
        lock.lock()
        defer { lock.unlock() }
        db?.close()
        db = nil
    }

    // MARK: Account and cursor

    /// The enrolled account, or nil on a device that has none yet.
    public func account() throws -> AccountRecord? {
        try locked { db in
            guard let json = try db.query("SELECT value FROM meta WHERE key = 'account'", [], { $0.text(0) }).first else {
                return nil
            }
            return try JSONDecoder().decode(AccountRecord.self, from: Data(json.utf8))
        }
    }

    /// Stores or replaces the account record.
    public func saveAccount(_ account: AccountRecord) throws {
        let json = String(decoding: try JSONEncoder().encode(account), as: UTF8.self)
        try locked { db in try Self.setMeta(db, "account", .text(json)) }
    }

    /// The seq of the last event this device has applied (0 before the first sync).
    public func cursor() throws -> Int64 {
        try locked { db in try Self.metaInt(db, "cursor") }
    }

    /// True once the first sync of PROTOCOL.md section 4 step 1 has completed.
    public func firstSyncDone() throws -> Bool {
        try locked { db in try Self.metaInt(db, "first_sync_done") != 0 }
    }

    // MARK: Notebooks

    /// Every notebook known locally.
    public func notebooks() throws -> [StoredNotebook] {
        try locked { db in try Self.readNotebooks(db) }
    }

    /// Stores a notebook created on this device; it is sent to the server by the next sync.
    public func addLocalNotebook(_ notebookId: String, wrappedKey: Data) throws {
        try locked { db in
            _ = try db.run(
                "INSERT INTO notebooks (notebook_id, wrapped_key, pending_put) VALUES (?, ?, 1)", [.text(notebookId), .blob(wrappedKey)])
        }
    }

    /// Records that the server now has this notebook.
    public func markNotebookPushed(_ notebookId: String) throws {
        try locked { db in _ = try db.run("UPDATE notebooks SET pending_put = 0 WHERE notebook_id = ?", [.text(notebookId)]) }
    }

    /// Notebooks created locally that the server does not have yet.
    public func pendingNotebooks() throws -> [StoredNotebook] {
        try notebooks().filter(\.pendingPut)
    }

    // MARK: Documents

    /// Every document known locally.
    public func docs() throws -> [StoredDoc] {
        try locked { db in
            try db.query("SELECT doc_id, notebook_id, snapshot_seq, damaged FROM docs ORDER BY doc_id", []) {
                StoredDoc(docId: $0.text(0), notebookId: $0.text(1), snapshotSeq: $0.int(2), damaged: $0.int(3) != 0)
            }
        }
    }

    /// One document row, or nil.
    public func doc(_ docId: String) throws -> StoredDoc? {
        try locked { db in try Self.readDoc(db, docId) }
    }

    /// The ciphertext of one document, or nil if nothing is stored for it.
    public func loadDoc(_ docId: String) throws -> StoredDocContent? {
        try locked { db in
            try db.transaction {
                guard var content = try db.query(
                    "SELECT notebook_id, snapshot_seq, snapshot_blob FROM docs WHERE doc_id = ?", [.text(docId)],
                    { StoredDocContent(docId: docId, notebookId: $0.text(0), snapshotSeq: $0.int(1), snapshotBlob: $0.blob(2), updateBlobs: []) }
                ).first else {
                    return nil
                }
                content.updateBlobs = try db.query(
                    "SELECT blob FROM updates WHERE doc_id = ? ORDER BY local_id", [.text(docId)], { $0.blob(0) ?? Data() })
                return content
            }
        }
    }

    /// Documents with more than `threshold` acknowledged updates since their last snapshot, and no damage.
    public func docsToCompact(threshold: Int) throws -> [StoredDoc] {
        try locked { db in
            try db.query(
                """
                SELECT d.doc_id, d.notebook_id, d.snapshot_seq FROM docs d
                WHERE d.damaged = 0
                  AND (SELECT count(*) FROM updates u WHERE u.doc_id = d.doc_id AND u.seq IS NOT NULL) > ?
                ORDER BY d.doc_id
                """, [.int(Int64(threshold))]
            ) {
                StoredDoc(docId: $0.text(0), notebookId: $0.text(1), snapshotSeq: $0.int(2), damaged: false)
            }
        }
    }

    // MARK: Outbox

    /// Appends a sealed local edit to the outbox (creating the document row on first use).
    /// Returns once the row is committed.
    @discardableResult
    public func appendLocalUpdate(docId: String, notebookId: String, clientUpdateId: String, blob: Data) throws -> Int64 {
        try locked { db in
            try db.transaction {
                _ = try db.run("INSERT OR IGNORE INTO docs (doc_id, notebook_id) VALUES (?, ?)", [.text(docId), .text(notebookId)])
                _ = try db.run(
                    "INSERT INTO updates (doc_id, seq, client_update_id, blob) VALUES (?, NULL, ?, ?)",
                    [.text(docId), .text(clientUpdateId), .blob(blob)])
                return db.lastInsertRowId
            }
        }
    }

    /// Number of updates waiting in the outbox.
    public func outboxCount() throws -> Int {
        try locked { db in Int(try db.scalar("SELECT count(*) FROM updates WHERE seq IS NULL") ?? 0) }
    }

    /// How many documents have updates waiting in the outbox: page documents, and notebook
    /// trees (a tree's document id is its notebook's id).
    public func outboxDocuments() throws -> (pages: Int, notebooks: Int) {
        try locked { db in
            let trees = try db.query(
                """
                SELECT DISTINCT u.doc_id, d.notebook_id FROM updates u JOIN docs d ON d.doc_id = u.doc_id
                WHERE u.seq IS NULL
                """, []
            ) { $0.text(0) == $0.text(1) }
            let notebooks = trees.filter { $0 }.count
            return (trees.count - notebooks, notebooks)
        }
    }

    /// A stamp per document that changes whenever its stored content does.
    public func docVersions() throws -> [String: DocumentVersion] {
        try locked { db in
            let rows = try db.query(
                """
                SELECT d.doc_id, d.snapshot_seq,
                       (SELECT ifnull(max(u.local_id), 0) FROM updates u WHERE u.doc_id = d.doc_id),
                       (SELECT count(*) FROM updates u WHERE u.doc_id = d.doc_id)
                FROM docs d
                """, []
            ) { ($0.text(0), DocumentVersion(snapshotSeq: $0.int(1), lastUpdate: $0.int(2), updates: $0.int(3))) }
            return Dictionary(rows, uniquingKeysWith: { first, _ in first })
        }
    }

    /// The next push: the oldest outbox entries that belong to one document, in the order they
    /// were made, up to `maxCount` entries and (beyond the first) `maxBytes` of blobs.
    public func peekOutbox(maxCount: Int, maxBytes: Int) throws -> [OutboxEntry] {
        try locked { db in
            let rows = try db.query(
                """
                SELECT u.local_id, u.doc_id, d.notebook_id, u.client_update_id, u.blob
                FROM updates u JOIN docs d ON d.doc_id = u.doc_id
                WHERE u.seq IS NULL ORDER BY u.local_id LIMIT ?
                """, [.int(Int64(maxCount))]
            ) {
                OutboxEntry(localId: $0.int(0), docId: $0.text(1), notebookId: $0.text(2), clientUpdateId: $0.text(3), blob: $0.blob(4) ?? Data())
            }
            var list: [OutboxEntry] = []
            var bytes = 0
            for entry in rows {
                if let first = list.first, entry.docId != first.docId || bytes + entry.blob.count > maxBytes {
                    break
                }
                bytes += entry.blob.count
                list.append(entry)
            }
            return list
        }
    }

    /// Records the seqs the server assigned; the entries leave the outbox in one transaction.
    public func acknowledgeOutbox(_ acknowledged: [(localId: Int64, seq: Int64)]) throws {
        try locked { db in
            try db.transaction {
                for (localId, seq) in acknowledged {
                    // If the same seq is already stored (the update also came back through /events), the copy goes.
                    if try db.run("UPDATE OR IGNORE updates SET seq = ? WHERE local_id = ? AND seq IS NULL", [.int(seq), .int(localId)]) == 0 {
                        _ = try db.run("DELETE FROM updates WHERE local_id = ? AND seq IS NULL", [.int(localId)])
                    }
                }
            }
        }
    }

    // MARK: Batches

    /// Runs `body` in one transaction: either everything it does (including the cursor it sets)
    /// is stored, or - when it throws - nothing is.
    public func apply<R>(_ body: (Batch) throws -> R) throws -> R {
        try locked { db in
            try db.transaction { try body(Batch(db: db)) }
        }
    }

    /// The operations available inside `apply`.
    public struct Batch {
        fileprivate let db: Database

        /// Stores an update event received from the server. A seq that is already stored is ignored.
        public func addRemoteUpdate(docId: String, notebookId: String, seq: Int64, blob: Data) throws {
            _ = try db.run("INSERT OR IGNORE INTO docs (doc_id, notebook_id) VALUES (?, ?)", [.text(docId), .text(notebookId)])
            _ = try db.run(
                "INSERT OR IGNORE INTO updates (doc_id, seq, client_update_id, blob) VALUES (?, ?, NULL, ?)",
                [.text(docId), .int(seq), .blob(blob)])
        }

        /// Stores a snapshot and drops the acknowledged updates it covers. Outbox entries stay.
        /// An older snapshot than the stored one is ignored.
        public func setSnapshot(docId: String, notebookId: String, coveredSeq: Int64, blob: Data) throws {
            _ = try db.run("INSERT OR IGNORE INTO docs (doc_id, notebook_id) VALUES (?, ?)", [.text(docId), .text(notebookId)])
            if try db.run(
                "UPDATE docs SET snapshot_seq = ?1, snapshot_blob = ?2 WHERE doc_id = ?3 AND snapshot_seq <= ?1",
                [.int(coveredSeq), .blob(blob), .text(docId)]) > 0 {
                _ = try db.run(
                    "DELETE FROM updates WHERE doc_id = ? AND seq IS NOT NULL AND seq <= ?", [.text(docId), .int(coveredSeq)])
            }
        }

        /// The stored snapshot's coveredSeq (0 when none), or nil if the document is unknown.
        public func snapshotSeq(docId: String) throws -> Int64? {
            try LocalStore.readDoc(db, docId)?.snapshotSeq
        }

        /// Removes a document with its snapshot, updates and outbox entries.
        public func dropDoc(_ docId: String) throws {
            _ = try db.run("DELETE FROM updates WHERE doc_id = ?", [.text(docId)])
            _ = try db.run("DELETE FROM docs WHERE doc_id = ?", [.text(docId)])
        }

        /// Flags a document whose stored history has a hole (a blob that did not open); it is never compacted from this device.
        public func markDamaged(docId: String, notebookId: String) throws {
            _ = try db.run("INSERT OR IGNORE INTO docs (doc_id, notebook_id) VALUES (?, ?)", [.text(docId), .text(notebookId)])
            _ = try db.run("UPDATE docs SET damaged = 1 WHERE doc_id = ?", [.text(docId)])
        }

        /// Replaces the notebook list with the server's. Notebooks the server no longer has are
        /// removed together with their documents - except ones created here that were never
        /// pushed. Returns the removed notebooks with the ids of their documents.
        public func replaceServerNotebooks(_ serverNotebooks: [(notebookId: String, wrappedKey: Data)]) throws
            -> [(notebookId: String, docIds: [String])] {
            let onServer = Set(serverNotebooks.map(\.notebookId))
            var removed: [(notebookId: String, docIds: [String])] = []
            for local in try LocalStore.readNotebooks(db) where !onServer.contains(local.notebookId) && !local.pendingPut {
                removed.append((local.notebookId, try removeNotebook(local.notebookId)))
            }
            for (id, wrappedKey) in serverNotebooks {
                _ = try db.run(
                    """
                    INSERT INTO notebooks (notebook_id, wrapped_key, pending_put) VALUES (?, ?, 0)
                    ON CONFLICT (notebook_id) DO UPDATE SET wrapped_key = excluded.wrapped_key, pending_put = 0
                    """, [.text(id), .blob(wrappedKey)])
            }
            return removed
        }

        /// Removes a notebook and every document in it. Returns the ids of those documents.
        public func removeNotebook(_ notebookId: String) throws -> [String] {
            let docs = try docIds(notebookId: notebookId)
            _ = try db.run("DELETE FROM updates WHERE doc_id IN (SELECT doc_id FROM docs WHERE notebook_id = ?)", [.text(notebookId)])
            _ = try db.run("DELETE FROM docs WHERE notebook_id = ?", [.text(notebookId)])
            _ = try db.run("DELETE FROM notebooks WHERE notebook_id = ?", [.text(notebookId)])
            return docs
        }

        /// Ids of the documents stored for a notebook.
        public func docIds(notebookId: String) throws -> [String] {
            try db.query("SELECT doc_id FROM docs WHERE notebook_id = ?", [.text(notebookId)], { $0.text(0) })
        }

        /// Advances the event cursor (it never moves backwards).
        public func setCursor(_ seq: Int64) throws {
            if seq > (try LocalStore.metaInt(db, "cursor")) {
                try LocalStore.setMeta(db, "cursor", .int(seq))
            }
        }

        /// Records that the first sync has completed.
        public func setFirstSyncDone() throws {
            try LocalStore.setMeta(db, "first_sync_done", .int(1))
        }
    }

    // MARK: Plumbing

    private func locked<R>(_ body: (Database) throws -> R) throws -> R {
        lock.lock()
        defer { lock.unlock() }
        guard let db else { throw LocalStoreClosedError() }
        return try body(db)
    }

    private static func metaInt(_ db: Database, _ key: String) throws -> Int64 {
        try db.query("SELECT value FROM meta WHERE key = ?", [.text(key)], { $0.int(0) }).first ?? 0
    }

    private static func setMeta(_ db: Database, _ key: String, _ value: Database.Value) throws {
        _ = try db.run(
            "INSERT INTO meta (key, value) VALUES (?, ?) ON CONFLICT (key) DO UPDATE SET value = excluded.value", [.text(key), value])
    }

    private static func readNotebooks(_ db: Database) throws -> [StoredNotebook] {
        try db.query("SELECT notebook_id, wrapped_key, pending_put FROM notebooks ORDER BY notebook_id", []) {
            StoredNotebook(notebookId: $0.text(0), wrappedKey: $0.blob(1) ?? Data(), pendingPut: $0.int(2) != 0)
        }
    }

    private static func readDoc(_ db: Database, _ docId: String) throws -> StoredDoc? {
        try db.query("SELECT doc_id, notebook_id, snapshot_seq, damaged FROM docs WHERE doc_id = ?", [.text(docId)]) {
            StoredDoc(docId: $0.text(0), notebookId: $0.text(1), snapshotSeq: $0.int(2), damaged: $0.int(3) != 0)
        }.first
    }
}

/// A thin wrapper over one SQLite connection. Not thread safe; `LocalStore` guards it.
final class Database {
    enum Value {
        case int(Int64)
        case text(String)
        case blob(Data)
        case null
    }

    struct Row {
        fileprivate let statement: OpaquePointer

        func int(_ column: Int32) -> Int64 {
            sqlite3_column_int64(statement, column)
        }

        func text(_ column: Int32) -> String {
            sqlite3_column_text(statement, column).map { String(cString: $0) } ?? ""
        }

        func blob(_ column: Int32) -> Data? {
            guard sqlite3_column_type(statement, column) != SQLITE_NULL else { return nil }
            let count = Int(sqlite3_column_bytes(statement, column))
            guard count > 0, let bytes = sqlite3_column_blob(statement, column) else { return Data() }
            return Data(bytes: bytes, count: count)
        }
    }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private var handle: OpaquePointer?
    private var inTransaction = false

    init(path: String) throws {
        var handle: OpaquePointer?
        let code = sqlite3_open_v2(path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX, nil)
        guard code == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "cannot open the database"
            sqlite3_close_v2(handle)
            throw LocalStoreError(code: code, message: message)
        }
        self.handle = handle
        sqlite3_busy_timeout(handle, 5000)
    }

    func close() {
        if let handle {
            sqlite3_close_v2(handle)
        }
        handle = nil
    }

    var lastInsertRowId: Int64 {
        sqlite3_last_insert_rowid(handle)
    }

    func exec(_ sql: String) throws {
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else {
            throw error()
        }
    }

    /// Runs `body` in a transaction; nested calls join the outer one.
    func transaction<R>(_ body: () throws -> R) throws -> R {
        if inTransaction {
            return try body()
        }
        try exec("BEGIN IMMEDIATE")
        inTransaction = true
        defer { inTransaction = false }
        do {
            let result = try body()
            try exec("COMMIT")
            return result
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    /// Runs a statement and returns the number of rows it changed.
    func run(_ sql: String, _ parameters: [Value]) throws -> Int {
        let statement = try prepare(sql, parameters)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw error()
        }
        return Int(sqlite3_changes(handle))
    }

    func query<T>(_ sql: String, _ parameters: [Value], _ read: (Row) -> T) throws -> [T] {
        let statement = try prepare(sql, parameters)
        defer { sqlite3_finalize(statement) }
        var rows: [T] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW: rows.append(read(Row(statement: statement)))
            case SQLITE_DONE: return rows
            default: throw error()
            }
        }
    }

    func scalar(_ sql: String) throws -> Int64? {
        try query(sql, [], { $0.int(0) }).first
    }

    private func prepare(_ sql: String, _ parameters: [Value]) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw error()
        }
        for (offset, value) in parameters.enumerated() {
            let index = Int32(offset + 1)
            let code: Int32
            switch value {
            case .int(let v):
                code = sqlite3_bind_int64(statement, index, v)
            case .text(let v):
                code = sqlite3_bind_text(statement, index, v, -1, Self.transient)
            case .blob(let v):
                code = v.isEmpty
                    ? sqlite3_bind_zeroblob(statement, index, 0)
                    : v.withUnsafeBytes { sqlite3_bind_blob(statement, index, $0.baseAddress, Int32($0.count), Self.transient) }
            case .null:
                code = sqlite3_bind_null(statement, index)
            }
            guard code == SQLITE_OK else {
                sqlite3_finalize(statement)
                throw error()
            }
        }
        return statement
    }

    private func error() -> LocalStoreError {
        LocalStoreError(code: sqlite3_errcode(handle), message: String(cString: sqlite3_errmsg(handle)))
    }
}

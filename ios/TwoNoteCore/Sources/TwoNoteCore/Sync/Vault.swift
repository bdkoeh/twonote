import Foundation
import TwoNoteCrypto
import YrsKit

/// A decrypted remote change on its way to an open document.
struct RemoteChange: Sendable {
    var docId: String
    var notebookId: String
    var seq: Int64?
    var plaintext: Data
}

/// The open documents. Main-actor state: documents are created, read, edited and merged on the
/// main actor only.
@MainActor
final class DocumentRegistry {
    final class Entry {
        let doc: YrsDocument
        let notebookId: String
        /// Set while the stored history is still being read and decrypted off the main actor.
        var loadTask: Task<Void, any Error>?
        var loading: Bool
        /// Remote changes committed while loading; applied, in order, after the loaded history.
        var buffer: [RemoteChange] = []

        init(doc: YrsDocument, notebookId: String, loading: Bool) {
            self.doc = doc
            self.notebookId = notebookId
            self.loading = loading
        }
    }

    var live: [String: Entry] = [:]

    /// Brings the open documents up to date with a batch the sync engine has just committed to
    /// the store. Returns the changes that were not valid Yjs updates.
    func applyCommitted(updates: [RemoteChange], deleted: [String]) -> [RemoteChange] {
        var failed: [RemoteChange] = []
        for update in updates {
            guard let entry = live[update.docId] else { continue }
            if entry.loading {
                entry.buffer.append(update)
            } else if !entry.doc.applyUpdate(update.plaintext) {
                failed.append(update)
            }
        }
        for docId in deleted {
            detach(docId, deleted: true)
        }
        return failed
    }

    func detach(_ docId: String, deleted: Bool) {
        guard let entry = live.removeValue(forKey: docId) else { return }
        entry.doc.onLocalUpdate = nil
        if deleted {
            entry.doc.markDeleted()
        }
    }

    func detachAll() {
        for docId in Array(live.keys) {
            detach(docId, deleted: false)
        }
    }
}

/// What exists only while the account is unlocked: the vault key, the notebook keys, and the
/// documents that are open in memory. Bridges documents to the local store.
///
/// Threads: the keys are behind a lock; the registry of open documents is main-actor state;
/// everything that touches SQLite or encrypts runs on `queue`, a serial queue. A local edit is
/// handed to that queue from inside the editing call, so edits reach the outbox in the order
/// they were made, a moment after the edit returns.
final class Vault: Sendable {
    /// The stored history of a document, decrypted. `complete` is false if a blob had to be skipped.
    struct Loaded: Sendable {
        var plaintexts: [Data] = []
        var complete = true
    }

    enum FullState: Sendable {
        case state(Data)
        /// The local copy has a hole; this device must not snapshot the document.
        case incomplete
        /// Not now (the document is still loading, or is going away); try again next cycle.
        case unavailable
    }

    private struct Keys {
        var vaultKey: SecretBytes?
        var notebooks: [String: SecretBytes] = [:]
    }

    let store: LocalStore
    let registry: DocumentRegistry
    private let keys: Locked<Keys>
    private let queue = DispatchQueue(label: "twonote.vault", qos: .userInitiated)
    private let report: @Sendable (SyncIssue) -> Void
    private let localChange: @Sendable () -> Void
    private let undoCaptureMilliseconds: Int

    @MainActor
    init(
        store: LocalStore, vaultKey: SecretBytes, undoCaptureMilliseconds: Int,
        report: @escaping @Sendable (SyncIssue) -> Void, localChange: @escaping @Sendable () -> Void
    ) {
        self.store = store
        self.registry = DocumentRegistry()
        self.keys = Locked(Keys(vaultKey: vaultKey))
        self.report = report
        self.localChange = localChange
        self.undoCaptureMilliseconds = undoCaptureMilliseconds
    }

    // MARK: Keys (any thread)

    var vaultKey: SecretBytes? { keys.withLock { $0.vaultKey } }

    var notebookIds: [String] { keys.withLock { $0.notebooks.keys.sorted() } }

    func hasKey(_ notebookId: String) -> Bool {
        keys.withLock { $0.notebooks[notebookId] != nil }
    }

    /// Unwraps and remembers the keys of the given notebooks. A key that does not open is reported and skipped.
    func addKeys(_ notebooks: [(notebookId: String, wrappedKey: Data)]) {
        for (notebookId, wrappedKey) in notebooks {
            guard let id = WireEncoding.id(hex: notebookId), let vaultKey else { continue }
            if let key = try? KeyHierarchy.unwrapNotebookKey(vaultKey: vaultKey, notebookId: id, wrappedNotebookKey: wrappedKey) {
                keys.withLock { if $0.vaultKey != nil { $0.notebooks[notebookId] = key } }
            } else if !hasKey(notebookId) {
                report(SyncIssue(
                    kind: .notebookKeyRejected, notebookId: notebookId, docId: nil, seq: nil,
                    message: "The notebook key did not open with this account's vault key."))
            }
        }
    }

    func removeKey(_ notebookId: String) {
        keys.withLock { $0.notebooks[notebookId] = nil }
    }

    /// Opens a blob of this notebook; nil when there is no key or the blob does not authenticate.
    func tryOpen(notebookId: String, kind: BlobKind, docId: String, blob: Data) -> Data? {
        guard let key = keys.withLock({ $0.notebooks[notebookId] }), let id = WireEncoding.id(hex: docId) else { return nil }
        return kind == .snapshot
            ? try? KeyHierarchy.openSnapshot(notebookKey: key, docId: id, blob: blob)
            : try? KeyHierarchy.openUpdate(notebookKey: key, docId: id, blob: blob)
    }

    func seal(notebookId: String, kind: BlobKind, docId: String, plaintext: Data) throws -> Data {
        guard let key = keys.withLock({ $0.notebooks[notebookId] }) else { throw ClientError.unknownNotebook }
        guard let id = WireEncoding.id(hex: docId) else { throw ClientError.invalidArgument("Not a document id.") }
        return kind == .snapshot
            ? try KeyHierarchy.sealSnapshot(notebookKey: key, docId: id, snapshot: plaintext)
            : try KeyHierarchy.sealUpdate(notebookKey: key, docId: id, update: plaintext)
    }

    // MARK: Work on the vault queue

    /// Runs `work` on the vault queue, after everything queued before it (local edits included).
    private func onQueue<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                continuation.resume(with: Result { try work() })
            }
        }
    }

    /// Returns once every local edit made so far is in the outbox.
    func flush() async {
        try? await onQueue {}
    }

    /// Unwraps the keys of the notebooks in the local store. Called once, right after unlocking.
    func loadStoredKeys() async throws {
        try await onQueue { [self] in
            addKeys(try store.notebooks().map { ($0.notebookId, $0.wrappedKey) })
        }
    }

    /// Reads and decrypts what the store holds for a document.
    private func load(docId: String, notebookId: String, reportIssues: Bool) throws -> Loaded {
        var loaded = Loaded()
        guard let content = try store.loadDoc(docId) else { return loaded }
        guard content.notebookId == notebookId else {
            throw ClientError.invalidArgument("The document belongs to a different notebook.")
        }
        func open(_ kind: BlobKind, _ blob: Data) {
            if let plaintext = tryOpen(notebookId: notebookId, kind: kind, docId: docId, blob: blob) {
                loaded.plaintexts.append(plaintext)
                return
            }
            loaded.complete = false
            if reportIssues {
                report(SyncIssue(
                    kind: .blobRejected, notebookId: notebookId, docId: docId, seq: nil,
                    message: "A stored blob could not be used and was skipped."))
            }
        }
        if let snapshot = content.snapshotBlob {
            open(.snapshot, snapshot)
        }
        for blob in content.updateBlobs {
            open(.update, blob)
        }
        return loaded
    }

    private func markDamaged(docId: String, notebookId: String) {
        queue.async { [self] in
            // The local history has a hole, so this device must not snapshot the document.
            _ = try? store.apply { try $0.markDamaged(docId: docId, notebookId: notebookId) }
        }
    }

    // MARK: Documents (main actor)

    @MainActor
    func createNotebook(title: String) async throws -> YrsNotebookTree {
        let idBytes = WireEncoding.newId()
        let id = try WireEncoding.hexString(id: idBytes)
        try await onQueue { [self] in
            guard let vaultKey else { throw ClientError.locked }
            let key = KeyHierarchy.createNotebookKey()
            let wrapped = try KeyHierarchy.wrapNotebookKey(vaultKey: vaultKey, notebookId: idBytes, notebookKey: key)
            try store.addLocalNotebook(id, wrappedKey: wrapped)
            keys.withLock { if $0.vaultKey != nil { $0.notebooks[id] = key } }
        }
        guard hasKey(id) else { throw ClientError.locked }
        let tree = YrsNotebookTree(notebookId: id)
        register(tree, notebookId: id)
        tree.initialize(title: title)
        return tree
    }

    @MainActor
    func openNotebook(_ notebookId: String) async throws -> YrsNotebookTree {
        try await open(docId: notebookId, notebookId: notebookId) { YrsNotebookTree(notebookId: notebookId) }
    }

    @MainActor
    func createPage(notebookId: String, sectionId: String, title: String, at index: Int?, pageId: String? = nil) async throws -> YrsPageDocument {
        let tree = try await openNotebook(notebookId)
        if let pageId {
            guard WireEncoding.id(hex: pageId) != nil, tree.page(pageId) == nil, registry.live[pageId] == nil else {
                throw ClientError.invalidArgument("The page id is not usable.")
            }
        }
        // From here to the end nothing suspends: the tree entry and the page's first content are
        // produced, and queued for the outbox, together.
        let pageId = tree.addPage(inSection: sectionId, title: title, at: index, id: pageId)
        let page = YrsPageDocument(pageId: pageId, undoCaptureMilliseconds: undoCaptureMilliseconds)
        register(page, notebookId: notebookId)
        page.initialize()
        return page
    }

    @MainActor
    func openPage(notebookId: String, pageId: String) async throws -> YrsPageDocument {
        let capture = undoCaptureMilliseconds
        return try await open(docId: pageId, notebookId: notebookId) { YrsPageDocument(pageId: pageId, undoCaptureMilliseconds: capture) }
    }

    @MainActor
    func close(_ docId: String) {
        registry.detach(docId, deleted: false)
    }

    /// Loads a document from the store, or returns the instance that is already open.
    ///
    /// The document is registered before its history is read, and remote changes committed in
    /// the meantime are buffered and applied after it: whatever the order of events, every
    /// update reaches the document, and none overtakes an older one.
    @MainActor
    private func open<D: YrsDocument>(docId: String, notebookId: String, make: () -> D) async throws -> D {
        guard WireEncoding.id(hex: docId) != nil, hasKey(notebookId) else { throw ClientError.unknownNotebook }
        if let entry = registry.live[docId] {
            guard let doc = entry.doc as? D, entry.notebookId == notebookId else {
                throw ClientError.invalidArgument("The document is open as something else.")
            }
            try await entry.loadTask?.value
            return doc
        }

        let doc = make()
        let entry = DocumentRegistry.Entry(doc: doc, notebookId: notebookId, loading: true)
        registry.live[docId] = entry
        let task = Task { @MainActor [self] in
            do {
                let loaded = try await onQueue { [self] in try load(docId: docId, notebookId: notebookId, reportIssues: true) }
                guard registry.live[docId] === entry else { throw ClientError.documentUnavailable }
                var complete = loaded.complete
                for plaintext in loaded.plaintexts + entry.buffer.map(\.plaintext) where !doc.applyUpdate(plaintext) {
                    complete = false
                    report(SyncIssue(
                        kind: .updateRejected, notebookId: notebookId, docId: docId, seq: nil,
                        message: "A stored update was not valid and was skipped."))
                }
                entry.buffer = []
                entry.loading = false
                entry.loadTask = nil
                attach(doc, notebookId: notebookId)
                if !complete {
                    markDamaged(docId: docId, notebookId: notebookId)
                }
            } catch {
                if registry.live[docId] === entry {
                    registry.live[docId] = nil
                }
                throw error
            }
        }
        entry.loadTask = task
        try await task.value
        return doc
    }

    @MainActor
    private func register(_ doc: YrsDocument, notebookId: String) {
        registry.live[doc.docId] = DocumentRegistry.Entry(doc: doc, notebookId: notebookId, loading: false)
        attach(doc, notebookId: notebookId)
    }

    /// From now on every local edit of the document is sealed and written to the outbox.
    @MainActor
    private func attach(_ doc: YrsDocument, notebookId: String) {
        let docId = doc.docId
        doc.onLocalUpdate = { [weak doc, self] update in
            guard let doc, !doc.isDeleted else { return }
            queue.async { [self] in
                guard hasKey(notebookId) else { return } // locked, or the notebook is gone
                do {
                    let blob = try seal(notebookId: notebookId, kind: .update, docId: docId, plaintext: update)
                    let clientUpdateId = try WireEncoding.hexString(id: WireEncoding.newId())
                    try store.appendLocalUpdate(docId: docId, notebookId: notebookId, clientUpdateId: clientUpdateId, blob: blob)
                    localChange()
                } catch {
                    report(SyncIssue(
                        kind: .editNotSaved, notebookId: notebookId, docId: docId, seq: nil,
                        message: "A local edit could not be written to the local store (\(type(of: error)))."))
                }
            }
        }
    }

    /// False while the notebook is waiting for its first push.
    func isNotebookOnServer(_ notebookId: String) async -> Bool {
        (try? await onQueue { [self] in
            !(try store.notebooks().contains { $0.notebookId == notebookId && $0.pendingPut })
        }) ?? true
    }

    /// A stamp per stored document that changes with its content.
    func documentVersions() async throws -> [String: DocumentVersion] {
        try await onQueue { [self] in try store.docVersions() }
    }

    /// The text of a page: from the open document if there is one, otherwise rebuilt from the
    /// store in a scratch document that is thrown away. Nil when nothing is stored for the page.
    @MainActor
    func pageText(notebookId: String, pageId: String) async throws -> String? {
        guard WireEncoding.id(hex: pageId) != nil, hasKey(notebookId) else { throw ClientError.unknownNotebook }
        if let entry = registry.live[pageId] {
            try await entry.loadTask?.value
            return (entry.doc as? YrsPageDocument)?.text
        }
        let loaded = try await onQueue { [self] in try load(docId: pageId, notebookId: notebookId, reportIssues: false) }
        guard !loaded.plaintexts.isEmpty else { return nil }
        let scratch = YrsPageDocument(pageId: pageId, undoCaptureMilliseconds: 0)
        for plaintext in loaded.plaintexts {
            _ = scratch.applyUpdate(plaintext)
        }
        return scratch.text
    }

    /// The full state of a document as one Yjs update, for a snapshot.
    func encodeFullState(docId: String, notebookId: String) async -> FullState {
        enum Live { case state(Data), busy, closed }
        let live: Live = await MainActor.run {
            guard let entry = registry.live[docId] else { return .closed }
            return entry.loading || entry.doc.isDeleted ? .busy : .state(entry.doc.encodeState())
        }
        switch live {
        case .state(let state): return .state(state)
        case .busy: return .unavailable
        case .closed: break
        }

        // Not open: rebuild it in a scratch document. The concrete type does not matter for merging.
        guard let loaded = try? await onQueue({ [self] in try load(docId: docId, notebookId: notebookId, reportIssues: false) }) else {
            return .unavailable
        }
        guard loaded.complete else { return .incomplete }
        return await MainActor.run {
            let scratch = YrsNotebookTree(notebookId: docId)
            for plaintext in loaded.plaintexts where !scratch.applyUpdate(plaintext) {
                return .incomplete
            }
            return .state(scratch.encodeState())
        }
    }

    /// Lets go of every open document, waits until the edits already made have reached the
    /// outbox, then forgets the keys.
    @MainActor
    func shutdown() async {
        registry.detachAll()
        await flush()
        keys.withLock { $0 = Keys() }
    }
}

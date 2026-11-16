import Foundation
import Observation
import TwoNoteCrypto
#if canImport(Network)
import Network
#endif

// Concurrency model of the client core
// ------------------------------------
// * Documents (`YrsNotebookTree`, `YrsPageDocument`) and the registry of open documents live on
//   the main actor. The editor reads and edits them directly, synchronously.
// * `SyncEngine` is an actor: the whole sync cycle - HTTP, JSON, opening and sealing blobs,
//   SQLite transactions - runs on its executor, never on the main thread. Cycles are serialised
//   by `cycleLock`, because an actor is re-entrant across `await`.
// * The vault owns a serial dispatch queue for the storage work that documents cause: sealing
//   a local edit into the outbox, and reading + decrypting a document's history when it is
//   opened. A local edit is handed to that queue from inside the editing call (in order, so the
//   outbox keeps the order the edits were made) and is in SQLite a moment after the edit
//   returns; `lock()` waits for the queue to drain before the keys are dropped.
// * `LocalStore` is thread safe (one lock, one connection); the engine and the vault queue
//   both use it, and it is never called from the main actor.
// * The engine hops to the main actor in exactly two places: to merge a committed batch of
//   remote changes into the open documents (`DocumentRegistry.applyCommitted`, once per page
//   of events, after the page and its cursor were committed in one SQLite transaction), and to
//   read a full state for a snapshot. Status for the UI is published to `SyncMonitor`, an
//   `@Observable` main-actor object.
// * Opening a document registers it first and loads its history second, buffering remote
//   changes that are committed in between, so an update can never fall between "what was in
//   the store when it was read" and "which documents were open when the batch was applied".

/// How the last sync attempt ended.
public enum SyncState: Equatable, Sendable {
    /// Nothing has failed and nothing is running: up to date as far as this device knows.
    case idle
    /// A sync cycle is running.
    case syncing
    /// The server could not be reached. Edits keep queueing locally. A normal state for a phone.
    case offline
    /// The server refused the session token (revoked, or the password was changed elsewhere).
    /// Call `TwoNoteClient.signInAgain(password:)`.
    case authRequired
    /// The last cycle failed for another reason; see `SyncStatus.lastError`.
    case error
}

/// A snapshot of the sync engine for the UI.
public struct SyncStatus: Equatable, Sendable {
    /// How the last attempt ended.
    public var state: SyncState = .idle
    /// True while the background loop is started.
    public var running = false
    /// Seq of the last server event this device has applied.
    public var cursor: Int64 = 0
    /// Highest server seq this device has heard of.
    public var head: Int64 = 0
    /// Local edits not yet acknowledged by the server.
    public var pendingUpdates = 0
    /// Pages with edits not yet acknowledged by the server.
    public var pendingPages = 0
    /// Notebooks whose lists (title, sections, page titles and order) have changes not yet acknowledged.
    public var pendingNotebooks = 0
    /// True while the head listener socket is open.
    public var webSocketConnected = false
    /// When a cycle last completed.
    public var lastSyncedAt: Date?
    /// Human-readable reason for `.error` (never contains secrets or content).
    public var lastError: String?
}

/// What kind of problem a `SyncIssue` describes.
public enum SyncIssueKind: Equatable, Sendable {
    /// A sealed blob (update or snapshot) did not open. It was discarded, never applied.
    case blobRejected
    /// A blob opened but its content is not a valid Yjs update. It was not applied.
    case updateRejected
    /// A wrapped notebook key did not open with the vault key; the notebook is unusable on this device.
    case notebookKeyRejected
    /// A document is too large to snapshot within the server's blob limit.
    case snapshotTooLarge
    /// Local edits were dropped because the server had deleted their document or notebook.
    case editsDropped
    /// A local edit could not be written to the local store (disk full, store closed).
    case editNotSaved
}

/// A problem the sync engine worked around and wants reported. Carries ids only, never content.
public struct SyncIssue: Equatable, Sendable {
    public var kind: SyncIssueKind
    public var notebookId: String?
    public var docId: String?
    public var seq: Int64?
    public var message: String
}

/// The sync engine's state for SwiftUI: observe `status` for the indicator (offline / syncing /
/// up to date / error), `notebooksRevision` to re-read the notebook list.
@MainActor
@Observable
public final class SyncMonitor {
    /// The current status.
    public private(set) var status = SyncStatus()
    /// The issues reported since the account was unlocked (most recent last, at most 200).
    public private(set) var issues: [SyncIssue] = []
    /// Grows whenever a pull or push changed the set of notebooks on this device.
    public private(set) var notebooksRevision = 0
    /// The last head the server announced over the WebSocket.
    public private(set) var lastNotifiedHead: Int64 = 0

    nonisolated init() {}

    func update(_ status: SyncStatus) {
        if self.status != status {
            self.status = status
        }
    }

    func add(_ issue: SyncIssue) {
        if issues.count >= 200 {
            issues.removeFirst()
        }
        issues.append(issue)
    }

    func clearIssues() {
        issues = []
    }

    func notebooksChanged() {
        notebooksRevision += 1
    }

    func headNotified(_ head: Int64) {
        lastNotifiedHead = max(lastNotifiedHead, head)
    }
}

/// The client side of PROTOCOL.md section 4: first sync, incremental pull strictly in seq
/// order, ordered and idempotent push of the outbox, snapshots, deletions, compaction, and
/// waking on the WebSocket. Obtain it from `TwoNoteClient.sync`.
public actor SyncEngine {
    private static let maxBlobBytes = 8 * 1024 * 1024
    private static let pushByteBudget = 16 * 1024 * 1024

    private struct Shared {
        var status = SyncStatus()
        var localEditPending = false
        var issues: [SyncIssue] = []
    }

    /// The observable mirror of `status` for SwiftUI.
    public nonisolated let monitor: SyncMonitor

    private let api: TwoNoteApi
    private let store: LocalStore
    private let options: ClientOptions
    private nonisolated let shared = Locked(Shared())
    private nonisolated let wake = WakeSignal()
    private nonisolated let cycleLock = AsyncLock()
    private var listener: HeadListener?
    private var vault: Vault?
    private var deviceId: String?
    private var loopTask: Task<Void, Never>?
    #if canImport(Network)
    private var pathMonitor: NWPathMonitor?
    #endif

    init(api: TwoNoteApi, store: LocalStore, options: ClientOptions, monitor: SyncMonitor) {
        self.api = api
        self.store = store
        self.options = options
        self.monitor = monitor
    }

    /// The current state. Readable from any thread without blocking.
    public nonisolated var status: SyncStatus { shared.withLock { $0.status } }

    /// The issues reported since the account was unlocked (most recent last, at most 200).
    public nonisolated var issues: [SyncIssue] { shared.withLock { $0.issues } }

    /// True while the background loop is started.
    public var isRunning: Bool { loopTask != nil }

    /// Runs one complete sync cycle now: pull, push, pull again, compact. Throws what stopped it
    /// (`ServerUnreachableError`, `ApiError`, …); the outbox is untouched by a failure and the
    /// next cycle resumes where this one stopped.
    public func syncNow() async throws {
        try await runCycle()
    }

    /// Starts syncing in the background: once now, then whenever a local edit is made, the
    /// server announces a new head over the WebSocket, the network comes back, or the poll
    /// interval elapses. Failures are retried with backoff. Requires an unlocked account.
    public func start() throws {
        guard loopTask == nil else { return }
        guard vault != nil else { throw ClientError.locked }
        loopTask = Task { [weak self] in
            await self?.loop()
        }
        if options.useWebSocket {
            let listener = self.listener ?? makeListener()
            self.listener = listener
            listener.start()
        }
        startPathMonitor()
        shared.withLock { $0.status.running = true }
        publishStatus()
    }

    /// Asks the background loop to sync as soon as it can (for instance when the app comes to
    /// the foreground). Does nothing if the loop is not started.
    public nonisolated func requestSync() {
        wake.signal()
    }

    /// Stops the background loop and the WebSocket ("go offline"). Local edits keep queueing.
    public func stop() async {
        let task = loopTask
        loopTask = nil
        task?.cancel()
        stopPathMonitor()
        await listener?.stop()
        await task?.value
        shared.withLock { $0.status.running = false }
        publishStatus()
    }

    // MARK: Wiring from TwoNoteClient

    func attach(_ vault: Vault, deviceId: String) {
        self.vault = vault
        self.deviceId = deviceId
        shared.withLock { s in
            s.status.state = .idle
            s.status.lastError = nil
            s.issues = []
        }
        Task { @MainActor [monitor] in monitor.clearIssues() }
        publishStatus()
    }

    /// Stops everything and waits for a running cycle to finish before the vault goes away.
    func detach() async {
        await stop()
        await cycleLock.lock()
        vault = nil
        cycleLock.unlock()
    }

    nonisolated func report(_ issue: SyncIssue) {
        shared.withLock { s in
            if s.issues.count >= 200 {
                s.issues.removeFirst()
            }
            s.issues.append(issue)
        }
        Task { @MainActor [monitor] in monitor.add(issue) }
    }

    /// A local edit reached the outbox. Called on the vault queue.
    nonisolated func notifyLocalChange() {
        shared.withLock { $0.localEditPending = true }
        publishStatus()
        wake.signal()
    }

    nonisolated func raiseNotebooksChanged() {
        Task { @MainActor [monitor] in monitor.notebooksChanged() }
    }

    /// Deletes a notebook on the server (unless it never got there) and locally, while no cycle runs.
    func deleteNotebook(_ notebookId: String) async throws {
        await cycleLock.lock()
        defer { cycleLock.unlock() }
        guard let vault else { throw ClientError.locked }
        let neverPushed = try store.notebooks().contains { $0.notebookId == notebookId && $0.pendingPut }
        if !neverPushed {
            do {
                try await api.deleteNotebook(notebookId)
            } catch let error as ApiError where error.code == ErrorCodes.unknownNotebook {
            }
        }
        try await dropLocally(vault, docIds: [], notebookId: notebookId, notebookGone: true, issueMessage: nil)
    }

    /// Removes a page document for good (`DELETE /docs`), on the server and locally, while no cycle runs.
    func purgePage(notebookId: String, pageId: String) async throws {
        await cycleLock.lock()
        defer { cycleLock.unlock() }
        guard let vault else { throw ClientError.locked }
        do {
            try await api.deleteDoc(pageId)
        } catch let error as ApiError where error.code == ErrorCodes.unknownDoc {
        }
        try await dropLocally(vault, docIds: [pageId], notebookId: notebookId, notebookGone: false, issueMessage: nil)
    }

    // MARK: Loop

    private func makeListener() -> HeadListener {
        HeadListener(
            url: api.webSocketURL,
            token: { [api] in api.token },
            connector: options.webSocketConnector,
            initialBackoff: options.initialRetryDelay,
            maxBackoff: options.maxOfflineRetryDelay,
            onHead: { [weak self] head in self?.onHead(head) },
            onConnectionChanged: { [weak self] connected in
                guard let self else { return }
                shared.withLock { $0.status.webSocketConnected = connected }
                if connected {
                    wake.signal() // the server is reachable again: do not wait for the backoff
                }
                publishStatus()
            })
    }

    private nonisolated func onHead(_ head: Int64) {
        let behind = shared.withLock { s -> Bool in
            s.status.head = max(s.status.head, head)
            return head > s.status.cursor
        }
        Task { @MainActor [monitor] in monitor.headNotified(head) }
        if behind {
            wake.signal()
        }
        publishStatus()
    }

    private func startPathMonitor() {
        #if canImport(Network)
        guard options.wakeOnNetworkChange, pathMonitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [wake] path in
            if path.status == .satisfied {
                wake.signal()
            }
        }
        monitor.start(queue: DispatchQueue(label: "twonote.path", qos: .utility))
        pathMonitor = monitor
        #endif
    }

    private func stopPathMonitor() {
        #if canImport(Network)
        pathMonitor?.cancel()
        pathMonitor = nil
        #endif
    }

    private func loop() async {
        var failures = 0
        while !Task.isCancelled {
            var wait = options.pollInterval
            do {
                shared.withLock { $0.localEditPending = false }
                try await runCycle()
                failures = 0
            } catch is CancellationError {
                break
            } catch let error as ApiError where error.status == 401 {
                // Retrying cannot help until the user signs in again (which wakes the loop).
            } catch {
                // runCycle has already recorded why. Retry with backoff; a wake-up retries at once.
                failures += 1
                let cap = error is ServerUnreachableError ? options.maxOfflineRetryDelay : options.maxRetryDelay
                wait = min(cap, options.initialRetryDelay * (1 << min(failures - 1, 20)))
            }
            if Task.isCancelled {
                break
            }
            let woken = await wake.wait(for: wait)
            if Task.isCancelled {
                break
            }
            if woken, options.pushDebounce > .zero, shared.withLock({ $0.localEditPending }) {
                try? await Task.sleep(for: options.pushDebounce)
            }
        }
    }

    private func runCycle() async throws {
        await cycleLock.lock()
        defer { cycleLock.unlock() }
        guard let vault else { throw ClientError.locked }
        // An unreachable server stays "offline" while the next attempt is made: no flicker
        // between offline and syncing for as long as the phone is away from home.
        if status.state != .offline {
            setState(.syncing, error: nil)
        }
        do {
            try await cycle(vault)
        } catch is CancellationError {
            setState(.idle, error: nil)
            throw CancellationError()
        } catch let error as ServerUnreachableError {
            setState(.offline, error: nil)
            throw error
        } catch let error as ApiError where error.status == 401 {
            setState(.authRequired, error: nil)
            throw error
        } catch let error as ApiError {
            setState(.error, error: "The server answered \(error.status) \(error.code).")
            throw error
        } catch {
            // Only the type: error descriptions from lower layers are not vetted for content.
            setState(.error, error: "Sync failed (\(type(of: error))).")
            throw error
        }
        shared.withLock { $0.status.lastSyncedAt = Date() }
        setState(.idle, error: nil)
    }

    // MARK: The algorithm of PROTOCOL.md section 4

    private func cycle(_ vault: Vault) async throws {
        // Edits made before this cycle was asked for are in the outbox before it looks there.
        await vault.flush()
        if try !store.firstSyncDone() {
            try await firstSync(vault)
        }

        // Pull before push, so deletions made elsewhere are known before stale edits go out; then
        // pull again after a push to move the cursor past this device's own events.
        for _ in 0..<100 {
            try await pull(vault)
            if try await !push(vault) {
                break
            }
        }

        if try await compact(vault) {
            try await pull(vault)
        }
    }

    /// The server answered: whatever happens next, it is not "offline" any more.
    private func markReachable() {
        if status.state == .offline {
            setState(.syncing, error: nil)
        }
    }

    /// Step 1: notebooks, documents, every snapshot; the events from 0 follow in `pull`.
    private func firstSync(_ vault: Vault) async throws {
        let notebooks = try await api.notebooks()
        markReachable()
        let docs = try await api.docs()
        vault.addKeys(notebooks.map { ($0.notebookId, $0.wrappedKey) })

        var work: [PendingChange] = []
        for doc in docs where doc.snapshotSeq > 0 && Self.isId(doc.docId) && Self.isId(doc.notebookId) {
            if let snapshot = try await api.snapshot(docId: doc.docId) {
                work.append(openSnapshot(vault, docId: doc.docId, notebookId: doc.notebookId, snapshot: snapshot, seq: nil))
            }
        }
        try await commit(vault, notebooks: notebooks, work: work, newCursor: nil, firstSyncDone: true)
    }

    /// Step 2: read `/events` from the cursor until there are no more, applying each page atomically and in seq order.
    private func pull(_ vault: Vault) async throws {
        while true {
            try Task.checkCancellation()
            let cursor = try store.cursor()
            let page = try await api.events(after: cursor, limit: options.eventsPageSize)
            markReachable()
            shared.withLock { $0.status.head = max($0.status.head, page.head) }

            guard let last = page.events.last else {
                if page.more {
                    throw ProtocolViolationError("The server announced more events but sent none.")
                }
                if page.head > cursor {
                    // Everything between the cursor and head was removed by a snapshot or a deletion.
                    try store.apply { try $0.setCursor(page.head) }
                }
                publishStatus()
                return
            }

            var notebooks: [NotebookEntry]?
            if page.events.contains(where: { $0.type == ServerEvent.notebooksChanged }) {
                // The list read now is at least as new as the event, which is all that matters.
                let list = try await api.notebooks()
                vault.addKeys(list.map { ($0.notebookId, $0.wrappedKey) })
                notebooks = list
            }

            var work: [PendingChange] = []
            for event in page.events {
                switch event.type {
                case ServerEvent.update:
                    guard let docId = event.docId, let notebookId = event.notebookId, let blob = event.blob,
                          Self.isId(docId), Self.isId(notebookId) else { continue }
                    if event.deviceId == deviceId {
                        continue // this device's own edit: already in the local store
                    }
                    if let plaintext = vault.tryOpen(notebookId: notebookId, kind: .update, docId: docId, blob: blob) {
                        work.append(.update(docId: docId, notebookId: notebookId, seq: event.seq, blob: blob, plaintext: plaintext))
                    } else {
                        work.append(.rejected(docId: docId, notebookId: notebookId, seq: event.seq))
                    }

                case ServerEvent.snapshot:
                    guard let docId = event.docId, let notebookId = event.notebookId, Self.isId(docId), Self.isId(notebookId) else { continue }
                    if (try store.doc(docId)?.snapshotSeq ?? 0) >= (event.coveredSeq ?? .max) {
                        continue // already stored (for instance, this device uploaded it)
                    }
                    if let snapshot = try await api.snapshot(docId: docId) {
                        work.append(openSnapshot(vault, docId: docId, notebookId: notebookId, snapshot: snapshot, seq: event.seq))
                    }

                case ServerEvent.docDeleted:
                    guard let docId = event.docId, Self.isId(docId) else { continue }
                    work.append(.deleted(docId: docId, seq: event.seq))

                default:
                    continue // notebooksChanged was handled above; unknown event types are skipped
                }
            }

            let newCursor = page.more ? last.seq : max(last.seq, page.head)
            try await commit(vault, notebooks: notebooks, work: work, newCursor: newCursor, firstSyncDone: false)
            publishStatus()

            if !page.more {
                return
            }
        }
    }

    private func openSnapshot(_ vault: Vault, docId: String, notebookId: String, snapshot: SnapshotEntry, seq: Int64?) -> PendingChange {
        if let plaintext = vault.tryOpen(notebookId: notebookId, kind: .snapshot, docId: docId, blob: snapshot.blob) {
            return .snapshot(
                docId: docId, notebookId: notebookId, seq: seq, coveredSeq: snapshot.coveredSeq, blob: snapshot.blob, plaintext: plaintext)
        }
        return .rejected(docId: docId, notebookId: notebookId, seq: seq)
    }

    /// Stores one batch of changes and the new cursor in a single local transaction, then brings
    /// the open documents up to date in the same order.
    private func commit(
        _ vault: Vault, notebooks: [NotebookEntry]?, work: [PendingChange], newCursor: Int64?, firstSyncDone: Bool
    ) async throws {
        var removedNotebooks: [String] = []
        var deletedDocs: [String] = []
        var issues: [SyncIssue] = []
        var memory: [RemoteChange] = []

        try store.apply { batch in
            if let notebooks {
                let valid = notebooks.filter { Self.isId($0.notebookId) }.map { (notebookId: $0.notebookId, wrappedKey: $0.wrappedKey) }
                for (notebookId, docIds) in try batch.replaceServerNotebooks(valid) {
                    removedNotebooks.append(notebookId)
                    deletedDocs.append(contentsOf: docIds + [notebookId])
                }
            }
            for change in work {
                switch change {
                case .update(let docId, let notebookId, let seq, let blob, let plaintext):
                    try batch.addRemoteUpdate(docId: docId, notebookId: notebookId, seq: seq, blob: blob)
                    memory.append(RemoteChange(docId: docId, notebookId: notebookId, seq: seq, plaintext: plaintext))
                case .snapshot(let docId, let notebookId, let seq, let coveredSeq, let blob, let plaintext):
                    try batch.setSnapshot(docId: docId, notebookId: notebookId, coveredSeq: coveredSeq, blob: blob)
                    memory.append(RemoteChange(docId: docId, notebookId: notebookId, seq: seq, plaintext: plaintext))
                case .deleted(let docId, _):
                    try batch.dropDoc(docId)
                    deletedDocs.append(docId)
                case .rejected(let docId, let notebookId, let seq):
                    try batch.markDamaged(docId: docId, notebookId: notebookId)
                    issues.append(SyncIssue(
                        kind: .blobRejected, notebookId: notebookId, docId: docId, seq: seq,
                        message: "A blob from the server did not open; it was discarded."))
                }
            }
            if let newCursor {
                try batch.setCursor(newCursor)
            }
            if firstSyncDone {
                try batch.setFirstSyncDone()
            }
        }

        for notebookId in removedNotebooks {
            vault.removeKey(notebookId)
        }

        if !memory.isEmpty || !deletedDocs.isEmpty {
            let updates = memory
            let deleted = deletedDocs
            let failed = await vault.registry.applyCommitted(updates: updates, deleted: deleted)
            for change in failed {
                issues.append(SyncIssue(
                    kind: .updateRejected, notebookId: change.notebookId, docId: change.docId, seq: change.seq,
                    message: "A decrypted update was not valid and was not applied."))
            }
        }

        for issue in issues {
            report(issue)
        }
        if notebooks != nil {
            raiseNotebooksChanged()
        }
    }

    /// Step 3: send the outbox in the order the edits were made. Returns true if anything was sent.
    private func push(_ vault: Vault) async throws -> Bool {
        var sent = false
        for notebook in try store.pendingNotebooks() {
            let head = try await api.putNotebook(notebook.notebookId, wrappedKey: notebook.wrappedKey)
            try store.markNotebookPushed(notebook.notebookId)
            shared.withLock { $0.status.head = max($0.status.head, head) }
            sent = true
        }

        while true {
            try Task.checkCancellation()
            let batch = try store.peekOutbox(maxCount: options.pushBatchSize, maxBytes: Self.pushByteBudget)
            guard let first = batch.first else {
                return sent
            }
            let docId = first.docId
            let notebookId = first.notebookId
            do {
                let result = try await api.pushUpdates(
                    docId: docId, notebookId: notebookId,
                    updates: batch.map { OutgoingUpdate(clientUpdateId: $0.clientUpdateId, blob: $0.blob) })

                // Only now, with the server's acknowledgement stored, do the updates leave the outbox.
                try store.acknowledgeOutbox(zip(batch, result.seqs).map { (localId: $0.localId, seq: $1) })
                shared.withLock { $0.status.head = max($0.status.head, result.head) }
                sent = true
            } catch let error as ApiError where error.code == ErrorCodes.docDeleted {
                try await dropLocally(
                    vault, docIds: [docId], notebookId: notebookId, notebookGone: false,
                    issueMessage: "The document was deleted on the server; unsent edits to it were dropped.")
            } catch let error as ApiError where error.code == ErrorCodes.unknownNotebook {
                let notebooks = try await api.notebooks()
                if notebooks.contains(where: { $0.notebookId == notebookId }) {
                    throw error // the server contradicts itself; do not destroy anything on its word
                }
                try await dropLocally(
                    vault, docIds: [], notebookId: notebookId, notebookGone: true,
                    issueMessage: "The notebook was deleted on the server; unsent edits to it were dropped.")
            }
            publishStatus()
        }
    }

    /// Removes documents (or a whole notebook) from the local store and tells the open documents.
    private func dropLocally(
        _ vault: Vault, docIds: [String], notebookId: String, notebookGone: Bool, issueMessage: String?
    ) async throws {
        var dropped = docIds
        try store.apply { batch in
            if notebookGone {
                dropped.append(contentsOf: try batch.removeNotebook(notebookId))
                dropped.append(notebookId)
            } else {
                for docId in docIds {
                    try batch.dropDoc(docId)
                }
            }
        }
        if notebookGone {
            vault.removeKey(notebookId)
        }
        let deleted = dropped
        _ = await vault.registry.applyCommitted(updates: [], deleted: deleted)

        if let issueMessage {
            report(SyncIssue(
                kind: .editsDropped, notebookId: notebookId, docId: docIds.count == 1 ? docIds[0] : nil, seq: nil, message: issueMessage))
        }
        if notebookGone {
            raiseNotebooksChanged()
        }
        publishStatus()
    }

    /// Step 4: a document with more than the threshold of un-snapshotted updates gets a snapshot
    /// with `coveredSeq = head` - but only while this device has applied every event up to head
    /// and has nothing left to push. Returns true if a snapshot was uploaded.
    private func compact(_ vault: Vault) async throws -> Bool {
        var uploaded = false
        for doc in try store.docsToCompact(threshold: options.compactionThreshold) {
            try Task.checkCancellation()
            let cursor = try store.cursor()
            if try store.outboxCount() > 0 || cursor < status.head || cursor < 1 {
                return uploaded // not caught up (any more); the next cycle tries again
            }
            guard vault.hasKey(doc.notebookId) else { continue }

            let state: Data
            switch await vault.encodeFullState(docId: doc.docId, notebookId: doc.notebookId) {
            case .state(let data):
                state = data
            case .incomplete:
                try store.apply { try $0.markDamaged(docId: doc.docId, notebookId: doc.notebookId) }
                continue
            case .unavailable:
                continue
            }

            if state.count + SealedBlob.overhead > Self.maxBlobBytes {
                report(SyncIssue(
                    kind: .snapshotTooLarge, notebookId: doc.notebookId, docId: doc.docId, seq: nil,
                    message: "The document is too large to snapshot; its update log keeps growing."))
                continue
            }

            let blob = try vault.seal(notebookId: doc.notebookId, kind: .snapshot, docId: doc.docId, plaintext: state)
            do {
                let result = try await api.putSnapshot(docId: doc.docId, coveredSeq: cursor, blob: blob)
                try store.apply { try $0.setSnapshot(docId: doc.docId, notebookId: doc.notebookId, coveredSeq: cursor, blob: blob) }
                shared.withLock { $0.status.head = max($0.status.head, result.head) }
                uploaded = true
            } catch let error as ApiError
                where [ErrorCodes.staleSnapshot, ErrorCodes.unknownDoc, ErrorCodes.docDeleted].contains(error.code) {
                // Another device got there first, or the document is gone; the event log will say which.
            }
        }
        return uploaded
    }

    // MARK: Helpers

    private static func isId(_ id: String) -> Bool {
        WireEncoding.id(hex: id) != nil
    }

    private nonisolated func setState(_ state: SyncState, error: String?) {
        shared.withLock { s in
            s.status.state = state
            s.status.lastError = error
        }
        publishStatus()
    }

    /// Refreshes the numbers that come from the store and hands the status to the monitor.
    /// Reads SQLite, so it is only called off the main actor.
    private nonisolated func publishStatus() {
        let cursor = try? store.cursor()
        let pending = try? store.outboxCount()
        let documents = try? store.outboxDocuments()
        shared.withLock { s in
            if let documents {
                s.status.pendingPages = documents.pages
                s.status.pendingNotebooks = documents.notebooks
            }
            if let cursor {
                s.status.cursor = cursor
            }
            if let pending {
                s.status.pendingUpdates = pending
            }
            s.status.head = max(s.status.head, s.status.cursor)
        }
        // The task reads the status when it runs, so the monitor always ends on the latest one.
        Task { @MainActor [monitor, shared] in
            monitor.update(shared.withLock { $0.status })
        }
    }

    /// One event of a page, already decrypted, waiting to be committed.
    private enum PendingChange {
        case update(docId: String, notebookId: String, seq: Int64, blob: Data, plaintext: Data)
        case snapshot(docId: String, notebookId: String, seq: Int64?, coveredSeq: Int64, blob: Data, plaintext: Data)
        case deleted(docId: String, seq: Int64)
        case rejected(docId: String, notebookId: String, seq: Int64?)
    }
}

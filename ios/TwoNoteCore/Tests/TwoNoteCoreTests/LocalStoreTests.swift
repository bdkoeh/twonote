import Foundation
import SQLite3
import Testing
import TwoNoteCrypto
@testable import TwoNoteCore

// The scenarios of tests/TwoNote.Core.Tests/LocalStoreTests.cs.

private func blob(_ seed: UInt8, _ length: Int = 60) -> Data {
    Data((0..<length).map { UInt8(truncatingIfNeeded: Int(seed) &* 31 &+ $0 &* 7) })
}

private func newId() -> String {
    try! WireEncoding.hexString(id: WireEncoding.newId())
}

@Suite("local store")
struct LocalStoreTests {
    let path = temporaryDatabasePath()

    @Test func aNewStoreIsEmptyAndEverythingSurvivesReopening() throws {
        let nb = newId(), doc = newId()
        let account = AccountRecord(
            username: "bob", accountId: newId(), deviceId: newId(), deviceName: "phone", kdfSalt: blob(1, 16),
            kdfParams: .default, wrappedVaultKey: blob(2, 73))
        do {
            let store = try LocalStore.open(path: path)
            #expect(try store.account() == nil)
            #expect(try store.cursor() == 0)
            #expect(try !store.firstSyncDone())
            #expect(try store.notebooks().isEmpty)
            #expect(try store.docs().isEmpty)
            #expect(try store.outboxCount() == 0)
            #expect(try store.loadDoc(doc) == nil)

            try store.saveAccount(account)
            try store.addLocalNotebook(nb, wrappedKey: blob(3, 73))
            try store.appendLocalUpdate(docId: doc, notebookId: nb, clientUpdateId: newId(), blob: blob(4))
            try store.apply { batch in
                try batch.addRemoteUpdate(docId: doc, notebookId: nb, seq: 7, blob: blob(5))
                try batch.setCursor(7)
                try batch.setFirstSyncDone()
            }
            store.close()
        }

        do {
            let store = try LocalStore.open(path: path)
            #expect(try store.account() == account)
            #expect(try store.cursor() == 7)
            #expect(try store.firstSyncDone())
            #expect(try store.notebooks() == [StoredNotebook(notebookId: nb, wrappedKey: blob(3, 73), pendingPut: true)])
            #expect(try store.outboxCount() == 1)
            let content = try #require(try store.loadDoc(doc))
            #expect(content.notebookId == nb)
            #expect(content.snapshotBlob == nil)
            #expect(content.updateBlobs == [blob(4), blob(5)]) // arrival order
            store.close()
        }

        // A file written by a newer version is refused rather than misread.
        var handle: OpaquePointer?
        #expect(sqlite3_open(path, &handle) == SQLITE_OK)
        #expect(sqlite3_exec(handle, "PRAGMA user_version = 99", nil, nil, nil) == SQLITE_OK)
        sqlite3_close(handle)
        #expect(throws: LocalStoreError.self) { _ = try LocalStore.open(path: path) }
    }

    @Test func theOutboxHandsOutEditsInTheOrderTheyWereMadeOneDocumentAtATime() throws {
        let store = try LocalStore.open(path: path)
        let nb = newId(), x = newId(), y = newId()
        let ids = [
            try store.appendLocalUpdate(docId: x, notebookId: nb, clientUpdateId: newId(), blob: blob(1)),
            try store.appendLocalUpdate(docId: x, notebookId: nb, clientUpdateId: newId(), blob: blob(2)),
            try store.appendLocalUpdate(docId: y, notebookId: nb, clientUpdateId: newId(), blob: blob(3)),
            try store.appendLocalUpdate(docId: x, notebookId: nb, clientUpdateId: newId(), blob: blob(4)),
        ]
        #expect(ids == ids.sorted())

        // x, x - then y must go before the last x.
        let first = try store.peekOutbox(maxCount: 10, maxBytes: .max)
        #expect(first.map(\.localId) == [ids[0], ids[1]])
        #expect(first.allSatisfy { $0.docId == x && $0.notebookId == nb })
        #expect(first.map(\.blob) == [blob(1), blob(2)])
        #expect(try store.peekOutbox(maxCount: 1, maxBytes: .max).map(\.localId) == [ids[0]])
        // The byte budget cuts a batch, but never below one entry.
        #expect(try store.peekOutbox(maxCount: 10, maxBytes: 70).map(\.localId) == [ids[0]])
        #expect(try store.peekOutbox(maxCount: 10, maxBytes: 1).map(\.localId) == [ids[0]])

        // Peeking removes nothing; only an acknowledgement does.
        #expect(try store.outboxCount() == 4)
        try store.acknowledgeOutbox([(ids[0], 11), (ids[1], 12)])
        #expect(try store.outboxCount() == 2)
        #expect(try store.peekOutbox(maxCount: 10, maxBytes: .max).map(\.localId) == [ids[2]])
        try store.acknowledgeOutbox([(ids[2], 13)])
        #expect(try store.peekOutbox(maxCount: 10, maxBytes: .max).map(\.localId) == [ids[3]])

        // The update came back through /events before the acknowledgement was stored: one copy stays.
        try store.apply { try $0.addRemoteUpdate(docId: x, notebookId: nb, seq: 14, blob: blob(4)) }
        try store.acknowledgeOutbox([(ids[3], 14)])
        #expect(try store.outboxCount() == 0)
        #expect(try store.loadDoc(x)?.updateBlobs == [blob(1), blob(2), blob(4)])
    }

    @Test func aBatchIsAllOrNothingIncludingTheCursor() throws {
        struct Boom: Error {}
        let store = try LocalStore.open(path: path)
        let nb = newId(), doc = newId()
        try store.apply { batch in
            try batch.addRemoteUpdate(docId: doc, notebookId: nb, seq: 1, blob: blob(1))
            try batch.setCursor(1)
        }
        #expect(throws: Boom.self) {
            try store.apply { batch in
                try batch.addRemoteUpdate(docId: doc, notebookId: nb, seq: 2, blob: blob(2))
                try batch.addRemoteUpdate(docId: newId(), notebookId: nb, seq: 3, blob: blob(3))
                try batch.setCursor(3)
                try batch.setFirstSyncDone()
                throw Boom()
            }
        }
        #expect(try store.cursor() == 1)
        #expect(try !store.firstSyncDone())
        #expect(try store.docs().count == 1)
        #expect(try store.loadDoc(doc)?.updateBlobs == [blob(1)])

        // The store still works, the same seq twice is stored once, and the cursor never moves backwards.
        try store.apply { batch in
            try batch.addRemoteUpdate(docId: doc, notebookId: nb, seq: 2, blob: blob(2))
            try batch.addRemoteUpdate(docId: doc, notebookId: nb, seq: 2, blob: blob(2))
            try batch.setCursor(5)
            try batch.setCursor(3)
        }
        #expect(try store.cursor() == 5)
        #expect(try store.loadDoc(doc)?.updateBlobs == [blob(1), blob(2)])
    }

    @Test func aSnapshotReplacesTheAcknowledgedUpdatesItCoversAndNothingElse() throws {
        let store = try LocalStore.open(path: path)
        let nb = newId(), doc = newId(), other = newId()
        try store.apply { batch in
            try batch.addRemoteUpdate(docId: doc, notebookId: nb, seq: 1, blob: blob(1))
            try batch.addRemoteUpdate(docId: doc, notebookId: nb, seq: 2, blob: blob(2))
            try batch.addRemoteUpdate(docId: other, notebookId: nb, seq: 3, blob: blob(3))
            try batch.addRemoteUpdate(docId: doc, notebookId: nb, seq: 5, blob: blob(5))
        }
        try store.appendLocalUpdate(docId: doc, notebookId: nb, clientUpdateId: newId(), blob: blob(6))

        try store.apply { batch in
            #expect(try batch.snapshotSeq(docId: doc) == 0)
            #expect(try batch.snapshotSeq(docId: newId()) == nil)
            try batch.setSnapshot(docId: doc, notebookId: nb, coveredSeq: 4, blob: blob(40))
        }
        var content = try #require(try store.loadDoc(doc))
        #expect(content.snapshotSeq == 4)
        #expect(content.snapshotBlob == blob(40))
        #expect(content.updateBlobs == [blob(5), blob(6)]) // seq 5 and the outbox entry stay
        #expect(try store.loadDoc(other)?.updateBlobs == [blob(3)])
        #expect(try store.outboxCount() == 1)

        // An older snapshot is ignored; an equal or newer one replaces.
        try store.apply { try $0.setSnapshot(docId: doc, notebookId: nb, coveredSeq: 3, blob: blob(30)) }
        #expect(try store.loadDoc(doc)?.snapshotBlob == blob(40))
        try store.apply { try $0.setSnapshot(docId: doc, notebookId: nb, coveredSeq: 9, blob: blob(90)) }
        content = try #require(try store.loadDoc(doc))
        #expect(content.snapshotSeq == 9)
        #expect(content.updateBlobs == [blob(6)])

        // A snapshot can be the first thing known about a document.
        let fresh = newId()
        try store.apply { try $0.setSnapshot(docId: fresh, notebookId: nb, coveredSeq: 2, blob: blob(20)) }
        #expect(try store.doc(fresh) == StoredDoc(docId: fresh, notebookId: nb, snapshotSeq: 2, damaged: false))

        // Dropping a document takes its snapshot, updates and outbox entries.
        try store.apply { try $0.dropDoc(doc) }
        #expect(try store.loadDoc(doc) == nil)
        #expect(try store.outboxCount() == 0)
    }

    @Test func compactionCandidatesCountAcknowledgedUpdatesOnlyAndSkipDamagedDocuments() throws {
        let store = try LocalStore.open(path: path)
        let nb = newId(), busy = newId(), quiet = newId(), damaged = newId(), unsent = newId()
        try store.apply { batch in
            for seq in 1...4 {
                try batch.addRemoteUpdate(docId: busy, notebookId: nb, seq: Int64(seq), blob: blob(UInt8(seq)))
                try batch.addRemoteUpdate(docId: damaged, notebookId: nb, seq: Int64(10 + seq), blob: blob(UInt8(seq)))
            }
            try batch.addRemoteUpdate(docId: quiet, notebookId: nb, seq: 20, blob: blob(1))
            try batch.markDamaged(docId: damaged, notebookId: nb)
        }
        for i in 0..<5 {
            try store.appendLocalUpdate(docId: unsent, notebookId: nb, clientUpdateId: newId(), blob: blob(UInt8(i)))
        }
        #expect(try store.docsToCompact(threshold: 3).map(\.docId) == [busy])
        #expect(try store.docsToCompact(threshold: 4).isEmpty)
        #expect(try store.doc(damaged)?.damaged == true)

        // After a snapshot the count starts again.
        try store.apply { try $0.setSnapshot(docId: busy, notebookId: nb, coveredSeq: 4, blob: blob(9)) }
        #expect(try store.docsToCompact(threshold: 0).map(\.docId) == [quiet])
    }

    @Test func replacingTheNotebookListRemovesVanishedNotebooksButKeepsUnpushedLocalOnes() throws {
        let store = try LocalStore.open(path: path)
        let kept = newId(), gone = newId(), local = newId(), new = newId()
        let goneDoc = newId(), keptDoc = newId()
        try store.apply { batch in
            #expect(try batch.replaceServerNotebooks([(kept, blob(1)), (gone, blob(2))]).isEmpty)
            try batch.addRemoteUpdate(docId: goneDoc, notebookId: gone, seq: 1, blob: blob(3))
            try batch.addRemoteUpdate(docId: keptDoc, notebookId: kept, seq: 2, blob: blob(4))
        }
        try store.addLocalNotebook(local, wrappedKey: blob(5))
        try store.appendLocalUpdate(docId: goneDoc, notebookId: gone, clientUpdateId: newId(), blob: blob(6))
        #expect(try store.pendingNotebooks().map(\.notebookId) == [local])

        let removed = try store.apply { try $0.replaceServerNotebooks([(kept, blob(7)), (new, blob(8))]) }
        #expect(removed.count == 1)
        #expect(removed.first?.notebookId == gone)
        #expect(removed.first?.docIds == [goneDoc])
        #expect(Set(try store.notebooks().map(\.notebookId)) == [kept, local, new])
        #expect(try store.notebooks().first { $0.notebookId == kept }?.wrappedKey == blob(7)) // replaced key
        #expect(try store.loadDoc(goneDoc) == nil)
        #expect(try store.outboxCount() == 0)
        #expect(try store.loadDoc(keptDoc) != nil)

        // Once pushed, a local notebook is the server's to remove.
        try store.markNotebookPushed(local)
        #expect(try store.pendingNotebooks().isEmpty)
        #expect(try store.apply { try $0.replaceServerNotebooks([(kept, blob(7))]) }.map(\.notebookId).sorted() == [local, new].sorted())
        #expect(try store.apply { try $0.docIds(notebookId: kept) } == [keptDoc])
        #expect(try store.apply { try $0.removeNotebook(kept) } == [keptDoc])
        #expect(try store.notebooks().isEmpty && store.docs().isEmpty)
    }

    @Test func aClosedStoreRefusesWork() throws {
        let store = try LocalStore.open(path: path)
        store.close()
        store.close()
        #expect(throws: LocalStoreClosedError.self) { _ = try store.cursor() }
        #expect(throws: LocalStoreClosedError.self) { try store.apply { try $0.setCursor(1) } }
    }
}

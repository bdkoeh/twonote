import Foundation
import Testing
import TwoNoteCrypto
import TwoNoteDocuments
import YrsKit
@testable import TwoNoteCore

// The scenarios of tests/TwoNote.Core.Tests/SyncTests.cs, against the in-memory server.

@MainActor
@Suite("account flows")
struct AccountTests {
    @Test func registerThenEnrolASecondDeviceAndSeeTheSameNotebook() async throws {
        let seed = try await Seed.make()
        #expect(seed.a.client.state == .unlocked)
        #expect(!seed.server.registrationOpen)
        #expect(SecretKey.parse(seed.secretKey) != nil)
        #expect(seed.a.status.pendingUpdates == 0)
        seed.page.edit { editor in
            editor.format(at: 0, count: 7, attributes: [PageAttribute.bold: .bool(true)])
            editor.setBlock(newlineAt: editor.length - 1, block: "h1", indent: 0, checked: false)
        }
        try await seed.a.syncNow()

        let b = try await seed.enrol("B")
        #expect(b.client.state == .unlocked)
        #expect(b.client.account?.username == testUsername)
        #expect(b.client.account?.deviceId != seed.a.client.account?.deviceId)
        #expect(b.client.notebookIds == [seed.notebookId])
        let tree = try await b.client.openNotebook(seed.notebookId)
        #expect(tree.title == "Kestrel field journal")
        #expect(tree.sections() == seed.tree.sections())
        #expect(tree.pages(inSection: seed.sectionId) == seed.tree.pages(inSection: seed.sectionId))
        let page = try await b.client.openPage(notebookId: seed.notebookId, pageId: seed.pageId)
        #expect(page.text == "Bittern sighting\n")
        #expect(page.runs == seed.page.runs)
        #expect(page.runs.first?.attributes[PageAttribute.bold] == .bool(true))

        // The same instance is handed out while a document is open.
        #expect(try await b.client.openPage(notebookId: seed.notebookId, pageId: seed.pageId) === page)
        #expect(try await b.client.openNotebook(seed.notebookId) === tree)

        // A second registration is refused, and leaves nothing behind.
        let c = try await Device.make(seed.server, "C")
        await #expect(throws: ApiError.self) {
            _ = try await c.client.register(username: "eve", password: "x", deviceName: "C")
        }
        #expect(c.client.state == .noAccount)
        #expect(c.secrets.get(SecretNames.secretKey) == nil)
    }

    @Test func enrolRejectsAWrongPasswordAWrongSecretKeyAndAnUnknownUser() async throws {
        let seed = try await Seed.make()
        let b = try await Device.make(seed.server, "B")
        await #expect(throws: ClientError.wrongCredentials) {
            try await b.client.enrol(username: testUsername, password: "wrong", secretKey: seed.secretKey, deviceName: "B")
        }
        await #expect(throws: ClientError.wrongCredentials) {
            try await b.client.enrol(
                username: testUsername, password: testPassword, secretKey: SecretKey.generate().formatted(), deviceName: "B")
        }
        await #expect(throws: ClientError.malformedSecretKey) {
            try await b.client.enrol(username: testUsername, password: testPassword, secretKey: "T2-NOPE", deviceName: "B")
        }
        await #expect(throws: ClientError.wrongCredentials) {
            try await b.client.enrol(username: "nobody", password: testPassword, secretKey: seed.secretKey, deviceName: "B")
        }
        #expect(b.client.state == .noAccount)
        #expect(b.secrets.get(SecretNames.secretKey) == nil)
        #expect(b.secrets.get(SecretNames.sessionToken) == nil)

        // The Secret Key is accepted in a sloppy spelling.
        try await b.client.enrol(
            username: " Bob ", password: testPassword, secretKey: seed.secretKey.lowercased().replacingOccurrences(of: "-", with: " "),
            deviceName: "B")
        #expect(b.client.state == .unlocked)
    }

    @Test func lockAndUnlockWorkFromLocalStateWithTheServerUnreachable() async throws {
        let seed = try await Seed.make()
        var a = seed.a
        a.transport.offline = true

        await a.client.lock()
        #expect(a.client.state == .locked)
        #expect(a.client.notebookIds.isEmpty)
        await #expect(throws: ClientError.locked) { _ = try await a.client.openNotebook(seed.notebookId) }
        await #expect(throws: ClientError.wrongCredentials) { try await a.client.unlock(password: "not it") }
        #expect(a.client.state == .locked)

        try await a.client.unlock(password: testPassword)
        #expect(a.client.state == .unlocked)
        #expect(a.client.notebookIds == [seed.notebookId])
        var tree = try await a.client.openNotebook(seed.notebookId)
        #expect(tree.title == "Kestrel field journal")
        var page = try await a.client.openPage(notebookId: seed.notebookId, pageId: seed.pageId)
        #expect(page.text == "Bittern sighting\n")

        // Everything works offline: edits, new pages, new notebooks.
        page.append(" at dawn")
        let second = try await a.client.createPage(notebookId: seed.notebookId, sectionId: seed.sectionId, title: "Offline page")
        second.prepend("written offline")
        let offlineNotebook = try await a.client.createNotebook(title: "Made offline")
        await #expect(throws: ServerUnreachableError.self) { try await a.syncNow() }
        #expect(a.status.state == .offline)
        #expect(a.status.lastError == nil)
        #expect(a.status.pendingUpdates > 0)

        // An app restart while offline loses nothing.
        a = try await a.restart()
        #expect(a.client.state == .locked)
        #expect(a.client.account?.username == testUsername)
        try await a.client.unlock(password: testPassword)
        #expect(a.client.notebookIds.sorted() == [seed.notebookId, offlineNotebook.notebookId].sorted())
        tree = try await a.client.openNotebook(seed.notebookId)
        #expect(tree.pages(inSection: seed.sectionId).map(\.title) == ["Tuesday at the hide", "Offline page"])
        page = try await a.client.openPage(notebookId: seed.notebookId, pageId: seed.pageId)
        #expect(page.text == "Bittern sighting at dawn\n")
        #expect(try await a.client.openPage(notebookId: seed.notebookId, pageId: second.docId).text == "written offline\n")
        #expect(try await a.client.openNotebook(offlineNotebook.notebookId).title == "Made offline")

        // Back home: the queue drains and another device sees all of it.
        a.transport.offline = false
        try await a.syncNow()
        #expect(a.status.state == .idle)
        #expect(a.status.pendingUpdates == 0)
        let b = try await seed.enrol("B")
        #expect(b.client.notebookIds.sorted() == a.client.notebookIds.sorted())
        #expect(try await b.client.openPage(notebookId: seed.notebookId, pageId: seed.pageId).text == "Bittern sighting at dawn\n")
        #expect(try await b.client.openPage(notebookId: seed.notebookId, pageId: second.docId).text == "written offline\n")
        #expect(try await b.client.openNotebook(offlineNotebook.notebookId).title == "Made offline")
    }

    @Test func passwordChangeRekeysTheAccountAndSignsOtherDevicesOutUntilTheySignInAgain() async throws {
        let seed = try await Seed.make()
        let a = seed.a
        let b = try await seed.enrol("B")
        let newPassword = "a much better password"

        await #expect(throws: ClientError.wrongCredentials) {
            try await a.client.changePassword(currentPassword: "wrong", newPassword: newPassword)
        }
        try await a.client.changePassword(currentPassword: testPassword, newPassword: newPassword)
        try await a.syncNow() // this device keeps its session

        // The other device is signed out, and says so.
        await #expect(throws: ApiError.self) { try await b.syncNow() }
        #expect(b.status.state == .authRequired)
        await #expect(throws: ClientError.wrongCredentials) { try await b.client.signInAgain(password: testPassword) }
        try await b.client.signInAgain(password: newPassword)
        try await b.syncNow()
        #expect(b.status.state == .idle)
        #expect(b.client.account?.deviceId != nil)

        // Both devices now unlock locally with the new password only.
        for device in [a, b] {
            await device.client.lock()
            await #expect(throws: ClientError.wrongCredentials) { try await device.client.unlock(password: testPassword) }
            try await device.client.unlock(password: newPassword)
            #expect(try await device.client.openNotebook(seed.notebookId).title == "Kestrel field journal")
        }

        // A device can also sign in again while locked.
        await b.client.lock()
        try await b.client.signInAgain(password: newPassword)
        #expect(b.client.state == .unlocked)
    }

    @Test func thePasswordCanBeCheckedLocallyAndDevicesCanBeListedRenamedAndRevoked() async throws {
        let seed = try await Seed.make()
        let a = seed.a
        let b = try await seed.enrol("B")

        a.transport.offline = true
        #expect(try await a.client.verifyPassword(testPassword))
        #expect(try await !a.client.verifyPassword("nope"))
        #expect(try a.client.secretKeyForDisplay() == seed.secretKey)
        a.transport.offline = false

        var devices = try await a.client.devices()
        #expect(devices.map(\.name).sorted() == ["Device A", "Device B"])
        #expect(devices.first { $0.current }?.deviceId == a.client.account?.deviceId)
        #expect(devices.allSatisfy { abs($0.createdAt.timeIntervalSinceNow) < 120 })

        let deviceId = a.client.account?.deviceId
        await #expect(throws: ClientError.wrongCredentials) { try await a.client.renameDevice(password: "nope", newName: "X") }
        try await a.client.renameDevice(password: testPassword, newName: "Bob's phone")
        #expect(a.client.account?.deviceName == "Bob's phone")
        #expect(a.client.account?.deviceId == deviceId)
        devices = try await a.client.devices()
        #expect(devices.map(\.name).sorted() == ["Bob's phone", "Device B"])
        try await a.syncNow()

        try await a.client.revokeDevice(b.client.account!.deviceId)
        #expect(try await a.client.devices().count == 1)
        await #expect(throws: ApiError.self) { try await b.syncNow() }
        #expect(b.status.state == .authRequired)
    }

    @Test func nothingSecretAndNoPlaintextReachesTheLocalDatabaseOrTheServer() async throws {
        let seed = try await Seed.make()
        seed.page.append(" - booming call heard near the reedbed")
        try await seed.a.syncNow()
        let b = try await seed.enrol("B")
        _ = try await b.client.openPage(notebookId: seed.notebookId, pageId: seed.pageId)

        let secrets = [
            "Kestrel", "Marsh observations", "Tuesday at the hide", "Bittern", "booming call", testPassword,
            seed.secretKey, seed.a.secrets.get(SecretNames.sessionToken)!, b.secrets.get(SecretNames.sessionToken)!,
        ]
        var haystacks = seed.server.requestBodies
        for device in [seed.a, b] {
            await device.client.close() // checkpoints the WAL into the main file
            for suffix in ["", "-wal"] {
                if let data = FileManager.default.contents(atPath: device.databasePath + suffix) {
                    haystacks.append(data)
                }
            }
        }
        #expect(haystacks.count > 10)
        for needle in secrets {
            let bytes = Data(needle.utf8)
            #expect(!haystacks.contains { $0.range(of: bytes) != nil }, "\"\(needle.prefix(6))…\" was found in stored or sent bytes")
        }
    }
}

@MainActor
@Suite("sync algorithm")
struct SyncAlgorithmTests {
    @Test func offlineEditsToTheSamePageAndTreeConvergeOnBothDevices() async throws {
        let seed = try await Seed.make()
        let a = seed.a
        let b = try await seed.enrol("B")
        let treeB = try await b.client.openNotebook(seed.notebookId)
        let pageB = try await b.client.openPage(notebookId: seed.notebookId, pageId: seed.pageId)

        a.transport.offline = true
        b.transport.offline = true
        seed.page.prepend("[A on the train] ")
        seed.page.edit { $0.format(at: 0, count: 3, attributes: [PageAttribute.italic: .bool(true)]) }
        seed.tree.addSection(title: "Owl pellets")
        seed.tree.renamePage(seed.pageId, title: "Renamed by A")
        pageB.append(" [B in the cellar]")
        treeB.addSection(title: "Dissection notes")
        let extra = try await b.client.createPage(notebookId: seed.notebookId, sectionId: seed.sectionId, title: "B's page")
        extra.prepend("only on B so far")
        await #expect(throws: ServerUnreachableError.self) { try await a.syncNow() }
        await #expect(throws: ServerUnreachableError.self) { try await b.syncNow() }

        a.transport.offline = false
        b.transport.offline = false
        try await a.syncNow()
        try await b.syncNow()
        try await a.syncNow()

        #expect(seed.page.text == "[A on the train] Bittern sighting [B in the cellar]\n")
        #expect(pageB.text == seed.page.text)
        #expect(pageB.runs == seed.page.runs)
        #expect(Set(seed.tree.sections().map(\.title)) == ["Marsh observations", "Owl pellets", "Dissection notes"])
        #expect(treeB.sections() == seed.tree.sections())
        #expect(treeB.allPages() == seed.tree.allPages())
        #expect(treeB.page(seed.pageId)?.title == "Renamed by A")
        #expect(try await a.client.openPage(notebookId: seed.notebookId, pageId: extra.docId).text == "only on B so far\n")
        #expect(a.status.pendingUpdates == 0 && b.status.pendingUpdates == 0)
        #expect(a.status.cursor == seed.server.head && b.status.cursor == seed.server.head)
    }

    @Test func theOutboxIsPushedInTheOrderTheEditsWereMadeEvenAcrossDocumentsAndBatches() async throws {
        let seed = try await Seed.make { $0.pushBatchSize = 2 }
        let a = seed.a
        let second = try await a.client.createPage(notebookId: seed.notebookId, sectionId: seed.sectionId, title: "Second")
        try await a.syncNow()
        let mark = seed.server.head
        let requestsBefore = seed.server.requests.count

        a.transport.offline = true
        seed.page.append("1")
        second.append("2")
        seed.page.append("3")
        seed.page.append("4")
        seed.page.append("5")
        second.append("6")
        a.transport.offline = false
        try await a.syncNow()

        let pushed = seed.server.events.filter { $0.seq > mark && $0.type == "update" }.map(\.docId)
        #expect(pushed == [seed.pageId, second.docId, seed.pageId, seed.pageId, seed.pageId, second.docId])
        // Consecutive edits to one document share a request, up to the batch size.
        let pushes = seed.server.requests.dropFirst(requestsBefore).filter { $0.hasPrefix("A POST docs/") }
        #expect(pushes.count == 5)
        #expect(a.status.pendingUpdates == 0)

        let b = try await seed.enrol("B")
        #expect(try await b.client.openPage(notebookId: seed.notebookId, pageId: seed.pageId).text == "Bittern sighting1345\n")
        #expect(try await b.client.openPage(notebookId: seed.notebookId, pageId: second.docId).text == "26\n")
    }

    @Test func eventsAreAppliedPageByPageInSeqOrderAndAReorderedPageIsRefused() async throws {
        let seed = try await Seed.make()
        let a = seed.a
        for i in 0..<25 {
            seed.page.append(" \(i)")
        }
        try await a.syncNow()

        seed.server.configure { $0.maxEventsPerPage = 4 }
        let b = try await seed.enrol("B")
        let pageB = try await b.client.openPage(notebookId: seed.notebookId, pageId: seed.pageId)
        #expect(pageB.text == seed.page.text)
        #expect(seed.server.requests.filter { $0 == "B GET events" }.count >= 7)
        #expect(b.status.cursor == seed.server.head)

        // A page that is not in seq order is refused as a whole: nothing is applied, the cursor stays.
        seed.page.append(" tail")
        seed.page.prepend("head ")
        seed.tree.addSection(title: "Later")
        try await a.syncNow()
        let cursor = b.status.cursor
        seed.server.configure { server in
            server.maxEventsPerPage = nil
            server.eventsFilter = { client, events in client == "B" ? events.reversed() : events }
        }
        await #expect(throws: ProtocolViolationError.self) { try await b.syncNow() }
        #expect(b.status.state == .error)
        #expect(b.status.lastError == "Sync failed (ProtocolViolationError).")
        #expect(b.status.cursor == cursor)
        #expect(!pageB.text.contains("tail"))

        seed.server.configure { $0.eventsFilter = nil }
        try await b.syncNow()
        #expect(b.status.state == .idle)
        #expect(pageB.text == seed.page.text)
        #expect(try await b.client.openNotebook(seed.notebookId).sections() == seed.tree.sections())
    }

    @Test func aPushWhoseAnswerIsLostIsRetriedWithTheSameIdsAndNeverDuplicated() async throws {
        let seed = try await Seed.make()
        var a = seed.a
        seed.page.append(" once")
        seed.page.append(" twice")
        a.transport.loseAnswers(matching: "/updates")
        await #expect(throws: ServerUnreachableError.self) { try await a.syncNow() }
        #expect(a.status.pendingUpdates == 2) // not acknowledged, so still in the outbox
        let updates = seed.server.events.filter { $0.type == "update" }.count

        try await a.syncNow()
        #expect(a.status.pendingUpdates == 0)
        #expect(seed.server.events.filter { $0.type == "update" }.count == updates)

        // The same across a crash: the answer is lost and the app restarts before it can retry.
        seed.page.append(" thrice")
        a.transport.loseAnswers(matching: "/updates")
        await #expect(throws: ServerUnreachableError.self) { try await a.syncNow() }
        let afterCrash = seed.server.events.filter { $0.type == "update" }.count
        a = try await a.restart()
        try await a.client.unlock(password: testPassword)
        #expect(try await a.client.openPage(notebookId: seed.notebookId, pageId: seed.pageId).text == "Bittern sighting once twice thrice\n")
        try await a.syncNow()
        #expect(a.status.pendingUpdates == 0)
        #expect(seed.server.events.filter { $0.type == "update" }.count == afterCrash)

        let b = try await seed.enrol("B")
        #expect(try await b.client.openPage(notebookId: seed.notebookId, pageId: seed.pageId).text == "Bittern sighting once twice thrice\n")
    }

    @Test func moreUnsnapshottedUpdatesThanTheThresholdAreCompactedAndANewDeviceRebuildsFromTheSnapshot() async throws {
        let seed = try await Seed.make { $0.compactionThreshold = 10 }
        let a = seed.a
        let b = try await seed.enrol("B")
        let pageB = try await b.client.openPage(notebookId: seed.notebookId, pageId: seed.pageId)
        #expect(seed.server.snapshots.isEmpty)

        for i in 0..<15 {
            seed.page.append(" \(i)")
        }
        try await a.syncNow()
        let covered = try #require(seed.server.snapshots[seed.pageId])
        #expect(seed.server.snapshots[seed.notebookId] == nil) // the tree has few updates
        #expect(!seed.server.events.contains { $0.type == "update" && $0.docId == seed.pageId && $0.seq <= covered })
        #expect(seed.server.events.contains { $0.type == "snapshot" && $0.docId == seed.pageId && $0.coveredSeq == covered })
        #expect(a.status.cursor == seed.server.head)
        let storeA = try a.inspectStore()
        #expect(try storeA.doc(seed.pageId)?.snapshotSeq == covered)
        #expect(try storeA.loadDoc(seed.pageId)?.updateBlobs.isEmpty == true)

        // A device that had part of the history gets the snapshot event and merges it.
        try await b.syncNow()
        #expect(pageB.text == seed.page.text)
        #expect(try b.inspectStore().doc(seed.pageId)?.snapshotSeq == covered)

        // A new device has only the snapshot to build from.
        let c = try await seed.enrol("C")
        #expect(seed.server.requests.contains("C GET docs/\(seed.pageId)/snapshot"))
        #expect(try await c.client.openPage(notebookId: seed.notebookId, pageId: seed.pageId).text == seed.page.text)

        // Edits after the snapshot still travel as updates, and the next snapshot replaces the first.
        for i in 0..<12 {
            pageB.append(" b\(i)")
        }
        try await b.syncNow()
        try await a.syncNow()
        #expect(seed.page.text == pageB.text)
        #expect(try #require(seed.server.snapshots[seed.pageId]) > covered)
        #expect(seed.server.requests.contains("A PUT docs/\(seed.pageId)/snapshot"))
    }

    @Test func aDeviceThatMostlyReadsCompactsTooAndItsSnapshotHoldsEverything() async throws {
        let seed = try await Seed.make()
        let b = try await seed.enrol("B") { $0.compactionThreshold = 10 }
        for i in 0..<15 {
            seed.page.append(" \(i)")
        }
        try await seed.a.syncNow()
        #expect(seed.server.snapshots.isEmpty)

        // B never opened the page: the snapshot is built from its stored ciphertext.
        try await b.syncNow()
        #expect(seed.server.requests.contains("B PUT docs/\(seed.pageId)/snapshot"))
        #expect(seed.server.snapshots[seed.pageId] != nil)

        let c = try await seed.enrol("C")
        #expect(try await c.client.openPage(notebookId: seed.notebookId, pageId: seed.pageId).text == seed.page.text)
        try await seed.a.syncNow()
        #expect(seed.a.status.state == .idle)
    }

    @Test func aTamperedBlobIsReportedAndSkippedAndEverythingElseStillApplies() async throws {
        let seed = try await Seed.make()
        let a = seed.a
        let b = try await seed.enrol("B") { $0.compactionThreshold = 3 }
        let treeB = try await b.client.openNotebook(seed.notebookId)

        let other = try await a.client.createPage(notebookId: seed.notebookId, sectionId: seed.sectionId, title: "Untouched")
        other.prepend("intact")
        try await a.syncNow()
        seed.page.append(" damaged in transit")
        try await a.syncNow()
        let damagedSeq = seed.server.head
        for i in 0..<6 {
            seed.page.append(" \(i)")
        }
        seed.tree.addSection(title: "Added afterwards")
        try await a.syncNow()
        seed.server.tamper(seq: damagedSeq)

        try await b.syncNow()
        #expect(b.status.state == .idle)
        let rejected = b.sync.issues.filter { $0.kind == .blobRejected }
        #expect(rejected.count == 1)
        #expect(rejected.first?.seq == damagedSeq)
        #expect(rejected.first?.docId == seed.pageId)
        try await eventually("the issue reaches the monitor") { b.client.syncMonitor.issues.contains { $0.kind == .blobRejected } }

        // Everything else arrived.
        #expect(treeB.sections().map(\.title).contains("Added afterwards"))
        #expect(try await b.client.openPage(notebookId: seed.notebookId, pageId: other.docId).text == "intact\n")
        #expect(b.status.cursor == seed.server.head)

        // The damaged copy is flagged, and this device never snapshots it although it is over the threshold.
        #expect(try b.inspectStore().doc(seed.pageId)?.damaged == true)
        try await b.syncNow()
        #expect(!seed.server.requests.contains("B PUT docs/\(seed.pageId)/snapshot"))
        #expect(seed.server.snapshots[seed.pageId] == nil)
    }

    @Test func aTamperedSnapshotIsRejectedOnFirstSync() async throws {
        let seed = try await Seed.make { $0.compactionThreshold = 5 }
        for i in 0..<8 {
            seed.page.append(" \(i)")
        }
        try await seed.a.syncNow()
        #expect(seed.server.snapshots[seed.pageId] != nil)
        seed.server.tamperSnapshot(docId: seed.pageId)

        let b = try await seed.enrol("B") { $0.compactionThreshold = 0 }
        #expect(b.sync.issues.contains { $0.kind == .blobRejected && $0.docId == seed.pageId })
        #expect(try b.inspectStore().doc(seed.pageId)?.damaged == true)
        #expect(!seed.server.requests.contains("B PUT docs/\(seed.pageId)/snapshot"))
        // The tree was not affected.
        #expect(try await b.client.openNotebook(seed.notebookId).title == "Kestrel field journal")
    }

    @Test func aPushToADeletedDocumentGets410AndTheOutboxForItIsDropped() async throws {
        let seed = try await Seed.make()
        let a = seed.a
        let b = try await seed.enrol("B")
        let pageB = try await b.client.openPage(notebookId: seed.notebookId, pageId: seed.pageId)
        let keeper = try await b.client.createPage(notebookId: seed.notebookId, sectionId: seed.sectionId, title: "Keeper")
        try await b.syncNow()

        // A deletes the page for good while B is offline and still typing into it.
        seed.tree.setPageDeleted(seed.pageId)
        try await a.syncNow()
        try await a.client.purgePage(notebookId: seed.notebookId, pageId: seed.pageId)
        #expect(seed.page.isDeleted)
        #expect(!seed.server.docIds.contains(seed.pageId))

        pageB.append(" typed into a page that no longer exists")
        keeper.prepend("this one survives")
        // B does not hear of the deletion before it pushes (the event is withheld).
        seed.server.configure { server in
            server.eventsFilter = { client, events in client == "B" ? events.filter { $0["type"] as? String != "docDeleted" } : events }
        }
        try await b.syncNow()
        #expect(seed.server.requests.contains("B POST docs/\(seed.pageId)/updates"))
        #expect(b.status.state == .idle)
        #expect(b.status.pendingUpdates == 0)
        #expect(pageB.isDeleted)
        #expect(try b.inspectStore().doc(seed.pageId) == nil)
        #expect(b.sync.issues.contains { $0.kind == .editsDropped && $0.docId == seed.pageId })
        #expect(!seed.server.docIds.contains(seed.pageId)) // not re-created

        // The edit to the other page went through, and later edits to the dead page go nowhere.
        try await a.syncNow()
        #expect(try await a.client.openPage(notebookId: seed.notebookId, pageId: keeper.docId).text == "this one survives\n")
        pageB.append(" more")
        try await b.syncNow()
        #expect(b.status.pendingUpdates == 0)
    }

    @Test func aDocDeletedEventDropsTheLocalDocumentAndItsUnsentEdits() async throws {
        let seed = try await Seed.make()
        let b = try await seed.enrol("B")
        let pageB = try await b.client.openPage(notebookId: seed.notebookId, pageId: seed.pageId)

        try await seed.a.client.purgePage(notebookId: seed.notebookId, pageId: seed.pageId)
        b.transport.offline = true
        pageB.append(" unsent")
        await #expect(throws: ServerUnreachableError.self) { try await b.syncNow() }
        #expect(b.status.pendingUpdates == 1)
        b.transport.offline = false

        try await b.syncNow() // pulls before it pushes
        #expect(pageB.isDeleted)
        #expect(b.status.pendingUpdates == 0)
        #expect(try b.inspectStore().doc(seed.pageId) == nil)
        #expect(!seed.server.requests.contains("B POST docs/\(seed.pageId)/updates"))
        #expect(b.sync.issues.isEmpty)
    }

    @Test func notebooksCreatedAndDeletedElsewhereAppearAndDisappear() async throws {
        let seed = try await Seed.make()
        let a = seed.a
        let b = try await seed.enrol("B")
        let revision = b.client.syncMonitor.notebooksRevision

        let second = try await a.client.createNotebook(title: "Second notebook")
        let section = second.addSection(title: "S")
        let page = try await a.client.createPage(notebookId: second.notebookId, sectionId: section, title: "P")
        page.prepend("in the second notebook")
        try await a.syncNow()
        #expect(seed.server.notebookIds.count == 2)

        try await b.syncNow()
        #expect(b.client.notebookIds.sorted() == [seed.notebookId, second.notebookId].sorted())
        try await eventually("the monitor announces the change") { b.client.syncMonitor.notebooksRevision > revision }
        let secondB = try await b.client.openNotebook(second.notebookId)
        let pageB = try await b.client.openPage(notebookId: second.notebookId, pageId: page.docId)
        #expect(secondB.title == "Second notebook")
        #expect(pageB.text == "in the second notebook\n")

        // Deleted elsewhere: the notebook, its documents and unsent edits to them go.
        try await a.client.deleteNotebook(second.notebookId)
        #expect(a.client.notebookIds == [seed.notebookId])
        #expect(second.isDeleted && page.isDeleted)
        pageB.append(" unsent")
        try await b.syncNow()
        #expect(b.client.notebookIds == [seed.notebookId])
        #expect(secondB.isDeleted && pageB.isDeleted)
        #expect(b.status.pendingUpdates == 0)
        #expect(try b.inspectStore().docs().allSatisfy { $0.notebookId == seed.notebookId })
        await #expect(throws: ClientError.unknownNotebook) { _ = try await b.client.openNotebook(second.notebookId) }

        // A notebook that never reached the server is deleted without it.
        b.transport.offline = true
        let local = try await b.client.createNotebook(title: "Never synced")
        try await b.client.deleteNotebook(local.notebookId)
        #expect(b.client.notebookIds == [seed.notebookId])
        b.transport.offline = false
        try await b.syncNow()
        #expect(seed.server.notebookIds == [seed.notebookId])
    }

    @Test func aPushIntoADeletedNotebookGets404AndTheNotebookIsDroppedOnceTheServerConfirms() async throws {
        let seed = try await Seed.make()
        let b = try await seed.enrol("B")
        let treeB = try await b.client.openNotebook(seed.notebookId)
        let pageB = try await b.client.openPage(notebookId: seed.notebookId, pageId: seed.pageId)

        try await seed.a.client.deleteNotebook(seed.notebookId)
        treeB.addSection(title: "Too late")
        pageB.append(" too late")
        seed.server.configure { server in
            server.eventsFilter = { client, events in client == "B" ? events.filter { $0["type"] as? String != "notebooksChanged" } : events }
        }
        try await b.syncNow()
        #expect(seed.server.requests.contains("B GET notebooks"))
        #expect(b.client.notebookIds.isEmpty)
        #expect(treeB.isDeleted && pageB.isDeleted)
        #expect(b.status.pendingUpdates == 0)
        #expect(try b.inspectStore().docs().isEmpty)
        #expect(b.sync.issues.contains { $0.kind == .editsDropped && $0.notebookId == seed.notebookId })
        #expect(seed.server.notebookIds.isEmpty)
    }

    @Test func remoteChangesReachAnOpenPageAsDeltasOnTheMainActor() async throws {
        let seed = try await Seed.make()
        let b = try await seed.enrol("B")
        let pageB = try await b.client.openPage(notebookId: seed.notebookId, pageId: seed.pageId)
        var changes: [TextChange] = []
        let observation = pageB.observeText { change in
            MainActor.assertIsolated()
            changes.append(change)
        }

        seed.page.edit { $0.insert("Great ", at: 0, attributes: [PageAttribute.bold: .bool(true)]) }
        try await seed.a.syncNow()
        try await b.syncNow()
        #expect(changes == [TextChange(delta: [.insert(text: "Great ", attributes: [PageAttribute.bold: .bool(true)])], source: .remote)])
        #expect(pageB.text == "Great Bittern sighting\n")

        // A page closed and opened again is rebuilt from the store, unsent edits included.
        pageB.append("!")
        observation.cancel()
        b.client.closePage(seed.pageId)
        let reopened = try await b.client.openPage(notebookId: seed.notebookId, pageId: seed.pageId)
        #expect(reopened !== pageB)
        #expect(reopened.text == "Great Bittern sighting!\n")
        pageB.append(" (edit to a closed instance is not synced)")
        try await b.syncNow()
        try await seed.a.syncNow()
        #expect(seed.page.text == "Great Bittern sighting!\n")
    }
}

@MainActor
@Suite("background loop")
struct BackgroundLoopTests {
    @Test func theLoopIsWokenByTheWebSocketAndByLocalEditsAndSurvivesAnOutage() async throws {
        let seed = try await Seed.make { $0.useWebSocket = true }
        let a = seed.a
        let b = try await seed.enrol("B") { $0.useWebSocket = true }
        let pageB = try await b.client.openPage(notebookId: seed.notebookId, pageId: seed.pageId)

        // The poll interval is a minute: everything below happens because of wake-ups.
        try await a.sync.start()
        try await b.sync.start()
        try await eventually("both sockets connect") { a.status.webSocketConnected && b.status.webSocketConnected }
        #expect(a.status.running && b.status.running)

        seed.page.append(" - live")
        try await eventually("B receives A's edit") { pageB.text == "Bittern sighting - live\n" }
        try await eventually("A is idle again") { a.status.state == .idle && a.status.pendingUpdates == 0 }
        #expect(b.client.syncMonitor.lastNotifiedHead > 0)
        pageB.append(" - and back")
        try await eventually("A receives B's edit") { seed.page.text == "Bittern sighting - live - and back\n" }
        try await eventually("the monitor shows up to date") {
            b.client.syncMonitor.status.state == .idle && b.client.syncMonitor.status.cursor == seed.server.head
                && b.client.syncMonitor.status.lastSyncedAt != nil
        }

        // Outage: the server vanishes for both. Offline is a quiet state, edits queue.
        a.transport.offline = true
        b.transport.offline = true
        seed.server.dropSockets()
        seed.page.append(" - written during the outage")
        try await eventually("A notices it is offline") { a.status.state == .offline && !a.status.webSocketConnected }
        try await eventually("B's socket is gone") { !b.status.webSocketConnected }
        #expect(a.status.pendingUpdates == 1)
        #expect(a.status.lastError == nil)
        #expect(a.sync.issues.isEmpty)
        try await Task.sleep(for: .milliseconds(500)) // several failed retries
        #expect(a.status.state == .offline)
        #expect(pageB.text == "Bittern sighting - live - and back\n")

        // The server is back: both reconnect and catch up by themselves.
        a.transport.offline = false
        b.transport.offline = false
        try await eventually("B catches up after the outage") { pageB.text == seed.page.text }
        try await eventually("both are idle and connected") {
            a.status.state == .idle && b.status.state == .idle && a.status.pendingUpdates == 0
                && a.status.webSocketConnected && b.status.webSocketConnected
        }

        // Stopping means stopping: nothing is sent until started again.
        await a.sync.stop()
        #expect(!a.status.running)
        seed.page.append(" - while stopped")
        try await Task.sleep(for: .milliseconds(300))
        #expect(!pageB.text.contains("while stopped"))
        try await eventually("the edit is queued") { a.status.pendingUpdates == 1 }
        try await a.sync.start()
        try await eventually("B receives the queued edit") { pageB.text == seed.page.text }

        // Locking stops the loop.
        await b.client.lock()
        #expect(!b.status.running)
        await a.client.close()
    }

    @Test func aRevokedDeviceStopsRetryingUntilItSignsInAgain() async throws {
        let seed = try await Seed.make()
        let b = try await seed.enrol("B")
        try await b.sync.start()
        try await eventually("B is idle") { b.status.state == .idle && b.status.lastSyncedAt != nil }

        try await seed.a.client.changePassword(currentPassword: testPassword, newPassword: "new password")
        let pageB = try await b.client.openPage(notebookId: seed.notebookId, pageId: seed.pageId)
        pageB.append(" queued")
        try await eventually("B needs to sign in") { b.status.state == .authRequired }
        let attempts = seed.server.requests.filter { $0.hasPrefix("B GET events") }.count
        try await Task.sleep(for: .milliseconds(400))
        #expect(seed.server.requests.filter { $0.hasPrefix("B GET events") }.count == attempts) // no retry storm

        try await b.client.signInAgain(password: "new password")
        try await eventually("B syncs again") { b.status.state == .idle && b.status.pendingUpdates == 0 }
        try await seed.a.syncNow()
        #expect(seed.page.text == "Bittern sighting queued\n")
        await b.client.close()
    }
}

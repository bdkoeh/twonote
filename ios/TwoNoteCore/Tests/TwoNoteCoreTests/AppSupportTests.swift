import Foundation
import Testing
import TwoNoteCrypto
import TwoNoteDocuments
import YrsKit
@testable import TwoNoteCore

// What the iOS app needs beyond the Windows client's core: unlocking with a stored unlock key
// (biometric unlock), reading page text without opening the page (search), and a status that
// counts documents rather than updates.

@MainActor
@Suite("app support")
struct AppSupportTests {
    @Test func theUnlockKeyStandsInForThePasswordUntilThePasswordChanges() async throws {
        let seed = try await Seed.make()
        var a = seed.a

        await #expect(throws: ClientError.wrongCredentials) { _ = try await a.client.unlockKey(password: "not the password") }
        let key = try await a.client.unlockKey(password: testPassword)
        #expect(key.count == 32)
        #expect(key != Data(testPassword.utf8))

        // Already unlocked: the key is not a way around the state machine.
        await #expect(throws: ClientError.wrongState(expected: .locked, actual: .unlocked)) { try await a.client.unlock(unlockKey: key) }

        // After a restart it unlocks, offline, and the device syncs with its stored token.
        a = try await a.restart()
        #expect(a.client.state == .locked)
        a.transport.offline = true
        var wrong = key
        wrong[0] ^= 1
        await #expect(throws: ClientError.wrongCredentials) { try await a.client.unlock(unlockKey: wrong) }
        await #expect(throws: ClientError.wrongCredentials) { try await a.client.unlock(unlockKey: Data()) }
        #expect(a.client.state == .locked)
        try await a.client.unlock(unlockKey: key)
        #expect(a.client.state == .unlocked)
        #expect(a.client.notebookIds == [seed.notebookId])
        let page = try await a.client.openPage(notebookId: seed.notebookId, pageId: seed.pageId)
        #expect(page.text == "Bittern sighting\n")
        a.transport.offline = false
        page.append(" at dusk")
        try await a.syncNow()
        #expect(a.status.pendingUpdates == 0)

        // A password change wraps the vault key under a new unlock key: the old one opens nothing.
        try await a.client.changePassword(currentPassword: testPassword, newPassword: "another password")
        let newKey = try await a.client.unlockKey(password: "another password")
        #expect(newKey != key)
        await a.client.lock()
        await #expect(throws: ClientError.wrongCredentials) { try await a.client.unlock(unlockKey: key) }
        try await a.client.unlock(unlockKey: newKey)
        #expect(a.client.state == .unlocked)
        await a.client.close()
    }

    @Test func pageTextIsReadWithoutOpeningThePageAndVersionsShowWhatChanged() async throws {
        let seed = try await Seed.make()
        let b = try await seed.enrol("B")

        // Not open on B: rebuilt from the store, nothing registered.
        #expect(try await b.client.pageText(notebookId: seed.notebookId, pageId: seed.pageId) == "Bittern sighting\n")
        let before = try await b.client.documentVersions()
        #expect(before[seed.pageId] != nil && before[seed.notebookId] != nil)
        #expect(try await b.client.documentVersions() == before, "nothing changed")

        // A change from the other device moves the page's version, and only the page's.
        seed.page.append(" - booming")
        try await seed.a.syncNow()
        try await b.syncNow()
        let after = try await b.client.documentVersions()
        #expect(after[seed.pageId] != before[seed.pageId])
        #expect(after[seed.notebookId] == before[seed.notebookId])
        #expect(try await b.client.pageText(notebookId: seed.notebookId, pageId: seed.pageId) == "Bittern sighting - booming\n")

        // Open: the live document's text, including what is not stored yet.
        let page = try await b.client.openPage(notebookId: seed.notebookId, pageId: seed.pageId)
        page.prepend("Dawn. ")
        #expect(try await b.client.pageText(notebookId: seed.notebookId, pageId: seed.pageId) == "Dawn. Bittern sighting - booming\n")
        await b.client.flushPendingEdits()
        #expect(try await b.client.documentVersions()[seed.pageId] != after[seed.pageId])

        // Nothing stored for a page, an unknown notebook, a locked client.
        let empty = seed.tree.addPage(inSection: seed.sectionId, title: "No content yet")
        #expect(try await b.client.pageText(notebookId: seed.notebookId, pageId: empty) == nil)
        await #expect(throws: ClientError.unknownNotebook) {
            _ = try await b.client.pageText(notebookId: String(repeating: "0", count: 32), pageId: seed.pageId)
        }
        await b.client.lock()
        await #expect(throws: ClientError.locked) { _ = try await b.client.pageText(notebookId: seed.notebookId, pageId: seed.pageId) }
        await #expect(throws: ClientError.locked) { _ = try await b.client.documentVersions() }
        await b.client.close()
    }

    @Test func theStatusCountsDocumentsWithUnsentEditsAndKnowsUnsentNotebooks() async throws {
        let seed = try await Seed.make()
        let a = seed.a
        #expect(a.status.pendingPages == 0 && a.status.pendingNotebooks == 0)
        #expect(await a.client.isNotebookOnServer(seed.notebookId))

        a.transport.offline = true
        for word in ["one ", "two ", "three "] {
            seed.page.append(word)
        }
        await a.client.flushPendingEdits()
        #expect(a.status.pendingUpdates == 3)
        #expect(a.status.pendingPages == 1 && a.status.pendingNotebooks == 0)

        seed.tree.renamePage(seed.pageId, title: "Renamed")
        let second = try await a.client.createPage(notebookId: seed.notebookId, sectionId: seed.sectionId, title: "Second")
        second.append("text")
        await a.client.flushPendingEdits()
        #expect(a.status.pendingPages == 2 && a.status.pendingNotebooks == 1)

        let local = try await a.client.createNotebook(title: "Made offline")
        await a.client.flushPendingEdits()
        #expect(a.status.pendingNotebooks == 2)
        #expect(await a.client.isNotebookOnServer(local.notebookId) == false)

        a.transport.offline = false
        try await a.syncNow()
        #expect(a.status.pendingUpdates == 0 && a.status.pendingPages == 0 && a.status.pendingNotebooks == 0)
        #expect(await a.client.isNotebookOnServer(local.notebookId))
        await a.client.close()
    }

    @Test func aPageCanBeCreatedUnderAnIdTheCallerChoseAndOnlyOnce() async throws {
        let seed = try await Seed.make()
        let a = seed.a
        let pageId = "000102030405060708090a0b0c0d0e0f"
        let page = try await a.client.createPage(notebookId: seed.notebookId, sectionId: seed.sectionId, title: "Shared", pageId: pageId)
        #expect(page.docId == pageId)
        #expect(seed.tree.page(pageId)?.title == "Shared")
        page.append("from the share sheet")

        await #expect(throws: ClientError.self) {
            _ = try await a.client.createPage(notebookId: seed.notebookId, sectionId: seed.sectionId, title: "Again", pageId: pageId)
        }
        await #expect(throws: ClientError.self) {
            _ = try await a.client.createPage(notebookId: seed.notebookId, sectionId: seed.sectionId, title: "Bad", pageId: "not an id")
        }
        #expect(seed.tree.pages(inSection: seed.sectionId).map(\.title) == ["Tuesday at the hide", "Shared"])

        // It syncs like any other page.
        try await a.syncNow()
        let b = try await seed.enrol("B")
        let tree = try await b.client.openNotebook(seed.notebookId)
        #expect(tree.page(pageId)?.title == "Shared")
        #expect(try await b.client.pageText(notebookId: seed.notebookId, pageId: pageId) == "from the share sheet\n")
        await a.client.close()
        await b.client.close()
    }

    @Test func aSecretSealedForThisDeviceOpensOnlyWhileUnlockedAndOnlyForThisAccount() async throws {
        let seed = try await Seed.make()
        var a = seed.a
        let secret = SecretBytes.random(count: 32)
        let blob = try a.client.sealForThisDevice(secret, label: "share-inbox")
        #expect(blob.range(of: secret.copyToData()) == nil)
        #expect(try a.client.openForThisDevice(blob, label: "share-inbox") == secret)
        #expect(throws: SealedBlobError.authenticationFailed) { try a.client.openForThisDevice(blob, label: "something else") }

        await a.client.lock()
        #expect(throws: ClientError.locked) { try a.client.openForThisDevice(blob, label: "share-inbox") }
        #expect(throws: ClientError.locked) { try a.client.sealForThisDevice(secret, label: "share-inbox") }

        // Still opens after a restart and after a password change (the vault key stays the same).
        a = try await a.restart()
        try await a.client.unlock(password: testPassword)
        #expect(try a.client.openForThisDevice(blob, label: "share-inbox") == secret)
        try await a.client.changePassword(currentPassword: testPassword, newPassword: "another password")
        #expect(try a.client.openForThisDevice(blob, label: "share-inbox") == secret)

        // Another account's vault key does not open it.
        let stranger = try await Seed.make()
        #expect(throws: SealedBlobError.authenticationFailed) { try stranger.a.client.openForThisDevice(blob, label: "share-inbox") }
        await a.client.close()
        await stranger.a.client.close()
    }
}

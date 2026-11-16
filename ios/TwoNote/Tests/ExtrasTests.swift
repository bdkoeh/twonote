import Foundation
import SwiftUI
import Testing
import TwoNoteCrypto
import TwoNoteDocuments
import UIKit
import YrsKit
@testable import TwoNote
@testable import TwoNoteCore

// Share to TwoNote, twonote:// links and the widget's titles, against the in-memory protocol
// server. The share extension's own code path (ShareDraft, ShareInbox) is compiled into the
// app as well, so these tests run exactly what the extension runs, minus its sheet.

/// Every file under a folder with its content, for looking for things that must not be there.
private func files(under folder: URL) -> [(name: String, data: Data)] {
    guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
    var found: [(String, Data)] = []
    for case let file as URL in walker where (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
        found.append((file.path.replacingOccurrences(of: folder.path + "/", with: ""), (try? Data(contentsOf: file)) ?? Data()))
    }
    return found.sorted { $0.0 < $1.0 }
}

private func contains(_ text: String, in folder: URL) -> Bool {
    files(under: folder).contains { $0.data.range(of: Data(text.utf8)) != nil }
}

extension Installation {
    var inbox: ShareInbox { ShareInbox(container: shared) }
    var shareKeyURL: URL { AppModel.shareKeyURL(environment) }

    /// Pages of a section as the app shows them.
    func titles(_ library: LibraryModel, notebookId: String, section: String) -> [String] {
        guard let notebook = library.notebook(notebookId), let section = notebook.sections.first(where: { $0.title == section }) else { return [] }
        return notebook.pages(in: section.id).map(\.title)
    }
}

@Suite("shared items: plain logic")
struct ShareLogicTests {
    @Test func whatTheHostHandsOverBecomesTitleTextAndLink() {
        // Safari: the address, and the page title as the item's descriptive text.
        let safari = ShareDraft(ShareInput(contentText: "Bitterns | Marsh Birds", urls: ["https://example.org/birds/bittern?x=1"]))
        #expect(safari.suggestedTitle == "Bitterns | Marsh Birds")
        #expect(safari.text == "" && safari.url == "https://example.org/birds/bittern?x=1")

        // Text alone: the first line is the title; paragraphs are kept, noise is not.
        let text = ShareDraft(ShareInput(texts: ["\n  Booming call at dawn  \r\n\r\n\r\n\r\nSecond paragraph.\u{2028}Third.\n\n"]))
        #expect(text.text == "  Booming call at dawn\n\nSecond paragraph.\nThird.")
        #expect(text.suggestedTitle == "Booming call at dawn")
        #expect(text.url == nil)

        // Text and a link together (a selection shared from a web page).
        let both = ShareDraft(ShareInput(texts: ["Seen near the reedbed."], urls: ["https://example.org/a"]))
        #expect(both.text == "Seen near the reedbed." && both.url == "https://example.org/a")
        #expect(both.suggestedTitle == "Seen near the reedbed.")
        let titled = ShareDraft(ShareInput(title: "Field notes\n", contentText: "ignored page title", texts: ["Seen."], urls: ["https://example.org/a"]))
        #expect(titled.suggestedTitle == "Field notes")
        #expect(titled.text == "Seen.")

        // A link handed over as plain text is still a link; a long description is text.
        let plainLink = ShareDraft(ShareInput(texts: [" https://example.org/plain \n"]))
        #expect(plainLink.url == "https://example.org/plain" && plainLink.text == "" && plainLink.suggestedTitle == "example.org")
        let described = ShareDraft(ShareInput(contentText: "Line one\nLine two", urls: ["https://example.org/a"]))
        #expect(described.text == "Line one\nLine two" && described.suggestedTitle == "Line one")
        #expect(ShareDraft(ShareInput(contentText: "Just a remark")).text == "Just a remark")
        #expect(ShareDraft(ShareInput(contentText: "https://example.org/a", urls: ["https://example.org/a"])).text == "")

        // Nothing TwoNote can keep: files, other schemes, emptiness.
        #expect(ShareDraft(ShareInput(urls: ["file:///private/var/mobile/photo.jpg"])).isEmpty)
        #expect(ShareDraft(ShareInput(urls: ["ftp://example.org/x", "javascript:alert(1)", "https://"])).isEmpty)
        #expect(ShareDraft(ShareInput(texts: [" \n\n "])).isEmpty)
        #expect(ShareDraft(ShareInput()).isEmpty)

        // A long first line is cut at a word for the title; the text keeps all of it.
        let long = String(repeating: "reeds and water ", count: 12).trimmingCharacters(in: .whitespaces)
        let cut = ShareDraft(ShareInput(texts: [long]))
        #expect(cut.suggestedTitle.count <= 81 && cut.suggestedTitle.hasSuffix("…") && long.hasPrefix(cut.suggestedTitle.dropLast()))
        #expect(cut.text == long)

        // The title the user typed wins; an emptied field falls back to the suggestion.
        #expect(safari.item(title: "  My own title \n").title == "My own title")
        #expect(safari.item(title: "   ").title == "Bitterns | Marsh Birds")
        let item = both.item(title: "")
        #expect(item.isValid && SharedItem.isId(item.id) && item.id != both.item(title: "").id)
    }

    @Test func itemsAreBoundedAndCheckedAgainOnArrival() throws {
        let huge = SharedItem(title: String(repeating: "t", count: 500), text: String(repeating: "😀", count: 80_000), url: nil)
        #expect(huge.title.count == SharedItem.maxTitleLength)
        #expect(huge.text.utf16.count == SharedItem.maxTextLength && huge.text.unicodeScalars.allSatisfy { $0 == "😀" })
        #expect(huge.isValid)
        #expect(SharedItem(title: "x", text: "a\0b", url: nil).text == "ab")
        #expect(SharedItem(title: "x", text: "", url: "https://example.org/" + String(repeating: "a", count: 5000)).url == nil)

        // Whatever is decoded from a file is not trusted to be clean.
        func decoded(_ change: (inout [String: Any]) -> Void) throws -> SharedItem? {
            var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(SharedItem(title: "t", text: "x", url: nil))) as? [String: Any])
            change(&object)
            return try? JSONDecoder().decode(SharedItem.self, from: JSONSerialization.data(withJSONObject: object))
        }
        #expect(try decoded { _ in }?.isValid == true)
        #expect(try decoded { $0["id"] = "../../etc" }?.isValid == false)
        #expect(try decoded { $0["id"] = "00112233445566778899AABBCCDDEEFF" }?.isValid == false)
        #expect(try decoded { $0["v"] = 2 }?.isValid == false)
        #expect(try decoded { $0["title"] = "two\nlines" }?.isValid == false)
        #expect(try decoded { $0["text"] = "trailing \n\n" }?.isValid == false)
        #expect(try decoded { $0["url"] = "file:///etc/passwd" }?.isValid == false)
        #expect(try decoded { $0["title"] = ""; $0["text"] = "" }?.isValid == false)
        #expect(try decoded { $0["text"] = 5 } == nil)
    }

    @Test func aSharedItemBecomesTextThenARealLink() {
        let link = "https://example.org/birds"
        #expect(SharedItemPage.runs(SharedItem(title: "t", text: "", url: link)) == [TextRun(text: link, attributes: [PageAttribute.link: .string(link)])])
        #expect(SharedItemPage.runs(SharedItem(title: "t", text: "One\n\nTwo", url: nil)) == [TextRun(text: "One\n\nTwo")])
        #expect(SharedItemPage.runs(SharedItem(title: "t", text: "One\nTwo", url: link)) == [
            TextRun(text: "One\nTwo\n"), TextRun(text: link, attributes: [PageAttribute.link: .string(link)]),
        ])
        #expect(SharedItemPage.runs(SharedItem(title: "only a title", text: "", url: nil)).isEmpty)
    }

    @Test func linksAreReadStrictly() throws {
        let notebook = "000102030405060708090a0b0c0d0e0f", page = "f0e0d0c0b0a090807060504030201000"
        #expect(DeepLink(url: URL(string: "twonote://new")!) == .newNote)
        #expect(DeepLink(url: URL(string: "TWONOTE://Search")!) == .search)
        #expect(DeepLink(url: URL(string: "twonote://continue/")!) == .continueLast)
        #expect(DeepLink(url: URL(string: "twonote://page/\(notebook)/\(page)")!) == .page(notebookId: notebook, pageId: page))
        for link in [DeepLink.newNote, .search, .continueLast, .page(notebookId: notebook, pageId: page)] {
            #expect(DeepLink(url: link.url) == link)
        }
        for bad in [
            "https://new", "twonote:new", "twonote://", "twonote://new/extra", "twonote://new?title=x", "twonote://new#x",
            "twonote://delete", "twonote://page", "twonote://page/\(notebook)", "twonote://page/\(notebook)/\(page)/more",
            "twonote://page/\(notebook)/NOTANID", "twonote://page/\(notebook.uppercased())/\(page)", "twonote://user@new", "twonote://new:80",
        ] {
            #expect(DeepLink(url: try #require(URL(string: bad))) == nil, "\(bad)")
        }
    }
}

@MainActor
@Suite("shared items", .serialized)
struct ShareInboxTests {
    @Test func whatIsSharedWhileLockedIsSealedAndBecomesPagesAfterUnlockThatSync() async throws {
        let seed = try await Seed.make()
        let phone = Installation(seed.server)

        // Before the app was ever unlocked on this device there is nothing to seal to.
        #expect(phone.inbox.publicKey == nil)
        #expect(throws: ShareInbox.Failure.notSetUp) { try phone.inbox.add(SharedItem(title: "t", text: "x", url: nil)) }
        #expect(files(under: phone.shared.root).isEmpty)

        var (app, library) = try await phone.launchEnrolled(seed)
        // Unlocking made the inbox: a public key for the extension, the private key sealed
        // under the vault key in the app's own folder.
        let publicKey = try #require(phone.inbox.publicKey)
        let wrapped = try Data(contentsOf: phone.shareKeyURL)
        #expect(wrapped.count == 32 + SealedBlob.overhead)
        #expect(files(under: phone.shared.root).map(\.name) == ["share-inbox.pub"])
        let privateKey = try #require(app.client).openForThisDevice(wrapped, label: ShareImporter.keyLabel)
        #expect(try SealedBox.publicKey(for: privateKey) == publicKey)
        #expect(wrapped.range(of: privateKey.copyToData()) == nil)

        await app.lock()
        let lockedClient = try #require(app.client)
        #expect(throws: ClientError.locked) { try lockedClient.openForThisDevice(wrapped, label: ShareImporter.keyLabel) }

        // The share extension, while the app is locked.
        let link = "https://example.org/birds/bittern"
        let article = ShareDraft(ShareInput(contentText: "Bitterns of the marsh", urls: [link])).item(title: "")
        let remark = ShareDraft(ShareInput(texts: ["Booming call at dawn.\n\nRefill the thermos tomorrow."], urls: ["https://example.org/calls"]))
            .item(title: "Dawn notes")
        try phone.inbox.add(article)
        try phone.inbox.add(remark)
        #expect(phone.inbox.waitingItems().count == 2)
        for secret in ["Bitterns", "bittern", "Booming", "thermos", "Dawn notes", "example.org", article.id, remark.id] {
            #expect(!contains(secret, in: phone.shared.root), "“\(secret)” is readable in the App Group container")
        }
        // The extension cannot read back what it sealed: the public key opens nothing.
        let sealed = try Data(contentsOf: try #require(phone.inbox.waitingItems().first))
        #expect(throws: SealedBoxError()) { try SealedBox.open(sealed, publicKey: publicKey, privateKey: SecretBytes(copying: publicKey)) }

        // A locked app does not touch them, and knows only how many there are.
        await app.importSharedItems()
        #expect(app.waitingSharedItems == 2 && phone.inbox.waitingItems().count == 2)
        await app.client?.close()
        app = await phone.launch()
        #expect(app.phase == .locked && app.waitingSharedItems == 2)

        try await app.unlock(password: testPassword)
        library = try #require(app.library)
        #expect(app.waitingSharedItems == 0)
        #expect(phone.inbox.waitingItems().isEmpty)
        #expect(library.notice?.text == "2 Shared Items Added")
        // First use: a section called Inbox in the first notebook, which is now the destination.
        #expect(phone.titles(library, notebookId: seed.notebookId, section: "Inbox") == ["Bitterns of the marsh", "Dawn notes"])
        let inboxId = try #require(library.notebook(seed.notebookId)?.sections.first { $0.title == "Inbox" }?.id)
        #expect(library.chosenShareDestination?.sectionId == inboxId)
        #expect(library.notice?.sectionId == inboxId)
        #expect(library.shareDestinationSummary == "Kestrel field journal › Inbox")

        let articlePage = try await library.open(PageRef(notebookId: seed.notebookId, pageId: article.id)).page
        #expect(articlePage.runs == [TextRun(text: link, attributes: [PageAttribute.link: .string(link)]), TextRun(text: "\n")])
        let remarkPage = try await library.open(PageRef(notebookId: seed.notebookId, pageId: remark.id)).page
        #expect(remarkPage.text == "Booming call at dawn.\n\nRefill the thermos tomorrow.\nhttps://example.org/calls\n")
        #expect(remarkPage.runs.contains(TextRun(text: "https://example.org/calls", attributes: [PageAttribute.link: .string("https://example.org/calls")])))
        #expect(remarkPage.runs.first == TextRun(text: "Booming call at dawn.\n\nRefill the thermos tomorrow.\n"))

        // They sync like any other page.
        try await eventually("the first device receives the shared pages") {
            try await seed.a.syncNow()
            let text = try? await seed.a.client.pageText(notebookId: seed.notebookId, pageId: remark.id)
            return seed.tree.page(article.id)?.title == "Bitterns of the marsh" && text?.hasSuffix("https://example.org/calls\n") == true
        }
        #expect(seed.tree.sections().map(\.title) == ["Marsh observations", "Inbox"])

        // Shared while the app is unlocked: added as soon as the app hears of it; the Inbox is reused.
        try phone.inbox.add(SharedItem(title: "While open", text: "x", url: nil))
        await app.importSharedItems()
        #expect(phone.titles(library, notebookId: seed.notebookId, section: "Inbox").last == "While open")
        #expect(library.notebook(seed.notebookId)?.sections.count == 2)
        #expect(library.notice?.text == "1 Shared Item Added")
        await app.lock()
    }

    @Test func anItemIsNeverAddedTwiceAndAHalfMadePageIsFinished() async throws {
        let seed = try await Seed.make()
        let phone = Installation(seed.server)
        let (app, library) = try await phone.launchEnrolled(seed)
        func pageCount() -> Int { library.notebook(seed.notebookId)?.pages.values.reduce(0) { $0 + $1.count } ?? 0 }

        // The app died after making the page and before removing the file: the file is back.
        let item = SharedItem(title: "Once", text: "Only once.", url: nil)
        try phone.inbox.add(item)
        let file = try #require(phone.inbox.waitingItems().first)
        let copy = try Data(contentsOf: file)
        await app.importSharedItems()
        #expect(pageCount() == 2 && !FileManager.default.fileExists(atPath: file.path))
        try copy.write(to: file)
        library.notice = nil
        await app.importSharedItems()
        #expect(pageCount() == 2, "the item was added a second time")
        #expect(phone.inbox.waitingItems().isEmpty)
        #expect(library.notice == nil, "nothing was added, so nothing is announced")
        #expect(try await app.client?.pageText(notebookId: seed.notebookId, pageId: item.id) == "Only once.\n")

        // The same after a relaunch (a new process finds the file again).
        try copy.write(to: file)
        await app.lock()
        try await app.unlock(password: testPassword)
        let relaunched = try #require(app.library)
        #expect(relaunched.notebook(seed.notebookId)?.pages.values.reduce(0) { $0 + $1.count } == 2)
        #expect(phone.inbox.waitingItems().isEmpty)

        // It died between the page's entry in the notebook and the page's text: the text is written now.
        let half = SharedItem(title: "Half", text: "The rest of it.", url: "https://example.org/half")
        try phone.inbox.add(half)
        let section = try #require(relaunched.chosenShareDestination).sectionId
        try #require(relaunched.tree(seed.notebookId)).addPage(inSection: section, title: "Half", id: half.id)
        await app.importSharedItems()
        #expect(phone.inbox.waitingItems().isEmpty)
        #expect(relaunched.notebook(seed.notebookId)?.pages(in: section).map(\.title) == ["Once", "Half"])
        #expect(try await app.client?.pageText(notebookId: seed.notebookId, pageId: half.id) == "The rest of it.\nhttps://example.org/half\n")

        // The user deleted the page before the leftover file was seen again: it stays deleted.
        try copy.write(to: file)
        relaunched.deletePage(PageRef(notebookId: seed.notebookId, pageId: item.id))
        await app.importSharedItems()
        #expect(phone.inbox.waitingItems().isEmpty)
        #expect(relaunched.notebook(seed.notebookId)?.pages(in: section).map(\.title) == ["Half"])
        #expect(relaunched.tree(seed.notebookId)?.page(item.id)?.deleted == true)
        await app.lock()
    }

    @Test func damagedForeignAndOversizedFilesAreRemovedAndTheInboxIsCapped() async throws {
        let seed = try await Seed.make()
        let phone = Installation(seed.server)
        let (app, library) = try await phone.launchEnrolled(seed)
        let publicKey = try #require(phone.inbox.publicKey)
        let folder = phone.shared.inboxURL
        func drop(_ name: String, _ data: Data) throws {
            try data.write(to: folder.appendingPathComponent(name))
        }
        func sealedJSON(_ object: [String: Any]) throws -> Data {
            try SealedBox.seal(JSONSerialization.data(withJSONObject: object), to: publicKey)
        }

        try drop("garbage.tnshare", Data("not a sealed box at all, just some bytes that are long enough".utf8))
        try drop("empty.tnshare", Data())
        try drop("foreign.tnshare", SealedBox.seal(Data("{}".utf8), to: SealedBox.generateKeyPair().publicKey))
        try drop("notjson.tnshare", SealedBox.seal(Data("hello".utf8), to: publicKey))
        try drop("badid.tnshare", sealedJSON(["v": 1, "id": "../escape", "createdAt": 0, "title": "t", "text": "x"]))
        try drop("future.tnshare", sealedJSON(["v": 9, "id": SharedItem.newId(), "createdAt": 0, "title": "t", "text": "x"]))
        try drop("huge.tnshare", Data(count: ShareInbox.maxItemSize + 1))
        var tampered = try SealedBox.seal(JSONEncoder().encode(SharedItem(title: "Tampered", text: "x", url: nil)), to: publicKey)
        tampered[60] ^= 0x01
        try drop("tampered.tnshare", tampered)
        // What a killed extension leaves: removed once it is old, left alone while it may still be written.
        try drop(".old.partial", Data(count: 10))
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-3600)], ofItemAtPath: folder.appendingPathComponent(".old.partial").path)
        try drop(".fresh.partial", Data(count: 10))
        try phone.inbox.add(SharedItem(title: "The good one", text: "Kept.", url: nil))
        #expect(phone.inbox.waitingItems().count == 9)

        await app.importSharedItems()
        #expect(files(under: folder).map(\.name) == [".fresh.partial"])
        #expect(app.waitingSharedItems == 0)
        #expect(phone.titles(library, notebookId: seed.notebookId, section: "Inbox") == ["The good one"])
        #expect(library.notice?.text == "1 Shared Item Added")

        // An item sealed to an older key pair (the key file was lost) cannot be opened: dropped, and the inbox works on.
        try phone.inbox.add(SharedItem(title: "Sealed to the old key", text: "x", url: nil))
        try FileManager.default.removeItem(at: phone.shareKeyURL)
        await app.importSharedItems()
        #expect(phone.inbox.waitingItems().isEmpty)
        let renewed = try #require(phone.inbox.publicKey)
        #expect(renewed != publicKey)
        try phone.inbox.add(SharedItem(title: "Sealed to the new key", text: "x", url: nil))
        await app.importSharedItems()
        #expect(phone.titles(library, notebookId: seed.notebookId, section: "Inbox") == ["The good one", "Sealed to the new key"])

        // The inbox does not grow without bound while the app is not opened.
        await app.lock()
        for index in 0..<ShareInbox.maxItems {
            try drop("filler-\(index).tnshare", Data([1]))
        }
        #expect(throws: ShareInbox.Failure.full) { try phone.inbox.add(SharedItem(title: "One too many", text: "x", url: nil)) }
        try await app.unlock(password: testPassword)
        #expect(phone.inbox.waitingItems().isEmpty)
        await app.lock()
    }

    @Test func itemsGoToTheChosenSectionAndWaitWhileThereIsNoNotebook() async throws {
        // An account without a notebook: what is shared waits, and is added when one arrives.
        let server = FakeServer()
        let desk = try await Device.make(server, "A")
        let secretKey = try await desk.client.register(username: testUsername, password: testPassword, deviceName: "Desk")
        try await desk.syncNow()
        let phone = Installation(server)
        let app = await phone.launch()
        try await app.enrol(server: fakeServerAddress, username: testUsername, password: testPassword, secretKey: secretKey, deviceName: "Phone")
        let library = try #require(app.library)
        try phone.inbox.add(SharedItem(title: "Early bird", text: "x", url: nil))
        await app.importSharedItems()
        #expect(app.waitingSharedItems == 1 && library.notice == nil)
        #expect(library.shareDestinationSummary == "Inbox")

        let journal = try await desk.client.createNotebook(title: "Journal")
        let marsh = journal.addSection(title: "Marsh")
        try await desk.syncNow()
        try await eventually("the waiting item is added once a notebook is there") {
            phone.titles(library, notebookId: journal.notebookId, section: "Inbox") == ["Early bird"]
        }
        try await eventually("the count is cleared") { app.waitingSharedItems == 0 && phone.inbox.waitingItems().isEmpty }

        // The user picks a section; then deletes it: back to the Inbox.
        try await eventually("the other section is here") { library.notebook(journal.notebookId)?.section(marsh) != nil }
        library.chooseShareDestination((journal.notebookId, marsh))
        #expect(library.shareDestinationSummary == "Journal › Marsh")
        try phone.inbox.add(SharedItem(title: "To the marsh", text: "x", url: nil))
        await app.importSharedItems()
        #expect(phone.titles(library, notebookId: journal.notebookId, section: "Marsh") == ["To the marsh"])
        #expect(library.notice?.sectionId == marsh)

        library.deleteSection(notebookId: journal.notebookId, sectionId: marsh)
        #expect(library.chosenShareDestination == nil)
        #expect(library.shareDestinationSummary == "Journal › Inbox")
        try phone.inbox.add(SharedItem(title: "Back to the inbox", text: "x", url: nil))
        await app.importSharedItems()
        #expect(phone.titles(library, notebookId: journal.notebookId, section: "Inbox") == ["Early bird", "Back to the inbox"])
        #expect(library.notebook(journal.notebookId)?.sections.map(\.title) == ["Inbox"], "the existing Inbox is used, not a second one")

        library.chooseShareDestination(nil)
        #expect(library.chosenShareDestination == nil)
        await app.lock()
        await desk.client.close()
    }

    @Test func signingOutRemovesTheInboxItsKeysAndWhatWasWaiting() async throws {
        let seed = try await Seed.make()
        let phone = Installation(seed.server)
        let (app, library) = try await phone.launchEnrolled(seed)
        library.chooseShareDestination((seed.notebookId, seed.sectionId))
        await app.lock()
        try phone.inbox.add(SharedItem(title: "Never opened", text: "x", url: nil))
        #expect(files(under: phone.shared.root).count == 2)

        await app.removeAccount()
        #expect(files(under: phone.shared.root).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: phone.shareKeyURL.path))
        #expect(phone.inbox.publicKey == nil)
        #expect(app.waitingSharedItems == 0)
        #expect(phone.defaults.string(forKey: ShareDestination.notebookKey) == nil && phone.defaults.string(forKey: ShareDestination.sectionKey) == nil)
        #expect(throws: ShareInbox.Failure.notSetUp) { try phone.inbox.add(SharedItem(title: "t", text: "x", url: nil)) }

        // Signing in again makes a new key pair.
        try await app.enrol(server: fakeServerAddress, username: testUsername, password: testPassword, secretKey: seed.secretKey, deviceName: "Phone")
        #expect(phone.inbox.publicKey != nil)
        await app.lock()
    }
}

@MainActor
@Suite("links", .serialized)
struct DeepLinkTests {
    @Test func aLinkFollowedWhileLockedWaitsForTheUnlock() async throws {
        let seed = try await Seed.make()
        let phone = Installation(seed.server)
        var (app, library) = try await phone.launchEnrolled(seed)
        library.setPath([.notebook(seed.notebookId), .section(notebookId: seed.notebookId, sectionId: seed.sectionId)])
        await app.client?.close()

        // A cold launch from the widget: the link arrives before the store is even open.
        app = AppModel(environment: phone.environment)
        await app.open(.newNote)
        #expect(app.pendingLink == .newNote)
        await app.start()
        #expect(app.phase == .locked && app.pendingLink == .newNote && app.library == nil)
        #expect(seed.tree.pages(inSection: seed.sectionId).count == 1, "nothing happens while locked")
        await #expect(throws: UnlockFailure.wrongPassword) { try await app.unlock(password: "wrong") }
        #expect(app.pendingLink == .newNote)

        try await app.unlock(password: testPassword)
        library = try #require(app.library)
        #expect(app.pendingLink == nil)
        // A new page in the section that was used last, open, with the title waiting for typing.
        let pages = try #require(library.notebook(seed.notebookId)).pages(in: seed.sectionId)
        #expect(pages.count == 2)
        let new = try #require(pages.last)
        #expect(library.selectedPage == PageRef(notebookId: seed.notebookId, pageId: new.id))
        #expect(library.path == [.notebook(seed.notebookId), .section(notebookId: seed.notebookId, sectionId: seed.sectionId)])
        try await eventually("the new page's editor is up") { library.editor?.ref.pageId == new.id }
        let stage = try Stage()
        defer { stage.close() }
        stage.show(try #require(library.editor).host)
        try await eventually("the title of the new page has the keyboard") { library.editor?.host.titleField.isFirstResponder == true }

        // The link is done once: locking and unlocking again makes no second page.
        await app.lock()
        try await app.unlock(password: testPassword)
        #expect(try #require(app.library?.notebook(seed.notebookId)).pages(in: seed.sectionId).count == 2)

        // A link that was followed but never unlocked for is dropped when the app is left.
        await app.lock()
        await app.open(.search)
        #expect(app.pendingLink == .search)
        await app.didEnterBackground()
        #expect(app.pendingLink == nil)
        try await app.unlock(password: testPassword)
        #expect(app.library?.wantsSearchFocus == false)
        await app.lock()
    }

    @Test func linksActAtOnceWhenUnlockedAndNotAtAllBeforeSetUp() async throws {
        let seed = try await Seed.make()
        let phone = Installation(seed.server)
        let fresh = await phone.launch()
        #expect(fresh.phase == .setUp)
        await fresh.open(.newNote)
        #expect(fresh.pendingLink == nil)

        let (app, library) = try await phone.launchEnrolled(seed)
        let ref = PageRef(notebookId: seed.notebookId, pageId: seed.pageId)

        // Search: Settings and the open page get out of the way, the field takes the keyboard.
        _ = try await library.open(ref)
        library.showingSettings = true
        library.compactLayout = true
        await app.open(.search)
        #expect(app.pendingLink == nil)
        #expect(library.wantsSearchFocus && !library.showingSettings && library.selectedPage == nil)
        library.wantsSearchFocus = false
        // Side by side, the page stays open next to the list.
        _ = try await library.open(ref)
        library.compactLayout = false
        await app.open(.search)
        #expect(library.wantsSearchFocus && library.selectedPage == ref)
        library.wantsSearchFocus = false

        // Continue: the page that was open last, even after it was closed.
        library.select(nil)
        library.setPath([])
        await app.open(.continueLast)
        #expect(library.selectedPage == ref)
        #expect(library.path == [.notebook(seed.notebookId), .section(notebookId: seed.notebookId, sectionId: seed.sectionId)])

        // A page link opens that page; one to a page that is gone does nothing.
        let other = try await #require(app.client).createPage(notebookId: seed.notebookId, sectionId: seed.sectionId, title: "Other")
        await app.open(.page(notebookId: seed.notebookId, pageId: other.docId))
        #expect(library.selectedPage?.pageId == other.docId)
        await app.open(.page(notebookId: seed.notebookId, pageId: "00000000000000000000000000000000"))
        await app.open(.page(notebookId: "00000000000000000000000000000000", pageId: seed.pageId))
        #expect(library.selectedPage?.pageId == other.docId)

        // New Note with no section on screen: next to the page that was open last.
        library.select(nil)
        library.setPath([])
        await app.open(.newNote)
        #expect(library.notebook(seed.notebookId)?.pages(in: seed.sectionId).count == 3)
        #expect(library.path.last == .section(notebookId: seed.notebookId, sectionId: seed.sectionId))
        await app.lock()
    }

    @Test func aNewNoteWithNowhereToGoUsesTheInboxOrSaysWhy() async throws {
        let server = FakeServer()
        let desk = try await Device.make(server, "A")
        let secretKey = try await desk.client.register(username: testUsername, password: testPassword, deviceName: "Desk")
        try await desk.syncNow()
        let phone = Installation(server)
        let app = await phone.launch()
        try await app.enrol(server: fakeServerAddress, username: testUsername, password: testPassword, secretKey: secretKey, deviceName: "Phone")
        let library = try #require(app.library)

        await app.open(.newNote)
        #expect(library.alert?.title == "No Notebooks Yet")
        library.alert = nil

        await library.createNotebook(title: "First")
        library.setPath([])
        let notebook = try #require(library.notebooks.first)
        await app.open(.newNote)
        #expect(notebook.sections.isEmpty)
        let made = try #require(library.notebook(notebook.id))
        #expect(made.sections.map(\.title) == ["Inbox"])
        #expect(made.pages(in: made.sections[0].id).count == 1)
        #expect(library.selectedPage != nil)
        await app.lock()
        await desk.client.close()
    }
}

@MainActor
@Suite("widget titles", .serialized)
struct WidgetTitleTests {
    @Test func nothingFromTheNotesLeavesTheStoreUnlessTheUserTurnsTitlesOn() async throws {
        let seed = try await Seed.make()
        let phone = Installation(seed.server)
        let (app, library) = try await phone.launchEnrolled(seed)
        #expect(!app.showsRecentPagesInWidget, "off unless switched on")

        // Off: edits, renames and new pages write nothing the widget could show.
        library.renamePage(PageRef(notebookId: seed.notebookId, pageId: seed.pageId), title: "Renamed at the hide")
        await library.addPage(notebookId: seed.notebookId, sectionId: seed.sectionId)
        app.publishRecentPages()
        try await Task.sleep(for: .milliseconds(500))
        #expect(RecentPages.load(from: phone.shared) == nil)
        #expect(files(under: phone.shared.root).map(\.name) == ["share-inbox.pub"])
        for secret in ["Renamed", "hide", "Kestrel", "Bittern"] {
            #expect(!contains(secret, in: phone.shared.root))
        }
        #expect(phone.widgetReloads == 0)

        // On: the titles of the pages edited last, newest first - titles and ids, nothing else.
        let tree = try #require(library.tree(seed.notebookId))
        var ids: [String] = [seed.pageId]
        for title in ["Second", "Third", "", "Fifth"] {
            let page = try await #require(app.client).createPage(notebookId: seed.notebookId, sectionId: seed.sectionId, title: title)
            page.append("Body text of \(title) that must stay in the vault")
            ids.append(page.docId)
        }
        app.setShowsRecentPagesInWidget(true)
        #expect(app.showsRecentPagesInWidget && phone.defaults.bool(forKey: "widget.recentPages"))
        let recent = try #require(RecentPages.load(from: phone.shared))
        #expect(recent.pages.count == RecentPages.limit)
        #expect(phone.widgetReloads == 1)
        let expected = RecentPagesFile.recent(in: library.notebooks)
        #expect(recent == expected)
        let stamps = recent.pages.map { tree.page($0.pageId)!.updatedAt }
        #expect(stamps == stamps.sorted(by: >), "newest first")
        #expect(recent.pages.allSatisfy { $0.notebookId == seed.notebookId && DeepLink(url: $0.link.url) == $0.link })
        #expect(!contains("Body text", in: phone.shared.root) && !contains("Bittern sighting", in: phone.shared.root))
        #expect(!contains("Kestrel", in: phone.shared.root), "no notebook or section names either")
        #expect(RecentPages.Page(notebookId: "n", pageId: "p", title: "").displayTitle == "Untitled Page")

        // Kept up to date while the app is unlocked; the widget is told only when something changed.
        library.renamePage(PageRef(notebookId: seed.notebookId, pageId: seed.pageId), title: "Just renamed")
        try await eventually("the widget's titles follow") { RecentPages.load(from: phone.shared)?.pages.first?.title == "Just renamed" }
        #expect(phone.widgetReloads == 2)
        app.publishRecentPages()
        #expect(phone.widgetReloads == 2)

        // Locking keeps them (that is what the switch is for); a relaunch keeps the switch.
        await app.lock()
        #expect(RecentPages.load(from: phone.shared)?.pages.first?.title == "Just renamed")
        await app.client?.close()
        let relaunched = await phone.launch()
        #expect(relaunched.showsRecentPagesInWidget)
        #expect(RecentPages.load(from: phone.shared) != nil)

        // Off again, even while locked: the file is gone and the widget is told.
        relaunched.setShowsRecentPagesInWidget(false)
        #expect(RecentPages.load(from: phone.shared) == nil)
        #expect(!FileManager.default.fileExists(atPath: phone.shared.recentPagesURL.path))
        #expect(!contains("Just renamed", in: phone.shared.root))
        #expect(phone.widgetReloads == 3)
        try await relaunched.unlock(password: testPassword)
        try await Task.sleep(for: .milliseconds(500))
        #expect(RecentPages.load(from: phone.shared) == nil)
        await relaunched.lock()
    }

    @Test func signingOutRemovesTheTitlesAndTurnsTheSwitchOff() async throws {
        let seed = try await Seed.make()
        let phone = Installation(seed.server)
        let (app, _) = try await phone.launchEnrolled(seed)
        app.setShowsRecentPagesInWidget(true)
        #expect(RecentPages.load(from: phone.shared)?.pages.map(\.title) == ["Tuesday at the hide"])
        let reloads = phone.widgetReloads

        await app.removeAccount()
        #expect(RecentPages.load(from: phone.shared) == nil)
        #expect(files(under: phone.shared.root).isEmpty)
        #expect(!app.showsRecentPagesInWidget && !phone.defaults.bool(forKey: "widget.recentPages"))
        #expect(phone.widgetReloads > reloads, "the widget is told to redraw")
        #expect(!(await phone.launch()).showsRecentPagesInWidget)

        // A file left behind by something else while the switch is off is removed at launch.
        try FileManager.default.createDirectory(at: phone.shared.root, withIntermediateDirectories: true)
        try JSONEncoder().encode(RecentPages(pages: [.init(notebookId: "n", pageId: "p", title: "Stale")])).write(to: phone.shared.recentPagesURL)
        _ = await phone.launch()
        #expect(!FileManager.default.fileExists(atPath: phone.shared.recentPagesURL.path))
    }

    @Test func theWidgetShowsButtonsOnlyUntilThereAreTitles() throws {
        // What the widget's timeline reads: nothing when the file is missing or unreadable.
        let container = SharedContainer(root: FileManager.default.temporaryDirectory.appendingPathComponent("twonote-widget-\(UUID().uuidString)"))
        #expect(RecentPages.load(from: nil) == nil)
        #expect(RecentPages.load(from: container) == nil)
        try FileManager.default.createDirectory(at: container.root, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: container.recentPagesURL)
        #expect(RecentPages.load(from: container) == nil)
        let many = RecentPages(pages: (0..<9).map { .init(notebookId: "n", pageId: "p\($0)", title: "Page \($0)") })
        #expect(RecentPagesFile.write(many, to: container))
        #expect(RecentPages.load(from: container)?.pages.map(\.title) == ["Page 0", "Page 1", "Page 2", "Page 3"], "never more than the widget shows")
        #expect(RecentPagesFile.remove(from: container))
        #expect(!RecentPagesFile.remove(from: container))
    }
}

import AppKit
import Foundation
import SwiftUI
import Testing
import TwoNoteDocuments
import TwoNoteEditor
import YrsKit
@testable import TwoNote
@testable import TwoNoteCore

// The Mac app: the iPhone's models compiled for the Mac, the Mac's editor session on AppKit,
// auto-lock and its system triggers, Touch ID through a fake sensor, and the menu commands.

@MainActor
@Suite("model sharing", .serialized)
struct ModelSharingTests {
    @Test func theIPhonesModelsRunOnTheMac() async throws {
        let seed = try await Seed.make()
        let mac = Installation(seed.server)
        let (app, library) = try await mac.launchEnrolled(seed)
        #expect(app.phase == .unlocked)
        #expect(app.environment.sharedContainer != nil, "the App Group container is shared with the extensions")
        #expect(app.waitingSharedItems == 0)
        #expect(library.notebooks.map(\.title) == ["Kestrel field journal"])
        #expect(library.notebook(seed.notebookId)?.sections.map(\.title) == ["Marsh observations"])

        // The Mac's own editor session drives an AppKit text view on TextKit 2.
        let editor = try await library.open(PageRef(notebookId: seed.notebookId, pageId: seed.pageId))
        #expect(editor.textView.textLayoutManager != nil)
        #expect(editor.textView.string == "Bittern sighting\n")
        #expect(editor.host.titleField.stringValue == "Tuesday at the hide")
        #expect(AppModel.unlockReason == "unlock your notes", "completes macOS's “TwoNote is trying to …”")

        // Search uses the same in-memory index.
        await library.search.refresh()
        library.search.query = "bittern"
        await library.search.settle()
        #expect(library.search.hits.map(\.title) == ["Tuesday at the hide"])
        #expect(library.search.pageText(seed.pageId) == "Bittern sighting\n")
        library.search.query = ""
        await app.lock()
    }

    @Test func typingWithFormattingReachesTheOtherDeviceAndItsEditsShowUpLive() async throws {
        EditorSession.touchDebounce = 0.05
        EditorSession.touchInterval = 0
        defer {
            EditorSession.touchDebounce = 2
            EditorSession.touchInterval = 30
        }
        let seed = try await Seed.make()
        let mac = Installation(seed.server)
        let (app, library) = try await mac.launchEnrolled(seed)
        let stage = Stage()
        defer { stage.close() }
        let editor = try await library.open(PageRef(notebookId: seed.notebookId, pageId: seed.pageId))
        stage.show(editor.host)
        let before = try #require(library.notebook(seed.notebookId)?.page(seed.pageId)).updatedAt
        try await Task.sleep(for: .milliseconds(20))

        stage.window.makeFirstResponder(editor.textView)
        editor.textView.setSelectedRange(NSRange(location: 16, length: 0))
        editor.toggle(PageAttribute.bold)
        #expect(editor.formatting.inline.bold)
        editor.textView.insertText(" at dusk", replacementRange: NSRange(location: NSNotFound, length: 0))
        editor.textView.insertNewline(nil)
        editor.chooseBlock("todo")
        editor.textView.insertText("Refill the thermos", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(editor.page.text == "Bittern sighting at dusk\nRefill the thermos\n")
        #expect(editor.page.runs.contains { $0.text.hasPrefix(" at dusk") && $0.attributes[PageAttribute.bold] == .bool(true) })
        #expect(editor.formatting.block.block == "todo")

        try await eventually("the page's last-edited time moves after a pause in typing") {
            (library.notebook(seed.notebookId)?.page(seed.pageId)?.updatedAt ?? before) > before
        }
        editor.host.titleField.stringValue = "Dusk at the hide"
        editor.flush()
        #expect(library.notebook(seed.notebookId)?.page(seed.pageId)?.title == "Dusk at the hide")

        try await eventually("the other device has the text and the title") {
            try await seed.a.syncNow()
            return seed.page.text == "Bittern sighting at dusk\nRefill the thermos\n" && seed.tree.page(seed.pageId)?.title == "Dusk at the hide"
        }

        // The other device types at the start while the caret here is at the end of the list item.
        let caret = editor.textView.selectedRange().location
        seed.page.prepend("Note: ")
        try await seed.a.syncNow()
        try await eventually("the edit from the other device shows up") {
            editor.textView.string == "Note: Bittern sighting at dusk\nRefill the thermos\n"
        }
        #expect(editor.textView.selectedRange() == NSRange(location: caret + 6, length: 0), "the caret stays where it was in the text")
        #expect(editor.binding.verify() == nil)

        library.select(nil)
        #expect(library.editor == nil)
        #expect(editor.host.superview == nil)
        await app.lock()
    }
}

@MainActor
@Suite("locking", .serialized)
struct LockTests {
    @Test func lockingClearsTheWindowTheIndexAndTheKeys() async throws {
        let seed = try await Seed.make()
        let mac = Installation(seed.server)
        let (app, library) = try await mac.launchEnrolled(seed)
        let stage = Stage()
        defer { stage.close() }
        library.setPath([.notebook(seed.notebookId), .section(notebookId: seed.notebookId, sectionId: seed.sectionId)])
        let editor = try await library.open(PageRef(notebookId: seed.notebookId, pageId: seed.pageId))
        let search = library.search
        await search.refresh()
        #expect(search.indexedPages == 1)

        stage.show(RootView().environment(app).environment(WindowRequests()))
        try await eventually("the page is on screen") {
            stage.pump()
            return stage.visibleStrings().contains { $0.contains("Bittern sighting") }
        }
        // The check below reads the window the way a person would; make sure it can see the notes.
        try await eventually("the lists can be read in the window", timeout: .seconds(20)) {
            stage.pump(0.2)
            let words = try stage.recognizedText().joined(separator: " ")
            return words.contains("Kestrel field journal") && words.contains("Bittern") && words.contains("Tuesday at the hide")
        }
        stage.window.makeFirstResponder(editor.textView)
        editor.textView.insertText("Typed just before locking. ", replacementRange: NSRange(location: 0, length: 0))

        await app.willResignActive()
        await app.lock()
        stage.pump(0.3)
        #expect(app.phase == .locked)
        #expect(app.library == nil)
        #expect(app.client?.state == .locked)
        #expect(app.client?.notebookIds == [])
        #expect(search.indexedPages == 0, "the search index is gone")
        #expect(search.pageText(seed.pageId) == nil)
        #expect(editor.host.superview == nil, "the editor is off the screen")
        #expect(!editor.textView.isEditable)

        let shown = stage.visibleStrings()
        try await eventually("the lock screen is drawn", timeout: .seconds(20)) {
            stage.pump(0.2)
            return try stage.recognizedText().joined(separator: " ").contains("TwoNote Is Locked")
        }
        let read = try stage.recognizedText()
        for secret in ["Bittern", "Tuesday", "Marsh", "Kestrel", "Typed just before"] {
            #expect(!shown.contains { $0.contains(secret) }, "“\(secret)” is still in a view of the window")
            #expect(!read.contains { $0.contains(secret) }, "“\(secret)” can still be read in the window")
        }

        // Nothing typed was lost.
        try await app.unlock(password: testPassword)
        let reopened = try await #require(app.library).open(PageRef(notebookId: seed.notebookId, pageId: seed.pageId))
        #expect(reopened.page.text.hasPrefix("Typed just before locking. "))
        await app.lock()
    }

    private func monitored(_ delay: AutoLockDelay) async throws -> (Seed, Installation, AppModel, AutoLockMonitor, Centers) {
        let seed = try await Seed.make()
        let mac = Installation(seed.server)
        let (app, _) = try await mac.launchEnrolled(seed)
        app.autoLock = delay
        let centers = Centers()
        let monitor = AutoLockMonitor(
            app: app, workspaceCenter: centers.workspace, distributedCenter: centers.distributed, appCenter: centers.app)
        monitor.start(watchEvents: false, runTimer: false)
        return (seed, mac, app, monitor, centers)
    }

    /// Stand-ins for the system's notification centres.
    struct Centers {
        let workspace = NotificationCenter()
        let distributed = NotificationCenter()
        let app = NotificationCenter()
    }

    @Test func idleTimeLocksAfterTheAutoLockTime() async throws {
        let (_, mac, app, monitor, _) = try await monitored(.oneMinute)
        defer { monitor.stop() }
        mac.clockOffset = .seconds(50)
        await monitor.checkIdle()
        #expect(app.phase == .unlocked)
        monitor.noteActivity() // a key press: the minute starts again
        mac.clockOffset = .seconds(100)
        await monitor.checkIdle()
        #expect(app.phase == .unlocked)
        mac.clockOffset = .seconds(111)
        await monitor.checkIdle()
        #expect(app.phase == .locked)
        #expect(monitor.locks == [.idle])
    }

    @Test(arguments: [
        (NSWorkspace.willSleepNotification, AutoLockMonitor.Reason.sleep, false),
        (NSWorkspace.screensDidSleepNotification, .screensSlept, false),
        (NSWorkspace.sessionDidResignActiveNotification, .sessionResigned, false),
        (AutoLockMonitor.screenLockedNotification, .screenLocked, true),
    ])
    func sleepAndScreenLockLock(_ name: Notification.Name, _ reason: AutoLockMonitor.Reason, _ distributed: Bool) async throws {
        let (_, _, app, monitor, centers) = try await monitored(.fifteenMinutes)
        defer { monitor.stop() }
        (distributed ? centers.distributed : centers.workspace).post(name: name, object: nil)
        try await eventually("the app locks") { app.phase == .locked }
        #expect(monitor.locks == [reason])
        #expect(app.library == nil)
    }

    @Test func neverMeansNever() async throws {
        let (_, mac, app, monitor, centers) = try await monitored(.never)
        defer { monitor.stop() }
        mac.clockOffset = .seconds(100_000)
        await monitor.checkIdle()
        centers.workspace.post(name: NSWorkspace.willSleepNotification, object: nil)
        centers.distributed.post(name: AutoLockMonitor.screenLockedNotification, object: nil)
        centers.app.post(name: NSApplication.didResignActiveNotification, object: nil)
        try await Task.sleep(for: .milliseconds(200))
        #expect(app.phase == .unlocked)
        #expect(monitor.locks.isEmpty)
        await app.lock()
    }

    @Test func immediatelyLocksWhenAnotherAppComesToTheFront() async throws {
        let (_, _, app, monitor, centers) = try await monitored(.immediately)
        defer { monitor.stop() }
        centers.app.post(name: NSApplication.didResignActiveNotification, object: nil)
        try await eventually("the app locks") { app.phase == .locked }
        #expect(monitor.locks == [.resignedActive])
    }

    @Test func goingToAnotherAppSavesButDoesNotLockOtherwise() async throws {
        let (seed, mac, app, monitor, centers) = try await monitored(.fiveMinutes)
        defer { monitor.stop() }
        let library = try #require(app.library)
        let editor = try await library.open(PageRef(notebookId: seed.notebookId, pageId: seed.pageId))
        mac.transport.offline = true
        try await eventually("offline") { app.client!.sync.status.state == .offline }
        let store = try LocalStore.open(path: mac.databasePath)
        defer { store.close() }
        let outboxBefore = try store.outboxCount()
        editor.textView.insertText("Typed before switching apps. ", replacementRange: NSRange(location: 0, length: 0))
        editor.host.titleField.stringValue = "Switched"

        centers.app.post(name: NSApplication.didResignActiveNotification, object: nil)
        try await eventually("the edits are in the store") { try store.outboxCount() >= outboxBefore + 2 }
        #expect(app.phase == .unlocked)

        // Back after six minutes away: that is longer than the Auto-Lock time.
        mac.clockOffset = .seconds(360)
        centers.app.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        try await eventually("the app locks on coming back") { app.phase == .locked }
        #expect(monitor.locks == [.idle])
    }
}

@MainActor
@Suite("Touch ID", .serialized)
struct TouchIDTests {
    @Test func withASensorTheOfferComesAndTouchIDUnlocks() async throws {
        let seed = try await Seed.make()
        let mac = Installation(seed.server)
        mac.biometrics.biometry = .touchID
        let (app, _) = try await mac.launchEnrolled(seed)
        #expect(app.biometricOffer)
        #expect(mac.biometrics.stored == nil)
        app.answerBiometricOffer(enable: true)
        #expect(app.biometricUnlockEnabled)
        #expect(mac.biometrics.stored?.count == 32, "only the 32-byte unlock key is stored")

        await app.lock()
        try await app.unlockWithBiometrics()
        #expect(app.phase == .unlocked)
        #expect(mac.biometrics.reasons == ["unlock your notes"])

        // A cancelled prompt leaves the password as the way in.
        await app.lock()
        mac.biometrics.outcome = .cancelled
        await #expect(throws: UnlockFailure.biometry(.cancelled)) { try await app.unlockWithBiometrics() }
        #expect(app.phase == .locked)
        try await app.unlock(password: testPassword)
        #expect(app.phase == .unlocked)

        // New fingerprints: the item is gone, Touch ID turns itself off and says why.
        await app.lock()
        mac.biometrics.outcome = nil
        mac.biometrics.changeEnrolledFingerprints()
        app.refreshBiometrics()
        #expect(!app.biometricUnlockEnabled)
        #expect(app.biometricNotice?.contains("turned off") == true)
        try await app.unlock(password: testPassword)
        #expect(app.biometricOffer, "asked again after the password")
        app.answerBiometricOffer(enable: false)
        await app.lock()
    }

    @Test func withoutASensorNothingAsksForTouchID() async throws {
        let seed = try await Seed.make()
        let mac = Installation(seed.server)
        mac.biometrics.biometry = .none // like the build Mac mini
        let (app, _) = try await mac.launchEnrolled(seed)
        #expect(app.biometry == .none)
        #expect(!app.biometricOffer)
        #expect(!app.biometricUnlockEnabled)
        await app.lock()
        try await app.unlockWithBiometrics() // does nothing
        #expect(app.phase == .locked)
        #expect(mac.biometrics.prompts == 0)
        try await app.unlock(password: testPassword)
        await #expect(throws: UserMessage.self) { try await app.setBiometricUnlock(true, password: testPassword) }
        #expect(!app.biometricUnlockEnabled)
        await app.lock()
    }

    @Test func theRealKeychainStoreDegradesWithoutASensor() {
        // On a Mac without Touch ID (or with none enrolled) the real store reports none, and
        // asking for the key fails cleanly instead of showing anything.
        let store = KeychainBiometricStore(service: "TwoNote-tests-\(UUID().uuidString)")
        if store.biometry == .none {
            #expect(!store.hasKey())
            #expect(throws: (any Error).self) { try store.save(Data(repeating: 1, count: 32)) }
            store.remove()
        }
    }
}

@MainActor
@Suite("menu commands", .serialized)
struct CommandTests {
    @Test func commandsFollowWhereTheUserIs() async throws {
        #expect(!MenuState(app: nil).canNewNotebook)

        let seed = try await Seed.make()
        let mac = Installation(seed.server)
        let app = await mac.launch()
        var state = MenuState(app: app)
        #expect(!state.unlocked && !state.canNewNotebook && !state.canLock && !state.canNewPage && !state.canFormat)

        try await app.enrol(
            server: fakeServerAddress, username: testUsername, password: testPassword, secretKey: seed.secretKey, deviceName: "Mac")
        let library = try #require(app.library)
        try await eventually("the seeded notebook arrives") { library.notebook(seed.notebookId) != nil }
        library.setPath([])
        library.select(nil)
        state = MenuState(app: app)
        #expect(state.canNewNotebook && state.canLock && state.canSearch)
        #expect(!state.canNewPage && !state.canNewSection && !state.canFormat && !state.canDeletePage)

        library.setPath([.notebook(seed.notebookId), .section(notebookId: seed.notebookId, sectionId: seed.sectionId)])
        state = MenuState(app: app)
        #expect(state.canNewPage && state.canNewSection)
        #expect(state.sectionForNewPage?.sectionId == seed.sectionId)
        #expect(!state.canFormat)

        let editor = try await library.open(PageRef(notebookId: seed.notebookId, pageId: seed.pageId))
        state = MenuState(app: app)
        #expect(state.canFormat && state.canDeletePage)
        #expect(!state.isOn(PageAttribute.bold))
        #expect(state.canIndent && !state.canOutdent && !state.canToggleChecked)
        #expect(state.hasBlock(nil))

        editor.textView.setSelectedRange(NSRange(location: 0, length: 7))
        editor.toggle(PageAttribute.bold)
        editor.chooseBlock("h1")
        state = MenuState(app: app)
        #expect(state.isOn(PageAttribute.bold) && state.hasBlock("h1") && !state.hasBlock(nil))
        editor.chooseBlock("h1") // choosing the style the paragraph has makes it body text again
        #expect(MenuState(app: app).hasBlock(nil))

        editor.chooseBlock("todo")
        editor.indent(by: 1)
        state = MenuState(app: app)
        #expect(state.canToggleChecked && state.canOutdent)
        editor.toggleChecked()
        #expect(editor.formatting.block.checked)

        // A page opened from search with the sidebar elsewhere: new pages go into its section.
        library.setPath([])
        state = MenuState(app: app)
        #expect(state.sectionForNewPage?.sectionId == seed.sectionId)
        #expect(state.notebookForNewSection == seed.notebookId)

        await app.lock()
        state = MenuState(app: app)
        #expect(!state.canFormat && !state.canNewPage && !state.canLock && !state.canNewNotebook)
    }

    @Test func linksAreAddedEditedAndRemoved() async throws {
        let seed = try await Seed.make()
        let mac = Installation(seed.server)
        let (app, library) = try await mac.launchEnrolled(seed)
        let editor = try await library.open(PageRef(notebookId: seed.notebookId, pageId: seed.pageId))
        editor.applyLink("https://example.com/bittern", selection: 0..<7, hadLink: false)
        #expect(editor.page.runs.first == TextRun(text: "Bittern", attributes: [PageAttribute.link: .string("https://example.com/bittern")]))
        editor.textView.setSelectedRange(NSRange(location: 3, length: 0))
        #expect(editor.formatting.inline.link == "https://example.com/bittern")
        editor.applyLink("", selection: 0..<7, hadLink: true)
        #expect(editor.page.runs.first == TextRun(text: "Bittern sighting\n", attributes: [:]))
        // With only a caret, the address goes in as its own linked text.
        editor.applyLink("https://example.com", selection: 17..<17, hadLink: false)
        #expect(editor.page.text == "Bittern sighting\nhttps://example.com\n" || editor.page.text == "Bittern sightinghttps://example.com\n")
        await app.lock()
    }

    @Test func pageListShowsWhatNotesShows() {
        #expect(PageListView.preview("\n  First line of text  \nSecond") == "First line of text")
        #expect(PageListView.preview(nil) == "")
        #expect(PageListView.preview("\n\n") == "")
        let now = Date()
        #expect(PageListView.date(now.addingTimeInterval(-86_400 * 30), now: now).contains("/") ||
                PageListView.date(now.addingTimeInterval(-86_400 * 30), now: now).contains("."))
    }
}

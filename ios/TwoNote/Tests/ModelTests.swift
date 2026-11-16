import Foundation
import SwiftUI
import Testing
import TwoNoteDocuments
import UIKit
import YrsKit
@testable import TwoNote
@testable import TwoNoteCore

@Suite("plain logic")
struct PlainLogicTests {
    @Test func serverAddressesAreReadTheWayTheyAreTyped() {
        #expect(ServerAddress.parse("192.168.1.20:8080")?.absoluteString == "http://192.168.1.20:8080")
        #expect(ServerAddress.parse("  http://nas.local:8080/  ")?.absoluteString == "http://nas.local:8080")
        #expect(ServerAddress.parse("HTTPS://notes.example.com/api/v1/status?x=1")?.absoluteString == "https://notes.example.com")
        #expect(ServerAddress.parse("nas.tail1234.ts.net:8080")?.absoluteString == "http://nas.tail1234.ts.net:8080")
        #expect(ServerAddress.parse("100.101.102.103:8080")?.absoluteString == "http://100.101.102.103:8080")
        #expect(ServerAddress.parse("") == nil)
        #expect(ServerAddress.parse("ftp://nas.local") == nil)
        #expect(ServerAddress.parse("my server") == nil)
        #expect(ServerAddress.parse("http://") == nil)
        #expect(ServerAddress.parse("http://bob:pw@nas.local") == nil)
    }

    @Test func syncSummaryCoversEveryState() {
        var status = SyncStatus()
        #expect(SyncSummary(status).kind == .offline) // the loop is not started

        status.running = true
        #expect(SyncSummary(status).kind == .syncing) // nothing synced yet
        status.lastSyncedAt = Date()
        #expect(SyncSummary(status).kind == .synced)
        #expect(SyncSummary(status).title == "Synced")
        #expect(!SyncSummary(status).wantsAttention)

        status.pendingUpdates = 2
        #expect(SyncSummary(status).kind == .syncing)
        status.state = .syncing
        #expect(SyncSummary(status).title == "Syncing…")

        status.state = .offline
        #expect(SyncSummary(status).kind == .offline)
        status.pendingPages = 2
        #expect(SyncSummary(status).title == "Offline · Changes Waiting", "no count of raw updates")
        #expect(SyncSummary(status).waiting == "2 Pages")
        #expect(!SyncSummary(status).wantsAttention, "offline is a normal state")
        status.pendingPages = 1
        status.pendingNotebooks = 1
        #expect(SyncSummary(status).waiting == "1 Page and Notebook Changes")
        status.pendingPages = 0
        #expect(SyncSummary(status).waiting == "Notebook Changes")
        status.pendingUpdates = 0
        status.pendingNotebooks = 0
        #expect(SyncSummary(status).waiting == nil)
        #expect(SyncSummary(status).title == "Offline")

        status.state = .authRequired
        #expect(SyncSummary(status).kind == .needsSignIn)
        #expect(SyncSummary(status).wantsAttention)
        status.state = .error
        #expect(SyncSummary(status).kind == .problem)

        status.state = .idle
        status.head = 9
        status.cursor = 4
        #expect(SyncSummary(status).kind == .syncing) // behind the server
    }

    /// Applies steps the way the tree does: the index counts the other items.
    private func apply(_ steps: [(id: String, index: Int)], to ids: [String]) -> [String] {
        var list = ids
        for step in steps {
            list.removeAll { $0 == step.id }
            list.insert(step.id, at: step.index)
        }
        return list
    }

    @Test func listMovesBecomeTreeMoves() {
        let ids = ["a", "b", "c", "d"]
        // SwiftUI's onMove: the destination is an index in the list before the move.
        #expect(apply(LibraryModel.moveSteps(ids, from: [0], to: 4), to: ids) == ["b", "c", "d", "a"])
        #expect(apply(LibraryModel.moveSteps(ids, from: [0], to: 2), to: ids) == ["b", "a", "c", "d"])
        #expect(apply(LibraryModel.moveSteps(ids, from: [3], to: 0), to: ids) == ["d", "a", "b", "c"])
        #expect(apply(LibraryModel.moveSteps(ids, from: [2], to: 1), to: ids) == ["a", "c", "b", "d"])
        #expect(apply(LibraryModel.moveSteps(ids, from: [0, 1], to: 4), to: ids) == ["c", "d", "a", "b"])
        #expect(apply(LibraryModel.moveSteps(ids, from: [1, 3], to: 0), to: ids) == ["b", "d", "a", "c"])
        #expect(LibraryModel.moveSteps(ids, from: [1], to: 1).isEmpty, "dropping a row where it was is no move")
        #expect(LibraryModel.moveSteps(ids, from: [1], to: 2).isEmpty)
    }

    @Test func failuresAreExplainedInTheUsersTerms() {
        let url = URL(string: "http://192.168.1.20:8080")!
        #expect(UserMessage.enrolFailure(ClientError.wrongCredentials, server: url, networkAvailable: true).title == "Incorrect Sign-In Details")
        #expect(UserMessage.enrolFailure(ClientError.malformedSecretKey, server: url, networkAvailable: true).title == "Check the Secret Key")
        let unreachable = ServerUnreachableError("The server could not be reached (-1004).")
        let wrongAddress = UserMessage.enrolFailure(unreachable, server: url, networkAvailable: true)
        #expect(wrongAddress.title == "Can’t Reach the Server")
        #expect(wrongAddress.detail.contains("http://192.168.1.20:8080"))
        #expect(UserMessage.enrolFailure(unreachable, server: url, networkAvailable: false).title == "You’re Offline")
        let notFound = ApiError(status: 404, code: "http_404", message: "HTTP 404")
        #expect(UserMessage.enrolFailure(notFound, server: url, networkAvailable: true).title == "Not a TwoNote Server")
        #expect(UserMessage.deleteNotebookFailure(unreachable).title == "Can’t Delete Right Now")
        #expect(UserMessage.signInFailure(ClientError.wrongCredentials).title == "Incorrect Password")
    }
}

@MainActor
@Suite("account flows", .serialized)
struct AccountFlowTests {
    @Test func setUpExplainsWhatIsWrongAndThenSucceeds() async throws {
        let seed = try await Seed.make()
        let phone = Installation(seed.server)
        let app = await phone.launch()
        #expect(app.phase == .setUp)

        func attempt(server: String = fakeServerAddress, password: String = testPassword, secretKey: String? = nil) async -> UserMessage? {
            do {
                try await app.enrol(
                    server: server, username: testUsername, password: password, secretKey: secretKey ?? seed.secretKey, deviceName: "Phone")
                return nil
            } catch {
                return error as? UserMessage
            }
        }

        #expect(await attempt(server: "not an address")?.title == "Check the Server Address")
        #expect(await attempt(secretKey: "T2-NOT-A-KEY")?.title == "Check the Secret Key")
        #expect(await attempt(password: "wrong password")?.title == "Incorrect Sign-In Details")

        phone.transport.offline = true
        #expect(await attempt()?.title == "Can’t Reach the Server")
        phone.networkAvailable = false
        #expect(await attempt()?.title == "You’re Offline")
        phone.networkAvailable = true
        phone.transport.offline = false
        #expect(app.phase == .setUp)
        #expect(phone.secrets.get(SecretNames.secretKey) == nil)

        #expect(await attempt() == nil)
        #expect(app.phase == .unlocked)
        #expect(app.serverURL?.absoluteString == "http://fake.test:8080")
        #expect(app.client?.account?.deviceName == "Phone")
        let library = try #require(app.library)
        try await eventually("the notebook from the other device arrives") {
            library.notebooks.map(\.title) == ["Kestrel field journal"]
                && library.notebooks[0].sections.map(\.title) == ["Marsh observations"]
                && library.notebooks[0].pages(in: seed.sectionId).map(\.title) == ["Tuesday at the hide"]
        }
        try await eventually("sync settles") { SyncSummary(app.client!.syncMonitor.status).kind == .synced }
        await app.lock()
    }

    @Test func relaunchAsksForThePasswordAndReturnsToTheLastPage() async throws {
        let seed = try await Seed.make()
        let phone = Installation(seed.server)
        var (app, library) = try await phone.launchEnrolled(seed)
        let ref = PageRef(notebookId: seed.notebookId, pageId: seed.pageId)
        library.setPath([.notebook(seed.notebookId), .section(notebookId: seed.notebookId, sectionId: seed.sectionId)])
        _ = try await library.open(ref)
        await app.client?.close() // the process ends

        phone.transport.offline = true // unlocking needs no server
        app = await phone.launch()
        #expect(app.phase == .locked)
        #expect(app.library == nil)
        await #expect(throws: UnlockFailure.wrongPassword) { try await app.unlock(password: "not it") }
        #expect(app.phase == .locked)

        try await app.unlock(password: testPassword)
        #expect(app.phase == .unlocked)
        library = try #require(app.library)
        #expect(library.path == [.notebook(seed.notebookId), .section(notebookId: seed.notebookId, sectionId: seed.sectionId)])
        #expect(library.selectedPage == ref)
        try await eventually("the page reopens") { library.editor?.ref == ref }
        #expect(library.editor?.page.text == "Bittern sighting\n")
        #expect(library.editor?.host.titleField.text == "Tuesday at the hide")
        await app.lock()
    }

    @Test func lockTakesEverythingDecryptedAway() async throws {
        let seed = try await Seed.make()
        let phone = Installation(seed.server)
        let (app, library) = try await phone.launchEnrolled(seed)
        let stage = try Stage()
        defer { stage.close() }
        let editor = try await library.open(PageRef(notebookId: seed.notebookId, pageId: seed.pageId))
        stage.show(editor.host)
        #expect(editor.textView.text.contains("Bittern sighting"))
        editor.textView.becomeFirstResponder()
        editor.textView.insertText("Typed just before locking. ")

        await app.lock()
        #expect(app.phase == .locked)
        #expect(app.library == nil)
        #expect(app.client?.state == .locked)
        #expect(app.client?.notebookIds == [])
        #expect(library.notebooks.isEmpty && library.editor == nil && library.selectedPage == nil)
        #expect(editor.host.superview == nil, "the editor is off the screen")

        // Nothing typed was lost: it is in the store, and comes back with the password.
        try await app.unlock(password: testPassword)
        let reopened = try await #require(app.library).open(PageRef(notebookId: seed.notebookId, pageId: seed.pageId))
        #expect(reopened.page.text.contains("Typed just before locking. "))
        await app.lock()
    }

    @Test func missingKeysAreReportedAndRemovingTheAccountStartsOver() async throws {
        let seed = try await Seed.make()
        let phone = Installation(seed.server)
        var (app, _) = try await phone.launchEnrolled(seed)
        await app.client?.close()

        phone.secrets.remove(SecretNames.secretKey) // a restored backup: the store without the Keychain
        app = await phone.launch()
        #expect(app.phase == .locked)
        await #expect(throws: UnlockFailure.keysMissing) { try await app.unlock(password: testPassword) }

        await app.removeAccount()
        #expect(app.phase == .setUp)
        #expect(!FileManager.default.fileExists(atPath: phone.databasePath))
        #expect(phone.secrets.get(SecretNames.sessionToken) == nil)
        #expect(await phone.launch().phase == .setUp)

        try await app.enrol(
            server: fakeServerAddress, username: testUsername, password: testPassword, secretKey: seed.secretKey, deviceName: "Phone again")
        #expect(app.phase == .unlocked)
        await app.lock()
    }
}

@MainActor
@Suite("library", .serialized)
struct LibraryTests {
    @Test func createRenameReorderAndDeleteWorkOfflineAndSyncLater() async throws {
        let seed = try await Seed.make()
        let phone = Installation(seed.server)
        let (app, library) = try await phone.launchEnrolled(seed)
        phone.transport.offline = true
        try await eventually("the app notices it is offline") { SyncSummary(app.client!.syncMonitor.status).kind == .offline }

        await library.createNotebook(title: "Allotment")
        let notebook = try #require(library.notebooks.first { $0.title == "Allotment" })
        #expect(library.notebooks.map(\.title) == ["Allotment", "Kestrel field journal"], "notebooks are listed by title")
        #expect(library.path == [.notebook(notebook.id)])

        let beds = try #require(library.addSection(notebookId: notebook.id, title: "Beds"))
        let seeds = try #require(library.addSection(notebookId: notebook.id, title: "Seeds"))
        let tools = try #require(library.addSection(notebookId: notebook.id, title: "Tools"))
        #expect(library.path == [.notebook(notebook.id), .section(notebookId: notebook.id, sectionId: tools)])
        library.moveSections(notebookId: notebook.id, from: [2], to: 0)
        #expect(library.notebook(notebook.id)?.sections.map(\.title) == ["Tools", "Beds", "Seeds"])
        library.renameSection(notebookId: notebook.id, sectionId: seeds, title: "Seed box")
        library.renameNotebook(notebook.id, title: "Allotment 2027")
        #expect(library.notebooks.map(\.title) == ["Allotment 2027", "Kestrel field journal"])

        await library.addPage(notebookId: notebook.id, sectionId: beds)
        let first = try #require(library.selectedPage)
        try await eventually("the new page opens") { library.editor?.ref == first }
        library.renamePage(first, title: "Bed 1")
        #expect(library.editor?.host.titleField.text == "Bed 1")
        await library.addPage(notebookId: notebook.id, sectionId: beds)
        let second = try #require(library.selectedPage)
        #expect(second != first)
        library.renamePage(second, title: "Bed 2")
        #expect(library.notebook(notebook.id)?.pages(in: beds).map(\.title) == ["Bed 1", "Bed 2"])
        library.movePages(notebookId: notebook.id, sectionId: beds, from: [1], to: 0)
        #expect(library.notebook(notebook.id)?.pages(in: beds).map(\.title) == ["Bed 2", "Bed 1"])
        library.movePage(first, toSection: tools)
        #expect(library.notebook(notebook.id)?.pages(in: tools).map(\.title) == ["Bed 1"])

        try await eventually("the second page opens") { library.editor?.ref == second }
        library.deletePage(second)
        #expect(library.selectedPage == nil && library.editor == nil, "deleting the open page closes it")
        #expect(library.notebook(notebook.id)?.pages(in: beds).isEmpty == true)

        library.setPath([.notebook(notebook.id), .section(notebookId: notebook.id, sectionId: tools)])
        library.deleteSection(notebookId: notebook.id, sectionId: tools)
        #expect(library.path == [.notebook(notebook.id)], "deleting the section being shown goes back to the notebook")
        #expect(library.notebook(notebook.id)?.sections.map(\.title) == ["Beds", "Seed box"])

        // Deleting a notebook is the one thing that needs the server (unless it never got there).
        await library.deleteNotebook(seed.notebookId)
        #expect(library.alert?.title == "Can’t Delete Right Now")
        #expect(library.notebook(seed.notebookId) != nil)
        library.alert = nil

        try await eventually("the indicator shows offline with changes waiting") {
            let status = SyncSummary(app.client!.syncMonitor.status)
            return status.kind == .offline && status.hasPending && status.title == "Offline · Changes Waiting"
        }

        // Back in reach: the other device gets all of it.
        phone.transport.offline = false
        await app.didBecomeActive()
        try await eventually("everything is sent") { SyncSummary(app.client!.syncMonitor.status).kind == .synced }
        try await seed.a.syncNow()
        #expect(seed.a.client.notebookIds.contains(notebook.id))
        let treeA = try await seed.a.client.openNotebook(notebook.id)
        #expect(treeA.title == "Allotment 2027")
        #expect(treeA.sections().map(\.title) == ["Beds", "Seed box"])
        #expect(treeA.sections(includeDeleted: true).count == 3)

        await library.deleteNotebook(notebook.id)
        #expect(library.alert == nil)
        #expect(library.notebooks.map(\.title) == ["Kestrel field journal"])
        #expect(library.path.isEmpty)
        await app.lock()
    }

    @Test func changesFromAnotherDeviceAppearWhileTheListsAreShown() async throws {
        let seed = try await Seed.make()
        let phone = Installation(seed.server)
        let (app, library) = try await phone.launchEnrolled(seed)
        let ref = PageRef(notebookId: seed.notebookId, pageId: seed.pageId)
        let editor = try await library.open(ref)

        // The other device adds a page, a section and a notebook, renames, and types.
        let added = try await seed.a.client.createPage(notebookId: seed.notebookId, sectionId: seed.sectionId, title: "Wednesday at the hide")
        seed.tree.addSection(title: "Garden list")
        seed.tree.renamePage(seed.pageId, title: "Tuesday, renamed")
        seed.page.append(" (seen twice)")
        let other = try await seed.a.client.createNotebook(title: "Recipes")
        try await seed.a.syncNow()

        try await eventually("the new page, section and notebook are listed") {
            library.notebook(seed.notebookId)?.pages(in: seed.sectionId).map(\.title) == ["Tuesday, renamed", "Wednesday at the hide"]
                && library.notebook(seed.notebookId)?.sections.map(\.title) == ["Marsh observations", "Garden list"]
                && library.notebooks.map(\.title) == ["Kestrel field journal", "Recipes"]
        }
        try await eventually("the open page follows") {
            editor.page.text == "Bittern sighting (seen twice)\n" && editor.host.titleField.text == "Tuesday, renamed"
        }
        #expect(editor.textView.text.hasPrefix("Bittern sighting (seen twice)"))

        // The other device deletes the page that is open here, and a whole notebook.
        seed.tree.setPageDeleted(seed.pageId)
        try await seed.a.client.deleteNotebook(other.notebookId)
        try await seed.a.syncNow()
        try await eventually("the open page closes and the notebook goes") {
            library.selectedPage == nil && library.editor == nil && library.notebooks.map(\.title) == ["Kestrel field journal"]
        }
        #expect(library.notebook(seed.notebookId)?.pages(in: seed.sectionId).map(\.id) == [added.docId])
        await app.lock()
    }
}

@MainActor
@Suite("editor", .serialized)
struct EditorTests {
    @Test func typingIsSavedStampedAndReachesTheOtherDevice() async throws {
        EditorSession.touchDebounce = 0.05
        EditorSession.touchInterval = 0
        defer {
            EditorSession.touchDebounce = 2
            EditorSession.touchInterval = 30
        }
        let seed = try await Seed.make()
        let phone = Installation(seed.server)
        let (app, library) = try await phone.launchEnrolled(seed)
        let stage = try Stage()
        defer { stage.close() }
        let ref = PageRef(notebookId: seed.notebookId, pageId: seed.pageId)
        let editor = try await library.open(ref)
        stage.show(editor.host)
        let before = try #require(library.notebook(seed.notebookId)?.page(seed.pageId)).updatedAt
        try await Task.sleep(for: .milliseconds(20))

        // Type at the end of the first line, in bold.
        editor.textView.becomeFirstResponder()
        editor.textView.selectedRange = NSRange(location: 16, length: 0)
        editor.binding.toggleInline(PageAttribute.bold)
        editor.textView.insertText(" at dusk")
        #expect(editor.page.text == "Bittern sighting at dusk\n")
        #expect(editor.page.runs.contains(TextRun(text: " at dusk", attributes: [PageAttribute.bold: .bool(true)])))

        try await eventually("the page's last-edited time moves after a pause in typing") {
            (library.notebook(seed.notebookId)?.page(seed.pageId)?.updatedAt ?? before) > before
        }

        // The title is part of the page.
        editor.host.titleField.text = "Dusk at the hide"
        editor.flush()
        #expect(library.notebook(seed.notebookId)?.page(seed.pageId)?.title == "Dusk at the hide")

        try await eventually("the other device has the text and the title") {
            try await seed.a.syncNow()
            return seed.page.text == "Bittern sighting at dusk\n" && seed.tree.page(seed.pageId)?.title == "Dusk at the hide"
        }
        #expect(seed.page.runs.contains(TextRun(text: " at dusk", attributes: [PageAttribute.bold: .bool(true)])))

        // Leaving the page releases its document.
        library.select(nil)
        #expect(library.editor == nil)
        #expect(editor.host.superview == nil)
        await app.lock()
    }

    @Test func goingToTheBackgroundPutsPendingEditsInTheStoreAtOnce() async throws {
        let seed = try await Seed.make()
        let phone = Installation(seed.server)
        let (app, library) = try await phone.launchEnrolled(seed)
        try await eventually("sync settles") { SyncSummary(app.client!.syncMonitor.status).kind == .synced }
        phone.transport.offline = true
        try await eventually("offline") { app.client!.sync.status.state == .offline }
        let stage = try Stage()
        defer { stage.close() }
        let editor = try await library.open(PageRef(notebookId: seed.notebookId, pageId: seed.pageId))
        stage.show(editor.host)
        let store = try LocalStore.open(path: phone.databasePath) // a second connection, to look at what is on disk
        defer { store.close() }
        let outboxBefore = try store.outboxCount()

        editor.textView.becomeFirstResponder()
        editor.textView.insertText("Typed as the app is closed. ")
        editor.host.titleField.text = "Closed mid-title"
        await app.willResignActive()
        // No waiting: the text edit and the title (with its timestamp) are in the outbox now.
        #expect(try store.outboxCount() >= outboxBefore + 2)

        await app.didEnterBackground(waitForSync: .seconds(2)) // offline: returns without sending
        #expect(app.client!.sync.status.state == .offline)

        // The process is killed. Next launch, back in reach of the server: the edit arrives.
        await app.client?.close()
        phone.transport.offline = false
        let relaunched = await phone.launch()
        try await relaunched.unlock(password: testPassword)
        try await eventually("the other device receives what was typed") {
            try await seed.a.syncNow()
            return seed.page.text.hasPrefix("Typed as the app is closed. ") && seed.tree.page(seed.pageId)?.title == "Closed mid-title"
        }
        await relaunched.lock()
    }

    @Test func foldingAndUnfoldingKeepsThePageSelectionScrollAndKeyboard() async throws {
        let seed = try await Seed.make()
        seed.page.edit { editor in
            editor.insert((1...120).map { "Line \($0) of the long page" }.joined(separator: "\n"), at: 0, attributes: [:])
        }
        try await seed.a.syncNow()
        let phone = Installation(seed.server)
        let (app, library) = try await phone.launchEnrolled(seed)
        let ref = PageRef(notebookId: seed.notebookId, pageId: seed.pageId)
        library.setPath([.notebook(seed.notebookId), .section(notebookId: seed.notebookId, sectionId: seed.sectionId)])
        let editor = try await library.open(ref)

        // The real root view in a window the size of the Duo's cover display.
        let stage = try Stage()
        defer { stage.close() }
        let cover = CGSize(width: 466, height: 678), inner = CGSize(width: 669, height: 951)
        let root = UIViewController()
        root.view.backgroundColor = .systemBackground
        stage.window.rootViewController = root
        let hosting = UIHostingController(
            rootView: LibraryView(library: library).environment(app).environment(\.horizontalSizeClass, .compact))
        root.addChild(hosting)
        root.view.addSubview(hosting.view)
        hosting.didMove(toParent: root)
        func resize(_ size: CGSize) {
            hosting.view.frame = CGRect(origin: .zero, size: size)
        }
        resize(cover)
        func settle() async throws {
            for _ in 0..<12 {
                stage.window.layoutIfNeeded()
                try await Task.sleep(for: .milliseconds(50))
            }
        }
        /// With TWONOTE_SNAPSHOT_DIR set, saves what the window shows (for looking at the wide layout).
        func snapshot(_ name: String) {
            guard let folder = ProcessInfo.processInfo.environment["TWONOTE_SNAPSHOT_DIR"], !folder.isEmpty else { return }
            let image = UIGraphicsImageRenderer(bounds: hosting.view.bounds).image { _ in
                hosting.view.drawHierarchy(in: hosting.view.bounds, afterScreenUpdates: true)
            }
            try? image.pngData()?.write(to: URL(fileURLWithPath: folder).appendingPathComponent(name + ".png"))
        }
        try await settle()
        #expect(editor.host.window === stage.window, "the cover display shows the page (pushed on the stack)")
        #expect(abs(editor.host.bounds.width - hosting.view.safeAreaLayoutGuide.layoutFrame.width) < 1, "host \(editor.host.bounds) safe \(hosting.view.safeAreaLayoutGuide.layoutFrame)")

        // Mid-edit: caret in line 60, scrolled there, keyboard up.
        let text = editor.textView.text as NSString
        let caret = text.range(of: "Line 60 of").location + 7
        editor.textView.becomeFirstResponder()
        editor.textView.selectedRange = NSRange(location: caret, length: 0)
        editor.textView.scrollRangeToVisible(NSRange(location: caret, length: 0))
        editor.textView.insertText("!")
        try await settle()
        #expect(editor.textView.isFirstResponder)
        let selection = editor.textView.selectedRange
        func topLine() -> String {
            let top = editor.textView.contentOffset.y + editor.textView.adjustedContentInset.top
            guard let position = editor.textView.closestPosition(to: CGPoint(x: 30, y: top + 4)) else { return "" }
            let index = editor.textView.offset(from: editor.textView.beginningOfDocument, to: position)
            return (editor.textView.text as NSString).substring(with: (editor.textView.text as NSString).lineRange(for: NSRange(location: index, length: 0)))
        }
        let lineAtTop = topLine()
        /// The scroll position survived: the line at the top is the same give or take two
        /// (the keyboard coming back nudges the text to keep the caret in view), and the
        /// caret is on screen.
        func scrollKept() -> Bool {
            func number(_ line: String) -> Int { Int(line.split(separator: " ").dropFirst().first ?? "") ?? -99 }
            guard let end = editor.textView.selectedTextRange?.end else { return false }
            let caret = editor.textView.caretRect(for: end)
            let visible = editor.textView.bounds.inset(by: editor.textView.adjustedContentInset)
            return abs(number(topLine()) - number(lineAtTop)) <= 2 && visible.intersects(caret)
        }
        snapshot("fold-1-cover")
        #expect(editor.textView.contentOffset.y > 500, "the page is scrolled well down")

        // Unfold.
        resize(inner)
        try await settle()
        #expect(library.selectedPage == ref && library.editor === editor, "the same page is open")
        #expect(editor.host.window === stage.window)
        #expect(editor.host.bounds.width < hosting.view.safeAreaLayoutGuide.layoutFrame.width - 230 && editor.host.bounds.width > 250, "the page now shares the screen with the sidebar: host \(editor.host.bounds) in \(hosting.view.bounds)")
        #expect(editor.textView.selectedRange == selection)
        #expect(editor.textView.isFirstResponder, "the keyboard stays with the text")
        try await eventually("the scroll position settles where it was (top line \(topLine()), was \(lineAtTop))", timeout: .seconds(4)) { scrollKept() }
        snapshot("fold-2-inner")
        editor.textView.insertText("?")
        #expect(editor.page.text.contains("Line 60!? of the long page"))

        // Fold again.
        resize(cover)
        try await settle()
        #expect(library.selectedPage == ref && library.editor === editor)
        #expect(editor.host.window === stage.window)
        #expect(abs(editor.host.bounds.width - hosting.view.safeAreaLayoutGuide.layoutFrame.width) < 1)
        #expect(editor.textView.selectedRange == NSRange(location: selection.location + 1, length: 0))
        #expect(editor.textView.isFirstResponder)
        try await eventually("the scroll position settles where it was (top line \(topLine()), was \(lineAtTop))", timeout: .seconds(4)) { scrollKept() }
        await app.lock()
    }
}

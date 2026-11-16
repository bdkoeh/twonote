import AppKit
import Foundation
import TwoNoteCore
import TwoNoteDocuments
import XCTest
import YrsKit

// The real Mac app against a REAL server container, with a second device (a headless
// `TwoNoteClient` inside this test process) on the same account.
//
// Skipped unless the environment names a fresh container (pass these to xcodebuild with the
// TEST_RUNNER_ prefix; tools/e2e-mac.sh does):
//   TWONOTE_E2E_URL       the server, e.g. http://127.0.0.1:18190 (no account on it yet)
//   TWONOTE_E2E_CONTROL   ../TwoNote/tools/e2e-control.py, e.g. http://127.0.0.1:18191 (stops
//                         and starts the container for the offline part)
//   TWONOTE_SHOTS_DIR     folder for screenshots of every window, light and dark (optional)
//
// Screenshots are of the app's own windows only (never the whole screen: this Mac is
// someone's desktop). Light and dark are switched inside the app (a DEBUG-only hook), not in
// System Settings.

@MainActor
final class EndToEndTests: XCTestCase {
    static let username = "bob"
    static let password = "correct horse battery staple"

    let environment = ProcessInfo.processInfo.environment
    var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = false
    }

    // MARK: Helpers

    func step(_ text: String) {
        print("[e2e] \(text)")
    }

    func eventually(_ what: String, timeout: TimeInterval = 30, _ condition: () async throws -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if try await condition() { return }
            try await Task.sleep(for: .milliseconds(250))
        }
        failureShot()
        XCTFail("Timed out waiting for: \(what)")
        throw CancellationError()
    }

    var shotsFolder: URL? {
        guard let folder = environment["TWONOTE_SHOTS_DIR"], !folder.isEmpty else { return nil }
        return URL(fileURLWithPath: folder)
    }

    func failureShot() {
        guard let shotsFolder, let app else { return }
        try? app.windows.firstMatch.screenshot().pngRepresentation.write(to: shotsFolder.appendingPathComponent("_failure.png"))
    }

    func require(_ element: XCUIElement, _ what: String, timeout: TimeInterval = 15) {
        if !element.waitForExistence(timeout: timeout) {
            failureShot()
            XCTFail("\(what) did not appear")
        }
    }

    func setAppearance(_ name: String?) {
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name("com.twonote.mac.debug.appearance"), object: name, userInfo: nil, deliverImmediately: true)
    }

    /// Saves the front window (with its sheet, if one is up) as <name>-light.png and <name>-dark.png.
    func shot(_ name: String, of element: XCUIElement? = nil) {
        guard let shotsFolder else { return }
        for appearance in ["light", "dark"] {
            setAppearance(appearance)
            Thread.sleep(forTimeInterval: 1.0)
            let target = element ?? app.windows.firstMatch
            let url = shotsFolder.appendingPathComponent("\(name)-\(appearance).png")
            try? target.screenshot().pngRepresentation.write(to: url)
        }
        setAppearance(nil)
        Thread.sleep(forTimeInterval: 0.5)
    }

    func type(_ text: String, into element: XCUIElement) {
        require(element, "\(element)")
        element.click()
        element.typeText(text)
    }

    func menu(_ menu: String, _ item: String) {
        let bar = app.menuBars.menuBarItems[menu]
        require(bar, "the \(menu) menu")
        bar.click()
        let entry = app.menuBars.menuItems[item]
        require(entry, "\(menu) > \(item)")
        XCTAssertTrue(entry.isEnabled, "\(menu) > \(item) is disabled")
        entry.click()
    }

    func nameSheet(_ text: String) {
        let field = app.textFields["name-field"]
        require(field, "the name sheet")
        field.typeText(text)
        app.buttons["name-confirm"].click()
        XCTAssertTrue(field.waitForNonExistence(timeout: 5), "the name sheet did not close")
    }

    func syncStatus(contains text: String, timeout: TimeInterval = 40) {
        let match = app.descendants(matching: .any).matching(identifier: "sync-status-line")
            .matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
        require(match, "sync status “\(text)”", timeout: timeout)
    }

    var editor: XCUIElement { app.textViews["page-editor"] }

    func editorText() -> String {
        editor.value as? String ?? ""
    }

    func control(_ action: String) async throws {
        let base = try XCTUnwrap(environment["TWONOTE_E2E_CONTROL"])
        let (_, response) = try await URLSession.shared.data(from: try XCTUnwrap(URL(string: base + "/" + action)))
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200, "docker \(action) failed")
    }

    /// Everything the window shows as text, for the privacy checks.
    func windowTexts() -> [String] {
        let window = app.windows.firstMatch
        var texts = [window.title]
        for query in [window.staticTexts, window.textFields, window.textViews, window.outlineRows, window.cells] {
            for element in query.allElementsBoundByIndex.prefix(200) {
                texts.append(element.label)
                if let value = element.value as? String { texts.append(value) }
            }
        }
        return texts
    }

    // MARK: The run

    func testEverythingAgainstARealServer() async throws {
        guard let address = environment["TWONOTE_E2E_URL"], let url = URL(string: address) else {
            throw XCTSkip("TWONOTE_E2E_URL is not set")
        }

        step("1. the other device registers the account and writes a notebook")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("twonote-peer-\(UUID().uuidString)")
        var options = ClientOptions(serverURL: url, databasePath: folder.appendingPathComponent("store.db").path, secretStore: InMemorySecretStore())
        options.maxOfflineRetryDelay = .seconds(2)
        let peer = try await TwoNoteClient.open(options)
        let status = try await peer.api.status()
        XCTAssertTrue(status.registrationOpen, "the container already has an account; start a fresh one")
        let secretKey = try await peer.register(username: Self.username, password: Self.password, deviceName: "Desk PC")
        let journal = try await peer.createNotebook(title: "Field Journal")
        let marsh = journal.addSection(title: "Marsh")
        journal.addSection(title: "Woodland")
        let monday = try await peer.createPage(notebookId: journal.notebookId, sectionId: marsh, title: "Monday at the hide")
        monday.edit { editor in
            editor.insert("Bittern sighting\nBooming call heard at dawn near the reedbed.\nRefill the thermos", at: 0, attributes: [:])
            editor.setBlock(newlineAt: 16, block: "h1", indent: 0, checked: false)
            editor.format(at: 17, count: 12, attributes: [PageAttribute.bold: .bool(true)])
            editor.setBlock(newlineAt: editor.length - 1, block: "todo", indent: 0, checked: false)
        }
        try await peer.sync.syncNow()
        try await peer.sync.start()

        step("2. first run: the set-up window; a wrong password is explained, the right one signs in")
        app = XCUIApplication()
        app.launchArguments = ["-TwoNoteResetState", "YES"]
        app.launch()
        app.activate()
        require(app.textFields["enrol-server"], "the set-up screen", timeout: 30)
        XCTAssertEqual(app.windows.firstMatch.title, "TwoNote")
        shot("01-setup")
        type(address, into: app.textFields["enrol-server"])
        type(Self.username, into: app.textFields["enrol-username"])
        type("wrong", into: app.secureTextFields["enrol-password"])
        type(secretKey, into: app.textFields["enrol-secret-key"])
        app.buttons["enrol-submit"].click()
        require(app.staticTexts["Incorrect Sign-In Details"], "the wrong-credentials alert", timeout: 40)
        shot("02-setup-wrong-details")
        app.buttons["OK"].firstMatch.click()
        let passwordField = app.secureTextFields["enrol-password"]
        passwordField.click()
        passwordField.typeKey("a", modifierFlags: .command)
        passwordField.typeText(Self.password)
        app.buttons["enrol-submit"].click()

        step("3. the other device's notebook arrives; this Mac has no Touch ID, so nothing offers it")
        require(app.staticTexts["Field Journal"], "the synced notebook", timeout: 60)
        XCTAssertFalse(app.staticTexts["Unlock with Touch ID?"].exists)
        syncStatus(contains: "Synced")
        app.staticTexts["Marsh"].firstMatch.click()
        require(app.staticTexts["Monday at the hide"], "the page list")
        shot("03-library")

        step("4. create a notebook, a section and a page from the menus; type with formatting and lists")
        menu("File", "New Notebook")
        require(app.textFields["name-field"], "the new-notebook sheet")
        shot("04-new-notebook")
        nameSheet("Trip Notes")
        require(app.staticTexts["Trip Notes"], "the new notebook in the sidebar")
        menu("File", "New Section")
        nameSheet("Packing")
        require(app.staticTexts["No Pages"], "the empty section")
        shot("05-section-empty")
        app.typeKey("n", modifierFlags: .command) // File > New Page
        let title = app.textFields["page-title"]
        require(title, "the new page")
        try await eventually("the title of a new page has the keyboard") { (title.value(forKey: "hasKeyboardFocus") as? Bool) == true }
        title.typeText("Checklist\r")
        editor.typeText("Plain start. ")
        app.typeKey("b", modifierFlags: .command)
        editor.typeText("Bold words")
        app.typeKey("b", modifierFlags: .command)
        editor.typeText("\r")
        app.typeKey("l", modifierFlags: [.command, .shift]) // Format > Checklist
        editor.typeText("Passport\rTickets")
        XCTAssertEqual(editorText(), "Plain start. Bold words\nPassport\nTickets\n")
        shot("06-editor")
        app.buttons["format-menu"].firstMatch.click()
        require(app.menuItems["Subheading"], "the toolbar's format menu")
        shot("07-format-menu")
        app.typeKey(.escape, modifierFlags: [])
        menu("Format", "Bold") // nothing selected: turns bold on for what is typed next, and off again
        menu("Format", "Bold")

        step("5. what was typed arrives at the other device, formatting included")
        var tripId = ""
        try await eventually("the other device has the new notebook", timeout: 40) {
            tripId = peer.notebookIds.first { $0 != journal.notebookId } ?? ""
            return !tripId.isEmpty
        }
        let trip = try await peer.openNotebook(tripId)
        var checklistId = ""
        try await eventually("the other device has the notebook's content", timeout: 40) {
            guard trip.title == "Trip Notes", let section = trip.sections().first, section.title == "Packing",
                  let page = trip.pages(inSection: section.id).first, page.title == "Checklist" else { return false }
            checklistId = page.id
            return true
        }
        let checklist = try await peer.openPage(notebookId: tripId, pageId: checklistId)
        try await eventually("the other device has the text", timeout: 40) {
            checklist.text == "Plain start. Bold words\nPassport\nTickets\n"
        }
        XCTAssertTrue(checklist.runs.contains(TextRun(text: "Bold words", attributes: [PageAttribute.bold: .bool(true)])), "\(checklist.runs)")
        XCTAssertTrue(checklist.runs.contains { $0.text == "\n" && $0.attributes[PageAttribute.block] == .string("todo") }, "\(checklist.runs)")

        step("6. the other device edits while the caret is in the page here: it shows up live and the caret stays put")
        checklist.edit { $0.insert("From the PC: ", at: 0, attributes: [:]) }
        try await peer.sync.syncNow()
        try await eventually("the edit shows up in the open page", timeout: 40) {
            editorText() == "From the PC: Plain start. Bold words\nPassport\nTickets\n"
        }
        editor.typeText(" x2")
        XCTAssertEqual(editorText(), "From the PC: Plain start. Bold words\nPassport\nTickets x2\n", "the caret moved")
        try await eventually("the typing after the remote edit arrives", timeout: 40) {
            checklist.text == "From the PC: Plain start. Bold words\nPassport\nTickets x2\n"
        }
        shot("08-editor-after-remote-edit")

        step("7. lock from the menu: nothing of the notes is in the window or its title")
        menu("File", "Lock TwoNote")
        require(app.secureTextFields["unlock-password"], "the lock screen")
        XCTAssertEqual(app.windows.firstMatch.title, "TwoNote")
        let shown = windowTexts().joined(separator: "\n")
        for secret in ["Checklist", "Passport", "Trip Notes", "Field Journal", "Bittern", "Packing"] {
            XCTAssertFalse(shown.contains(secret), "“\(secret)” is visible while locked")
        }
        XCTAssertTrue(app.staticTexts["TwoNote Is Locked"].exists)
        shot("09-locked")
        // The Window menu lists the window by its title only.
        app.menuBars.menuBarItems["Window"].click()
        let windowMenu = app.menuBars.menuItems.allElementsBoundByIndex.map(\.title).joined(separator: "|")
        app.typeKey(.escape, modifierFlags: [])
        for secret in ["Checklist", "Trip Notes", "Packing"] {
            XCTAssertFalse(windowMenu.contains(secret), "“\(secret)” is in the Window menu")
        }

        step("8. a wrong password is refused; the right one unlocks and returns to the page")
        type("not it\r", into: app.secureTextFields["unlock-password"])
        require(app.staticTexts["unlock-error"], "the wrong-password message")
        shot("10-locked-wrong-password")
        type(Self.password + "\r", into: app.secureTextFields["unlock-password"])
        require(editor, "the page after unlocking", timeout: 30)
        try await eventually("the page text is back") { editorText().hasPrefix("From the PC: ") }

        step("9. search everything (⌥⌘F) and open a result")
        app.typeKey("f", modifierFlags: [.command, .option])
        let field = app.searchFields.firstMatch
        require(field, "the search field")
        field.typeText("booming")
        let hit = app.descendants(matching: .any).matching(identifier: "search-hit").firstMatch
        require(hit, "a search result", timeout: 20)
        shot("11-search")
        hit.click()
        try await eventually("the found page opens") { editorText().hasPrefix("Bittern sighting\nBooming call") }
        XCTAssertEqual(app.textFields["page-title"].value as? String, "Monday at the hide")
        shot("12-found-page")

        step("10. offline: the server goes away; editing goes on; it syncs when the server is back")
        try await control("stop")
        syncStatus(contains: "Offline", timeout: 60)
        editor.click()
        app.typeKey(.downArrow, modifierFlags: .command) // to the end of the page
        editor.typeText(" (offline)")
        syncStatus(contains: "Changes Waiting", timeout: 30)
        app.buttons["sync-status"].firstMatch.click()
        require(app.descendants(matching: .any).matching(identifier: "sync-popover").firstMatch, "the sync popover")
        shot("13-offline-popover")
        app.typeKey(.escape, modifierFlags: [])
        try await control("start")
        syncStatus(contains: "Synced", timeout: 90)
        try await eventually("the offline edit reaches the other device", timeout: 60) {
            monday.text.hasSuffix("Refill the thermos (offline)\n")
        }

        step("11. Settings (⌘,): every tab")
        app.typeKey(",", modifierFlags: .command)
        let settings = app.windows.matching(NSPredicate(format: "identifier CONTAINS 'Settings' OR title CONTAINS 'Account' OR title CONTAINS 'Settings'")).firstMatch
        require(app.staticTexts["Username"], "the Settings window")
        shot("14-settings-account", of: settings.exists ? settings : nil)
        for (tab, name) in [("Sync", "15-settings-sync"), ("Security", "16-settings-security"), ("Devices", "17-settings-devices")] {
            app.toolbars.buttons[tab].firstMatch.click()
            try await Task.sleep(for: .seconds(1))
            shot(name, of: settings.exists ? settings : nil)
        }
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "settings-biometrics-unavailable").firstMatch.exists
                      || app.switches["settings-biometrics"].exists)
        app.typeKey("w", modifierFlags: .command)

        step("12. delete a page with the Delete key, after confirming")
        app.staticTexts["Trip Notes"].firstMatch.click()
        app.staticTexts["Packing"].firstMatch.click()
        let row = app.descendants(matching: .any).matching(identifier: "page-row").firstMatch
        require(row, "the page row")
        row.click()
        app.typeKey(.delete, modifierFlags: [])
        require(app.buttons["Delete Page"], "the delete confirmation")
        shot("18-delete-confirmation")
        app.buttons["Delete Page"].click()
        require(app.staticTexts["No Pages"], "the empty section after deleting")
        try await eventually("the other device sees the page go", timeout: 40) {
            trip.page(checklistId)?.deleted == true
        }

        step("13. lock again and quit")
        app.typeKey("l", modifierFlags: [.command, .control])
        require(app.secureTextFields["unlock-password"], "the lock screen")
        app.terminate()
        await peer.close()
        try? FileManager.default.removeItem(at: folder)
        step("done")
    }
}

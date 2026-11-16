import Foundation
import notify
import TwoNoteCore
import TwoNoteDocuments
import XCTest
import YrsKit

// Share to TwoNote, twonote:// links and the widget: the real app and its two extensions in
// the simulator against a REAL server container, with a second device in this test process.
//
// The share sheet is driven for real: Safari shows a page served by tools/e2e-control.py, its
// Share button brings up the system share sheet, "TwoNote" in it is the share extension.
// The widget is added to the Home Screen through SpringBoard's own widget gallery.
//
// Needs TWONOTE_E2E_URL and TWONOTE_E2E_CONTROL (see EndToEndTests.swift); starts from a fresh
// server by asking the control helper for one. Run alone with
//   TWONOTE_ONLY=TwoNoteUITests/ExtrasEndToEndTests tools/e2e.sh

@MainActor
final class ExtrasEndToEndTests: EndToEndCase {
    private let safari = XCUIApplication(bundleIdentifier: "com.apple.mobilesafari")
    private let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
    private var controlAddress = ""

    private var articleAddress: String { controlAddress + "/article" }

    /// Safari on the test article, then Share, then TwoNote: leaves the extension's sheet up.
    private func shareArticleToTwoNote() {
        XCUIDevice.shared.system.open(URL(string: articleAddress)!)
        require(safari.staticTexts["Marsh Birds Weekly"].firstMatch, "the article in Safari", timeout: 40)
        pause(1)
        safari.buttons["MoreMenuButton"].firstMatch.tap()
        require(safari.buttons["ShareButton"].firstMatch, "Share in Safari's page menu")
        safari.buttons["ShareButton"].firstMatch.tap()
        chooseTwoNoteInShareSheet()
    }

    private func chooseTwoNoteInShareSheet() {
        let cell = safari.cells.matching(identifier: "shareCell").matching(NSPredicate(format: "label == 'TwoNote'")).firstMatch
        require(cell, "TwoNote in the share sheet")
        cell.tap()
        require(safari.buttons["share-cancel"].firstMatch, "the share extension's sheet")
    }

    /// Selects a word of the article and shares the selection (text) from the edit menu.
    private func shareSelectedTextToTwoNote() -> Bool {
        let paragraph = safari.staticTexts["A bittern was heard booming at dawn near the reedbed."].firstMatch
        require(paragraph, "the article's text")
        paragraph.press(forDuration: 1.3)
        for _ in 0..<4 {
            for label in ["Share…", "Share...", "Share"] {
                let item = safari.menuItems[label].firstMatch.exists ? safari.menuItems[label].firstMatch : safari.buttons[label].firstMatch
                if item.exists && item.isHittable {
                    item.tap()
                    chooseTwoNoteInShareSheet()
                    return true
                }
            }
            let more = ["Next Page", "Forward", "Show more items"].map { safari.buttons[$0].firstMatch }.first { $0.exists && $0.isHittable }
            guard let more else { break }
            more.tap()
            pause(0.8)
        }
        let seen = (safari.menuItems.allElementsBoundByIndex + safari.buttons.allElementsBoundByIndex).map(\.label)
        print("[e2e] no Share in the edit menu; seen: \(seen)")
        return false
    }

    /// The files in the app's App Group container, read from outside the app (this process
    /// runs in the simulator, which does not fence containers off).
    private func appGroupFiles() -> [(name: String, data: Data)]? {
        // group.<prefix>.app, written into this test bundle's Info.plist by the build (project.yml).
        let appGroup = Bundle(for: Self.self).object(forInfoDictionaryKey: "TwoNoteAppGroup") as? String
        let containers = URL(fileURLWithPath: NSHomeDirectory())
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let groups = containers.appendingPathComponent("Shared/AppGroup")
        let manager = FileManager.default
        for folder in (try? manager.contentsOfDirectory(at: groups, includingPropertiesForKeys: nil)) ?? [] {
            let metadata = NSDictionary(contentsOf: folder.appendingPathComponent(".com.apple.mobile_container_manager.metadata.plist"))
            guard metadata?["MCMMetadataIdentifier"] as? String == appGroup else { continue }
            var found: [(String, Data)] = []
            let walker = manager.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey])
            while let file = walker?.nextObject() as? URL {
                let name = file.path.replacingOccurrences(of: folder.path + "/", with: "")
                guard (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
                      !name.hasPrefix("Library/"), !file.lastPathComponent.hasPrefix(".com.apple") else { continue }
                found.append((name, (try? Data(contentsOf: file)) ?? Data()))
            }
            return found.sorted { $0.0 < $1.0 }
        }
        return nil
    }

    private func unlock() {
        let passwordField = app.secureTextFields["unlock-password"]
        require(passwordField, "the unlock screen")
        passwordField.tap()
        passwordField.typeText(Self.password + "\n")
    }

    private func lock() {
        if !app.buttons["more-menu"].firstMatch.exists {
            goToNotebookList()
        }
        app.buttons["more-menu"].firstMatch.tap()
        require(app.buttons["Lock TwoNote"], "the More menu")
        app.buttons["Lock TwoNote"].tap()
        require(app.secureTextFields["unlock-password"], "the unlock screen after Lock")
    }

    /// Done, in Settings. After scrolling down the system may have put the bar with Done away;
    /// scrolling back brings it out.
    private func closeScrolledSettings() {
        for _ in 0..<4 where !app.buttons["Done"].firstMatch.waitForExistence(timeout: 2) {
            app.swipeDown()
        }
        closeSettings()
    }

    private func hasKeyboardFocus(_ element: XCUIElement) -> Bool {
        (element.value(forKey: "hasKeyboardFocus") as? Bool) == true
    }

    // MARK: The run

    func testShareLinksAndWidgetAgainstARealServer() async throws {
        guard let address = environment["TWONOTE_E2E_URL"], let url = URL(string: address),
              let control = environment["TWONOTE_E2E_CONTROL"] else {
            throw XCTSkip("TWONOTE_E2E_URL and TWONOTE_E2E_CONTROL are not set")
        }
        controlAddress = control

        step("x1. a fresh server; the app has never been set up: the share sheet offers TwoNote for a web page, and the sheet says to open TwoNote first")
        try await self.control("reset")
        try await eventually("the fresh server answers", timeout: 60) {
            ((try? await URLSession.shared.data(from: url.appendingPathComponent("api/v1/status")))?.1 as? HTTPURLResponse)?.statusCode == 200
        }
        app = XCUIApplication()
        app.launchArguments = ["-TwoNoteResetState"]
        app.launch()
        require(app.textFields["enrol-server"], "the set-up screen")
        if let files = appGroupFiles() {
            XCTAssertEqual(files.map(\.name), [], "a device that is not set up has nothing in the App Group container")
        } else {
            print("[e2e] the App Group container cannot be seen from the test; its content is not checked in this run")
        }
        shareArticleToTwoNote()
        require(safari.staticTexts["Open TwoNote First"], "the explanation in the share sheet")
        XCTAssertFalse(safari.buttons["share-save"].firstMatch.isEnabled)
        shot("36-share-not-set-up")
        safari.buttons["share-cancel"].firstMatch.tap()
        XCTAssertTrue(safari.buttons["share-cancel"].firstMatch.waitForNonExistence(timeout: 10))

        step("x2. the other device registers the account and writes a notebook; the app signs in")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("twonote-peer-\(UUID().uuidString)")
        var options = ClientOptions(serverURL: url, databasePath: folder.appendingPathComponent("store.db").path, secretStore: InMemorySecretStore())
        options.maxOfflineRetryDelay = .seconds(2)
        let peer = try await TwoNoteClient.open(options)
        let secretKey = try await peer.register(username: Self.username, password: Self.password, deviceName: "Desk PC")
        let journal = try await peer.createNotebook(title: "Field Journal")
        let marsh = journal.addSection(title: "Marsh")
        let monday = try await peer.createPage(notebookId: journal.notebookId, sectionId: marsh, title: "Monday at the hide")
        monday.edit { $0.insert("Booming call heard at dawn near the reedbed.", at: 0, attributes: [:]) }
        try await peer.sync.syncNow()
        try await peer.sync.start()

        app.activate()
        type(address, into: app.textFields["enrol-server"])
        type(Self.username, into: app.textFields["enrol-username"])
        type(Self.password, into: app.secureTextFields["enrol-password"])
        type(secretKey, into: app.textFields["enrol-secret-key"])
        app.buttons["enrol-submit"].tap()
        let notebookRow = app.staticTexts["Field Journal"].firstMatch
        for _ in 0..<40 where !notebookRow.exists {
            if app.alerts.buttons["Not Now"].exists {
                app.alerts.buttons["Not Now"].tap() // the offer to unlock with the sensor
            }
            pause(1)
        }
        require(notebookRow, "the synced notebook", timeout: 40)
        syncStatus(contains: "Synced")
        notebookRow.tap()
        require(app.staticTexts["Marsh"].firstMatch, "the section")
        app.staticTexts["Marsh"].firstMatch.tap()
        require(app.staticTexts["Monday at the hide"].firstMatch, "the page in the list")
        if let files = appGroupFiles() {
            XCTAssertEqual(files.map(\.name), ["share-inbox.pub"], "unlocking made the share inbox's public key and nothing else")
            XCTAssertEqual(files.first?.data.count, 32)
        }

        step("x3. locked: a web page is shared from Safari (title from the page, link), then a text selection with a title typed in")
        lock()
        shareArticleToTwoNote()
        let titleField = safari.textFields["share-title"].firstMatch
        require(titleField, "the title field of the share sheet")
        XCTAssertEqual(titleField.value as? String, "Marsh Birds Weekly", "the page title is suggested")
        let linkRow = safari.descendants(matching: .any).matching(identifier: "share-link").firstMatch
        require(linkRow, "the link in the preview")
        XCTAssertTrue(linkRow.label.contains(articleAddress) || safari.staticTexts[articleAddress].exists, linkRow.label)
        XCTAssertFalse(safari.staticTexts["Field Journal"].exists || safari.staticTexts["Marsh"].exists, "nothing from the notes is in the sheet")
        shot("37-share-sheet-link")
        safari.buttons["share-save"].firstMatch.tap()
        XCTAssertTrue(safari.buttons["share-cancel"].firstMatch.waitForNonExistence(timeout: 10), "the sheet closes after Save")

        var sharedText = false
        if shareSelectedTextToTwoNote() {
            let field = safari.textFields["share-title"].firstMatch
            require(field, "the title field")
            let suggested = field.value as? String ?? ""
            print("[e2e] shared selection: suggested title “\(suggested)”")
            let preview = safari.staticTexts.matching(identifier: "share-text").firstMatch
            require(preview, "the text in the preview")
            print("[e2e] shared selection: text “\(preview.label)”")
            field.tap()
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: suggested.count + 2) + "Dawn note")
            shot("37b-share-sheet-text")
            safari.buttons["share-save"].firstMatch.tap()
            XCTAssertTrue(safari.buttons["share-cancel"].firstMatch.waitForNonExistence(timeout: 10))
            sharedText = true
        }
        let expected = sharedText ? 2 : 1

        if let files = appGroupFiles() {
            print("[e2e] App Group container while locked: \(files.map { "\($0.name) (\($0.data.count) bytes)" })")
            XCTAssertEqual(files.filter { $0.name.hasSuffix(".tnshare") }.count, expected)
            XCTAssertEqual(files.count, expected + 1, "the public key and the sealed items, nothing else")
            for secret in ["Marsh Birds", "bittern", "127.0.0.1", "article", "Dawn", "Field Journal", "Monday"] {
                XCTAssertFalse(files.contains { $0.data.range(of: Data(secret.utf8)) != nil }, "“\(secret)” is readable in the App Group container")
            }
        }

        step("x4. unlock: the items become pages in Inbox, the app says so; the content is right and reaches the other device")
        app.activate()
        unlock()
        let notice = app.buttons["import-notice"].firstMatch
        require(notice, "the note that shared items were added", timeout: 20)
        XCTAssertEqual(notice.label, expected == 2 ? "2 Shared Items Added" : "1 Shared Item Added")
        shot("38-import-notice")
        if notice.exists {
            notice.tap()
        } else {
            goBack()
            app.staticTexts["Inbox"].firstMatch.tap()
        }
        require(app.staticTexts["Marsh Birds Weekly"].firstMatch, "the shared page in the Inbox section")
        if sharedText {
            require(app.staticTexts["Dawn note"].firstMatch, "the shared text in the Inbox section")
        }
        shot("39-inbox")
        app.staticTexts["Marsh Birds Weekly"].firstMatch.tap()
        let editor = app.textViews["page-editor"]
        require(editor, "the shared page")
        wide = app.buttons["new-page"].exists
        try await eventually("the page shows the link") { self.editorText() == self.articleAddress + "\n" }
        XCTAssertEqual(app.textFields["page-title"].value as? String, "Marsh Birds Weekly")
        shot("39b-shared-page")
        if let files = appGroupFiles() {
            XCTAssertEqual(files.map(\.name), ["share-inbox.pub"], "the sealed items are removed once they are pages")
        }

        var inboxId = ""
        try await eventually("the other device has the Inbox section and its pages", timeout: 60) {
            guard let inbox = journal.sections().first(where: { $0.title == "Inbox" }) else { return false }
            inboxId = inbox.id
            return journal.pages(inSection: inbox.id).count == expected
        }
        let sharedPages = journal.pages(inSection: inboxId)
        XCTAssertEqual(sharedPages.map(\.title), sharedText ? ["Marsh Birds Weekly", "Dawn note"] : ["Marsh Birds Weekly"])
        let article = try await peer.openPage(notebookId: journal.notebookId, pageId: sharedPages[0].id)
        try await eventually("the other device has the shared page's content") { article.text == self.articleAddress + "\n" }
        XCTAssertEqual(article.runs.first, TextRun(text: articleAddress, attributes: [PageAttribute.link: .string(articleAddress)]), "a real link")
        if sharedText {
            let note = try await peer.openPage(notebookId: journal.notebookId, pageId: sharedPages[1].id)
            try await eventually("the other device has the shared text") { note.length > 1 }
            print("[e2e] shared selection arrived as: \(note.runs)")
            XCTAssertFalse(note.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }

        step("x5. Settings: where shared items go (picker), and the widget switch with its warning")
        openSettings()
        let destination = app.buttons["settings-share-destination"].firstMatch
        reveal(destination, "the Shared Items row")
        XCTAssertTrue(destination.label.contains("Field Journal › Inbox"), destination.label)
        shot("40-settings-sharing")
        destination.tap()
        require(app.buttons["share-destination-inbox"].firstMatch, "the destination picker")
        shot("41-share-destination")
        app.buttons["Marsh"].firstMatch.tap()
        goBack()
        try await eventually("the row shows the new destination") { destination.label.contains("Field Journal › Marsh") }
        let widgetSwitch = app.switches["settings-widget-recent"].firstMatch
        reveal(widgetSwitch, "the widget switch")
        XCTAssertEqual(widgetSwitch.value as? String, "0", "off unless switched on")
        reveal(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'outside the encrypted vault'")).firstMatch, "the warning")
        shot("42-settings-widget")
        if let files = appGroupFiles() {
            XCTAssertEqual(files.map(\.name), ["share-inbox.pub"], "with the switch off no title is outside the store")
        }
        closeScrolledSettings()

        step("x6. locked: twonote://new waits for the unlock, then a new page is open in the section used last, title focused")
        leaveEditor()
        lock()
        XCUIDevice.shared.system.open(URL(string: "twonote://new")!)
        if let open = systemPromptButton(["Open"], timeout: 4) {
            open.tap()
        }
        require(app.secureTextFields["unlock-password"], "still locked after the link")
        XCTAssertFalse(app.textFields["page-title"].exists, "nothing happens before the unlock")
        unlock()
        let title = app.textFields["page-title"]
        require(title, "the new page")
        require(app.keyboards.firstMatch, "the keyboard")
        try await eventually("the title of the new page has the focus") { self.hasKeyboardFocus(title) }
        title.typeText("From a link\n")
        app.textViews["page-editor"].typeText("Made by twonote://new.")
        shot("43-link-new-page")
        app.buttons["Hide Keyboard"].tap()
        try await eventually("the other device has the new page in the section used last", timeout: 60) {
            journal.pages(inSection: inboxId).contains { $0.title == "From a link" }
        }

        step("x7. twonote://search while unlocked: the search field has the keyboard; twonote://continue reopens the last page")
        XCUIDevice.shared.system.open(URL(string: "twonote://search")!)
        if let open = systemPromptButton(["Open"], timeout: 3) {
            open.tap()
        }
        let searchField = app.searchFields.firstMatch
        require(searchField, "the search field")
        try await eventually("the search field has the focus") { self.hasKeyboardFocus(searchField) }
        searchField.typeText("marsh birds")
        require(app.buttons.containing(NSPredicate(format: "label CONTAINS 'Marsh Birds Weekly'")).firstMatch, "the shared page, found")
        shot("44-link-search")
        searchField.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 11))
        for label in ["Cancel", "Close", "close"] where app.buttons[label].firstMatch.exists {
            app.buttons[label].firstMatch.tap()
            break
        }
        XCUIDevice.shared.system.open(URL(string: "twonote://continue")!)
        if let open = systemPromptButton(["Open"], timeout: 3) {
            open.tap()
        }
        try await eventually("the last page is open again") { (self.app.textFields["page-title"].value as? String) == "From a link" }

        step("x8. the widget switch on: the titles of the pages edited last are written for the widget, and nothing else")
        openSettings()
        reveal(widgetSwitch, "the widget switch")
        widgetSwitch.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        try await eventually("the switch is on") { (widgetSwitch.value as? String) == "1" }
        shot("42b-settings-widget-on")
        closeScrolledSettings()
        if let files = appGroupFiles() {
            XCTAssertEqual(files.map(\.name), ["share-inbox.pub", "widget-recent.json"])
            let recent = String(decoding: files[1].data, as: UTF8.self)
            print("[e2e] widget-recent.json: \(recent)")
            XCTAssertTrue(recent.contains("From a link") && recent.contains("Marsh Birds Weekly"))
            XCTAssertFalse(recent.contains("Made by twonote") || recent.contains("127.0.0.1") || recent.contains("Booming"), "titles only, no text")
        }

        try await widgetOnTheHomeScreen()

        await peer.close()
    }

    /// Adds the widget to the Home Screen in both sizes, looks at it, uses it, removes it again.
    private func widgetOnTheHomeScreen() async throws {
        step("x9. the widget on the Home Screen, small and medium, showing the titles the user asked for; its buttons and rows open the app")
        goHome()
        removeWidgets()
        addWidget(medium: false)
        addWidget(medium: true)
        springboard.buttons["Done"].firstMatch.tap()
        pause(2)
        let widgets = springboard.icons.matching(NSPredicate(format: "identifier == 'TwoNote' AND value == 'Widget'"))
        XCTAssertEqual(widgets.count, 2, "both sizes are on the Home Screen")
        dumpWidgets("titles on")
        require(springboard.staticTexts["Recent Pages"].firstMatch, "the list of recent pages in the medium widget", timeout: 20)
        for title in ["From a link", "Marsh Birds Weekly"] {
            XCTAssertTrue(springboard.descendants(matching: .any).matching(NSPredicate(format: "label == %@", title)).firstMatch.exists, "“\(title)” in the widget")
        }
        shot("45-widgets-recent-pages")

        // A button of the small widget: the app starts locked, and makes the page after the unlock.
        springboard.buttons["New Note"].firstMatch.tap()
        unlock()
        let title = app.textFields["page-title"]
        require(title, "the new page, from the widget's New Note")
        try await eventually("the new page's title has the focus") { self.hasKeyboardFocus(title) }
        title.typeText("From the widget\n")
        // A row of the medium widget: the page it names.
        goHome()
        springboard.descendants(matching: .any).matching(NSPredicate(format: "label == 'Marsh Birds Weekly'")).firstMatch.tap()
        unlock()
        try await eventually("the page named in the widget is open") { (self.app.textFields["page-title"].value as? String) == "Marsh Birds Weekly" }

        step("x10. the switch off again: the titles are gone from the device's shared container and from the widget")
        wide = app.buttons["new-page"].exists
        leaveEditor()
        goToNotebookList()
        openSettings()
        let widgetSwitch = app.switches["settings-widget-recent"].firstMatch
        reveal(widgetSwitch, "the widget switch")
        widgetSwitch.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        try await eventually("the switch is off") { (widgetSwitch.value as? String) == "0" }
        if let files = appGroupFiles() {
            XCTAssertEqual(files.map(\.name), ["share-inbox.pub"], "no title is left outside the store")
        }
        goHome()
        try await eventually("the widget shows no title any more", timeout: 30) {
            !self.springboard.staticTexts["Recent Pages"].firstMatch.exists
        }
        dumpWidgets("titles off")
        for title in ["From a link", "From the widget", "Marsh Birds Weekly", "Dawn note", "Monday at the hide"] {
            XCTAssertFalse(springboard.descendants(matching: .any).matching(NSPredicate(format: "label == %@", title)).firstMatch.exists, "“\(title)” is still in the widget")
        }
        require(springboard.buttons["Continue"].firstMatch, "Continue in the medium widget")
        shot("46-widgets")
        springboard.buttons["Search"].firstMatch.tap()
        unlock()
        let searchField = app.searchFields.firstMatch
        require(searchField, "the search field, from the widget's Search")
        try await eventually("the search field has the focus") { self.hasKeyboardFocus(searchField) }

        goHome()
        removeWidgets()
        XCTAssertEqual(widgets.count, 0, "the widgets are off the Home Screen again")
    }

    /// The Home Screen: the Home button does nothing in this simulator, ending the apps does.
    private func goHome() {
        app.terminate()
        safari.terminate()
        pause(2)
    }

    private func dumpWidgets(_ what: String) {
        let widgets = springboard.icons.matching(NSPredicate(format: "identifier == 'TwoNote' AND value == 'Widget'"))
        for index in 0..<widgets.count {
            let lines = widgets.element(boundBy: index).debugDescription.split(separator: "\n")
                .filter { $0.contains("label: '") && !$0.contains("→") }
                .compactMap { $0.split(separator: "label: '").last?.split(separator: "'").first }
            print("[e2e] widget \(index) (\(what)): \(lines.joined(separator: " | "))")
        }
    }

    /// Adds one TwoNote widget from SpringBoard's gallery; leaves the Home Screen in edit mode.
    private func addWidget(medium: Bool) {
        openWidgetGallery()
        let cell = springboard.cells["TwoNote"].firstMatch
        require(cell, "TwoNote in the widget gallery")
        cell.tap()
        let add = springboard.buttons.matching(NSPredicate(format: "label CONTAINS 'Add Widget'")).firstMatch
        require(add, "the gallery's page for TwoNote")
        let small = springboard.buttons.matching(NSPredicate(format: "value CONTAINS 'Small'")).firstMatch
        require(small, "the small widget's preview")
        if medium {
            small.swipeLeft()
            require(springboard.buttons.matching(NSPredicate(format: "value CONTAINS 'Medium'")).firstMatch, "the medium widget's preview")
            pause(1)
        }
        add.tap()
        XCTAssertTrue(add.waitForNonExistence(timeout: 10), "the gallery closes after Add Widget")
        pause(1)
    }

    /// Takes every TwoNote widget off the Home Screen.
    private func removeWidgets() {
        if springboard.buttons["Close"].firstMatch.exists {
            springboard.buttons["Close"].firstMatch.tap() // a gallery an earlier run left open
            pause(1)
        }
        if springboard.buttons["Done"].firstMatch.exists {
            springboard.buttons["Done"].firstMatch.tap()
            pause(1)
        }
        let widgets = springboard.icons.matching(NSPredicate(format: "identifier == 'TwoNote' AND value == 'Widget'"))
        for _ in 0..<4 where widgets.count > 0 {
            widgets.firstMatch.press(forDuration: 1.3)
            let remove = springboard.buttons["Remove Widget"].firstMatch
            require(remove, "Remove Widget in the widget's menu")
            remove.tap()
            if let confirm = systemPromptButton(["Remove"], timeout: 5) {
                confirm.tap()
            }
            pause(1.5)
        }
    }

    /// SpringBoard's widget gallery, from wherever the Home Screen is.
    private func openWidgetGallery() {
        if springboard.searchFields["Search Widgets"].firstMatch.exists { return }
        if !springboard.buttons["Edit"].firstMatch.exists {
            springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.72)).press(forDuration: 2.0)
        }
        require(springboard.buttons["Edit"].firstMatch, "the Home Screen's edit mode")
        springboard.buttons["Edit"].firstMatch.tap()
        require(springboard.buttons["Add Widget"].firstMatch, "Add Widget in the Edit menu")
        springboard.buttons["Add Widget"].firstMatch.tap()
        require(springboard.searchFields["Search Widgets"].firstMatch, "the widget gallery")
    }
}

import Foundation
import notify
import TwoNoteCore
import TwoNoteDocuments
import XCTest
import YrsKit

// The real app in the simulator against a REAL server container, with a second device (a
// headless `TwoNoteClient` inside this test process) on the same account.
//
// Skipped unless the environment names a fresh container (pass these to xcodebuild with the
// TEST_RUNNER_ prefix):
//   TWONOTE_E2E_URL       the server, e.g. http://127.0.0.1:18090 (no account on it yet)
//   TWONOTE_E2E_CONTROL   tools/e2e-control.py, e.g. http://127.0.0.1:18091 (optional: without
//                         it the offline part is skipped)
//   TWONOTE_SHOTS_DIR     folder on the Mac for screenshots of every screen, light and dark (optional)
//
// The run works in both layouts: the compact one (one navigation stack: the iPhone Duo's cover
// display) and the wide one (sidebar and page side by side: an iPad).

@MainActor
final class EndToEndTests: EndToEndCase {
    private static let newPassword = "four new unrelated words"

    // MARK: The run

    func testEverythingAgainstARealServer() async throws {
        guard let address = environment["TWONOTE_E2E_URL"], let url = URL(string: address) else {
            throw XCTSkip("TWONOTE_E2E_URL is not set")
        }
        setBiometricEnrolment(true)

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

        step("2. first run: set-up screen, a wrong password is explained, the right one signs in")
        app = XCUIApplication()
        app.launchArguments = ["-TwoNoteResetState"]
        app.launch()
        require(app.textFields["enrol-server"], "the set-up screen")
        shot("01-setup")
        type(address, into: app.textFields["enrol-server"])
        type(Self.username, into: app.textFields["enrol-username"])
        type("wrong", into: app.secureTextFields["enrol-password"])
        type(secretKey, into: app.textFields["enrol-secret-key"])
        app.buttons["enrol-submit"].tap()
        require(app.alerts["Incorrect Sign-In Details"], "the wrong-credentials alert")
        shot("02-setup-wrong-details")
        app.alerts.buttons["OK"].tap()
        type(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 5) + Self.password, into: app.secureTextFields["enrol-password"])
        app.buttons["enrol-submit"].tap()

        step("3. the password was just typed: biometric unlock is offered (declined for now); the other device's notebook arrives")
        let offer = app.alerts.firstMatch
        require(offer, "the offer to unlock with the sensor", timeout: 40)
        XCTAssertTrue(offer.label.hasPrefix("Unlock with "), offer.label)
        let sensor = String(offer.label.dropFirst("Unlock with ".count).dropLast())
        print("[e2e] this simulator's sensor: \(sensor)")
        shot("18-biometric-offer")
        offer.buttons["Not Now"].tap()
        require(app.staticTexts["Field Journal"], "the synced notebook", timeout: 40)
        syncStatus(contains: "Synced")
        shot("03-notebooks")

        step("4. create a notebook, a section and a page; type with formatting")
        app.buttons["new-notebook"].tap()
        require(app.alerts["New Notebook"], "the new-notebook alert")
        shot("04-new-notebook")
        name("Trip Notes", confirm: "Create")
        require(app.staticTexts["No Sections"], "the empty notebook")
        shot("05-sections-empty")
        app.buttons["new-section"].tap()
        name("Packing", confirm: "Create")
        require(app.staticTexts["No Pages"], "the empty section")
        app.buttons["new-page"].firstMatch.tap()
        let title = app.textFields["page-title"]
        require(title, "the new page")
        require(app.keyboards.firstMatch, "the keyboard (the title of a new page has the focus)")
        wide = app.buttons["new-page"].exists
        print("[e2e] layout: \(wide ? "wide (lists and page side by side)" : "compact (one stack)")")
        title.typeText("Checklist\n")
        let editor = app.textViews["page-editor"]
        editor.typeText("Plain start. ")
        app.buttons["Bold"].tap()
        editor.typeText("Bold words")
        app.buttons["Bold"].tap()
        editor.typeText("\n")
        chooseChecklist(shotOfMenu: "07b-editor-lists-menu")
        editor.typeText("Passport")
        shot("06-editor-keyboard")
        app.buttons["Paragraph Style"].tap()
        require(app.buttons["Heading"], "the paragraph style menu")
        shot("07-editor-style-menu")
        app.buttons["Heading"].tap()
        app.buttons["Paragraph Style"].tap()
        require(app.buttons["Heading"], "the paragraph style menu")
        app.buttons["Heading"].tap() // choosing the style a paragraph has turns it back into body text
        chooseChecklist()
        app.buttons["More Formatting"].tap()
        require(app.buttons["Inline Code"], "the More menu of the format bar")
        shot("07c-editor-more-menu")
        app.buttons["Inline Code"].tap()
        app.buttons["More Formatting"].tap()
        require(app.buttons["Inline Code"], "the More menu of the format bar")
        app.buttons["Inline Code"].tap()
        app.buttons["Hide Keyboard"].tap()
        XCTAssertEqual(editorText(), "Plain start. Bold words\nPassport\n")
        shot("08-editor")

        step("5. what was typed arrives at the other device, formatting included")
        var tripId = ""
        try await eventually("the other device has the new notebook") {
            tripId = peer.notebookIds.first { $0 != journal.notebookId } ?? ""
            return !tripId.isEmpty
        }
        let trip = try await peer.openNotebook(tripId)
        var checklistId = ""
        try await eventually("the other device has the notebook's content") {
            guard trip.title == "Trip Notes", let section = trip.sections().first, section.title == "Packing",
                  let page = trip.pages(inSection: section.id).first, page.title == "Checklist" else { return false }
            checklistId = page.id
            return true
        }
        let checklist = try await peer.openPage(notebookId: tripId, pageId: checklistId)
        try await eventually("the other device has the page text") {
            checklist.text == "Plain start. Bold words\nPassport\n" && checklist.runs.last?.attributes[PageAttribute.block] == .string("todo")
        }
        XCTAssertTrue(checklist.runs.contains(TextRun(text: "Bold words", attributes: [PageAttribute.bold: .bool(true)])), "\(checklist.runs)")
        XCTAssertEqual(checklist.runs.first, TextRun(text: "Plain start. "))

        step("6. the lists")
        leaveEditor()
        require(app.staticTexts["Checklist"].firstMatch, "the page in its section's list")
        shot("09-pages")
        goBack()
        require(app.staticTexts["Packing"].firstMatch, "the section in its notebook's list")
        shot("10-sections")
        app.staticTexts["Packing"].firstMatch.tap()
        app.staticTexts["Checklist"].firstMatch.tap()
        require(editor, "the page, reopened")

        step("7. kill the app, relaunch: locked; a wrong password is refused; unlock returns to the page")
        app.terminate()
        app.launchArguments = []
        app.launch()
        let passwordField = app.secureTextFields["unlock-password"]
        require(passwordField, "the unlock screen")
        XCTAssertFalse(editor.exists)
        XCTAssertFalse(app.buttons["unlock-biometrics"].exists, "biometric unlock was declined")
        shot("11-unlock")
        passwordField.typeText("not the password\n")
        require(app.staticTexts["unlock-error"], "the wrong-password message")
        shot("12-unlock-wrong")
        passwordField.typeText(Self.password + "\n")
        require(editor, "the page that was open before the relaunch")
        XCTAssertEqual(editorText(), "Plain start. Bold words\nPassport\n")
        XCTAssertEqual(app.textFields["page-title"].value as? String, "Checklist")
        XCTAssertFalse(app.alerts.firstMatch.exists, "the offer is made once")

        step("8. Settings: turn biometric unlock on (asks for the password); relaunch; a match unlocks")
        openSettings()
        shot("19-settings")
        let biometricSwitch = app.switches["settings-biometrics"].firstMatch
        reveal(biometricSwitch, "the biometric unlock switch")
        biometricSwitch.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap() // the switch itself, at the row's trailing edge
        let turnOn = app.alerts.firstMatch
        require(turnOn, "the password prompt for biometric unlock")
        shot("20-settings-biometrics-password")
        turnOn.secureTextFields.firstMatch.typeText(Self.password)
        turnOn.buttons["Turn On"].tap()
        try await eventually("the switch is on") { (biometricSwitch.value as? String) == "1" }
        shot("21-settings-biometrics-on")
        closeSettings()

        app.terminate()
        app.launch()
        require(app.buttons["unlock-biometrics"], "the unlock screen with the sensor's button")
        XCTAssertFalse(editor.exists)
        pause(2) // the prompt comes up by itself
        shot("22-unlock-biometric-prompt")
        touchSensor(match: true)
        require(editor, "the page, after a matching finger or face")
        XCTAssertEqual(app.textFields["page-title"].value as? String, "Checklist")

        step("9. lock; a finger that does not match does not unlock; the password still does")
        app.buttons["more-menu"].firstMatch.tap()
        app.buttons["Lock TwoNote"].tap()
        require(app.buttons["unlock-biometrics"], "the unlock screen after Lock")
        pause(2)
        touchSensor(match: false)
        pause(2)
        XCTAssertFalse(editor.exists, "a non-matching finger unlocked the app")
        shot("23-unlock-biometric-no-match")
        if let button = systemPromptButton(["Enter Password", "Cancel"]) {
            print("[e2e] leaving the sensor's prompt with “\(button.label)”")
            button.tap()
        } else {
            print("[e2e] the sensor's prompt has no button to leave it with; it went away by itself")
        }
        require(passwordField, "the password field")
        XCTAssertFalse(editor.exists)
        passwordField.tap()
        passwordField.typeText(Self.password + "\n")
        require(editor, "the page, after the password")

        step("10. the other device types into the open page and adds a page: both appear here")
        checklist.edit { $0.insert("Tickets", at: $0.length - 1, attributes: [:]) }
        let fromPeer = try await peer.createPage(notebookId: tripId, sectionId: trip.sections()[0].id, title: "From the desk")
        fromPeer.edit { $0.insert("Written on the other device.", at: 0, attributes: [:]) }
        try await eventually("the other device's typing shows in the open editor") { self.editorText().contains("PassportTickets") }
        leaveEditor()
        require(app.staticTexts["From the desk"].firstMatch, "the page created on the other device", timeout: 30)
        syncStatus(contains: "Synced")

        if environment["TWONOTE_E2E_CONTROL"] != nil {
            step("11. the server goes away: editing and creating carry on; offline is shown calmly, without counting keystrokes")
            try await control("stop")
            app.staticTexts["From the desk"].firstMatch.tap()
            require(editor, "the other device's page")
            editor.tap()
            editor.typeText("Typed offline. ")
            app.buttons["Hide Keyboard"].tap()
            syncStatus(contains: "Offline", timeout: 90)
            shot("13-editor-offline")
            leaveEditor()
            app.buttons["new-page"].firstMatch.tap()
            require(app.keyboards.firstMatch, "the keyboard")
            app.textFields["page-title"].typeText("Made offline\n")
            app.buttons["Hide Keyboard"].tap()
            leaveEditor()
            require(app.staticTexts["Made offline"].firstMatch, "the page created offline")
            syncStatus(contains: "Offline · Changes Waiting")
            shot("14-pages-offline")
            app.buttons.matching(identifier: "sync-status").firstMatch.tap()
            require(app.staticTexts["Username"], "Settings, from the sync status")
            require(app.staticTexts["Waiting to Sync"], "what is waiting")
            // The typed-in page has unsent text and the notebook has an unsent new page; whether the
            // new, still empty page counts as a page depends on whether it has content of its own.
            let pattern = ".*[12] Pages? and Notebook Changes.*"
            let waiting = app.descendants(matching: .any)
                .matching(NSPredicate(format: "label MATCHES %@ OR value MATCHES %@", pattern, pattern)).firstMatch
            if waiting.exists {
                print("[e2e] waiting to sync: \(waiting.label) \(waiting.value as? String ?? "")")
            } else {
                failureShot()
                let seen = app.staticTexts.allElementsBoundByIndex.map { "\($0.label)=\($0.value as? String ?? "")" }
                print("[e2e] texts in Settings: \(seen.joined(separator: " | "))")
                XCTFail("pages, not raw updates, are counted")
            }
            XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] 'update'")).firstMatch.exists)
            shot("15-settings-offline")
            reveal(app.buttons["settings-devices"].firstMatch, "the Devices row")
            app.buttons["settings-devices"].firstMatch.tap()
            require(app.staticTexts["Can’t Reach the Server"], "why the devices cannot be shown offline", timeout: 60)
            shot("16-devices-offline")
            goBack()
            closeSettings()

            // A notebook that is on the server cannot be deleted now, and the app says so before asking.
            goToNotebookList()
            app.staticTexts["Field Journal"].firstMatch.press(forDuration: 1.2)
            require(app.buttons["Delete"], "the notebook's context menu")
            app.buttons["Delete"].tap()
            require(app.alerts["Can’t Delete While Offline"], "the explanation")
            shot("17b-notebook-delete-offline")
            app.alerts.buttons["OK"].tap()
            app.staticTexts["Trip Notes"].firstMatch.tap()
            app.staticTexts["Packing"].firstMatch.tap()

            step("12. the server comes back: everything made offline arrives at the other device")
            try await control("start")
            try await eventually("the other device receives the offline edits", timeout: 240) {
                self.app.activate() // keeps the app in front
                return fromPeer.text.contains("Typed offline. ")
                    && trip.pages(inSection: trip.sections()[0].id).contains { $0.title == "Made offline" }
            }
            syncStatus(contains: "Synced", timeout: 120)
        }

        step("13. search finds text typed earlier, in a title, and on the other device; a result opens its page")
        let searchField = app.searchFields.firstMatch
        require(searchField, "the search field")
        searchField.tap()
        searchField.typeText("passport")
        let passportHit = app.buttons.containing(NSPredicate(format: "label CONTAINS[c] 'PassportTickets'")).firstMatch
        require(passportHit, "the page found by its text")
        XCTAssertTrue(passportHit.label.contains("Checklist"), passportHit.label)
        XCTAssertTrue(passportHit.label.contains("Trip Notes › Packing"), passportHit.label)
        shot("24-search-text")
        searchField.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 8) + "BOOMING call")
        let boomingHit = app.buttons.containing(NSPredicate(format: "label CONTAINS 'Monday at the hide'")).firstMatch
        require(boomingHit, "the other device's page found by its text, whatever the case")
        XCTAssertTrue(boomingHit.label.contains("Field Journal › Marsh"), boomingHit.label)
        searchField.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 12) + "wood")
        require(app.buttons.containing(NSPredicate(format: "label CONTAINS 'Woodland'")).firstMatch, "a section found by its title")
        shot("25-search-titles")
        searchField.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 4) + "zzzz")
        require(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'No Results'")).firstMatch, "the empty result")
        shot("26-search-nothing")
        searchField.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 4) + "thermos")
        let thermosHit = app.buttons.containing(NSPredicate(format: "label CONTAINS 'Monday at the hide'")).firstMatch
        require(thermosHit, "the page with the thermos")
        thermosHit.tap()
        require(editor, "the page of the search result")
        try await eventually("the result's page is open") { (self.app.textFields["page-title"].value as? String) == "Monday at the hide" }
        XCTAssertTrue(editorText().contains("Refill the thermos"))
        shot("27-search-result-opened")
        leaveEditor()
        require(app.staticTexts["Monday at the hide"].firstMatch, "the list of the section the result is in")
        XCTAssertFalse(app.buttons.containing(NSPredicate(format: "label CONTAINS 'Field Journal › Marsh'")).firstMatch.exists, "the search is over")

        step("14. type, send the app to the background at once, kill it: the edit is in the store, reaches the other device, and is there after a relaunch")
        app.staticTexts["Monday at the hide"].firstMatch.tap()
        require(editor, "the page")
        editor.tap()
        editor.typeText("Typed just before leaving. ")
        sendToBackground()
        pause(3)
        app.terminate()
        XCUIApplication(bundleIdentifier: "com.apple.Preferences").terminate()
        try await eventually("the edit made just before leaving reaches the other device", timeout: 60) {
            monday.text.contains("Typed just before leaving. ")
        }
        app.launch()
        require(app.buttons["unlock-biometrics"], "the unlock screen")
        pause(2)
        touchSensor(match: true)
        require(editor, "the page, after the relaunch")
        XCTAssertTrue(editorText().contains("Typed just before leaving. "), editorText())

        step("15. Settings: another device is listed and revoked")
        let laptopFolder = FileManager.default.temporaryDirectory.appendingPathComponent("twonote-laptop-\(UUID().uuidString)")
        let laptop = try await TwoNoteClient.open(
            ClientOptions(serverURL: url, databasePath: laptopFolder.appendingPathComponent("store.db").path, secretStore: InMemorySecretStore()))
        try await laptop.enrol(username: Self.username, password: Self.password, secretKey: secretKey, deviceName: "Old Laptop")
        try await laptop.sync.syncNow()
        openSettings()
        reveal(app.buttons["settings-devices"].firstMatch, "the Devices row")
        app.buttons["settings-devices"].firstMatch.tap()
        let laptopRow = app.staticTexts["Old Laptop"]
        require(laptopRow, "the other device in the list", timeout: 30)
        XCTAssertTrue(app.staticTexts["Desk PC"].exists)
        XCTAssertTrue(app.staticTexts["This Device"].exists)
        shot("28-devices")
        laptopRow.swipeLeft()
        require(app.buttons["Revoke"], "the Revoke action")
        app.buttons["Revoke"].tap()
        require(app.buttons["Revoke Device"], "the confirmation")
        shot("29-devices-revoke")
        app.buttons["Revoke Device"].tap()
        XCTAssertTrue(laptopRow.waitForNonExistence(timeout: 20), "the revoked device is still listed")
        XCTAssertTrue(app.staticTexts["Desk PC"].exists)
        do {
            try await laptop.sync.syncNow()
            XCTFail("the revoked device still syncs")
        } catch let error as ApiError {
            XCTAssertEqual(error.status, 401)
        }
        await laptop.close()
        goBack()

        step("16. Settings: the Secret Key is shown after the sensor matches")
        reveal(app.buttons["settings-secret-key"].firstMatch, "the Secret Key row")
        app.buttons["settings-secret-key"].firstMatch.tap()
        require(app.buttons["secret-key-show"], "the Secret Key screen")
        XCTAssertFalse(app.staticTexts[secretKey].exists)
        shot("30-secret-key-hidden")
        app.buttons["secret-key-show"].tap()
        pause(2)
        touchSensor(match: true)
        require(app.staticTexts[secretKey], "the Secret Key, after the sensor matched")
        shot("31-secret-key-shown")
        goBack()

        step("17. Settings: change the password; the other device signs in again with it and still syncs both ways")
        reveal(app.buttons["settings-change-password"].firstMatch, "the Change Password row")
        app.buttons["settings-change-password"].firstMatch.tap()
        type(Self.password, into: app.secureTextFields["password-current"])
        type("short", into: app.secureTextFields["password-new"])
        require(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'at least 8'")).firstMatch, "what is wrong with the new password")
        shot("32-change-password-too-short")
        app.secureTextFields["password-new"].typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 5) + Self.newPassword)
        type(Self.newPassword, into: app.secureTextFields["password-verify"])
        shot("33-change-password")
        reveal(app.buttons["password-submit"].firstMatch, "the Change Password button")
        app.buttons["password-submit"].firstMatch.tap()
        require(app.alerts["Password Changed"], "the confirmation", timeout: 30)
        shot("34-password-changed")
        app.alerts.buttons["OK"].tap()
        pause(1.5) // Settings slides back in; a tap during that goes nowhere
        reveal(app.buttons["settings-autolock"].firstMatch, "the Auto-Lock row")
        let autoLock = app.buttons["settings-autolock"].firstMatch
        // After `reveal` the row can be under the bar at the top (a tap there scrolls the list
        // to its top instead) or in the strip along the bottom edge, where a tap goes nowhere.
        // Bring it in: slowly, and held at the end, so that nothing coasts on.
        let rowTop = autoLock.frame.minY
        if rowTop < 110 || rowTop > app.frame.height - 110 {
            let (from, to) = rowTop < 110 ? (0.4, 0.65) : (0.55, 0.35)
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: from))
                .press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: to)),
                       withVelocity: .slow, thenHoldForDuration: 0.5)
            pause(0.5)
        }
        autoLock.tap()
        require(app.buttons["Immediately"], "the auto-lock times")
        shot("35-settings-autolock")
        app.buttons["After 1 Minute"].tap()
        closeSettings()

        try await eventually("the other device is told to sign in again", timeout: 90) {
            peer.sync.requestSync()
            return peer.sync.status.state == .authRequired
        }
        try await peer.signInAgain(password: Self.newPassword)
        monday.edit { $0.insert("After the password change. ", at: 0, attributes: [:]) }
        try await eventually("the other device's edit arrives here after the password change", timeout: 60) {
            self.editorText().contains("After the password change. ")
        }
        editor.tap()
        editor.typeText("And back. ")
        app.buttons["Hide Keyboard"].tap()
        try await eventually("this device's edit arrives there after the password change", timeout: 60) { monday.text.contains("And back. ") }

        step("18. lock: the sensor still unlocks (its key was renewed); the old password is refused, the new one unlocks")
        app.buttons["more-menu"].firstMatch.tap()
        app.buttons["Lock TwoNote"].tap()
        require(app.buttons["unlock-biometrics"], "the unlock screen")
        XCTAssertFalse(app.staticTexts["Field Journal"].exists)
        XCTAssertFalse(editor.exists)
        pause(2)
        touchSensor(match: true)
        require(editor, "the page, unlocked by the sensor after the password change")
        app.buttons["more-menu"].firstMatch.tap()
        app.buttons["Lock TwoNote"].tap()
        require(app.buttons["unlock-biometrics"], "the unlock screen")
        pause(2)
        if let button = systemPromptButton(["Enter Password", "Cancel"], timeout: 5) {
            button.tap()
        }
        passwordField.tap()
        passwordField.typeText(Self.password + "\n")
        require(app.staticTexts["unlock-error"], "the old password is refused")
        passwordField.typeText(Self.newPassword + "\n")
        require(editor, "the page, unlocked with the new password")

        step("19. auto-lock: still unlocked after 20 seconds in the background, locked after more than a minute")
        sendToBackground()
        pause(20)
        app.activate()
        require(editor, "still unlocked after 20 seconds away")
        sendToBackground()
        pause(65)
        app.activate()
        XCUIApplication(bundleIdentifier: "com.apple.Preferences").terminate()
        require(app.buttons["unlock-biometrics"], "locked after more than a minute away")
        XCTAssertFalse(editor.exists)
        pause(2)
        touchSensor(match: true)
        require(editor, "the page")

        step("20. More menu, then Lock: back to the unlock screen with nothing of the notes left on screen")
        leaveEditor()
        goToNotebookList()
        require(app.staticTexts["Field Journal"].firstMatch, "the notebook list")
        app.buttons["more-menu"].firstMatch.tap()
        require(app.buttons["Lock TwoNote"], "the menu")
        shot("17-more-menu")
        app.buttons["Lock TwoNote"].tap()
        require(app.secureTextFields["unlock-password"], "the unlock screen after Lock")
        XCTAssertFalse(app.staticTexts["Field Journal"].exists)
        XCTAssertFalse(editor.exists)
        if let button = systemPromptButton(["Cancel", "Enter Password"], timeout: 5) {
            button.tap()
        }

        await peer.close()
    }
}

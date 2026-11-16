import Foundation
import notify
import XCTest

// What the end-to-end runs share: the app under test, waiting, screenshots, getting around the
// lists, Settings, the background, and the simulator's biometric sensor.

@MainActor
class EndToEndCase: XCTestCase {
    static let username = "bob"
    static let password = "correct horse battery staple"

    let environment = ProcessInfo.processInfo.environment
    var app: XCUIApplication!
    /// True when the lists and the page are side by side (found out when the first page opens).
    var wide = false

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
        XCTFail("Timed out waiting for: \(what)")
        throw CancellationError()
    }

    func failureShot() {
        if let folder = environment["TWONOTE_SHOTS_DIR"], !folder.isEmpty {
            try? XCUIScreen.main.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: folder).appendingPathComponent("_failure.png"))
        }
    }

    func require(_ element: XCUIElement, _ what: String, timeout: TimeInterval = 15) {
        if !element.waitForExistence(timeout: timeout) {
            failureShot()
            XCTFail("\(what) did not appear")
        }
    }

    /// Saves the screen as <name>-light.png and <name>-dark.png.
    func shot(_ name: String) {
        guard let folder = environment["TWONOTE_SHOTS_DIR"], !folder.isEmpty else { return }
        for (appearance, suffix) in [(XCUIDevice.Appearance.light, "light"), (.dark, "dark")] {
            XCUIDevice.shared.appearance = appearance
            Thread.sleep(forTimeInterval: 1.2)
            let url = URL(fileURLWithPath: folder).appendingPathComponent("\(name)-\(suffix).png")
            try? XCUIScreen.main.screenshot().pngRepresentation.write(to: url)
        }
        XCUIDevice.shared.appearance = .light
        Thread.sleep(forTimeInterval: 0.6)
    }

    func type(_ text: String, into element: XCUIElement) {
        require(element, "\(element)")
        element.tap()
        element.typeText(text)
    }

    /// The back button of the lists. On the iPhone Duo's cover display the navigation bar is a
    /// strip down the side of the screen, so it is looked for as a button anywhere, not inside a bar.
    func goBack() {
        // The frontmost one: a sheet's back button comes after those of the lists under it.
        for query in [app.buttons.matching(identifier: "BackButton"), app.buttons.matching(identifier: "Back"), app.navigationBars.buttons] {
            if let candidate = query.allElementsBoundByIndex.last(where: { $0.exists && $0.isHittable }) {
                candidate.tap()
                return
            }
        }
        let buttons = app.buttons.allElementsBoundByIndex.map { "\($0.identifier)|\($0.label)" }
        print("[e2e] no back button among: \(buttons)")
        failureShot()
        XCTFail("no back button")
    }

    /// From the open page to the list it is in. In the wide layout the list is already there.
    func leaveEditor() {
        if !wide {
            goBack()
        }
    }

    /// Up the lists until the notebook list is showing.
    func goToNotebookList() {
        for _ in 0..<4 where !app.buttons["new-notebook"].exists {
            goBack()
            _ = app.buttons["new-notebook"].waitForExistence(timeout: 2)
        }
        require(app.buttons["new-notebook"], "the notebook list")
    }

    func name(_ text: String, confirm: String) {
        let field = app.alerts.textFields.firstMatch
        require(field, "the name alert")
        field.typeText(text)
        app.alerts.buttons[confirm].tap()
    }

    func syncStatus(contains text: String, timeout: TimeInterval = 30) {
        let match = app.buttons.matching(identifier: "sync-status")
            .matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
        require(match, "sync status “\(text)”", timeout: timeout)
    }

    func editorText() -> String {
        app.textViews["page-editor"].value as? String ?? ""
    }

    func control(_ action: String) async throws {
        let base = try XCTUnwrap(environment["TWONOTE_E2E_CONTROL"])
        let (_, response) = try await URLSession.shared.data(from: try XCTUnwrap(URL(string: base + "/" + action)))
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200, "docker \(action) failed")
    }

    func openSettings() {
        app.buttons["more-menu"].firstMatch.tap()
        require(app.buttons["Settings"], "the More menu")
        app.buttons["Settings"].tap()
        require(app.staticTexts["Username"], "Settings")
    }

    func closeSettings() {
        app.buttons["Done"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Username"].waitForNonExistence(timeout: 10), "Settings did not close")
    }

    /// Scrolls the settings list until the element can be tapped.
    func leftTheForeground(within seconds: TimeInterval) -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if app.state == .runningBackground || app.state == .runningBackgroundSuspended { return true }
            pause(0.2)
        }
        return false
    }

    /// Really in the background (the scene's didEnterBackground runs), not just covered.
    func sendToBackground() {
        XCUIDevice.shared.press(.home)
        var how = "the Home button"
        if !leftTheForeground(within: 8) {
            // Pressing Home does nothing in this simulator: put another app in front instead.
            how = "the Settings app opened in front of it"
            XCUIApplication(bundleIdentifier: "com.apple.Preferences").launch()
        }
        XCTAssertTrue(leftTheForeground(within: 10), "the app did not go to the background (state \(app.state.rawValue))")
        print("[e2e] in the background by \(how); state \(app.state.rawValue) (3 = background, 2 = suspended)")
    }

    func reveal(_ element: XCUIElement, _ what: String) {
        for _ in 0..<4 where !(element.exists && element.isHittable) {
            app.swipeUp()
        }
        for _ in 0..<6 where !(element.exists && element.isHittable) {
            app.swipeDown()
        }
        require(element, what)
    }

    /// A list or tick-box paragraph: one tap where the bar has room, the Lists menu otherwise.
    func chooseChecklist(shotOfMenu: String? = nil) {
        if app.buttons["Lists"].exists {
            app.buttons["Lists"].tap()
            require(app.buttons["Numbered List"], "the Lists menu")
            if let shotOfMenu { shot(shotOfMenu) }
        }
        let items = app.buttons.matching(identifier: "Checklist")
        items.element(boundBy: items.count - 1).tap()
    }

    /// Waits, blocking: for things that have no state to wait on (a system prompt coming up).
    func pause(_ seconds: TimeInterval) {
        Thread.sleep(forTimeInterval: seconds)
    }

    // MARK: The simulator's biometric sensor
    //
    // The same Darwin notifications the Simulator's Features > Touch ID / Face ID menu (and
    // `xcrun simctl spawn <device> notifyutil`) post. This process runs inside the simulator.

    func setBiometricEnrolment(_ enrolled: Bool) {
        var token: Int32 = 0
        notify_register_check("com.apple.BiometricKit.enrollmentChanged", &token)
        notify_set_state(token, enrolled ? 1 : 0)
        notify_post("com.apple.BiometricKit.enrollmentChanged")
        notify_cancel(token)
    }

    func touchSensor(match: Bool) {
        let outcome = match ? "match" : "nomatch"
        notify_post("com.apple.BiometricKit_Sim.fingerTouch.\(outcome)")
        notify_post("com.apple.BiometricKit_Sim.pearl.\(outcome)")
    }

    /// A button of the system's biometric prompt, which belongs to another process.
    func systemPromptButton(_ labels: [String], timeout: TimeInterval = 10) -> XCUIElement? {
        let hosts = ["com.apple.springboard", "com.apple.CoreAuthUI", "com.apple.LocalAuthenticationUIService"].map(XCUIApplication.init(bundleIdentifier:))
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            for host in hosts + [app!] {
                for label in labels {
                    let button = host.buttons[label].firstMatch
                    if button.exists { return button }
                }
            }
            Thread.sleep(forTimeInterval: 0.3)
        } while Date() < deadline
        return nil
    }
}

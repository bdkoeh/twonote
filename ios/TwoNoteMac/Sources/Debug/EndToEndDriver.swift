#if DEBUG
import AppKit
import Foundation
import SwiftUI
import TwoNoteCore
import TwoNoteDocuments
import Vision
import YrsKit

/// The end-to-end run, driven from inside the real app (DEBUG builds only).
///
/// XCUITest would drive the app from outside, through the accessibility system; on this Mac
/// that needs "automation mode", which macOS only enables after an administrator confirms it
/// on screen. So the run is driven from within: the real, signed, sandboxed app with its real
/// Keychain and store, against a real server container, with a second device (a headless
/// `TwoNoteClient`) in the same process. Keys and shortcuts are real key events sent through
/// `NSApplication.sendEvent` (so menus' key equivalents and the text views' input handling
/// run as for a person typing), menu commands are the menu bar's own items, and the window
/// is checked by drawing it into an image and reading it with the system's text recognition.
/// Moving around the lists selects rows in the lists' own table views.
///
/// Started by `tools/e2e-mac.sh`:
///   TwoNote.app --args -TwoNoteResetState -TwoNoteE2E http://127.0.0.1:18190 -TwoNoteE2EControl http://127.0.0.1:18191
/// Progress, screenshots and the result go to the control helper (e2e-mac-control.py) over
/// the loopback network, because the sandbox lets the app write nowhere else.
@MainActor
final class EndToEndDriver {
    static let username = "bob"
    static let password = "correct horse battery staple"

    let app: AppModel
    let delegate: AppDelegate
    let server: URL
    let control: URL
    private var failures: [String] = []

    struct Failure: Error, CustomStringConvertible {
        var description: String
    }

    init(app: AppModel, delegate: AppDelegate, server: URL, control: URL) {
        self.app = app
        self.delegate = delegate
        self.server = server
        self.control = control
    }

    /// Which run this launch is: the full run, or one of the two launches of the Keychain
    /// migration run (`-TwoNoteE2EMode legacy-enrol` / `migrate-check`).
    enum Mode: String {
        case full
        /// Behaves as a stage M1 build (login keychain only) and signs in; leaves everything in place.
        case legacyEnrol = "legacy-enrol"
        /// A normal launch after that: the migration must have moved the secrets and kept the account.
        case migrateCheck = "migrate-check"
    }

    static var mode: Mode {
        let arguments = ProcessInfo.processInfo.arguments
        guard let i = arguments.firstIndex(of: "-TwoNoteE2EMode"), i + 1 < arguments.count else { return .full }
        return Mode(rawValue: arguments[i + 1]) ?? .full
    }

    /// The arguments, if this launch is an end-to-end run.
    static func arguments() -> (server: URL, control: URL)? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let i = arguments.firstIndex(of: "-TwoNoteE2E"), i + 1 < arguments.count, let server = URL(string: arguments[i + 1]),
              let j = arguments.firstIndex(of: "-TwoNoteE2EControl"), j + 1 < arguments.count, let control = URL(string: arguments[j + 1])
        else { return nil }
        return (server, control)
    }

    func start() {
        Task {
            do {
                switch Self.mode {
                case .full: try await run()
                case .legacyEnrol: try await legacyEnrol()
                case .migrateCheck: try await migrateCheck()
                }
            } catch {
                failures.append("stopped: \(error)")
                await shot("_failure")
            }
            let result = failures.isEmpty ? "passed" : "failed: " + failures.joined(separator: " | ")
            await log("RESULT \(result)")
            await post("result", Data(result.utf8))
            if app.phase == .unlocked { await app.lock() }
            if Self.mode != .legacyEnrol || !failures.isEmpty {
                AppModel.wipe(app.environment)
            }
            NSApp.terminate(nil)
            // Should quitting still wait on something, the run is over all the same.
            try? await Task.sleep(for: .seconds(5))
            exit(failures.isEmpty ? 0 : 1)
        }
    }

    // MARK: Talking to the helper

    func log(_ text: String) async {
        print("[e2e] \(text)")
        await post("log", Data(text.utf8))
    }

    private func post(_ path: String, _ body: Data) async {
        var request = URLRequest(url: control.appending(path: path))
        request.httpMethod = "POST"
        request.httpBody = body
        request.timeoutInterval = 20
        _ = try? await URLSession.shared.data(for: request)
    }

    func docker(_ action: String) async throws {
        let (_, response) = try await URLSession.shared.data(from: control.appending(path: action))
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw Failure(description: "docker \(action) failed") }
    }

    func check(_ condition: Bool, _ what: String) async {
        if !condition {
            failures.append(what)
            await log("FAILED: \(what)")
        }
    }

    func eventually(_ what: String, timeout: TimeInterval = 30, _ condition: () async throws -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            delegate.autoLock?.noteActivity()
            if try await condition() { return }
            try await Task.sleep(for: .milliseconds(200))
        }
        await shot("_failure")
        let windows = NSApp.windows.map { "\($0.identifier?.rawValue ?? "-")|\($0.title)|\($0.isVisible ? "visible" : "hidden")" }
        await log("state: phase \(app.phase), windows \(windows), key \(NSApp.keyWindow?.identifier?.rawValue ?? "none"), first responder \(String(describing: NSApp.keyWindow?.firstResponder))")
        let fields = views(NSTextField.self, in: window?.contentView).filter(\.isEditable).map {
            "\(Swift.type(of: $0))|id=\($0.accessibilityIdentifier())|ph=\($0.placeholderString ?? "")|label=\($0.accessibilityLabel() ?? "")"
        }
        await log("fields: \(fields)")
        throw Failure(description: "timed out waiting for: \(what)")
    }

    // MARK: The window

    var window: NSWindow? {
        NSApp.windows.first { $0.identifier?.rawValue.hasPrefix("main") == true && $0.isVisible }
            ?? NSApp.windows.first { $0.isVisible && $0.contentView is NSHostingView<AnyView> }
            ?? NSApp.mainWindow
    }

    var settingsWindow: NSWindow? {
        NSApp.windows.first { $0.isVisible && $0 !== window && $0.identifier?.rawValue.contains("Settings") == true }
            ?? NSApp.windows.first { $0.isVisible && $0 !== window && $0.title != "" && $0.title != "TwoNote" && $0.level == .normal && !($0 is NSPanel) }
    }

    func front() {
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
        window?.makeMain()
        delegate.autoLock?.noteActivity()
    }

    func pump(_ seconds: TimeInterval = 0.15) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

    /// The window drawn into an image, title bar and toolbar included.
    func image(of window: NSWindow) -> CGImage? {
        guard let frameView = window.contentView?.superview ?? window.contentView else { return nil }
        frameView.layoutSubtreeIfNeeded()
        guard let rep = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds) else { return nil }
        frameView.cacheDisplay(in: frameView.bounds, to: rep)
        return rep.cgImage
    }

    /// The words that can be read in the window.
    func readWindow(_ target: NSWindow? = nil) -> String {
        guard let target = target ?? window, let image = image(of: target) else { return "" }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        try? VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
    }

    /// Saves the window (and any sheet on it) as <name>-light.png and <name>-dark.png.
    func shot(_ name: String, of target: NSWindow? = nil) async {
        guard let target = target ?? window else { return }
        for appearance in ["light", "dark"] {
            NSApp.appearance = NSAppearance(named: appearance == "dark" ? .darkAqua : .aqua)
            await pump(0.6)
            var images: [CGImage] = []
            if let image = image(of: target) { images.append(image) }
            for sheet in target.sheets {
                if let image = image(of: sheet) { images.append(image) }
            }
            guard let composed = Self.compose(images, sheetOn: target) else { continue }
            let rep = NSBitmapImageRep(cgImage: composed)
            if let png = rep.representation(using: .png, properties: [:]) {
                await post("shot/\(name)-\(appearance).png", png)
            }
        }
        NSApp.appearance = nil
        await pump(0.3)
    }

    /// The window with its sheets drawn over it where they hang (centred under the title bar).
    static func compose(_ images: [CGImage], sheetOn window: NSWindow) -> CGImage? {
        guard let base = images.first else { return nil }
        guard images.count > 1 else { return base }
        let width = base.width, height = base.height
        let scale = CGFloat(width) / window.frame.width
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return base }
        context.draw(base, in: CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(gray: 0, alpha: 0.12))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        for (sheet, image) in zip(window.sheets, images.dropFirst()) {
            let frame = sheet.frame
            let x = (frame.minX - window.frame.minX) * scale
            let y = (frame.minY - window.frame.minY) * scale
            context.setShadow(offset: CGSize(width: 0, height: -6), blur: 24, color: CGColor(gray: 0, alpha: 0.35))
            context.draw(image, in: CGRect(x: x, y: y, width: CGFloat(image.width), height: CGFloat(image.height)))
        }
        return context.makeImage()
    }

    // MARK: Keys and menus

    private func send(_ characters: String, ignoring: String? = nil, keyCode: UInt16, modifiers: NSEvent.ModifierFlags = []) {
        // The window that would have the keyboard: a sheet over the main window, else the
        // frontmost of the app's windows. The app may not be the active app (this Mac's user
        // may be working in another one), so the events go to that window directly instead of
        // through the active app's key window - the same path NSApplication.sendEvent takes:
        // first the menus' key equivalents, then the window and its first responder.
        guard let target = NSApp.keyWindow ?? frontWindow else { return }
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard let event = NSEvent.keyEvent(
                with: type, location: .zero, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: target.windowNumber, context: nil, characters: characters,
                charactersIgnoringModifiers: ignoring ?? characters, isARepeat: false, keyCode: keyCode) else { continue }
            refreshMenus()
            if NSApp.isActive, NSApp.keyWindow === target {
                // The app has the keyboard: the event goes into the app's queue and takes the
                // system's own path from there (event monitors, menus, the first responder).
                NSApp.postEvent(event, atStart: false)
                continue
            }
            // What the app's event monitor does for an event from the queue.
            if type == .keyDown, delegate.route(event) { continue }
            let special = characters.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7f || (0xF700...0xF8FF).contains($0.value) }
            if type == .keyDown, special || !modifiers.intersection([.command, .control]).isEmpty {
                if target.performKeyEquivalent(with: event) { continue }
                if NSApp.mainMenu?.performKeyEquivalent(with: event) == true { continue }
            }
            target.sendEvent(event)
        }
        delegate.autoLock?.noteActivity()
    }

    /// Types text the way the keyboard does (Return as the Return key).
    func type(_ text: String) async {
        for character in text {
            switch character {
            case "\n": send("\r", keyCode: 36)
            case "\t": send("\t", keyCode: 48)
            default: send(String(character), keyCode: 0)
            }
            await pump(0.01)
        }
        await pump()
    }

    enum Key {
        case escape, delete, downArrow, tab
    }

    func press(_ key: Key, _ modifiers: NSEvent.ModifierFlags = []) async {
        switch key {
        case .escape: send("\u{1b}", keyCode: 53, modifiers: modifiers)
        case .delete: send("\u{7f}", keyCode: 51, modifiers: modifiers)
        case .tab: send(modifiers.contains(.shift) ? "\u{19}" : "\t", ignoring: "\t", keyCode: 48, modifiers: modifiers)
        case .downArrow:
            let arrow = String(UnicodeScalar(UInt16(NSDownArrowFunctionKey))!)
            send(arrow, keyCode: 125, modifiers: modifiers.union([.numericPad, .function]))
        }
        await pump()
    }

    /// A shortcut, e.g. ⌘B: the key event goes through the menus' key equivalents.
    func shortcut(_ key: String, _ modifiers: NSEvent.ModifierFlags) async {
        let codes: [String: UInt16] = ["a": 0, "b": 11, "f": 3, "k": 40, "l": 37, "n": 45, ",": 43, "w": 13, "1": 18, "2": 19]
        // With Shift held the keyboard reports the shifted character, as for ⇧⌘L.
        let shifted = modifiers.contains(.shift) ? key.uppercased() : key
        send(shifted, ignoring: shifted, keyCode: codes[key] ?? 0, modifiers: modifiers)
        await pump(0.3)
    }

    /// Brings every menu's items up to date the way opening each would (SwiftUI fills them in
    /// from its delegate), so that their key equivalents match what the menus would show.
    func refreshMenus(_ menu: NSMenu? = NSApp.mainMenu) {
        guard let menu else { return }
        menu.delegate?.menuNeedsUpdate?(menu)
        menu.update()
        for item in menu.items { refreshMenus(item.submenu) }
    }

    /// The menu bar's item, by menu and title.
    func menuItem(_ path: [String]) -> NSMenuItem? {
        var menu: NSMenu? = NSApp.mainMenu
        var item: NSMenuItem?
        for title in path {
            // What opening the menu does: its delegate (SwiftUI) brings the items up to date.
            if let menu { menu.delegate?.menuNeedsUpdate?(menu) }
            menu?.update()
            item = menu?.items.first { $0.title == title }
            menu = item?.submenu
        }
        return item
    }

    /// Chooses a menu command the way a click on it does.
    func choose(_ path: String...) async throws {
        guard let item = menuItem(path), let menu = item.menu else { throw Failure(description: "no menu item \(path)") }
        menu.update()
        guard item.isEnabled else { throw Failure(description: "menu item \(path) is disabled") }
        menu.performActionForItem(at: menu.index(of: item))
        await pump(0.4)
    }

    // MARK: Lists

    func views<T: NSView>(_ type: T.Type, in root: NSView?) -> [T] {
        guard let root else { return [] }
        var found: [T] = []
        func walk(_ view: NSView) {
            if let match = view as? T { found.append(match) }
            view.subviews.forEach(walk)
        }
        walk(root)
        return found
    }

    /// SwiftUI's lists, left to right: the sidebar's, then the page list's (both may be outline
    /// views underneath).
    var lists: [NSTableView] {
        views(NSTableView.self, in: window?.contentView)
            .filter { $0.window != nil && !$0.isHiddenOrHasHiddenAncestor }
            .sorted { $0.convert($0.bounds, to: nil).minX < $1.convert($1.bounds, to: nil).minX }
    }
    var sidebar: NSTableView? { lists.first }
    var pageTable: NSTableView? { lists.count > 1 ? lists[1] : nil }
    var textView: NSTextView? {
        views(NSTextView.self, in: window?.contentView).first { $0.accessibilityIdentifier() == "page-editor" }
    }
    var titleField: NSTextField? {
        views(NSTextField.self, in: window?.contentView).first { $0.accessibilityIdentifier() == "page-title" }
    }

    /// A text field of the window (or of its sheet), by accessibility identifier.
    func field(_ identifier: String) -> NSTextField? {
        let roots = (window?.sheets.map(\.contentView) ?? []) + [window?.contentView]
        for root in roots {
            if let match = views(NSTextField.self, in: root).first(where: { $0.accessibilityIdentifier() == identifier }) {
                return match
            }
        }
        // SwiftUI's fields carry their identifier in the accessibility tree only, not on the
        // view; they are found by their place in the form instead.
        let order = ["enrol-server", "enrol-username", "enrol-password", "enrol-secret-key", "enrol-device-name"]
        let editable = { (root: NSView?) in self.views(NSTextField.self, in: root).filter { $0.isEditable } }
        if let index = order.firstIndex(of: identifier) {
            let fields = editable(window?.contentView)
            return index < fields.count ? fields[index] : nil
        }
        if ["name-field", "link-field"].contains(identifier) {
            return window?.sheets.lazy.compactMap { editable($0.contentView).first }.first
        }
        if identifier == "unlock-password" {
            return editable(window?.contentView).first { $0 is NSSecureTextField } ?? editable(window?.contentView).first
        }
        return nil
    }

    /// The app's window that is in front: a sheet, the Settings window, or the main window.
    var frontWindow: NSWindow? {
        if let sheet = window?.attachedSheet { return sheet }
        let visible = NSApp.orderedWindows.filter { $0.isVisible && !($0 is NSPanel) }
        return visible.first ?? window
    }

    /// Puts the keyboard in a field, as a click into it does.
    func focus(_ identifier: String) async throws {
        try await eventually("the field \(identifier)") { field(identifier) != nil }
        if let field = field(identifier) {
            field.window?.makeFirstResponder(field)
        }
        await pump(0.2)
    }

    /// Fills a secure field. macOS keeps synthesized keyboard input out of a secure field
    /// while the app is not the active one (secure keyboard entry), and this Mac's desktop may
    /// belong to another app; so the field gets its text the way its field editor would hand it
    /// over (value, then the delegate's text-did-change), which is what SwiftUI's binding hears.
    func fillSecure(_ identifier: String, _ text: String, submit: Bool = false) async throws {
        try await focus(identifier)
        guard let field = field(identifier) else { throw Failure(description: "no field \(identifier)") }
        await type(text)
        await pump(0.2)
        if (field.currentEditor() as? NSTextView)?.textStorage?.length != text.count {
            field.stringValue = text
            if let editor = field.currentEditor() {
                editor.string = text
                field.textDidChange(Notification(name: NSText.didChangeNotification, object: editor))
            } else {
                field.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: field))
            }
        }
        await pump(0.2)
        if submit {
            // Return, as the field editor turns it into a command for the field's delegate.
            (field.currentEditor() as? NSTextView)?.doCommand(by: #selector(NSResponder.insertNewline(_:)))
            await pump(0.2)
        }
    }

    /// Presses a button of the window's sheet (an alert) by its title, as a click does.
    func click(_ title: String) async throws {
        try await eventually("the button \(title)") {
            (window?.sheets ?? []).contains { sheet in views(NSButton.self, in: sheet.contentView).contains { $0.title == title } }
        }
        for sheet in window?.sheets ?? [] {
            if let button = views(NSButton.self, in: sheet.contentView).first(where: { $0.title == title }) {
                button.performClick(nil)
                break
            }
        }
        await pump(0.4)
    }

    /// Selects a list row as a click does, and gives the list the keyboard.
    func select(row: Int, in table: NSTableView) async {
        window?.makeFirstResponder(table)
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        await pump(0.4)
    }

    /// The row of the sidebar whose text is `title`.
    func sidebarRow(_ title: String) -> Int? {
        // The rows are SwiftUI's (no text fields, no labels on the views), in the model's order:
        // each notebook's header, then its sections while it is expanded.
        guard let sidebar, let library else { return nil }
        let collapsed = Set((UserDefaults.standard.string(forKey: "sidebar.collapsedNotebooks") ?? "").split(separator: ",").map(String.init))
        var rows: [String] = []
        for notebook in library.notebooks {
            rows.append(notebook.displayTitle)
            if !collapsed.contains(notebook.id) {
                rows += notebook.sections.map { SectionTitle(id: $0.id, title: $0.title).displayTitle }
            }
        }
        guard rows.count == sidebar.numberOfRows else { return nil }
        return rows.firstIndex(of: title)
    }

    var library: LibraryModel? { app.library }
    var editorText: String { textView?.string ?? "" }

    // MARK: The run

    func run() async throws {
        await log("1. the other device registers the account and writes a notebook (windows: \(NSApp.windows.count))")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("twonote-peer-\(UUID().uuidString)")
        var options = ClientOptions(serverURL: server, databasePath: folder.appendingPathComponent("store.db").path, secretStore: InMemorySecretStore())
        options.maxOfflineRetryDelay = .seconds(2)
        let peer = try await TwoNoteClient.open(options)
        defer { try? FileManager.default.removeItem(at: folder) }
        let status = try await peer.api.status()
        await check(status.registrationOpen, "the container already has an account")
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

        await log("2. first run: the set-up window; a wrong password is explained, the right one signs in (windows: \(NSApp.windows.count))")
        try await eventually("the set-up screen") { app.phase == .setUp && window != nil }
        front()
        await pump(1)
        await check(window?.title == "TwoNote", "the set-up window is called TwoNote (it is “\(window?.title ?? "")”)")
        await shot("01-setup")
        try await focus("enrol-server")
        await type(server.absoluteString)
        try await focus("enrol-username")
        await type(Self.username)
        try await fillSecure("enrol-password", "wrong")
        try await focus("enrol-secret-key")
        await type(secretKey)
        try await focus("enrol-device-name")
        await shortcut("a", .command)
        await type("Test Mac\n") // Return in the last field signs in
        try await eventually("the wrong-credentials alert", timeout: 40) { readWindow().contains("Incorrect Sign-In Details") || (window?.attachedSheet != nil) }
        await pump(0.5)
        await shot("02-setup-wrong-details")
        try await click("OK")
        try await eventually("the alert closes") { window?.attachedSheet == nil }
        try await focus("enrol-password")
        await shortcut("a", .command)
        await press(.delete)
        try await fillSecure("enrol-password", Self.password)
        try await focus("enrol-device-name")
        await type("\n")

        await log("3. the other device's notebook arrives; this Mac has no Touch ID, so nothing offers it")
        try await eventually("the synced notebook", timeout: 60) { library?.notebooks.contains { $0.title == "Field Journal" } == true }
        await check(!app.biometricOffer, "no Touch ID offer on a Mac without Touch ID")
        await check(app.biometry == .none, "this Mac reports no usable Touch ID")
        try await eventually("the sync status says Synced", timeout: 40) { SyncSummary(app.client!.syncMonitor.status).kind == .synced }
        try await eventually("the section is in the sidebar") { sidebarRow("Marsh") != nil }
        await select(row: sidebarRow("Marsh")!, in: sidebar!)
        try await eventually("the page list") { pageTable?.numberOfRows == 1 }
        await pump(0.8)
        let library3 = readWindow()
        await check(library3.contains("Monday at the hide") && library3.contains("Field Journal"), "the library shows the synced page: \(library3)")
        await shot("03-library")

        await log("4. create a notebook, a section and a page from the menus; type with formatting and lists")
        try await choose("File", "New Notebook")
        try await eventually("the new-notebook sheet") { window?.attachedSheet != nil }
        await pump(0.5)
        await shot("04-new-notebook")
        await type("Trip Notes\n")
        try await eventually("the new notebook") { library?.notebooks.contains { $0.title == "Trip Notes" } == true }
        try await choose("File", "New Section")
        try await eventually("the new-section sheet") { window?.attachedSheet != nil }
        await pump(0.3)
        await type("Packing\n")
        try await eventually("the empty section") {
            guard let library, case .section(_, let id)? = library.path.last else { return false }
            return library.notebooks.contains { $0.section(id)?.title == "Packing" }
        }
        await pump(0.8)
        await check(readWindow().contains("No Pages"), "the empty section says so")
        await shot("05-section-empty")
        await shortcut("n", .command) // File > New Page
        try await eventually("the new page with the keyboard in its title") {
            guard let field = titleField, let editor = field.currentEditor() else { return false }
            return window?.firstResponder === editor
        }
        await type("Checklist\n")
        try await eventually("the text has the keyboard") { window?.firstResponder === textView }
        await type("Plain start. ")
        await shortcut("b", .command)
        await type("Bold words")
        await shortcut("b", .command)
        await type("\n")
        await shortcut("l", [.command, .shift]) // Format > Checklist
        if library?.editor?.formatting.block.block != "todo" {
            await check(false, "⇧⌘L made no checklist")
            try await choose("Format", "Checklist")
        }
        await type("Passport\nTickets")
        await check(editorText == "Plain start. Bold words\nPassport\nTickets\n", "the editor text is \(editorText.debugDescription)")
        await pump(0.5)
        await shot("06-editor")
        await check(menuItem(["Format", "Checklist"])?.state == .on, "Format > Checklist is ticked in a checklist")
        await check(menuItem(["Format", "Bold"])?.keyEquivalent == "b", "Format > Bold is ⌘B")

        await log("5. what was typed arrives at the other device, formatting included")
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
        await check(checklist.runs.contains(TextRun(text: "Bold words", attributes: [PageAttribute.bold: .bool(true)])), "bold arrived: \(checklist.runs)")
        await check(checklist.runs.contains { $0.text == "\n" && $0.attributes[PageAttribute.block] == .string("todo") }, "the checklist arrived: \(checklist.runs)")

        await log("6. the other device edits while the caret is in the page here: it shows up live and the caret stays put")
        let caret = textView?.selectedRange().location ?? -1
        checklist.edit { $0.insert("From the PC: ", at: 0, attributes: [:]) }
        try await peer.sync.syncNow()
        try await eventually("the edit shows up in the open page", timeout: 40) {
            editorText == "From the PC: Plain start. Bold words\nPassport\nTickets\n"
        }
        await check(textView?.selectedRange().location == caret + 13, "the caret moved with its text (\(caret) → \(textView?.selectedRange().location ?? -1))")
        await check(window?.firstResponder === textView, "the text kept the keyboard")
        await type(" x2")
        await check(editorText == "From the PC: Plain start. Bold words\nPassport\nTickets x2\n", "typing after the remote edit: \(editorText.debugDescription)")
        try await eventually("the typing after the remote edit arrives", timeout: 40) {
            checklist.text == "From the PC: Plain start. Bold words\nPassport\nTickets x2\n"
        }
        await shot("07-editor-after-remote-edit")

        await log("7. lock from the menu: nothing of the notes is in the window, its title or the Window menu")
        try await choose("File", "Lock TwoNote")
        try await eventually("the lock screen") { app.phase == .locked }
        await pump(1)
        let lockedText = readWindow()
        await check(window?.title == "TwoNote", "the locked window is called TwoNote (it is “\(window?.title ?? "")”)")
        await check(lockedText.contains("TwoNote Is Locked"), "the lock screen is shown: \(lockedText)")
        for secret in ["Checklist", "Passport", "Trip Notes", "Field Journal", "Bittern", "Packing", "Marsh"] {
            await check(!lockedText.contains(secret), "“\(secret)” can be read in the locked window")
        }
        await check(textView == nil, "no text view in the locked window")
        let windowMenu = (menuItem(["Window"])?.submenu?.items ?? []).map(\.title).joined(separator: "|")
        for secret in ["Checklist", "Trip Notes", "Packing"] {
            await check(!windowMenu.contains(secret), "“\(secret)” is in the Window menu: \(windowMenu)")
        }
        await check(MenuState(app: app).canFormat == false && menuItem(["File", "New Page"])?.isEnabled == false, "page commands are off while locked")
        await shot("08-locked")

        await log("8. a wrong password is refused; the right one unlocks and returns to the page")
        front()
        try await fillSecure("unlock-password", "not it", submit: true)
        try await eventually("the wrong-password message") { readWindow().contains("Incorrect password") }
        await shot("09-locked-wrong-password")
        try await focus("unlock-password")
        await shortcut("a", .command)
        await press(.delete)
        try await fillSecure("unlock-password", Self.password, submit: true)
        try await eventually("the page after unlocking", timeout: 30) { editorText.hasPrefix("From the PC: ") }

        await log("9. search everything (⌥⌘F) and open a result")
        await shortcut("f", [.command, .option])
        await pump(0.4)
        await type("booming")
        try await eventually("a search result", timeout: 20) { library?.search.hits.contains { $0.title == "Monday at the hide" } == true }
        await pump(0.8)
        await check(readWindow().contains("Monday at the hide"), "the result is in the window")
        await shot("10-search")
        // The result list is a table: choose the page's row.
        if let table = pageTable, let hit = library?.search.hits.firstIndex(where: { $0.title == "Monday at the hide" }) {
            _ = table
            library?.open(library!.search.hits[hit]) // what a click on the row does
        }
        try await eventually("the found page opens") { editorText.hasPrefix("Bittern sighting\nBooming call") }
        await check(titleField?.stringValue == "Monday at the hide", "the found page's title")
        await pump(0.8)
        await shot("11-found-page")

        await log("10. offline: the server goes away; editing goes on; it syncs when the server is back")
        try await docker("stop")
        try await eventually("the status says Offline", timeout: 60) { SyncSummary(app.client!.syncMonitor.status).kind == .offline }
        if let textView {
            window?.makeFirstResponder(textView)
            textView.setSelectedRange(NSRange(location: (textView.string as NSString).length - 1, length: 0))
        }
        await type(" (offline)")
        try await eventually("Offline · Changes Waiting", timeout: 30) { SyncSummary(app.client!.syncMonitor.status).title == "Offline · Changes Waiting" }
        await pump(0.5)
        // The status line sits at the foot of the sidebar, which an in-process capture cannot
        // draw (see the report); the status itself is checked just above.
        await shot("12-offline")
        try await docker("start")
        try await eventually("Synced again", timeout: 90) {
            app.client?.sync.requestSync()
            return SyncSummary(app.client!.syncMonitor.status).kind == .synced
        }
        try await eventually("the offline edit reaches the other device", timeout: 60) {
            monday.text.hasSuffix("Refill the thermos (offline)\n")
        }

        await log("11. Settings (⌘,): every tab")
        await shortcut(",", .command)
        try await eventually("the Settings window") { settingsWindow != nil }
        await pump(1)
        if let settings = settingsWindow {
            // Settings opens on the tab last shown; start from Account.
            if let item = settings.toolbar?.items.first, let action = item.action {
                NSApp.sendAction(action, to: item.target, from: item)
                await pump(1)
            }
            await check(readWindow(settings).contains("Username"), "Settings shows the account: \(readWindow(settings))")
            await shot("13-settings-account", of: settings)
            for (index, name) in ["14-settings-sync", "15-settings-security", "16-settings-devices"].enumerated() {
                if let toolbar = settings.toolbar, toolbar.items.count > index + 1 {
                    let item = toolbar.items[index + 1]
                    if let action = item.action { NSApp.sendAction(action, to: item.target, from: item) }
                }
                await pump(1.2)
                await shot(name, of: settings)
                if name == "15-settings-security" {
                    await check(readWindow(settings).contains("Unlock with Touch ID") && app.biometry == .none, "the Touch ID row shows, as not available: \(readWindow(settings))")
                }
            }
            settings.close()
        }

        await log("12. delete a page with the Delete key, after confirming")
        front()
        if let row = sidebarRow("Packing"), let sidebar { await select(row: row, in: sidebar) }
        try await eventually("the Packing pages") { pageTable?.numberOfRows == 1 }
        if let table = pageTable { await select(row: 0, in: table) }
        try await eventually("the page opens from the list") { library?.editor != nil }
        if let table = pageTable { window?.makeFirstResponder(table) }
        await press(.delete)
        await pump(0.5)
        if window?.attachedSheet == nil {
            NSApp.sendAction(#selector(NSText.delete(_:)), to: nil, from: nil)
            await pump(0.5)
            await check(false, "the Delete key opened no confirmation (Edit > Delete did: \(window?.attachedSheet != nil))")
        }
        try await eventually("the delete confirmation") { window?.attachedSheet != nil || readWindow().contains("Delete Page") }
        await pump(0.5)
        await shot("17-delete-confirmation")
        try await click("Delete Page")
        try await eventually("the section is empty", timeout: 20) { pageTable?.numberOfRows ?? 0 == 0 }
        try await eventually("the other device sees the page go", timeout: 40) { trip.page(checklistId)?.deleted == true }

        await log("13. lock with ⌃⌘L")
        await shortcut("l", [.command, .control])
        try await eventually("locked") { app.phase == .locked }

        var notebooks = PeerNotebooks(peer: peer, trees: [journal.notebookId: journal, tripId: trip])
        try await runM2(&notebooks)
        await peer.close()
    }
}
#endif

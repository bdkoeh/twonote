#if DEBUG
import AppKit
import Foundation
import SwiftUI
import TwoNoteCore
import TwoNoteDocuments
import WidgetKit
import YrsKit

// The end-to-end run's stage M2 steps: twonote:// links (the widget's), Share to TwoNote
// through the real share extension, the Settings rows for both, and the looks of the widget
// and the share sheet. Run after step 13, with the app locked.
extension EndToEndDriver {
    /// The other device's notebooks, by id.
    struct PeerNotebooks {
        var peer: TwoNoteClient
        var trees: [String: YrsNotebookTree]

        mutating func tree(_ id: String) async throws -> YrsNotebookTree {
            if let tree = trees[id] { return tree }
            let tree = try await peer.openNotebook(id)
            trees[id] = tree
            return tree
        }
    }

    func required<T>(_ value: T?, _ what: String) throws -> T {
        guard let value else { throw Failure(description: "missing: \(what)") }
        return value
    }

    func runM2(_ notebooks: inout PeerNotebooks) async throws {
        try await linkSteps(&notebooks)
        try await shareSteps(&notebooks)
        try await sharingSettingsSteps()
        await looks()
        await log("19. lock")
        await shortcut("l", [.command, .control])
        try await eventually("locked") { app.phase == .locked }
    }

    // MARK: Links

    /// Opens a link the way the system does: through Launch Services, to this very app (this
    /// build, not whatever else claims twonote:), which receives it as a "get URL" Apple event.
    func openThroughLaunchServices(_ link: String) async -> Bool {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        do {
            _ = try await NSWorkspace.shared.open([URL(string: link)!], withApplicationAt: Bundle.main.bundleURL, configuration: configuration)
            return true
        } catch {
            await log("Launch Services could not open \(link): \(error)")
            return false
        }
    }

    private func linkSteps(_ notebooks: inout PeerNotebooks) async throws {
        await log("14. twonote://new while locked: kept until the unlock, the window comes forward, then a new page with the keyboard in its title")
        guard app.phase == .locked else { throw Failure(description: "not locked before the link steps") }
        // TwoNote out of sight, as when the widget is clicked on the desktop.
        NSApp.hide(nil)
        await pump(0.8)
        _ = await openThroughLaunchServices("twonote://new")
        do {
            try await eventually("the link is kept for the unlock", timeout: 15) { app.pendingLink == .newNote }
        } catch {
            await check(false, "twonote://new did not arrive through Launch Services; delivered in-process instead")
            delegate.open(URL(string: "twonote://new")!)
        }
        try await eventually("the window is shown again") { window?.isVisible == true && !NSApp.isHidden }
        await log("after the link: active \(NSApp.isActive), key window \(NSApp.keyWindow === window)")
        await check(app.phase == .locked && app.library == nil, "nothing happens before the unlock")
        await check(readWindow().contains("TwoNote Is Locked"), "the window shows the lock screen")
        try await fillSecure("unlock-password", Self.password, submit: true)
        try await eventually("the new page with the keyboard in its title", timeout: 30) {
            guard let library, let ref = library.editor?.ref, app.pendingLink == nil,
                  let page = library.notebook(ref.notebookId)?.page(ref.pageId), page.title.isEmpty,
                  let field = titleField, let editor = field.currentEditor() else { return false }
            return window?.firstResponder === editor
        }
        let ref = try required(library?.editor?.ref, "the new page")
        let section = library?.notebook(ref.notebookId)?.page(ref.pageId)?.sectionId
        await check(library?.notebook(ref.notebookId)?.section(section ?? "")?.title == "Packing", "the new page is in the section used last")
        await type("From the widget\n")
        await type("Started with twonote://new.")
        await pump(0.5)
        await shot("18-link-new-page")
        let tree = try await notebooks.tree(ref.notebookId)
        try await eventually("the other device has the page from the link", timeout: 40) {
            tree.page(ref.pageId)?.title == "From the widget"
        }

        await log("15. twonote://search: the window's search field takes the keyboard")
        _ = await openThroughLaunchServices("twonote://search")
        try await eventually("the search field has the keyboard", timeout: 15) {
            guard NSApp.isActive, let responder = window?.firstResponder else { return false }
            return responder is NSSearchField || (responder as? NSTextView)?.delegate is NSSearchField
        }
        await check(library?.editor?.ref == ref, "the open page stays open beside the list")
        await type("booming")
        try await eventually("a search result", timeout: 20) { library?.search.hits.contains { $0.title == "Monday at the hide" } == true }
        await pump(0.8)
        await shot("19-link-search")
        library?.search.query = ""
        await pump(0.5)
        window?.makeFirstResponder(nil)
    }

    // MARK: Share to TwoNote

    private func shareSteps(_ notebooks: inout PeerNotebooks) async throws {
        await log("16. Share to TwoNote while locked, through the share extension; the unlock adds it; the other device gets it")
        await shortcut("l", [.command, .control])
        try await eventually("locked") { app.phase == .locked }
        guard let container = app.environment.sharedContainer else { throw Failure(description: "no App Group container") }
        let link = "https://example.org/birds/bittern"
        let throughExtension = await shareThroughExtension(container: container, link: link, title: "Bittern article")
        if !throughExtension {
            // The same code the extension runs (ShareModel, ShareInbox), in this process.
            await log("FALLBACK: the item is sealed into the App Group by the extension's code in this process, not by the extension")
            let model = ShareModel(container: container)
            model.load(ShareInput(contentText: "Bitterns of the marsh", urls: [link]))
            model.title = "Bittern article"
            await check(model.save(), "the item was sealed")
            app.refreshWaitingSharedItems()
        }
        try await eventually("the item is waiting", timeout: 20) { app.waitingSharedItems == 1 }
        let files = ShareInbox(container: container).waitingItems()
        await check(files.count == 1, "one sealed item in the inbox: \(files.map(\.lastPathComponent))")
        for file in files {
            let data = (try? Data(contentsOf: file)) ?? Data()
            for secret in ["Bittern", "bittern", "example.org"] {
                await check(data.range(of: Data(secret.utf8)) == nil, "“\(secret)” is readable in the sealed item")
            }
        }
        front()
        try await fillSecure("unlock-password", Self.password, submit: true)
        try await eventually("the notice", timeout: 30) { library?.notice?.text == "1 Shared Item Added" }
        await pump(0.6)
        await check(readWindow().contains("1 Shared Item Added"), "the notice is in the window")
        await shot("20-shared-item-added")
        let notice = try required(library?.notice, "the notice")
        let notebookId = try required(notice.notebookId, "the notice's notebook"), sectionId = try required(notice.sectionId, "the notice's section")
        await check(library?.notebook(notebookId)?.section(sectionId)?.title == "Inbox", "the item went to the Inbox section")
        await check(library?.notebooks.first?.id == notebookId, "of the first notebook")
        let page = try required(library?.notebook(notebookId)?.pages(in: sectionId).first { $0.title == "Bittern article" }, "the shared page")
        // Clicking the notice shows the section; the page opens from the list.
        if let button = views(NSButton.self, in: window?.contentView).first(where: { $0.title == "1 Shared Item Added" }) {
            button.performClick(nil)
        } else {
            library?.setPath([.notebook(notebookId), .section(notebookId: notebookId, sectionId: sectionId)])
            library?.notice = nil
        }
        try await eventually("the Inbox section is shown") { library?.path.last == .section(notebookId: notebookId, sectionId: sectionId) }
        library?.select(PageRef(notebookId: notebookId, pageId: page.id))
        try await eventually("the shared page opens") { editorText == link + "\n" }
        let runs = try required(library?.editor?.page.runs, "the page's text")
        await check(runs.first == TextRun(text: link, attributes: [PageAttribute.link: .string(link)]), "the link is a real link: \(runs)")
        await pump(0.8)
        await shot("21-shared-page")
        let tree = try await notebooks.tree(notebookId)
        try await eventually("the other device has the shared page", timeout: 40) {
            tree.page(page.id)?.title == "Bittern article"
        }
        let peerPage = try await notebooks.peer.openPage(notebookId: notebookId, pageId: page.id)
        try await eventually("with its text", timeout: 40) { peerPage.text == link + "\n" }
    }

    /// Shares a link through the real share extension, in its own process, from a helper
    /// process standing in for another app's Share menu (TwoNote is never offered its own share
    /// extension). The extension's Debug build saves by itself when a marker file asks it to
    /// (this run cannot click into another process's sheet). False if that did not happen -
    /// for instance because macOS does not offer TwoNote in the Share menu until the user
    /// turns it on (System Settings > General > Login Items & Extensions > Sharing).
    private func shareThroughExtension(container: SharedContainer, link: String, title: String) async -> Bool {
        let marker = container.root.appendingPathComponent("e2e-share-autosave")
        try? Data(title.utf8).write(to: marker.appendingPathExtension("title"))
        try? Data().write(to: marker)
        defer {
            try? FileManager.default.removeItem(at: marker)
            try? FileManager.default.removeItem(at: marker.appendingPathExtension("title"))
        }
        var components = URLComponents(url: control.appending(path: "share"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "url", value: link)]
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 100
        guard let (body, response) = try? await URLSession.shared.data(for: request) else {
            await log("the share helper did not answer")
            return false
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        await log("share helper (\(status)): \(String(decoding: body, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))")
        guard status == 200 else { return false }
        do {
            try await eventually("the app hears of the item", timeout: 20) { app.waitingSharedItems == 1 }
            await log("the share extension sealed the item, and the app heard of it")
            return true
        } catch {
            await check(false, "the extension reported the item shared, but the app counts \(app.waitingSharedItems)")
            return false
        }
    }

    // MARK: Settings > Sharing

    private func sharingSettingsSteps() async throws {
        await log("17. Settings > Sharing: destination picker, waiting count, the widget switch")
        guard let container = app.environment.sharedContainer, let library else { throw Failure(description: "not ready") }
        // An item that arrived without the app hearing of it yet: counted, shown as waiting.
        try ShareInbox(container: container).add(SharedItem(title: "Waiting item", text: "Arrived while Settings was open.", url: nil))
        app.refreshWaitingSharedItems()
        await check(app.waitingSharedItems == 1, "one item waiting")
        await shortcut(",", .command)
        try await eventually("the Settings window") { settingsWindow != nil }
        await pump(1)
        guard let settings = settingsWindow else { return }
        if let toolbar = settings.toolbar, toolbar.items.count > 4, let action = toolbar.items[4].action {
            NSApp.sendAction(action, to: toolbar.items[4].target, from: toolbar.items[4])
        }
        await pump(2)
        settings.displayIfNeeded()
        let text = readWindow(settings)
        await check(text.contains("Shared Items Go To") && text.contains("Waiting to Be Added") && text.contains("Show Recent Pages in Widget"),
                    "the Sharing tab shows its rows: \(text)")
        await shot("22-settings-sharing", of: settings)

        // The picker: another section. SwiftUI draws this pop-up itself (there is no AppKit pop-up
        // button to select an item of, and opening its menu from outside would need an
        // accessibility permission), so the choice goes through the picker's own binding - the
        // tag of the section, as the menu item sets it - and the window must then show it.
        let packing = library.notebooks.lazy.compactMap { notebook in
            notebook.sections.first { $0.title == "Packing" }.map { (notebook.id, $0.id) }
        }.first
        if let packing {
            SharingSettings.destination(library).wrappedValue = SharingSettings.tag(packing.0, packing.1)
            await pump(1)
            await check(library.chosenShareDestination?.sectionId == packing.1, "Packing is chosen")
            let shown = readWindow(settings)
            await check(shown.contains("Packing"), "the picker shows Packing: \(shown)")
            await shot("22b-settings-sharing-destination", of: settings)
        } else {
            await check(false, "no Packing section")
        }
        await app.importSharedItems()
        await check(app.waitingSharedItems == 0, "the waiting item was added")
        if let packing {
            await check(library.notebook(packing.0)?.pages(in: packing.1).contains { $0.title == "Waiting item" } == true, "into Packing")
        }

        // The widget switch: titles written only while it is on.
        let toggle = views(NSSwitch.self, in: settings.contentView).first
        await check(toggle != nil, "the widget switch")
        await check(!app.showsRecentPagesInWidget && !FileManager.default.fileExists(atPath: container.recentPagesURL.path), "off, and no titles, by default")
        toggle?.performClick(nil)
        try await eventually("the switch is on") { app.showsRecentPagesInWidget }
        try await eventually("the titles are there") { RecentPages.load(from: container)?.pages.isEmpty == false }
        let recent = RecentPages.load(from: container)
        await log("widget-recent.json: \(recent?.pages.map(\.title) ?? [])")
        let raw = (try? Data(contentsOf: container.recentPagesURL)) ?? Data()
        for secret in ["Booming", "Refill", "Field Journal", "Trip Notes", "Started with"] {
            await check(raw.range(of: Data(secret.utf8)) == nil, "“\(secret)” is in widget-recent.json")
        }
        await pump(0.6)
        await shot("23-settings-widget-on", of: settings)
        toggle?.performClick(nil)
        try await eventually("the switch is off") { !app.showsRecentPagesInWidget }
        await check(!FileManager.default.fileExists(atPath: container.recentPagesURL.path), "the titles are removed when the switch goes off")
        settings.close()
        front()
    }

    // MARK: Looks

    /// The widget (small and medium, titles off and on) and the share sheet, drawn by this
    /// process with the extensions' own views: the system's widget host and share sheet are
    /// other processes, which this run cannot capture without a screen-recording permission.
    private func looks() async {
        await log("18. the widget (small, medium; titles off, on) and the share sheet, light and dark")
        let titles = RecentPages(pages: [
            .init(notebookId: "n", pageId: "1", title: "From the widget"),
            .init(notebookId: "n", pageId: "2", title: "Bittern article"),
            .init(notebookId: "n", pageId: "3", title: "Monday at the hide"),
            .init(notebookId: "n", pageId: "4", title: ""),
        ])
        for (family, name) in [(WidgetFamily.systemSmall, "small"), (.systemMedium, "medium")] {
            for (recent, setting) in [(nil as RecentPages?, "off"), (titles, "on")] {
                // The small widget never shows titles: the file is read only by the medium one.
                await shotOfView("24-widget-\(name)-titles-\(setting)", background: NSColor(calibratedWhite: 0.56, alpha: 1),
                                 WidgetChrome(family: family) { TwoNoteWidgetView(recent: recent, size: family) })
            }
        }
        if let container = app.environment.sharedContainer {
            let model = ShareModel(container: container)
            model.load(ShareInput(contentText: "Marsh Birds Weekly", urls: ["https://example.org/marsh/weekly"]))
            await shotOfView("25-share-sheet-link", background: .windowBackgroundColor, MacShareView(model: model, onCancel: {}, onSaved: {}))
            let text = ShareModel(container: container)
            text.load(ShareInput(texts: ["Booming call heard at dawn near the reedbed.\n\nTwo birds, maybe three. Refill the thermos."]))
            await shotOfView("25b-share-sheet-text", background: .windowBackgroundColor, MacShareView(model: text, onCancel: {}, onSaved: {}))
        }
        let empty = SharedContainer(root: FileManager.default.temporaryDirectory.appendingPathComponent("e2e-empty-\(UUID().uuidString)"))
        let notSetUp = ShareModel(container: empty)
        notSetUp.load(ShareInput(texts: ["x"]))
        await shotOfView("26-share-sheet-not-set-up", background: .windowBackgroundColor, MacShareView(model: notSetUp, onCancel: {}, onSaved: {}))
    }

    /// A view drawn in a window of its own (borderless, its size), saved light and dark.
    private func shotOfView(_ name: String, background: NSColor, _ view: some View) async {
        let host = NSHostingView(rootView: view)
        let size = host.fittingSize
        let stage = NSWindow(contentRect: NSRect(x: 120, y: 120, width: size.width, height: size.height),
                             styleMask: [.borderless], backing: .buffered, defer: false)
        stage.isReleasedWhenClosed = false
        stage.backgroundColor = background
        stage.contentView = host
        stage.orderFront(nil)
        await pump(0.5)
        await shot(name, of: stage)
        stage.orderOut(nil)
    }
}

/// The widget the way the desktop shows it: the system's margins, its background and corner
/// radius, on a stretch of desktop.
private struct WidgetChrome<Content: View>: View {
    let family: WidgetFamily
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(14)
            .frame(width: family == .systemSmall ? 170 : 364, height: 170)
            .background(.background)
            .clipShape(.rect(cornerRadius: 22, style: .continuous))
            .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
            .padding(28)
    }
}
#endif

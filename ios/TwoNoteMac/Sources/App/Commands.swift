import AppKit
import SwiftUI
import TwoNoteDocuments

/// The menu bar: File, Edit (with Find), Format and View, the way Notes lays them out.
/// Enablement and ticks come from `MenuState`.
struct TwoNoteCommands: Commands {
    let app: AppModel?
    let requests: WindowRequests

    private var library: LibraryModel? { app?.library }
    private var editor: EditorSession? { app?.library?.editor }

    var body: some Commands {
        SidebarCommands()
        ToolbarCommands()

        CommandGroup(replacing: .newItem) { Live(app: app) { state in
            Button("New Page") { newPage(state) }
                .keyboardShortcut("n")
                .disabled(!state.canNewPage)
            Button("New Section") { newSection(state) }
                .disabled(!state.canNewSection)
            Button("New Notebook") { newNotebook() }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(!state.canNewNotebook)
        } }

        CommandGroup(after: .saveItem) { Live(app: app) { state in
            Divider()
            Button("Delete Page…") { deletePage() }
                .disabled(!state.canDeletePage)
            Divider()
            Button("Lock TwoNote") { lock() }
                .keyboardShortcut("l", modifiers: [.command, .control])
                .disabled(!state.canLock)
        } }

        CommandGroup(after: .pasteboard) { Live(app: app) { state in
            Divider()
            Menu("Find") {
                Button("Find…") { find(.showFindInterface) }
                    .keyboardShortcut("f")
                    .disabled(!state.canFormat)
                Button("Find and Replace…") { find(.showReplaceInterface) }
                    .keyboardShortcut("f", modifiers: [.command, .control])
                    .disabled(!state.canFormat)
                Button("Find Next") { find(.nextMatch) }
                    .keyboardShortcut("g")
                    .disabled(!state.canFormat)
                Button("Find Previous") { find(.previousMatch) }
                    .keyboardShortcut("g", modifiers: [.command, .shift])
                    .disabled(!state.canFormat)
                Button("Use Selection for Find") { find(.setSearchString) }
                    .keyboardShortcut("e")
                    .disabled(!state.canFormat)
                Divider()
                Button("Search All Notes") { requests.searchFocusRequests += 1 }
                    .keyboardShortcut("f", modifiers: [.command, .option])
                    .disabled(!state.canSearch)
            }
        } }

        CommandMenu("Format") { Live(app: app) { state in
            Menu("Style") {
                styleItem("Title", "h1", key: "1", state)
                styleItem("Heading", "h2", key: "2", state)
                styleItem("Subheading", "h3", key: "3", state)
                styleItem("Body", nil, key: "0", state)
                Divider()
                styleItem("Code Block", "code", key: nil, state)
            }
            .disabled(!state.canFormat)
            Divider()
            inlineItem("Bold", PageAttribute.bold, key: "b", state)
            inlineItem("Italic", PageAttribute.italic, key: "i", state)
            inlineItem("Underline", PageAttribute.underline, key: "u", state)
            inlineItem("Strikethrough", PageAttribute.strike, key: nil, state)
            inlineItem("Inline Code", PageAttribute.code, key: nil, state)
            Divider()
            listItem("Bulleted List", "ul", key: "7", state)
            listItem("Numbered List", "ol", key: "9", state)
            listItem("Checklist", "todo", key: "l", state)
            Button("Mark as Checked") { editor?.toggleChecked() }
                .keyboardShortcut("u", modifiers: [.command, .shift])
                .disabled(!state.canToggleChecked)
            Divider()
            Button("Increase Indent") { editor?.indent(by: 1) }
                .keyboardShortcut("]")
                .disabled(!state.canIndent)
            Button("Decrease Indent") { editor?.indent(by: -1) }
                .keyboardShortcut("[")
                .disabled(!state.canOutdent)
            Divider()
            Button(state.link == nil ? "Add Link…" : "Edit Link…") { editLink() }
                .keyboardShortcut("k")
                .disabled(!state.canFormat)
        } }
    }

    // MARK: Items

    private func styleItem(_ title: String, _ block: String?, key: Character?, _ state: MenuState) -> some View {
        Toggle(title, isOn: Binding(get: { state.hasBlock(block) }, set: { _ in choose(block) }))
            .modifier(Shortcut(key, [.command, .option]))
    }

    private func inlineItem(_ title: String, _ key: String, key shortcut: Character?, _ state: MenuState) -> some View {
        Toggle(title, isOn: Binding(get: { state.isOn(key) }, set: { _ in editor?.toggle(key) }))
            .modifier(Shortcut(shortcut, .command))
            .disabled(!state.canFormat)
    }

    private func listItem(_ title: String, _ block: String, key: Character, _ state: MenuState) -> some View {
        Toggle(title, isOn: Binding(get: { state.hasBlock(block) }, set: { _ in choose(block) }))
            .keyboardShortcut(KeyEquivalent(key), modifiers: [.command, .shift])
            .disabled(!state.canFormat)
    }

    // MARK: Actions

    private func choose(_ block: String?) {
        editor?.chooseBlock(block)
    }

    private func newPage(_ state: MenuState) {
        guard let library, let place = state.sectionForNewPage else { return }
        Task { await library.addPage(notebookId: place.notebookId, sectionId: place.sectionId) }
    }

    private func newSection(_ state: MenuState) {
        guard let library, let notebookId = state.notebookForNewSection else { return }
        requests.nameRequest = LibraryPrompts.newSection(library, notebookId: notebookId)
    }

    private func newNotebook() {
        guard let library else { return }
        requests.nameRequest = LibraryPrompts.newNotebook(library)
    }

    private func deletePage() {
        guard let library, let ref = editor?.ref, let info = library.notebook(ref.notebookId)?.page(ref.pageId) else { return }
        requests.deleteRequest = LibraryPrompts.deletePage(library, ref, title: pageTitle(info.title))
    }

    private func lock() {
        guard let app else { return }
        Task {
            await app.willResignActive()
            await app.lock()
        }
    }

    private func editLink() {
        guard let editor else { return }
        let state = editor.formatting
        requests.linkRequest = LinkRequest(url: state.inline.link ?? "", selection: editor.binding.selectedRange, hadLink: state.inline.link != nil)
    }

    /// The page's find bar (NSTextFinder), whichever field has the keyboard.
    private func find(_ action: NSTextFinder.Action) {
        guard let editor else { return }
        editor.host.focusBody()
        let sender = NSMenuItem()
        sender.tag = action.rawValue
        editor.textView.performTextFinderAction(sender)
    }
}

/// Menu items built from the app's current state. Their body is a view's, so SwiftUI tracks
/// what it reads (phase, path, open page, formatting) and rebuilds the items when that changes;
/// a `Commands` body alone is not re-evaluated for changes of an @Observable model.
private struct Live<Content: View>: View {
    let app: AppModel?
    @ViewBuilder let content: (MenuState) -> Content

    var body: some View {
        content(MenuState(app: app))
    }
}

/// A keyboard shortcut for the items that have one.
private struct Shortcut: ViewModifier {
    let key: Character?
    let modifiers: EventModifiers

    init(_ key: Character?, _ modifiers: EventModifiers) {
        self.key = key
        self.modifiers = modifiers
    }

    func body(content: Content) -> some View {
        if let key {
            content.keyboardShortcut(KeyEquivalent(key), modifiers: modifiers)
        } else {
            content
        }
    }
}

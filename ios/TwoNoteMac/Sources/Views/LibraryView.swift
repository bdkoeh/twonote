import AppKit
import SwiftUI
import TwoNoteCore
import YrsKit

/// The unlocked app: the Mac's three columns, as in Notes and Mail. The sidebar lists the
/// notebooks with their sections, the middle column the pages of the chosen section (or the
/// search results), the right one the open page.
///
/// All of it renders `LibraryModel`'s state - the same model the iPhone app uses - so where
/// the user is (section and page) is saved and restored the same way.
struct LibraryView: View {
    let library: LibraryModel

    @Environment(AppModel.self) private var app
    @Environment(WindowRequests.self) private var requests
    @State private var columns = NavigationSplitViewVisibility.all
    @FocusState private var searchFocused: Bool

    var body: some View {
        @Bindable var search = library.search
        @Bindable var requests = requests
        NavigationSplitView(columnVisibility: $columns) {
            SidebarView(library: library)
                .navigationSplitViewColumnWidth(min: 190, ideal: 230, max: 340)
        } content: {
            PageColumn(library: library)
                .navigationSplitViewColumnWidth(min: 240, ideal: 290, max: 420)
        } detail: {
            DetailView(library: library)
        }
        .searchable(text: $search.query, placement: .toolbar, prompt: "Search")
        .searchFocused($searchFocused)
        .onChange(of: requests.searchFocusRequests) {
            searchFocused = true
        }
        // twonote://search (the widget): the field takes the keyboard, once.
        .onChange(of: library.wantsSearchFocus, initial: true) { _, wants in
            guard wants else { return }
            library.wantsSearchFocus = false
            searchFocused = true
        }
        .overlay(alignment: .bottom) {
            NoticeBanner(library: library)
        }
        .namePrompt($requests.nameRequest)
        .deletePrompt($requests.deleteRequest)
        .sheet(item: $requests.linkRequest) { request in
            LinkSheet(request: request, editor: library.editor)
        }
        .alert(
            "Unlock with \(app.biometry.name)?",
            isPresented: Binding(get: { app.biometricOffer }, set: { _ in }) // both buttons answer
        ) {
            Button("Use \(app.biometry.name)") { app.answerBiometricOffer(enable: true) }
            Button("Not Now", role: .cancel) { app.answerBiometricOffer(enable: false) }
        } message: {
            Text("TwoNote can unlock with \(app.biometry.name) on this Mac instead of your password. You can change this in Settings.")
        }
        .alert(
            library.alert?.title ?? "",
            isPresented: Binding(get: { library.alert != nil }, set: { if !$0 { library.alert = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(library.alert?.detail ?? "")
        }
        .onDisappear {
            // Locked: no prompt about the notes may outlive them.
            requests.nameRequest = nil
            requests.deleteRequest = nil
            requests.linkRequest = nil
        }
    }
}

// MARK: - Sidebar

/// Notebooks as collapsible groups, their sections as the rows (with page counts), the way
/// Notes shows accounts and folders.
struct SidebarView: View {
    let library: LibraryModel

    @Environment(WindowRequests.self) private var requests
    /// Notebooks the user folded away, by id (stays across launches; ids say nothing about content).
    @AppStorage("sidebar.collapsedNotebooks") private var collapsed = ""

    private var selection: Binding<Route?> {
        Binding(
            get: { library.path.last.flatMap { if case .section = $0 { $0 } else { nil } } },
            set: { route in
                guard case .section(let notebookId, _)? = route, let route else { return }
                library.setPath([.notebook(notebookId), route])
            })
    }

    var body: some View {
        List(selection: selection) {
            ForEach(library.notebooks) { notebook in
                Section(isExpanded: expanded(notebook.id)) {
                    ForEach(notebook.sections) { section in
                        let info = SectionTitle(id: section.id, title: section.title)
                        Label(info.displayTitle, systemImage: "folder")
                            .badge(notebook.pages(in: section.id).count)
                            .tag(Route.section(notebookId: notebook.id, sectionId: section.id))
                            .accessibilityIdentifier("section-\(info.displayTitle)")
                            .contextMenu {
                                Button("New Section…") { requests.nameRequest = LibraryPrompts.newSection(library, notebookId: notebook.id) }
                                Divider()
                                Button("Rename Section…") {
                                    requests.nameRequest = LibraryPrompts.renameSection(library, notebookId: notebook.id, info)
                                }
                                Button("Delete Section…", role: .destructive) {
                                    requests.deleteRequest = LibraryPrompts.deleteSection(library, notebookId: notebook.id, info)
                                }
                            }
                    }
                    .onMove { source, destination in
                        library.moveSections(notebookId: notebook.id, from: source, to: destination)
                    }
                } header: {
                    Text(notebook.displayTitle)
                        .accessibilityIdentifier("notebook-\(notebook.displayTitle)")
                        .contextMenu {
                            Button("New Section…") { requests.nameRequest = LibraryPrompts.newSection(library, notebookId: notebook.id) }
                            Divider()
                            Button("Rename Notebook…") { requests.nameRequest = LibraryPrompts.renameNotebook(library, notebook) }
                            Button("Delete Notebook…", role: .destructive) {
                                LibraryPrompts.deleteNotebook(library, notebook) { requests.deleteRequest = $0 }
                            }
                        }
                }
            }
        }
        .listStyle(.sidebar)
        .accessibilityIdentifier("sidebar")
        .overlay {
            if library.notebooks.isEmpty {
                ContentUnavailableView {
                    Label("No Notebooks", systemImage: "book.closed")
                } description: {
                    Text("Notebooks from your other devices appear here once they have synced.")
                } actions: {
                    Button("New Notebook") { requests.nameRequest = LibraryPrompts.newNotebook(library) }
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            // Like Notes' "New Folder" at the foot of its sidebar, with the sync status above it
            // (one line each, so neither is cut short in a narrow sidebar).
            VStack(alignment: .leading, spacing: 6) {
                SyncStatusLine(library: library)
                    .font(.callout)
                Button {
                    requests.nameRequest = LibraryPrompts.newNotebook(library)
                } label: {
                    Label("New Notebook", systemImage: "plus.circle")
                        .lineLimit(1)
                }
                .buttonStyle(.borderless)
                .labelStyle(.titleAndIcon)
                .help("New Notebook")
                .accessibilityIdentifier("new-notebook")
            }
            .font(.callout)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    private func expanded(_ notebookId: String) -> Binding<Bool> {
        Binding(
            get: { !collapsedIds.contains(notebookId) },
            set: { open in
                var ids = collapsedIds
                if open { ids.remove(notebookId) } else { ids.insert(notebookId) }
                collapsed = ids.sorted().joined(separator: ",")
            })
    }

    private var collapsedIds: Set<String> {
        Set(collapsed.split(separator: ",").map(String.init))
    }
}

// MARK: - Page list

/// The middle column: the pages of the chosen section, or the search results while a search
/// is typed.
struct PageColumn: View {
    let library: LibraryModel

    @Environment(WindowRequests.self) private var requests

    private var place: (notebookId: String, sectionId: String)? {
        for route in library.path.reversed() {
            if case .section(let notebookId, let sectionId) = route { return (notebookId, sectionId) }
        }
        return nil
    }

    var body: some View {
        Group {
            if library.search.isActive {
                SearchResultsView(library: library)
            } else if let place, let notebook = library.notebook(place.notebookId), let section = notebook.section(place.sectionId) {
                PageListView(library: library, notebook: notebook, section: SectionTitle(id: section.id, title: section.title))
            } else {
                ContentUnavailableView(
                    "No Section Selected",
                    systemImage: "folder",
                    description: Text(library.notebooks.isEmpty ? "Create a notebook to start." : "Choose a section in the sidebar."))
                    .navigationTitle("TwoNote")
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    guard let place else { return }
                    Task { await library.addPage(notebookId: place.notebookId, sectionId: place.sectionId) }
                } label: {
                    Label("New Page", systemImage: "square.and.pencil")
                }
                .help("New Page")
                .disabled(place == nil)
                .accessibilityIdentifier("new-page")
            }
        }
    }
}

struct PageListView: View {
    let library: LibraryModel
    let notebook: LibraryModel.Notebook
    let section: SectionTitle

    @Environment(WindowRequests.self) private var requests

    /// What makes the page texts (for the previews) worth re-reading.
    private struct Trigger: Hashable {
        var cursor: Int64
        var pending: Int
        var pages: Int
    }

    var body: some View {
        let pages = notebook.pages(in: section.id)
        let status = library.client.syncMonitor.status
        let search = library.search
        let _ = search.textsRevision // redraw the previews when the texts were read again
        List(selection: Binding<String?>(
            get: { library.selectedPage?.notebookId == notebook.id ? library.selectedPage?.pageId : nil },
            set: { id in
                if let id { library.select(PageRef(notebookId: notebook.id, pageId: id)) }
            })
        ) {
            ForEach(pages) { page in
                PageRow(title: pageTitle(page.title), date: page.updatedAt, preview: Self.preview(search.pageText(page.id)))
                    .tag(page.id)
                    .contextMenu { menu(for: page) }
            }
            .onMove { source, destination in
                library.movePages(notebookId: notebook.id, sectionId: section.id, from: source, to: destination)
            }
        }
        .listStyle(.inset)
        .alternatingRowBackgrounds(.disabled)
        .accessibilityIdentifier("page-list")
        // Edit > Delete, which the Delete key also sends while a list has the keyboard
        // (AppDelegate.route).
        .onDeleteCommand(perform: deleteSelected)
        .overlay {
            if pages.isEmpty {
                ContentUnavailableView {
                    Label("No Pages", systemImage: "doc.text")
                } description: {
                    Text("This section is empty.")
                } actions: {
                    Button("New Page") {
                        Task { await library.addPage(notebookId: notebook.id, sectionId: section.id) }
                    }
                }
            }
        }
        .navigationTitle(section.displayTitle)
        .navigationSubtitle(notebook.displayTitle)
        .task(id: Trigger(cursor: status.cursor, pending: status.pendingUpdates, pages: pages.count)) {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            await search.refresh()
        }
    }

    private func deleteSelected() {
        if let ref = library.selectedPage, ref.notebookId == notebook.id, let page = notebook.page(ref.pageId) {
            requests.deleteRequest = LibraryPrompts.deletePage(library, ref, title: pageTitle(page.title))
        }
    }

    @ViewBuilder
    private func menu(for page: PageInfo) -> some View {
        let ref = PageRef(notebookId: notebook.id, pageId: page.id)
        Button("Rename Page…") {
            requests.nameRequest = LibraryPrompts.renamePage(library, ref, title: page.title)
        }
        let others = notebook.sections.filter { $0.id != section.id }
        if !others.isEmpty {
            Menu("Move to Section") {
                ForEach(others) { other in
                    Button(other.title.isEmpty ? "Untitled Section" : other.title) {
                        library.movePage(ref, toSection: other.id)
                    }
                }
            }
        }
        Divider()
        Button("Delete Page…", role: .destructive) {
            requests.deleteRequest = LibraryPrompts.deletePage(library, ref, title: pageTitle(page.title))
        }
    }

    /// The first line of the text, as Notes shows under the title.
    static func preview(_ text: String?) -> String {
        guard let text else { return "" }
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { return String(trimmed.prefix(160)) }
        }
        return ""
    }

    /// Today's pages show the time, this week's the weekday, older ones the date - like Notes.
    static func date(_ date: Date, now: Date = Date()) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            return date.formatted(date: .omitted, time: .shortened)
        }
        if calendar.isDateInYesterday(date) {
            return "Yesterday"
        }
        if let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day, days < 7, days > 0 {
            return date.formatted(.dateTime.weekday(.wide))
        }
        return date.formatted(date: .numeric, time: .omitted)
    }
}

private struct PageRow: View {
    let title: String
    let date: Date
    let preview: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.headline)
                .lineLimit(1)
            HStack(spacing: 6) {
                Text(PageListView.date(date))
                    .foregroundStyle(.primary)
                    .layoutPriority(1)
                Text(preview.isEmpty ? "No additional text" : preview)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .font(.subheadline)
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 2)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("page-row")
    }
}

// MARK: - Detail

/// The right column: the page editor, or what to show when no page is open.
struct DetailView: View {
    let library: LibraryModel

    var body: some View {
        Group {
            if let editor = library.editor {
                EditorHost(session: editor)
                    .id(editor.ref)
            } else if library.selectedPage != nil {
                Color(nsColor: .textBackgroundColor) // the page's document is being read from the store
            } else {
                ContentUnavailableView(
                    "No Page Selected",
                    systemImage: "doc.text",
                    description: Text("Choose a page from the list."))
            }
        }
        .frame(minWidth: 360)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                FormatControls(editor: library.editor)
            }
            ToolbarItem(placement: .primaryAction) {
                SyncStatusButton(library: library)
            }
        }
    }
}

/// The toolbar's formatting: the paragraph style menu ("Aa", as in Notes), the checklist and
/// the link button. Everything else is in the Format menu.
struct FormatControls: View {
    let editor: EditorSession?
    @Environment(WindowRequests.self) private var requests

    var body: some View {
        let formatting = editor?.formatting
        let block = formatting?.block.block
        let link = formatting?.inline.link
        Menu {
            Section {
                blockToggle("Title", "h1", block)
                blockToggle("Heading", "h2", block)
                blockToggle("Subheading", "h3", block)
                blockToggle("Body", nil, block)
                blockToggle("Code Block", "code", block)
            }
            Section {
                inlineToggle("Bold", "bold", formatting?.inline.bold ?? false)
                inlineToggle("Italic", "italic", formatting?.inline.italic ?? false)
                inlineToggle("Underline", "underline", formatting?.inline.underline ?? false)
                inlineToggle("Strikethrough", "strike", formatting?.inline.strike ?? false)
                inlineToggle("Inline Code", "code", formatting?.inline.code ?? false)
            }
            Section {
                blockToggle("Bulleted List", "ul", block)
                blockToggle("Numbered List", "ol", block)
                Button("Increase Indent") { editor?.indent(by: 1) }
                Button("Decrease Indent") { editor?.indent(by: -1) }
                    .disabled((formatting?.block.indent ?? 0) == 0)
            }
        } label: {
            Label("Format", systemImage: "textformat")
        }
        .help("Format")
        .accessibilityIdentifier("format-menu")
        .disabled(editor == nil)

        Toggle(isOn: Binding(get: { block == "todo" }, set: { _ in editor?.chooseBlock("todo") })) {
            Label("Checklist", systemImage: "checklist")
        }
        .help("Checklist")
        .accessibilityIdentifier("format-checklist")
        .disabled(editor == nil)

        Button {
            guard let editor else { return }
            requests.linkRequest = LinkRequest(
                url: link ?? "", selection: editor.binding.selectedRange, hadLink: link != nil)
        } label: {
            Label(link == nil ? "Add Link" : "Edit Link", systemImage: "link")
        }
        .help(link == nil ? "Add Link" : "Edit Link")
        .accessibilityIdentifier("format-link")
        .disabled(editor == nil)
    }

    private func blockToggle(_ title: String, _ value: String?, _ current: String?) -> some View {
        Toggle(title, isOn: Binding(get: { current == value }, set: { _ in editor?.chooseBlock(value) }))
    }

    private func inlineToggle(_ title: String, _ key: String, _ on: Bool) -> some View {
        Toggle(title, isOn: Binding(get: { on }, set: { _ in editor?.toggle(key) }))
    }
}

/// Add, change or remove the link at the selection.
struct LinkSheet: View {
    let request: LinkRequest
    let editor: EditorSession?
    @Environment(\.dismiss) private var dismiss
    @State private var url = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(request.hadLink ? "Edit Link" : "Add Link")
                .font(.headline)
            TextField("Address", text: $url, prompt: Text(verbatim: "https://example.com"))
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                .focused($focused)
                .onSubmit(done)
                .accessibilityIdentifier("link-field")
            HStack {
                if request.hadLink {
                    Button("Remove Link", role: .destructive) {
                        editor?.applyLink("", selection: request.selection, hadLink: true)
                        dismiss()
                    }
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Done", action: done)
                    .keyboardShortcut(.defaultAction)
                    .disabled(url.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 380)
        .onAppear {
            url = request.url
            focused = true
        }
    }

    private func done() {
        guard !url.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        editor?.applyLink(url, selection: request.selection, hadLink: request.hadLink)
        dismiss()
        editor?.focusText()
    }
}

// MARK: - Sync status

/// The status as text at the bottom of the sidebar: "Synced", "Offline · Changes Waiting"…
/// Offline reads as plainly as synced; only a sign-in request or a failing sync stands out.
struct SyncStatusLine: View {
    let library: LibraryModel

    var body: some View {
        let summary = SyncSummary(library.client.syncMonitor.status)
        HStack(spacing: 4) {
            if summary.wantsAttention {
                Image(systemName: summary.symbol)
            }
            Text(summary.title)
                .lineLimit(1)
        }
        .foregroundStyle(summary.wantsAttention ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("sync-status-line")
        .accessibilityLabel("Sync status: \(summary.title)")
    }
}

/// The same status as a toolbar button; its popover has the details and Sync Now.
struct SyncStatusButton: View {
    let library: LibraryModel
    @State private var showing = false

    var body: some View {
        let status = library.client.syncMonitor.status
        let summary = SyncSummary(status)
        Button {
            showing.toggle()
        } label: {
            Label(summary.title, systemImage: summary.symbol)
                .foregroundStyle(summary.wantsAttention ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
        }
        .help("Sync: \(summary.title)")
        .accessibilityIdentifier("sync-status")
        .accessibilityLabel("Sync status: \(summary.title)")
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 10) {
                Label(summary.title, systemImage: summary.symbol)
                    .font(.headline)
                    .foregroundStyle(summary.wantsAttention ? AnyShapeStyle(.orange) : AnyShapeStyle(.primary))
                Text(summary.kind == .problem ? [summary.explanation, status.lastError].compactMap { $0 }.joined(separator: " ") : summary.explanation)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let last = status.lastSyncedAt {
                    LabeledContent("Last Synced", value: last.formatted(date: .abbreviated, time: .shortened))
                }
                if let waiting = summary.waiting {
                    LabeledContent("Waiting to Sync", value: waiting)
                }
                HStack {
                    SettingsLink {
                        Text("Settings…")
                    }
                    Spacer()
                    Button("Sync Now") {
                        library.client.sync.requestSync()
                    }
                    .disabled(summary.kind == .needsSignIn)
                }
                .padding(.top, 2)
            }
            .padding(16)
            .frame(width: 300)
            .accessibilityIdentifier("sync-popover")
        }
    }
}

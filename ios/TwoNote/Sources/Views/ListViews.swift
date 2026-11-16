import SwiftUI
import YrsKit

/// The top of the hierarchy: the notebooks on this device.
struct NotebookListView: View {
    let library: LibraryModel

    @State private var nameRequest: NameRequest?
    @State private var deleteRequest: DeleteRequest?

    var body: some View {
        Group {
            if library.search.isActive {
                SearchResultsView(library: library)
            } else {
                list
            }
        }
        .navigationTitle("Notebooks")
        .librarySearch(library, isFront: library.path.isEmpty)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                MoreMenu(library: library)
            }
            // The status is text, not a button-shaped thing: no glass capsule around it.
            ToolbarItem(placement: .bottomBar) {
                SyncStatusLine(library: library)
            }
            .sharedBackgroundVisibility(.hidden)
            ToolbarSpacer(.flexible, placement: .bottomBar)
            ToolbarItem(placement: .bottomBar) {
                Button("New Notebook", systemImage: "plus", action: create)
                    .accessibilityIdentifier("new-notebook")
            }
        }
        .namePrompt($nameRequest)
        .deletePrompt($deleteRequest)
    }

    private var list: some View {
        List {
            ForEach(library.notebooks) { notebook in
                NavigationLink(value: Route.notebook(notebook.id)) {
                    Label(notebook.displayTitle, systemImage: "book.closed")
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button { delete(notebook) } label: { Label("Delete", systemImage: "trash") }
                        .tint(.red)
                    Button { rename(notebook) } label: { Label("Rename", systemImage: "pencil") }
                }
                .contextMenu {
                    Button("Rename", systemImage: "pencil") { rename(notebook) }
                    Button("Delete", systemImage: "trash", role: .destructive) { delete(notebook) }
                }
            }
        }
        .overlay {
            if library.notebooks.isEmpty {
                ContentUnavailableView {
                    Label("No Notebooks", systemImage: "book.closed")
                } description: {
                    Text("Notebooks from your other devices appear here once they have synced.")
                } actions: {
                    Button("New Notebook", action: create)
                }
            }
        }
    }

    private func create() {
        nameRequest = NameRequest(title: "New Notebook", message: "Enter a name for this notebook.", confirm: "Create") { name in
            Task { await library.createNotebook(title: name) }
        }
    }

    private func rename(_ notebook: LibraryModel.Notebook) {
        nameRequest = NameRequest(title: "Rename Notebook", initial: notebook.title) { name in
            library.renameNotebook(notebook.id, title: name)
        }
    }

    private func delete(_ notebook: LibraryModel.Notebook) {
        Task {
            // Say why before asking "are you sure?", not after.
            if let obstacle = await library.deleteNotebookObstacle(notebook.id) {
                library.alert = obstacle
                return
            }
            deleteRequest = DeleteRequest(
                title: "Delete “\(notebook.displayTitle)”?",
                message: "The notebook and everything in it will be deleted from your server and all your devices. This can’t be undone.",
                confirm: "Delete Notebook"
            ) {
                Task { await library.deleteNotebook(notebook.id) }
            }
        }
    }
}

/// The sections of one notebook.
struct SectionListView: View {
    let library: LibraryModel
    let notebookId: String

    @State private var nameRequest: NameRequest?
    @State private var deleteRequest: DeleteRequest?

    var body: some View {
        let notebook = library.notebook(notebookId)
        let sections = notebook?.sections ?? []
        Group {
            if library.search.isActive {
                SearchResultsView(library: library)
            } else {
                list(notebook, sections)
            }
        }
        .navigationTitle(notebook?.displayTitle ?? "")
        .librarySearch(library, isFront: library.path.last == .notebook(notebookId))
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                EditButton()
                    .disabled(sections.count < 2 || library.search.isActive)
            }
            // The status is text, not a button-shaped thing: no glass capsule around it.
            ToolbarItem(placement: .bottomBar) {
                SyncStatusLine(library: library)
            }
            .sharedBackgroundVisibility(.hidden)
            ToolbarSpacer(.flexible, placement: .bottomBar)
            ToolbarItem(placement: .bottomBar) {
                Button("New Section", systemImage: "folder.badge.plus", action: create)
                    .accessibilityIdentifier("new-section")
            }
        }
        .namePrompt($nameRequest)
        .deletePrompt($deleteRequest)
    }

    private func list(_ notebook: LibraryModel.Notebook?, _ sections: [SectionInfo]) -> some View {
        List {
            ForEach(sections) { section in
                NavigationLink(value: Route.section(notebookId: notebookId, sectionId: section.id)) {
                    Label(section.title.isEmpty ? "Untitled Section" : section.title, systemImage: "folder")
                        .badge(notebook?.pages(in: section.id).count ?? 0)
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button { delete(section) } label: { Label("Delete", systemImage: "trash") }
                        .tint(.red)
                    Button { rename(section) } label: { Label("Rename", systemImage: "pencil") }
                }
                .contextMenu {
                    Button("Rename", systemImage: "pencil") { rename(section) }
                    Button("Delete", systemImage: "trash", role: .destructive) { delete(section) }
                }
            }
            .onMove { source, destination in
                library.moveSections(notebookId: notebookId, from: source, to: destination)
            }
        }
        .overlay {
            if sections.isEmpty {
                ContentUnavailableView {
                    Label("No Sections", systemImage: "folder")
                } description: {
                    Text("Sections group the pages of a notebook.")
                } actions: {
                    Button("New Section", action: create)
                }
            }
        }
    }

    private func create() {
        nameRequest = NameRequest(title: "New Section", message: "Enter a name for this section.", confirm: "Create") { name in
            library.addSection(notebookId: notebookId, title: name)
        }
    }

    private func rename(_ section: SectionInfo) {
        nameRequest = NameRequest(title: "Rename Section", initial: section.title) { name in
            library.renameSection(notebookId: notebookId, sectionId: section.id, title: name)
        }
    }

    private func delete(_ section: SectionInfo) {
        let count = library.notebook(notebookId)?.pages(in: section.id).count ?? 0
        let pages = count == 0 ? "The section" : count == 1 ? "The section and its page" : "The section and its \(count) pages"
        deleteRequest = DeleteRequest(
            title: "Delete “\(section.title.isEmpty ? "Untitled Section" : section.title)”?",
            message: "\(pages) will be deleted on all your devices.",
            confirm: "Delete Section"
        ) {
            library.deleteSection(notebookId: notebookId, sectionId: section.id)
        }
    }
}

/// The pages of one section.
struct PageListView: View {
    let library: LibraryModel
    let notebookId: String
    let sectionId: String

    @State private var nameRequest: NameRequest?
    @State private var deleteRequest: DeleteRequest?

    var body: some View {
        let notebook = library.notebook(notebookId)
        let pages = notebook?.pages(in: sectionId) ?? []
        Group {
            if library.search.isActive {
                SearchResultsView(library: library)
            } else {
                list(notebook, pages)
            }
        }
        .navigationTitle(notebook?.section(sectionId).map { $0.title.isEmpty ? "Untitled Section" : $0.title } ?? "")
        .librarySearch(library, isFront: library.path.last == .section(notebookId: notebookId, sectionId: sectionId))
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                EditButton()
                    .disabled(pages.count < 2 || library.search.isActive)
            }
            // The status is text, not a button-shaped thing: no glass capsule around it.
            ToolbarItem(placement: .bottomBar) {
                SyncStatusLine(library: library)
            }
            .sharedBackgroundVisibility(.hidden)
            ToolbarSpacer(.flexible, placement: .bottomBar)
            ToolbarItem(placement: .bottomBar) {
                Button("New Page", systemImage: "square.and.pencil", action: create)
                    .accessibilityIdentifier("new-page")
            }
        }
        .namePrompt($nameRequest)
        .deletePrompt($deleteRequest)
    }

    private func list(_ notebook: LibraryModel.Notebook?, _ pages: [PageInfo]) -> some View {
        List(selection: Binding<String?>(
            get: { library.selectedPage?.notebookId == notebookId ? library.selectedPage?.pageId : nil },
            // Only taps select. The list also clears its selection on its own (entering edit
            // mode); that must not close the open page.
            set: { id in
                if let id {
                    library.select(PageRef(notebookId: notebookId, pageId: id))
                }
            })
        ) {
            ForEach(pages) { page in
                VStack(alignment: .leading, spacing: 2) {
                    Text(Self.title(page))
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                    Text(Self.date(page.updatedAt))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button { delete(page) } label: { Label("Delete", systemImage: "trash") }
                        .tint(.red)
                    Button { rename(page) } label: { Label("Rename", systemImage: "pencil") }
                }
                .contextMenu {
                    Button("Rename", systemImage: "pencil") { rename(page) }
                    let others = (notebook?.sections ?? []).filter { $0.id != sectionId }
                    if !others.isEmpty {
                        Menu("Move to Section", systemImage: "folder") {
                            ForEach(others) { section in
                                Button(section.title.isEmpty ? "Untitled Section" : section.title) {
                                    library.movePage(PageRef(notebookId: notebookId, pageId: page.id), toSection: section.id)
                                }
                            }
                        }
                    }
                    Button("Delete", systemImage: "trash", role: .destructive) { delete(page) }
                }
            }
            .onMove { source, destination in
                library.movePages(notebookId: notebookId, sectionId: sectionId, from: source, to: destination)
            }
        }
        .overlay {
            if pages.isEmpty {
                ContentUnavailableView {
                    Label("No Pages", systemImage: "doc.text")
                } description: {
                    Text("This section is empty.")
                } actions: {
                    Button("New Page", action: create)
                }
            }
        }
    }

    static func title(_ page: PageInfo) -> String {
        page.title.isEmpty ? "Untitled Page" : page.title
    }

    /// Today's pages show the time, older ones the date - the way Notes and Mail do.
    static func date(_ date: Date) -> String {
        Calendar.current.isDateInToday(date)
            ? date.formatted(date: .omitted, time: .shortened)
            : date.formatted(date: .abbreviated, time: .omitted)
    }

    private func create() {
        Task { await library.addPage(notebookId: notebookId, sectionId: sectionId) }
    }

    private func rename(_ page: PageInfo) {
        nameRequest = NameRequest(title: "Rename Page", initial: page.title) { name in
            library.renamePage(PageRef(notebookId: notebookId, pageId: page.id), title: name)
        }
    }

    private func delete(_ page: PageInfo) {
        deleteRequest = DeleteRequest(
            title: "Delete “\(Self.title(page))”?",
            message: "The page will be deleted on all your devices.",
            confirm: "Delete Page"
        ) {
            library.deletePage(PageRef(notebookId: notebookId, pageId: page.id))
        }
    }
}

/// The open page: the editor, or what to show when there is none.
struct PageView: View {
    let library: LibraryModel

    var body: some View {
        Group {
            if let editor = library.editor {
                EditorHost(session: editor)
                    .id(editor.ref)
                    .ignoresSafeArea(.container, edges: .bottom)
            } else if library.selectedPage != nil {
                Color(.systemBackground) // the page's document is being read from the store
                    .ignoresSafeArea()
            } else {
                ContentUnavailableView(
                    "No Page Selected",
                    systemImage: "doc.text",
                    description: Text("Choose a page from the sidebar."))
            }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                SyncStatusButton(library: library)
                MoreMenu(library: library)
            }
        }
    }
}

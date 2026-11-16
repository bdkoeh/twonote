import Foundation
import Observation
import TwoNoteCore
import TwoNoteDocuments
import YrsKit

/// A page and the notebook it lives in.
struct PageRef: Hashable, Sendable {
    var notebookId: String
    var pageId: String
}

/// A place in the navigation hierarchy: notebooks → sections → pages → page.
enum Route: Hashable, Sendable {
    case notebook(String)
    case section(notebookId: String, sectionId: String)
    case page(PageRef)
}

/// The unlocked account as the screens see it: the notebooks with their sections and pages
/// (kept current as changes sync in), where the user is, and the open page.
///
/// The model owns the navigation state rather than the views, so that the compact layout (one
/// stack) and the wide layout (sidebar and page side by side) are two renderings of the same
/// state and switching between them - folding or unfolding the device - loses nothing.
@MainActor
@Observable
final class LibraryModel {
    /// One notebook, read from its tree document.
    struct Notebook: Identifiable, Equatable {
        var id: String
        var title: String
        /// Visible sections in display order.
        var sections: [SectionInfo]
        /// Visible pages by section id, in display order.
        var pages: [String: [PageInfo]]

        var displayTitle: String { title.isEmpty ? "Untitled Notebook" : title }

        func section(_ sectionId: String) -> SectionInfo? {
            sections.first { $0.id == sectionId }
        }

        func pages(in sectionId: String) -> [PageInfo] {
            pages[sectionId] ?? []
        }

        /// A visible page in a visible section.
        func page(_ pageId: String) -> PageInfo? {
            for section in sections {
                if let page = pages[section.id]?.first(where: { $0.id == pageId }) {
                    return page
                }
            }
            return nil
        }
    }

    /// The notebooks, by title. (The protocol gives notebooks no order of their own.)
    private(set) var notebooks: [Notebook] = []
    /// The sidebar's position: empty (notebook list), a notebook (its sections), or a section (its pages).
    private(set) var path: [Route] = []
    /// The page shown in the editor, or nil.
    private(set) var selectedPage: PageRef?
    /// The editor of `selectedPage`, once its document is loaded.
    private(set) var editor: EditorSession?
    /// Something to tell the user (an alert).
    var alert: UserMessage?
    /// Whether the settings sheet is up.
    var showingSettings = false
    /// Something to mention in passing ("2 Shared Items Added"); goes away by itself.
    var notice: Notice?
    /// Set when the search field should take the keyboard (a `twonote://search` link); the
    /// list on screen clears it when it has done so.
    var wantsSearchFocus = false
    /// True while the lists and the page share one navigation stack (the view says which
    /// layout it is in): the page then has to close before a list can be seen.
    #if os(macOS)
    @ObservationIgnored var compactLayout = false // the Mac's three columns
    #else
    @ObservationIgnored var compactLayout = true
    #endif
    /// Called whenever `notebooks` changed.
    @ObservationIgnored var onNotebooksChanged: (() -> Void)?
    /// Counts changes to where shared items go (the choice itself is in the settings store).
    private var shareDestinationRevision = 0
    /// Search across everything in the account. Its page texts exist in memory only.
    @ObservationIgnored private(set) lazy var search = SearchModel(library: self)

    @ObservationIgnored let client: TwoNoteClient
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var trees: [String: YrsNotebookTree] = [:]
    @ObservationIgnored private var closed = false
    @ObservationIgnored private var openGeneration = 0
    @ObservationIgnored private var reloading = false
    @ObservationIgnored private var reloadAgain = false
    @ObservationIgnored private var newPageId: String?
    @ObservationIgnored private var pendingReveal: (ref: PageRef, range: NSRange)?

    private enum Keys {
        static let notebook = "location.notebook"
        static let section = "location.section"
        static let page = "location.page"
        /// The page that was open last, kept after it is closed (for "Continue").
        static let lastPage = "location.lastPage"
    }

    /// A passing remark, and where a tap on it leads.
    struct Notice: Equatable {
        var text: String
        var notebookId: String?
        var sectionId: String?
    }

    init(client: TwoNoteClient, defaults: UserDefaults) {
        self.client = client
        self.defaults = defaults
    }

    // MARK: Loading

    /// Reads the notebooks from the local store and returns to where the user last was.
    func load() async {
        await reloadNotebooks()
        restoreLocation()
        watchNotebookList()
        // Read the page texts for search in the background; the lists do not wait for it.
        Task { [weak self] in await self?.search.refresh() }
    }

    /// Re-reads the set of notebooks when sync says it changed (one arrived, one was deleted).
    private func watchNotebookList() {
        withObservationTracking {
            _ = client.syncMonitor.notebooksRevision
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, !self.closed else { return }
                self.watchNotebookList()
                await self.reloadNotebooks()
            }
        }
    }

    func reloadNotebooks() async {
        if reloading {
            reloadAgain = true
            return
        }
        reloading = true
        defer { reloading = false }
        repeat {
            reloadAgain = false
            for id in client.notebookIds where trees[id] == nil {
                guard let tree = try? await client.openNotebook(id) else { continue }
                if closed { return }
                attach(tree)
            }
            let current = Set(client.notebookIds)
            for id in trees.keys where !current.contains(id) {
                trees[id]?.onChanged = nil
                trees[id] = nil
                notebooks.removeAll { $0.id == id }
                onNotebooksChanged?()
            }
            validateLocation()
        } while reloadAgain && !closed
    }

    private func attach(_ tree: YrsNotebookTree) {
        let id = tree.notebookId
        trees[id] = tree
        // Called after every transaction on the tree, local or synced in. Reading is allowed
        // here; nothing in this path writes to the tree.
        tree.onChanged = { [weak self] _ in
            self?.treeChanged(id)
        }
        treeChanged(id)
    }

    private func treeChanged(_ notebookId: String) {
        guard !closed, let tree = trees[notebookId] else { return }
        let notebook = Notebook(
            id: notebookId, title: tree.title, sections: tree.sections(),
            pages: Dictionary(grouping: tree.allPages(), by: \.sectionId))
        var list = notebooks.filter { $0.id != notebookId }
        list.append(notebook)
        list.sort {
            let order = $0.displayTitle.localizedStandardCompare($1.displayTitle)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
        if list != notebooks {
            notebooks = list
            onNotebooksChanged?()
        }
        validateLocation()
        if let editor, editor.ref.notebookId == notebookId, let page = notebook.page(editor.ref.pageId) {
            editor.titleChanged(to: page.title)
        }
    }

    func notebook(_ id: String) -> Notebook? {
        notebooks.first { $0.id == id }
    }

    /// The tree document of a notebook that is on this device.
    func tree(_ notebookId: String) -> YrsNotebookTree? {
        trees[notebookId]
    }

    /// The notebook that has an entry for this page id, deleted or not, and the entry.
    func pageEntry(_ pageId: String) -> (notebookId: String, page: PageInfo)? {
        for (notebookId, tree) in trees {
            if let page = tree.page(pageId) {
                return (notebookId, page)
            }
        }
        return nil
    }

    /// The section the user chose for shared items, if it still exists; nil means the Inbox
    /// that is made when needed.
    var chosenShareDestination: (notebookId: String, sectionId: String)? {
        _ = shareDestinationRevision
        return ShareDestination.chosen(in: self, defaults: defaults)
    }

    /// "Trip Notes › Inbox".
    var shareDestinationSummary: String {
        _ = shareDestinationRevision
        return ShareDestination.summary(in: self, defaults: defaults)
    }

    /// Sets where shared items go; nil is the default.
    func chooseShareDestination(_ place: (notebookId: String, sectionId: String)?) {
        if let place {
            ShareDestination.choose(notebookId: place.notebookId, sectionId: place.sectionId, defaults: defaults)
        } else {
            ShareDestination.reset(defaults: defaults)
        }
        shareDestinationRevision += 1
    }

    /// The first section of the notebook with this title, made if there is none. Does not
    /// change what is on screen.
    func ensureSection(notebookId: String, title: String) -> String? {
        guard let tree = trees[notebookId] else { return nil }
        return tree.sections().first { $0.title == title }?.id ?? tree.addSection(title: title)
    }

    // MARK: Where the user is

    /// Moves the sidebar and the page selection together (the compact layout's single stack).
    func navigate(to routes: [Route]) {
        var sidebar: [Route] = []
        var page: PageRef?
        for route in routes {
            if case .page(let ref) = route {
                page = ref
            } else {
                sidebar.append(route)
            }
        }
        setPath(sidebar)
        select(page)
    }

    /// Moves the sidebar (the wide layout, where the page stays open beside it).
    func setPath(_ routes: [Route]) {
        let sidebar = routes.filter { if case .page = $0 { false } else { true } }
        guard sidebar != path else { return }
        path = sidebar
        saveLocation()
    }

    /// Opens a page in the editor, or closes the open one with nil.
    func select(_ ref: PageRef?) {
        guard ref != selectedPage else { return }
        closeEditor(save: true)
        selectedPage = ref
        saveLocation()
        guard let ref else { return }
        openGeneration += 1
        let generation = openGeneration
        Task { await open(ref, generation: generation) }
    }

    private func open(_ ref: PageRef, generation: Int) async {
        do {
            let page = try await client.openPage(notebookId: ref.notebookId, pageId: ref.pageId)
            guard !closed, generation == openGeneration, selectedPage == ref, let tree = trees[ref.notebookId] else {
                if selectedPage?.pageId != ref.pageId {
                    client.closePage(ref.pageId) // the user has moved on; a newer open owns the page otherwise
                }
                return
            }
            let title = notebook(ref.notebookId)?.page(ref.pageId)?.title ?? ""
            let session = EditorSession(ref: ref, page: page, tree: tree, title: title, isNew: newPageId == ref.pageId)
            editor = session
            newPageId = nil
            if let reveal = pendingReveal, reveal.ref == ref {
                session.reveal(reveal.range)
            }
            pendingReveal = nil
        } catch {
            guard !closed, generation == openGeneration, selectedPage == ref else { return }
            selectedPage = nil
            saveLocation()
            alert = .generic(error)
        }
    }

    private func closeEditor(save: Bool) {
        guard let editor else { return }
        self.editor = nil
        editor.close(save: save)
        client.closePage(editor.ref.pageId)
    }

    /// Drops whatever the location points at that no longer exists (deleted here or elsewhere).
    private func validateLocation() {
        var valid: [Route] = []
        for route in path {
            switch route {
            case .notebook(let id):
                guard notebook(id) != nil else { break }
                valid.append(route)
                continue
            case .section(let notebookId, let sectionId):
                guard notebook(notebookId)?.section(sectionId) != nil else { break }
                valid.append(route)
                continue
            case .page:
                continue
            }
            break
        }
        var changed = false
        if valid != path {
            path = valid
            changed = true
        }
        if let ref = selectedPage, notebook(ref.notebookId)?.page(ref.pageId) == nil {
            closeEditor(save: false) // the page is gone; there is nothing to stamp
            selectedPage = nil
            openGeneration += 1
            changed = true
        }
        if changed {
            saveLocation()
        }
    }

    private func saveLocation() {
        var notebookId: String?
        var sectionId: String?
        for route in path {
            switch route {
            case .notebook(let id): notebookId = id
            case .section(let id, let section): (notebookId, sectionId) = (id, section)
            case .page: break
            }
        }
        defaults.set(notebookId, forKey: Keys.notebook)
        defaults.set(sectionId, forKey: Keys.section)
        defaults.set(selectedPage.map { $0.notebookId + "/" + $0.pageId }, forKey: Keys.page)
        if let selectedPage {
            defaults.set(selectedPage.notebookId + "/" + selectedPage.pageId, forKey: Keys.lastPage)
        }
    }

    private func storedPage(_ key: String) -> PageRef? {
        guard let parts = defaults.string(forKey: key)?.split(separator: "/"), parts.count == 2 else { return nil }
        return PageRef(notebookId: String(parts[0]), pageId: String(parts[1]))
    }

    private func restoreLocation() {
        if let notebookId = defaults.string(forKey: Keys.notebook), let notebook = notebook(notebookId) {
            var routes: [Route] = [.notebook(notebookId)]
            if let sectionId = defaults.string(forKey: Keys.section), notebook.section(sectionId) != nil {
                routes.append(.section(notebookId: notebookId, sectionId: sectionId))
            }
            path = routes
        }
        if let parts = defaults.string(forKey: Keys.page)?.split(separator: "/"), parts.count == 2 {
            let ref = PageRef(notebookId: String(parts[0]), pageId: String(parts[1]))
            if notebook(ref.notebookId)?.page(ref.pageId) != nil {
                select(ref)
            }
        }
        saveLocation()
    }

    static func forgetLocation(in defaults: UserDefaults) {
        for key in [Keys.notebook, Keys.section, Keys.page, Keys.lastPage] {
            defaults.removeObject(forKey: key)
        }
    }

    // MARK: Notebooks

    /// Creates a notebook and shows it. Works offline.
    func createNotebook(title: String) async {
        do {
            let tree = try await client.createNotebook(title: title)
            guard !closed else { return }
            attach(tree)
            setPath([.notebook(tree.notebookId)])
        } catch {
            alert = .generic(error)
        }
    }

    func renameNotebook(_ notebookId: String, title: String) {
        trees[notebookId]?.setTitle(title)
    }

    /// Goes to a search result: a notebook's sections, a section's pages, or a page - opened
    /// and scrolled to the match. Ends the search.
    func open(_ hit: SearchHit) {
        search.query = ""
        switch hit.target {
        case .notebook(let id):
            guard notebook(id) != nil else { return }
            setPath([.notebook(id)])
        case .section(let notebookId, let sectionId):
            guard notebook(notebookId)?.section(sectionId) != nil else { return }
            setPath([.notebook(notebookId), .section(notebookId: notebookId, sectionId: sectionId)])
        case .page(let ref):
            guard let page = notebook(ref.notebookId)?.page(ref.pageId) else { return }
            setPath([.notebook(ref.notebookId), .section(notebookId: ref.notebookId, sectionId: page.sectionId)])
            if let editor, editor.ref == ref {
                if let range = hit.textMatch { editor.reveal(range) }
            } else {
                pendingReveal = hit.textMatch.map { (ref, $0) }
                select(ref)
            }
        }
    }

    /// Shows a page in its section's list and opens it. False if the page is not there (any more).
    @discardableResult
    func show(_ ref: PageRef) -> Bool {
        guard let page = notebook(ref.notebookId)?.page(ref.pageId) else { return false }
        setPath([.notebook(ref.notebookId), .section(notebookId: ref.notebookId, sectionId: page.sectionId)])
        select(ref)
        return true
    }

    /// Does what a `twonote://` link asks for (a widget button, mostly). Whatever is in the
    /// way - Settings, a search - is put away first.
    func perform(_ link: DeepLink) async {
        guard !closed else { return }
        showingSettings = false
        search.query = ""
        switch link {
        case .newNote:
            guard let place = sectionForNewPage() else {
                alert = UserMessage(title: "No Notebooks Yet", detail: "Create a notebook first. New pages go into one of its sections.")
                return
            }
            setPath([.notebook(place.notebookId), .section(notebookId: place.notebookId, sectionId: place.sectionId)])
            await addPage(notebookId: place.notebookId, sectionId: place.sectionId)
        case .search:
            if compactLayout {
                select(nil)
            }
            wantsSearchFocus = true
        case .continueLast:
            if selectedPage == nil, let last = storedPage(Keys.lastPage) {
                show(last)
            }
        case .page(let notebookId, let pageId):
            show(PageRef(notebookId: notebookId, pageId: pageId))
        }
    }

    /// Where a page made from outside the lists goes: the section that is on screen, else the
    /// section of the page that was open last, else where shared items go.
    private func sectionForNewPage() -> (notebookId: String, sectionId: String)? {
        for route in path.reversed() {
            if case .section(let notebookId, let sectionId) = route, notebook(notebookId)?.section(sectionId) != nil {
                return (notebookId, sectionId)
            }
        }
        for ref in [selectedPage, storedPage(Keys.lastPage)].compactMap({ $0 }) {
            if let page = notebook(ref.notebookId)?.page(ref.pageId) {
                return (ref.notebookId, page.sectionId)
            }
        }
        return ShareDestination.resolve(in: self, defaults: defaults)
    }

    /// Why the notebook cannot be deleted right now, or nil if it can. Deleting removes the
    /// notebook from the server and, through it, from every device, so it needs the server -
    /// except for a notebook that was made on this device and has not been sent yet.
    func deleteNotebookObstacle(_ notebookId: String) async -> UserMessage? {
        let status = client.syncMonitor.status
        guard status.state == .offline || !status.running else { return nil }
        return await client.isNotebookOnServer(notebookId) ? .deleteNotebookOffline : nil
    }

    /// Deletes a notebook for good, on the server and on every device. Needs the server
    /// (unless the notebook never got there).
    func deleteNotebook(_ notebookId: String) async {
        do {
            try await client.deleteNotebook(notebookId)
            await reloadNotebooks()
        } catch {
            alert = .deleteNotebookFailure(error)
        }
    }

    // MARK: Sections

    /// Adds a section at the end of the notebook and shows it.
    @discardableResult
    func addSection(notebookId: String, title: String) -> String? {
        guard let tree = trees[notebookId] else { return nil }
        let id = tree.addSection(title: title)
        setPath([.notebook(notebookId), .section(notebookId: notebookId, sectionId: id)])
        return id
    }

    func renameSection(notebookId: String, sectionId: String, title: String) {
        trees[notebookId]?.renameSection(sectionId, title: title)
    }

    /// Hides a section and its pages on every device (a flag in the notebook; works offline).
    func deleteSection(notebookId: String, sectionId: String) {
        trees[notebookId]?.setSectionDeleted(sectionId)
    }

    /// A list's drag-to-reorder: `source` and `destination` as SwiftUI's `onMove` reports them.
    func moveSections(notebookId: String, from source: IndexSet, to destination: Int) {
        guard let tree = trees[notebookId], let notebook = notebook(notebookId) else { return }
        for step in Self.moveSteps(notebook.sections.map(\.id), from: source, to: destination) {
            tree.moveSection(step.id, to: step.index)
        }
    }

    // MARK: Pages

    /// Adds an untitled page at the end of the section and opens it. Works offline.
    func addPage(notebookId: String, sectionId: String) async {
        do {
            let page = try await client.createPage(notebookId: notebookId, sectionId: sectionId, title: "")
            guard !closed else { return }
            newPageId = page.docId
            select(PageRef(notebookId: notebookId, pageId: page.docId))
        } catch {
            alert = .generic(error)
        }
    }

    func renamePage(_ ref: PageRef, title: String) {
        trees[ref.notebookId]?.renamePage(ref.pageId, title: title)
    }

    /// Hides a page on every device (a flag in the notebook; works offline).
    func deletePage(_ ref: PageRef) {
        trees[ref.notebookId]?.setPageDeleted(ref.pageId)
    }

    func movePages(notebookId: String, sectionId: String, from source: IndexSet, to destination: Int) {
        guard let tree = trees[notebookId], let notebook = notebook(notebookId) else { return }
        for step in Self.moveSteps(notebook.pages(in: sectionId).map(\.id), from: source, to: destination) {
            tree.movePage(step.id, toSection: sectionId, at: step.index)
        }
    }

    /// Moves a page to the end of another section of its notebook.
    func movePage(_ ref: PageRef, toSection sectionId: String) {
        trees[ref.notebookId]?.movePage(ref.pageId, toSection: sectionId, at: nil)
    }

    /// Turns a list move into single moves for the tree, whose index counts the *other* items.
    /// Each step places one moved item directly after the item that precedes it in the result.
    nonisolated static func moveSteps(_ ids: [String], from source: IndexSet, to destination: Int) -> [(id: String, index: Int)] {
        let moved = source.filter { $0 < ids.count }.map { ids[$0] }
        guard !moved.isEmpty else { return [] }
        var result = ids.enumerated().filter { !source.contains($0.offset) }.map(\.element)
        let insertAt = min(max(destination - source.filter { $0 < destination }.count, 0), result.count)
        result.insert(contentsOf: moved, at: insertAt)
        guard result != ids else { return [] }

        var steps: [(id: String, index: Int)] = []
        var current = ids
        for id in moved {
            current.removeAll { $0 == id }
            let position = result.firstIndex(of: id) ?? 0
            let index = position == 0 ? 0 : (current.firstIndex(of: result[position - 1]) ?? -1) + 1
            current.insert(id, at: index)
            steps.append((id, index))
        }
        return steps
    }

    // MARK: Saving and closing

    /// Hands everything typed so far to the documents (and with that to the local store).
    func flush() {
        editor?.flush()
    }

    /// Closes the open page and lets go of every document. Called when the account locks.
    func shutdown() {
        guard !closed else { return }
        closeEditor(save: true)
        closed = true
        onNotebooksChanged = nil
        notice = nil
        wantsSearchFocus = false
        search.clear()
        pendingReveal = nil
        for tree in trees.values {
            tree.onChanged = nil
        }
        trees = [:]
        notebooks = []
        path = []
        selectedPage = nil
    }
}

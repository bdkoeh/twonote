import Foundation
import Observation
import TwoNoteDocuments
import TwoNoteEditor

/// What the main window is asked to show by something outside it (a menu command): a prompt,
/// the search field, a confirmation. One per app, since the app has one main window.
@MainActor
@Observable
final class WindowRequests {
    var nameRequest: NameRequest?
    var deleteRequest: DeleteRequest?
    var linkRequest: LinkRequest?
    /// Counts the times the search field was asked for (⌥⌘F); the window focuses it on change.
    var searchFocusRequests = 0
    /// Opens the main window again after it was closed (a link arrived meanwhile); set by the
    /// window's content, which has SwiftUI's action for it.
    @ObservationIgnored var openMainWindow: (() -> Void)?
}

/// The page link sheet's input.
struct LinkRequest: Identifiable {
    let id = UUID()
    var url: String
    var selection: Range<Int>
    var hadLink: Bool
}

/// Which menu commands can run right now and which are ticked. Worked out from the app's state
/// alone, so it can be tested without menus.
@MainActor
struct MenuState {
    var unlocked = false
    /// The section new pages go into: the one shown, else the open page's.
    var sectionForNewPage: (notebookId: String, sectionId: String)?
    /// The notebook new sections go into.
    var notebookForNewSection: String?
    /// The open page, once its editor is up.
    var page: PageRef?
    /// What the selection has (nil without an open page).
    var current: PageTextBinding.Formatting?

    init(app: AppModel?) {
        guard let app, app.phase == .unlocked, let library = app.library else { return }
        unlocked = true
        for route in library.path.reversed() {
            if case .section(let notebookId, let sectionId) = route, library.notebook(notebookId)?.section(sectionId) != nil {
                sectionForNewPage = (notebookId, sectionId)
                break
            }
        }
        if sectionForNewPage == nil, let ref = library.selectedPage, let info = library.notebook(ref.notebookId)?.page(ref.pageId) {
            sectionForNewPage = (ref.notebookId, info.sectionId)
        }
        for route in library.path {
            if case .notebook(let id) = route, library.notebook(id) != nil {
                notebookForNewSection = id
            }
        }
        if notebookForNewSection == nil {
            notebookForNewSection = library.selectedPage?.notebookId
        }
        if let editor = library.editor {
            page = editor.ref
            current = editor.formatting
        }
    }

    var canNewPage: Bool { sectionForNewPage != nil }
    var canNewSection: Bool { notebookForNewSection != nil }
    var canNewNotebook: Bool { unlocked }
    var canLock: Bool { unlocked }
    var canFormat: Bool { page != nil && current != nil }
    var canDeletePage: Bool { page != nil }
    var canSearch: Bool { unlocked }
    var canIndent: Bool { (current?.block.indent ?? PageAttribute.maxIndent) < PageAttribute.maxIndent }
    var canOutdent: Bool { (current?.block.indent ?? 0) > 0 }
    var canToggleChecked: Bool { current?.block.block == "todo" }
    /// The link at the selection.
    var link: String? { current?.inline.link }

    func isOn(_ key: String) -> Bool {
        guard let formatting = current else { return false }
        switch key {
        case PageAttribute.bold: return formatting.inline.bold
        case PageAttribute.italic: return formatting.inline.italic
        case PageAttribute.underline: return formatting.inline.underline
        case PageAttribute.strike: return formatting.inline.strike
        case PageAttribute.code: return formatting.inline.code
        default: return false
        }
    }

    /// Whether the paragraph at the caret has this style (nil: body text).
    func hasBlock(_ block: String?) -> Bool {
        guard let formatting = current else { return false }
        return formatting.block.block == block
    }
}

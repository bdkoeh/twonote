import AppKit
import Foundation
import Observation
import TwoNoteDocuments
import TwoNoteEditor
import YrsKit

/// One open page on the Mac: the synced document, the text view bound to it and the title
/// field. Lives exactly as long as the page is selected. The same interface the iPhone's
/// session offers `LibraryModel` (which is compiled unchanged for both).
///
/// The session owns the AppKit views; SwiftUI only gives them a place in the window, so the
/// text, selection, scroll position and keyboard focus survive the window's layout changing.
@MainActor
@Observable
final class EditorSession {
    /// Quiet time after the last keystroke before the page's "last edited" time is updated.
    nonisolated(unsafe) static var touchDebounce: TimeInterval = 2
    /// Shortest time between two such updates while typing goes on.
    nonisolated(unsafe) static var touchInterval: TimeInterval = 30

    @ObservationIgnored let ref: PageRef
    @ObservationIgnored let page: YrsPageDocument
    @ObservationIgnored let host: PageEditorView
    @ObservationIgnored let binding: PageTextBinding

    /// What the toolbar and the Format menu show for the selection.
    private(set) var formatting: PageTextBinding.Formatting
    /// When the page was last edited (shown above its title).
    private(set) var updatedAt: Date?

    @ObservationIgnored private let tree: YrsNotebookTree
    @ObservationIgnored private var observation: ChangeObservation?
    @ObservationIgnored private var edited = false
    @ObservationIgnored private var lastTouch = Date.distantPast
    @ObservationIgnored private var touchTask: Task<Void, Never>?
    @ObservationIgnored private var closed = false

    var textView: EditorTextView { host.textView }

    init(ref: PageRef, page: YrsPageDocument, tree: YrsNotebookTree, title: String, isNew: Bool) {
        self.ref = ref
        self.page = page
        self.tree = tree
        host = PageEditorView()
        binding = PageTextBinding(textView: host.textView, page: page)
        formatting = binding.formatting
        host.titleField.stringValue = title
        updatedAt = tree.page(ref.pageId)?.updatedAt
        host.showDate(updatedAt)
        host.onTitleCommit = { [weak self] in self?.commitTitle() }
        binding.onStateChange = { [weak self] in self?.refreshFormatting() }
        refreshFormatting()
        host.focusWhenShown(isNew ? .title : .body)
        // Runs inside the page's change notification, so nothing here may edit the page; the
        // tree is only written later, from the debounce task.
        observation = page.observeText { [weak self] change in
            if change.source != .remote {
                self?.pageEdited()
            }
        }
    }

    func refreshFormatting() {
        let now = binding.formatting
        if now != formatting { formatting = now }
    }

    /// The title was changed somewhere (here, or on another device), or the page's entry
    /// changed in its notebook (its "last edited" time).
    func titleChanged(to title: String) {
        let date = tree.page(ref.pageId)?.updatedAt
        if date != updatedAt {
            updatedAt = date
            host.showDate(date)
        }
        guard !host.isEditingTitle, host.titleField.stringValue != title else { return }
        host.titleField.stringValue = title
    }

    /// Scrolls to a range of the page's text and marks it for a moment (a search result).
    func reveal(_ range: NSRange) {
        guard !closed else { return }
        host.revealWhenShown(range, binding: binding)
    }

    func commitTitle() {
        guard !closed, let entry = tree.page(ref.pageId), !entry.deleted else { return }
        let title = host.titleField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if title != entry.title {
            tree.renamePage(ref.pageId, title: title) // also stamps "last edited"
            edited = false
            lastTouch = Date()
        }
    }

    private func pageEdited() {
        edited = true
        touchTask?.cancel()
        let wait = max(Self.touchDebounce, Self.touchInterval - Date().timeIntervalSince(lastTouch))
        touchTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            guard !Task.isCancelled else { return }
            self?.touchIfEdited()
        }
    }

    private func touchIfEdited() {
        guard edited, !closed else { return }
        edited = false
        lastTouch = Date()
        if let entry = tree.page(ref.pageId), !entry.deleted {
            tree.touchPage(ref.pageId)
        }
    }

    /// Hands everything the views hold to the documents now: text the binding has not read
    /// yet, a title still being typed, and the pending "last edited" stamp.
    func flush() {
        guard !closed else { return }
        binding.syncLocal()
        commitTitle()
        touchTask?.cancel()
        touchTask = nil
        touchIfEdited()
    }

    /// Stops following the page and takes the views off screen. `save` is false when the page
    /// no longer exists.
    func close(save: Bool) {
        guard !closed else { return }
        if save {
            flush()
        }
        closed = true
        touchTask?.cancel()
        observation?.cancel()
        observation = nil
        binding.onStateChange = nil
        binding.detach()
        host.onTitleCommit = nil
        host.tearDown()
    }

    // MARK: Commands (toolbar and Format menu)

    func toggle(_ key: String) {
        binding.toggleInline(key)
        refreshFormatting()
    }

    /// A paragraph style: choosing the one the paragraph has turns it back into body text.
    func chooseBlock(_ block: String?) {
        if let block, block == formatting.block.block {
            binding.setBlock(nil)
        } else {
            binding.setBlock(block)
        }
        refreshFormatting()
    }

    func indent(by delta: Int) {
        binding.indent(by: delta)
        refreshFormatting()
    }

    /// Ticks or unticks the to-do the caret is in.
    func toggleChecked() {
        binding.toggleChecked(paragraphAt: binding.selectedRange.lowerBound)
        refreshFormatting()
    }

    /// Adds, changes or (with an empty address) removes the link at the selection. With a
    /// caret outside a link, the address is inserted as its own text.
    func applyLink(_ address: String, selection: Range<Int>, hadLink: Bool) {
        let url = address.trimmingCharacters(in: .whitespacesAndNewlines)
        if url.isEmpty {
            binding.setLink(nil, in: selection)
        } else if selection.isEmpty && !hadLink {
            binding.textView.setSelectedRange(NSRange(location: selection.lowerBound, length: 0))
            binding.insertLink(text: url, url: url)
        } else {
            binding.setLink(url, in: selection)
        }
        refreshFormatting()
    }

    func focusText() {
        host.focusWhenShown(.body)
    }
}

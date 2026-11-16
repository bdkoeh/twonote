import Foundation
import TwoNoteDocuments
import TwoNoteEditor
import UIKit
import YrsKit

/// One open page: the synced document, the text view bound to it, the title field and the
/// formatting bar. Lives exactly as long as the page is selected.
///
/// The session owns the UIKit views; SwiftUI only gives them a place on screen. When the
/// layout changes between the compact stack and the wide split view (the device folds or
/// unfolds), SwiftUI builds a new hierarchy, and the same text view moves into it with its
/// text, selection, scroll position and keyboard focus.
@MainActor
final class EditorSession {
    /// Quiet time after the last keystroke before the page's "last edited" time is updated.
    static var touchDebounce: TimeInterval = 2
    /// Shortest time between two such updates while typing goes on.
    static var touchInterval: TimeInterval = 30

    let ref: PageRef
    let page: YrsPageDocument
    let host: EditorHostView
    let binding: PageTextBinding

    private let tree: YrsNotebookTree
    let formatBar: FormatBar
    private var observation: ChangeObservation?
    private var edited = false
    private var lastTouch = Date.distantPast
    private var touchTask: Task<Void, Never>?
    private var closed = false

    var textView: EditorTextView { host.textView }

    init(ref: PageRef, page: YrsPageDocument, tree: YrsNotebookTree, title: String, isNew: Bool) {
        self.ref = ref
        self.page = page
        self.tree = tree
        host = EditorHostView()
        binding = PageTextBinding(textView: host.textView, page: page)
        formatBar = FormatBar(binding: binding)
        host.textView.inputAccessoryView = formatBar.toolbar
        host.titleField.text = title
        host.onTitleCommit = { [weak self] in self?.commitTitle() }
        if isNew {
            host.focusWhenShown(.title)
        }
        // Runs inside the page's change notification, so nothing here may edit the page; the
        // tree is only written later, from the debounce task.
        observation = page.observeText { [weak self] change in
            if change.source != .remote {
                self?.pageEdited()
            }
        }
    }

    /// The title was changed somewhere (here, or on another device).
    func titleChanged(to title: String) {
        guard !host.titleField.isFirstResponder, host.titleField.text != title else { return }
        host.titleField.text = title
    }

    /// Scrolls to a range of the page's text and marks it for a moment (a search result).
    func reveal(_ range: NSRange) {
        guard !closed else { return }
        host.revealWhenShown(range)
    }

    private func commitTitle() {
        guard !closed, let entry = tree.page(ref.pageId), !entry.deleted else { return }
        let title = (host.titleField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
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
        host.endEditing(true)
        host.removeFromSuperview()
    }
}

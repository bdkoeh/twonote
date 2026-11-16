import AppKit
import SwiftUI
import TwoNoteEditor

/// The editor's views on the Mac: the page text view in its scroll view, with the "last
/// edited" line and the title field at the top of the scrolling content, the way Notes puts
/// the date above the note.
final class PageEditorView: NSView, NSTextFieldDelegate {
    enum Focus {
        case title
        case body
    }

    let textView = EditorTextView()
    let scrollView: NSScrollView
    let titleField = NSTextField()
    let dateLabel = NSTextField(labelWithString: "")
    /// The title field finished editing (or the page is being saved).
    var onTitleCommit: (() -> Void)?

    private var focusOnShow: Focus?
    private var revealOnShow: (range: NSRange, binding: PageTextBinding)?
    private var highlightTask: Task<Void, Never>?
    private let side: CGFloat = 28
    private let top: CGFloat = 14

    init() {
        scrollView = textView.scrollable()
        super.init(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        scrollView.frame = bounds
        scrollView.autoresizingMask = [.width, .height]
        addSubview(scrollView)

        dateLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        dateLabel.textColor = .secondaryLabelColor
        dateLabel.alignment = .center
        dateLabel.setAccessibilityIdentifier("page-date")
        textView.addSubview(dateLabel)

        titleField.font = .systemFont(ofSize: 24, weight: .bold)
        titleField.placeholderString = "Title"
        titleField.isBordered = false
        titleField.drawsBackground = false
        titleField.focusRingType = .none
        titleField.usesSingleLineMode = true
        titleField.lineBreakMode = .byTruncatingTail
        titleField.cell?.isScrollable = true
        titleField.delegate = self
        titleField.setAccessibilityIdentifier("page-title")
        titleField.setAccessibilityLabel("Title")
        textView.addSubview(titleField)

        let titleHeight = ceil(titleField.intrinsicContentSize.height)
        // NSTextView's inset is the same at the top and the bottom; the room at the bottom
        // lets the last line scroll up from the window's edge.
        textView.textContainerInset = NSSize(width: side - 5, height: top + 18 + titleHeight + 10)
        layoutHeader()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("PageEditorView is created in code")
    }

    var isEditingTitle: Bool {
        guard let editor = titleField.currentEditor() else { return false }
        return window?.firstResponder === editor
    }

    func showDate(_ date: Date?) {
        dateLabel.stringValue = date.map(Self.format) ?? ""
    }

    /// "15 November 2026 at 09:41", as Notes writes it.
    static func format(_ date: Date) -> String {
        date.formatted(.dateTime.day().month(.wide).year().hour().minute())
    }

    // MARK: Layout

    override func layout() {
        super.layout()
        scrollView.frame = bounds
        layoutHeader()
        applyRevealIfShown()
    }

    private func layoutHeader() {
        let width = max(0, scrollView.contentSize.width - 2 * side)
        dateLabel.frame = NSRect(x: side, y: top, width: width, height: 16)
        let height = ceil(titleField.intrinsicContentSize.height)
        titleField.frame = NSRect(x: side - 2, y: top + 18, width: width + 4, height: height)
    }

    // MARK: Focus

    /// Gives the keyboard to the title or the text as soon as the view is in a window.
    func focusWhenShown(_ focus: Focus) {
        focusOnShow = focus
        applyFocusIfShown()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyFocusIfShown()
        applyRevealIfShown()
    }

    private func applyFocusIfShown() {
        guard window != nil, focusOnShow != nil else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window, let focus = self.focusOnShow else { return }
            self.focusOnShow = nil
            switch focus {
            case .title: window.makeFirstResponder(self.titleField)
            case .body: window.makeFirstResponder(self.textView)
            }
        }
    }

    /// The window's search field or a sheet may have taken the keyboard; give it back.
    func focusBody() {
        window?.makeFirstResponder(textView)
    }

    // MARK: Title field

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.insertNewline(_:)) || selector == #selector(NSResponder.insertTab(_:))
            || selector == #selector(NSResponder.moveDown(_:)) {
            onTitleCommit?()
            window?.makeFirstResponder(self.textView)
            self.textView.setSelectedRange(NSRange(location: 0, length: 0))
            return true
        }
        return false
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        onTitleCommit?()
    }

    // MARK: Showing a search match

    /// Scrolls the range into view, a third of the way down, and tints it for a few seconds.
    func revealWhenShown(_ range: NSRange, binding: PageTextBinding) {
        revealOnShow = (range, binding)
        applyRevealIfShown()
    }

    private func applyRevealIfShown() {
        guard window != nil, bounds.width > 0, revealOnShow != nil else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.window != nil, let reveal = self.revealOnShow else { return }
            self.revealOnShow = nil
            reveal.binding.scrollToShow(reveal.range.location)
            self.highlight(reveal.range)
            self.textView.setSelectedRange(NSRange(location: reveal.range.location, length: 0))
        }
    }

    /// A temporary tint drawn by the layout manager; the text itself is not touched.
    private func highlight(_ range: NSRange) {
        guard range.length > 0, let storage = textView.textStorage, NSMaxRange(range) <= storage.length,
              let manager = textView.textLayoutManager, let content = manager.textContentManager,
              let start = content.location(content.documentRange.location, offsetBy: range.location),
              let end = content.location(start, offsetBy: range.length),
              let textRange = NSTextRange(location: start, end: end) else { return }
        manager.removeRenderingAttribute(.backgroundColor, for: manager.documentRange)
        manager.addRenderingAttribute(.backgroundColor, value: NSColor.findHighlightColor.withAlphaComponent(0.6), for: textRange)
        textView.needsDisplay = true
        highlightTask?.cancel()
        highlightTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, let self, let manager = self.textView.textLayoutManager else { return }
            manager.removeRenderingAttribute(.backgroundColor, for: manager.documentRange)
            self.textView.needsDisplay = true
        }
    }

    /// The page is closed: nothing of it may stay in a window.
    func tearDown() {
        highlightTask?.cancel()
        titleField.delegate = nil
        textView.isEditable = false
        removeFromSuperview()
    }
}

/// Puts an `EditorSession`'s views in the SwiftUI window. The session keeps the views, so a
/// rebuilt layout puts the same text view (with its selection and scroll position) back.
struct EditorHost: NSViewRepresentable {
    let session: EditorSession

    final class Container: NSView {
        weak var editor: PageEditorView?

        func show(_ view: PageEditorView) {
            guard view.superview !== self else { return }
            subviews.forEach { $0.removeFromSuperview() }
            view.frame = bounds
            view.autoresizingMask = [.width, .height]
            addSubview(view)
            editor = view
        }

        func release() {
            if let editor, editor.superview === self {
                editor.removeFromSuperview()
            }
            editor = nil
        }
    }

    func makeNSView(context: Context) -> Container {
        Container()
    }

    func updateNSView(_ container: Container, context: Context) {
        container.show(session.host)
    }

    static func dismantleNSView(_ container: Container, coordinator: ()) {
        container.release()
    }
}

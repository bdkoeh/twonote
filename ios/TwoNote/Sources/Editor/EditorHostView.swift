import SwiftUI
import TwoNoteEditor
import UIKit

/// The editor's views: the page text view, with the title field at the top of its scrolling
/// content (so the title scrolls away with the text instead of taking a fixed strip of a small
/// screen).
final class EditorHostView: UIView, UITextFieldDelegate {
    enum Focus {
        case title
        case body
    }

    let textView = EditorTextView()
    let titleField = UITextField()
    /// The title field finished editing (or the page is being saved).
    var onTitleCommit: (() -> Void)?
    /// The SwiftUI-made containers that want to show this editor (see `EditorHost`).
    let containers = NSHashTable<EditorHost.Container>.weakObjects()

    private var focusOnShow: Focus?
    private var revealOnShow: NSRange?
    private var highlightTask: Task<Void, Never>?
    private var lostFocus: (focus: Focus, at: Date)?
    private var laidOutWidth: CGFloat = 0
    private let bodyTopInset: CGFloat

    init() {
        bodyTopInset = textView.textContainerInset.top
        super.init(frame: .zero)
        backgroundColor = .systemBackground
        textView.accessibilityIdentifier = "page-editor"
        addSubview(textView)

        let base = UIFontDescriptor.preferredFontDescriptor(withTextStyle: .title1)
        titleField.font = UIFont(descriptor: base.withSymbolicTraits(.traitBold) ?? base, size: 0)
        titleField.adjustsFontForContentSizeCategory = true
        titleField.placeholder = "Title"
        titleField.returnKeyType = .next
        titleField.autocapitalizationType = .sentences
        titleField.delegate = self
        titleField.accessibilityIdentifier = "page-title"
        titleField.addTarget(self, action: #selector(titleEditingEnded), for: .editingDidEnd)
        textView.addSubview(titleField)
        NotificationCenter.default.addObserver(
            self, selector: #selector(bodyEditingEnded), name: UITextView.textDidEndEditingNotification, object: textView)

        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (view: EditorHostView, _: UITraitCollection) in
            view.setNeedsLayout()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("EditorHostView is created in code")
    }

    /// Gives the keyboard to the title or the text as soon as the view is on screen.
    func focusWhenShown(_ focus: Focus) {
        focusOnShow = focus
        applyFocusIfShown()
    }

    // MARK: Layout

    override func layoutSubviews() {
        super.layoutSubviews()
        // A new width (rotation, fold, split view) re-wraps the text: keep the line that was
        // at the top of the screen at the top.
        let widthChanged = laidOutWidth > 0 && abs(laidOutWidth - bounds.width) > 0.5
        let anchor = widthChanged ? topAnchor() : nil
        textView.frame = bounds
        layoutTitle()
        laidOutWidth = bounds.width
        if let anchor {
            restore(anchor)
        }
        applyRevealIfShown()
    }

    private func layoutTitle() {
        let side = textView.textContainerInset.left + textView.textContainer.lineFragmentPadding
        let height = ceil(titleField.font?.lineHeight ?? 34) + 8
        titleField.frame = CGRect(x: side, y: bodyTopInset, width: max(0, bounds.width - 2 * side), height: height)
        let top = bodyTopInset + height + 6
        if abs(textView.textContainerInset.top - top) > 0.5 {
            textView.textContainerInset.top = top
        }
    }

    private func topAnchor() -> (position: UITextPosition, offset: CGFloat)? {
        let top = textView.contentOffset.y + textView.adjustedContentInset.top
        guard top > textView.textContainerInset.top else { return nil } // the title is in view: stay at the top
        let point = CGPoint(x: textView.textContainerInset.left + 8, y: top + 1)
        guard let position = textView.closestPosition(to: point) else { return nil }
        return (position, textView.caretRect(for: position).minY - top)
    }

    private func restore(_ anchor: (position: UITextPosition, offset: CGFloat)) {
        textView.layoutIfNeeded()
        let rect = textView.caretRect(for: anchor.position)
        guard !rect.isNull, !rect.isInfinite else { return }
        let inset = textView.adjustedContentInset
        let lowest = max(-inset.top, textView.contentSize.height - textView.bounds.height + inset.bottom)
        let y = min(max(rect.minY - anchor.offset - inset.top, -inset.top), lowest)
        textView.setContentOffset(CGPoint(x: 0, y: y), animated: false)
    }

    // MARK: Keyboard focus across re-hosting

    override func willMove(toWindow newWindow: UIWindow?) {
        super.willMove(toWindow: newWindow)
        if newWindow == nil {
            rememberFocus()
        }
    }

    /// Leaving a view hierarchy takes the keyboard away. If the view comes back (the layout
    /// was rebuilt around it), typing carries on where it was. Call before moving the view.
    func rememberFocus() {
        if textView.isFirstResponder {
            focusOnShow = .body
        } else if titleField.isFirstResponder {
            focusOnShow = .title
        } else if let lostFocus, Date().timeIntervalSince(lostFocus.at) < 2 {
            // The navigation container that is being replaced ended editing a moment before
            // it let go of the view.
            focusOnShow = lostFocus.focus
        }
    }

    @objc private func bodyEditingEnded() {
        lostFocus = (.body, Date())
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        applyFocusIfShown()
        applyRevealIfShown()
    }

    // MARK: Showing a search match

    /// Scrolls the given range of the text into view, a third of the way down, and tints it
    /// for a few seconds - as soon as the view is on screen.
    func revealWhenShown(_ range: NSRange) {
        revealOnShow = range
        applyRevealIfShown()
    }

    private func applyRevealIfShown() {
        guard window != nil, bounds.width > 0, revealOnShow != nil else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.window != nil, let range = self.revealOnShow else { return }
            self.revealOnShow = nil
            self.scroll(to: range)
            self.highlight(range)
            // Text further up is laid out for real only now; a second pass lands exactly.
            DispatchQueue.main.async { [weak self] in
                self?.scroll(to: range)
            }
        }
    }

    private func scroll(to range: NSRange) {
        textView.layoutIfNeeded()
        guard range.location <= textView.textStorage.length,
              let position = textView.position(from: textView.beginningOfDocument, offset: range.location) else { return }
        let rect = textView.caretRect(for: position)
        guard !rect.isNull, !rect.isInfinite else { return }
        let inset = textView.adjustedContentInset
        let visible = textView.bounds.height - inset.top - inset.bottom
        let lowest = max(-inset.top, textView.contentSize.height - textView.bounds.height + inset.bottom)
        let y = min(max(rect.minY - visible / 3 - inset.top, -inset.top), lowest)
        textView.setContentOffset(CGPoint(x: 0, y: y), animated: false)
    }

    /// A temporary tint drawn by the layout manager; the text itself is not touched.
    private func highlight(_ range: NSRange) {
        guard range.length > 0, NSMaxRange(range) <= textView.textStorage.length,
              let manager = textView.textLayoutManager, let content = manager.textContentManager,
              let start = content.location(content.documentRange.location, offsetBy: range.location),
              let end = content.location(start, offsetBy: range.length),
              let textRange = NSTextRange(location: start, end: end) else { return }
        manager.removeRenderingAttribute(.backgroundColor, for: manager.documentRange)
        manager.addRenderingAttribute(.backgroundColor, value: UIColor.systemYellow.withAlphaComponent(0.45), for: textRange)
        textView.setNeedsDisplay()
        highlightTask?.cancel()
        highlightTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, let self, let manager = self.textView.textLayoutManager else { return }
            manager.removeRenderingAttribute(.backgroundColor, for: manager.documentRange)
            self.textView.setNeedsDisplay()
        }
    }

    func applyFocusIfShown() {
        guard window != nil, focusOnShow != nil else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.window != nil, let focus = self.focusOnShow else { return }
            self.focusOnShow = nil
            switch focus {
            case .title: self.titleField.becomeFirstResponder()
            case .body: self.textView.becomeFirstResponder()
            }
        }
    }

    // MARK: Title field

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        textView.becomeFirstResponder()
        return false
    }

    @objc private func titleEditingEnded() {
        lostFocus = (.title, Date())
        onTitleCommit?()
    }
}

/// Puts an `EditorSession`'s views on screen.
///
/// While the layout is being rebuilt SwiftUI may create several of these for the same session
/// and throw some away again, in no particular order. Each container registers its interest
/// in the editor; the editor sits in one of them, and when that one goes away it moves to
/// another that is on screen.
struct EditorHost: UIViewRepresentable {
    let session: EditorSession

    final class Container: UIView {
        private weak var editor: EditorHostView?

        func show(_ view: EditorHostView) {
            if editor !== view {
                release()
                editor = view
                view.containers.add(self)
            }
            adoptIfNeeded()
        }

        /// Takes the editor in, unless another container that is on screen already has it.
        private func adoptIfNeeded() {
            guard let editor, editor.superview !== self else { return }
            if editor.window != nil && window == nil { return }
            editor.frame = bounds
            editor.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            editor.rememberFocus()
            addSubview(editor) // takes it out of the container it was in before, if any
            editor.applyFocusIfShown()
        }

        /// Gives the editor up; another interested container picks it up.
        func release() {
            guard let editor else { return }
            self.editor = nil
            editor.containers.remove(self)
            guard editor.superview === self else { return }
            editor.removeFromSuperview()
            let others = editor.containers.allObjects
            (others.first { $0.window != nil } ?? others.first)?.adoptIfNeeded()
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window != nil {
                adoptIfNeeded()
            }
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            if let editor, editor.superview === self, editor.frame != bounds {
                editor.frame = bounds
            }
        }
    }

    func makeUIView(context: Context) -> Container {
        Container()
    }

    func updateUIView(_ container: Container, context: Context) {
        container.show(session.host)
    }

    static func dismantleUIView(_ container: Container, coordinator: ()) {
        container.release()
    }
}

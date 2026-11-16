#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
import TwoNoteDocuments

/// The text view a `PageTextBinding` drives on the Mac. Always TextKit 2: it is created on an
/// `NSTextLayoutManager`, and nothing here or in the binding touches `layoutManager` (which
/// would make AppKit fall back to TextKit 1 for good).
///
/// Put it in an `NSScrollView` as its document view (`EditorTextView.scrollable()` does that).
public final class EditorTextView: NSTextView {
    weak var binding: PageTextBinding?
    private let contentStorage: NSTextContentStorage
    private let pageUndo = PageUndoManager()

    public init() {
        let content = NSTextContentStorage()
        let layout = NSTextLayoutManager()
        let container = NSTextContainer(size: CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layout.textContainer = container
        content.addTextLayoutManager(layout)
        contentStorage = content
        super.init(frame: CGRect(x: 0, y: 0, width: 400, height: 300), textContainer: container)
        pageUndo.textView = self
        isRichText = true
        importsGraphics = false
        allowsImageEditing = false
        usesFontPanel = false
        usesRuler = false
        usesInspectorBar = false
        allowsUndo = false
        allowsDocumentBackgroundColorChange = false
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        // Links are a page attribute; text the system decides is a link would exist in this view only.
        isAutomaticLinkDetectionEnabled = false
        isAutomaticDataDetectionEnabled = false
        usesFindBar = true
        isIncrementalSearchingEnabled = true
        drawsBackground = true
        backgroundColor = .textBackgroundColor
        textContainerInset = NSSize(width: 18, height: 14)
        isVerticallyResizable = true
        isHorizontallyResizable = false
        autoresizingMask = [.width]
        minSize = NSSize(width: 0, height: 0)
        maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        linkTextAttributes = [
            .foregroundColor: NSColor.linkColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .cursor: NSCursor.pointingHand,
        ]
        setAccessibilityIdentifier("page-editor")
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        fatalError("EditorTextView is created in code")
    }

    /// The text view inside a scroll view set up the way a page editor scrolls.
    public func scrollable() -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true
        scroll.backgroundColor = .textBackgroundColor
        scroll.borderType = .noBorder
        scroll.documentView = self
        frame = CGRect(origin: .zero, size: scroll.contentSize)
        return scroll
    }

    // MARK: Typing: the binding's list rules get the first say

    public override func insertText(_ string: Any, replacementRange: NSRange) {
        if !hasMarkedText(), let text = (string as? String) ?? (string as? NSAttributedString)?.string,
           binding?.handleInsert(text) == true {
            return
        }
        super.insertText(string, replacementRange: replacementRange)
    }

    public override func insertNewline(_ sender: Any?) {
        if binding?.handleInsert("\n") == true { return }
        super.insertNewline(sender)
    }

    public override func insertNewlineIgnoringFieldEditor(_ sender: Any?) {
        if binding?.handleInsert("\n") == true { return }
        super.insertNewlineIgnoringFieldEditor(sender)
    }

    public override func deleteBackward(_ sender: Any?) {
        if binding?.handleDeleteBackward() == true { return }
        super.deleteBackward(sender)
    }

    /// Tab and Shift-Tab indent and outdent the paragraph, as on the iPhone and iPad.
    public override func insertTab(_ sender: Any?) {
        guard let binding else { return super.insertTab(sender) }
        binding.indent(by: 1)
    }

    public override func insertBacktab(_ sender: Any?) {
        guard let binding else { return super.insertBacktab(sender) }
        binding.indent(by: -1)
    }

    public override func unmarkText() {
        super.unmarkText()
        binding?.compositionEnded()
    }

    public override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if binding?.handleClick(at: point) == true { return }
        super.mouseDown(with: event)
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        // The list markers and code backgrounds are drawn by the layout fragments in the
        // appearance of the moment; have them drawn again.
        if let layout = textLayoutManager {
            layout.invalidateLayout(for: layout.documentRange)
            layout.textViewportLayoutController.layoutViewport()
        }
        needsDisplay = true
    }

    // MARK: Plain text only

    /// v1 pages hold no images or tables; pasted and dropped text arrives as plain text.
    public override var readablePasteboardTypes: [NSPasteboard.PasteboardType] { [.string] }

    public override var acceptableDragTypes: [NSPasteboard.PasteboardType] { [.string] }

    public override func paste(_ sender: Any?) {
        guard let text = NSPasteboard.general.string(forType: .string) else { return }
        insertPlainText(text)
    }

    public override func pasteAsPlainText(_ sender: Any?) {
        paste(sender)
    }

    public override func pasteAsRichText(_ sender: Any?) {
        paste(sender)
    }

    /// Replaces the selection with plain text the way typing does (one change, undoable through
    /// the page), but without the typing rules: a pasted line break is a line break.
    public func insertPlainText(_ text: String) {
        replace(selectedRange(), with: TextSanitizer.plainText(text))
        binding?.syncLocal()
    }

    /// A programmatic edit that goes through the text view's change notifications like typing.
    func replace(_ range: NSRange, with text: String) {
        guard let storage = textStorage, NSMaxRange(range) <= storage.length,
              shouldChangeText(in: range, replacementString: text) else { return }
        storage.replaceCharacters(in: range, with: NSAttributedString(string: text, attributes: typingAttributes))
        setSelectedRange(NSRange(location: range.location + (text as NSString).length, length: 0))
        didChangeText()
    }

    /// Takes out what would change attributes behind the page's back (the Font and the
    /// writing-direction panels).
    public override func menu(for event: NSEvent) -> NSMenu? {
        guard let menu = super.menu(for: event) else { return nil }
        let unwanted: Set<String> = ["orderFrontFontPanel:", "changeLayoutOrientation:", "makeBaseWritingDirectionNatural:",
                                     "makeTextWritingDirectionNatural:", "toggleRuler:"]
        for item in menu.items.reversed() {
            let actions = (item.submenu?.items ?? []).compactMap { $0.action.map(NSStringFromSelector) }
                + [item.action.map(NSStringFromSelector)].compactMap { $0 }
            if actions.contains(where: unwanted.contains) {
                menu.removeItem(item)
            }
        }
        while let first = menu.items.first, first.isSeparatorItem { menu.removeItem(first) }
        return menu
    }

    // MARK: Undo belongs to the page

    /// Native undo would also take back other devices' edits; undo belongs to the page.
    public override var undoManager: UndoManager? { pageUndo }

    @objc public func undo(_ sender: Any?) {
        binding?.undo()
    }

    @objc public func redo(_ sender: Any?) {
        binding?.redo()
    }

    public override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case #selector(undo(_:)): return isEditable && (binding?.page.canUndo ?? false)
        case #selector(redo(_:)): return isEditable && (binding?.page.canRedo ?? false)
        case #selector(paste(_:)), #selector(pasteAsPlainText(_:)), #selector(pasteAsRichText(_:)):
            return isEditable && NSPasteboard.general.string(forType: .string) != nil
        default: return super.validateUserInterfaceItem(item)
        }
    }
}

/// What the system's undo menu items talk to: it registers nothing and forwards to the page.
final class PageUndoManager: UndoManager {
    weak var textView: EditorTextView?

    override init() {
        super.init()
        disableUndoRegistration()
    }

    override var canUndo: Bool { textView?.binding?.page.canUndo ?? false }
    override var canRedo: Bool { textView?.binding?.page.canRedo ?? false }
    override func undo() { textView?.binding?.undo() }
    override func redo() { textView?.binding?.redo() }
}
#endif

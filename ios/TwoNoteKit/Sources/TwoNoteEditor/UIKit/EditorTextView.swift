#if canImport(UIKit)
import UIKit
import TwoNoteDocuments

/// The text view a `PageTextBinding` drives. Always TextKit 2: it is created on an
/// `NSTextLayoutManager`, and nothing here or in the binding touches `layoutManager` (which
/// would make UIKit fall back to TextKit 1 for good).
public final class EditorTextView: UITextView {
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
        super.init(frame: .zero, textContainer: container)
        pageUndo.textView = self
        allowsEditingTextAttributes = false
        alwaysBounceVertical = true
        keyboardDismissMode = .interactive
        backgroundColor = .systemBackground
        textContainerInset = UIEdgeInsets(top: 12, left: 12, bottom: 24, right: 12)
        smartDashesType = .no
        smartQuotesType = .no
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        fatalError("EditorTextView is created in code")
    }

    // Typing funnels through these two; the binding's list rules get the first say.
    public override func insertText(_ text: String) {
        if binding?.handleInsert(text) == true { return }
        super.insertText(text)
    }

    public override func deleteBackward() {
        if binding?.handleDeleteBackward() == true { return }
        super.deleteBackward()
    }

    /// Plain text only (v1 pages hold no images or tables). Rich paste would parse the
    /// pasteboard's attributed string or HTML into paragraphs and runs and insert them with
    /// their page attributes; nothing in the binding prevents that.
    public override func paste(_ sender: Any?) {
        guard let text = UIPasteboard.general.string else { return }
        insertPlainText(text)
    }

    public func insertPlainText(_ text: String) {
        guard let range = selectedTextRange else { return }
        replace(range, withText: TextSanitizer.plainText(text))
        binding?.syncLocal()
    }

    public override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(paste(_:)) { return isEditable && UIPasteboard.general.hasStrings }
        return super.canPerformAction(action, withSender: sender)
    }

    /// Native undo would also take back other devices' edits; undo belongs to the page.
    public override var undoManager: UndoManager? { pageUndo }

    public override var keyCommands: [UIKeyCommand]? {
        func command(_ input: String, _ flags: UIKeyModifierFlags, _ action: Selector) -> UIKeyCommand {
            let command = UIKeyCommand(input: input, modifierFlags: flags, action: action)
            command.wantsPriorityOverSystemBehavior = true
            return command
        }
        return [
            command("z", .command, #selector(keyUndo)),
            command("z", [.command, .shift], #selector(keyRedo)),
            command("b", .command, #selector(keyBold)),
            command("i", .command, #selector(keyItalic)),
            command("u", .command, #selector(keyUnderline)),
            command("\t", [], #selector(keyIndent)),
            command("\t", .shift, #selector(keyOutdent)),
        ]
    }

    @objc private func keyUndo() { binding?.undo() }
    @objc private func keyRedo() { binding?.redo() }
    @objc private func keyBold() { binding?.toggleInline(PageAttribute.bold) }
    @objc private func keyItalic() { binding?.toggleInline(PageAttribute.italic) }
    @objc private func keyUnderline() { binding?.toggleInline(PageAttribute.underline) }
    @objc private func keyIndent() { binding?.indent(by: 1) }
    @objc private func keyOutdent() { binding?.indent(by: -1) }
}

/// What the system's undo gestures and menus talk to: it registers nothing and forwards to the page.
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

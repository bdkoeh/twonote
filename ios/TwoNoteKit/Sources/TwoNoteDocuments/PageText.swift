// The page text as an editor sees it (PROTOCOL.md 5.2): one rich-text stream, inline formatting
// as attributes on character runs, block formatting as attributes on the newline that ends
// each paragraph. Every index and length is in UTF-16 code units, the same as NSString.
//
// The real implementation is the Yjs page document; editors and tests depend only on these
// protocols, so they can also run against an in-memory stand-in.

/// A value an attribute can hold. Numbers are always doubles on the wire.
public enum AttributeValue: Equatable, Hashable, Sendable {
    case bool(Bool)
    case string(String)
    case number(Double)
}

/// Attributes that are set. An attribute that is not set is simply absent.
public typealias Attributes = [String: AttributeValue]

/// A change to attributes: a value sets the attribute, `nil` removes it; keys not mentioned are
/// left alone (including ones this client does not know).
public typealias AttributeChanges = [String: AttributeValue?]

/// The attribute names and block values of PROTOCOL.md 5.2.
public enum PageAttribute {
    public static let bold = "bold"
    public static let italic = "italic"
    public static let underline = "underline"
    public static let strike = "strike"
    public static let code = "code"
    /// Inline: link target (URL string).
    public static let link = "link"
    /// On a newline: the block type of the paragraph it ends; absent means plain paragraph.
    public static let block = "block"
    /// On a newline: indent level 0-8, a number.
    public static let indent = "indent"
    /// On a newline: whether a `todo` block is ticked.
    public static let checked = "checked"

    public static let inlineKeys = [bold, italic, underline, strike, code, link]
    public static let blockKeys = [block, indent, checked]
    /// The block values a v1 client understands.
    public static let blockTypes = ["h1", "h2", "h3", "ul", "ol", "todo", "code"]
    public static let maxIndent = 8
}

/// A run of text that shares one set of attributes.
public struct TextRun: Equatable, Sendable {
    public var text: String
    public var attributes: Attributes

    public init(text: String, attributes: Attributes = [:]) {
        self.text = text
        self.attributes = attributes
    }
}

/// One Quill-style delta operation.
public enum DeltaOp: Equatable, Sendable {
    /// Skip `count` code units, applying the attribute changes to them if there are any.
    case retain(count: Int, attributes: AttributeChanges?)
    /// Insert text with exactly these attributes.
    case insert(text: String, attributes: Attributes)
    /// Delete `count` code units.
    case delete(count: Int)
}

/// Who caused a change.
public enum ChangeSource: Equatable, Sendable {
    /// An edit made through `PageText.edit`.
    case local
    /// An update from another device (or loaded from the local store).
    case remote
    /// Undo or redo of this device's own edits.
    case undo
}

/// A change to the page text: the delta that turns the previous text into the current one.
public struct TextChange: Equatable, Sendable {
    public var delta: [DeltaOp]
    public var source: ChangeSource

    public init(delta: [DeltaOp], source: ChangeSource) {
        self.delta = delta
        self.source = source
    }
}

/// Keeps an observation alive; release it (or call `cancel`) to stop.
/// (Not called `Observation`: that is the name of the Swift module behind `@Observable`, and a
/// type of the same name shadows it in every file that imports this module.)
public final class ChangeObservation {
    private var onCancel: (() -> Void)?

    public init(_ onCancel: @escaping () -> Void) {
        self.onCancel = onCancel
    }

    public func cancel() {
        onCancel?()
        onCancel = nil
    }

    deinit {
        onCancel?()
    }
}

/// Access to the text during `PageText.edit`. Indexes refer to the text as changed so far
/// within the edit.
@MainActor
public protocol PageTextEditor {
    /// Current length in UTF-16 code units.
    var length: Int { get }
    /// Current text.
    var text: String { get }

    /// Inserts text with exactly the given attributes (nothing is inherited from neighbours).
    /// The position must be before the final newline and must not split a surrogate pair.
    func insert(_ text: String, at index: Int, attributes: Attributes)

    /// Deletes a range. The final newline cannot be deleted; a surrogate pair cannot be split.
    func delete(at index: Int, count: Int)

    /// Sets or removes attributes on a range.
    func format(at index: Int, count: Int, attributes: AttributeChanges)

    /// Changes the block formatting of the paragraph ended by the newline at `newlineIndex`.
    /// `block`, `indent` and `checked` are always written together; defaults are written as removals.
    func setBlock(newlineAt newlineIndex: Int, block: String?, indent: Int, checked: Bool)
}

/// The text of one page. Lives on the main actor: the editor reads and writes it directly, and
/// the sync layer hops to the main actor to merge what arrives.
@MainActor
public protocol PageText: AnyObject {
    /// Length in UTF-16 code units.
    var length: Int { get }
    /// The whole text, every paragraph ending in "\n".
    var text: String { get }
    /// The text as runs of equal attributes, in order. Unknown attributes are included unchanged.
    var runs: [TextRun] { get }

    /// Makes one user edit: everything `body` does is one transaction, one update for the other
    /// devices and (within the capture window) one undo step. If the text does not end in a
    /// newline yet, one is appended first.
    ///
    /// - Important: Must not be called from inside a change handler: not from an `observeText`
    ///   handler of this page, and not from any other callback the page raises while it reports
    ///   a change (for the Yjs page, `onChanged` and `onLocalUpdate`). The handlers run while the
    ///   page is still delivering the change, and the Yjs implementation stops the process with
    ///   a precondition failure when it is re-entered. The same holds for `undo` and `redo`.
    ///   A handler that wants to change the page (or decides to because of what it saw) defers
    ///   the edit to a later turn of the main run loop, e.g. `Task { @MainActor in page.edit … }`.
    ///   Editing a *different* document from a handler is allowed.
    func edit(_ body: (any PageTextEditor) -> Void)

    var canUndo: Bool { get }
    var canRedo: Bool { get }
    /// Undoes this device's latest edit (never another device's). Reported with source `.undo`.
    @discardableResult func undo() -> Bool
    @discardableResult func redo() -> Bool
    /// Closes the current undo step so the next edit starts a new one.
    func breakUndoGroup()

    /// Calls `handler` after every transaction that changed the text, with the delta and its
    /// source. For `.remote` and `.undo` an editor applies the delta to its view; `.local`
    /// changes were made by the editor itself.
    func observeText(_ handler: @escaping @MainActor (TextChange) -> Void) -> ChangeObservation
}

import CYrs
import Foundation
import TwoNoteDocuments

/// The page document of PROTOCOL.md 5.2. v1 pages have one container, `main`, whose text is the
/// root-level Yjs Text `c:main`.
@MainActor
public final class YrsPageDocument: YrsDocument, PageText {
    /// The id of the single container of a v1 page.
    public static let mainContainer = "main"

    private static let embedPlaceholder = "\u{FFFC}"

    /// The root types; set right after `super.init` (they need the document).
    private var roots: (meta: UnsafeMutablePointer<Branch>, containers: UnsafeMutablePointer<Branch>, text: UnsafeMutablePointer<Branch>)!
    nonisolated(unsafe) private var textSubscription: UnsafeMutablePointer<YSubscription>?
    nonisolated(unsafe) private var undoManager: UnsafeMutablePointer<YUndoManager>?
    private var capturedDeltas: [[DeltaOp]] = []
    private var observers: [Int: @MainActor (TextChange) -> Void] = [:]
    private var nextObserverId = 0

    /// Creates an empty replica; fill it with `applyUpdate` or `initialize`.
    /// - Parameter undoCaptureMilliseconds: edits closer together than this merge into one undo step.
    public init(pageId: String, undoCaptureMilliseconds: Int = 500) {
        super.init(docId: pageId)
        setUp(undoCaptureMilliseconds: undoCaptureMilliseconds)
    }

    private func setUp(undoCaptureMilliseconds: Int) {
        roots = (rootMap("meta"), rootMap("containers"), ("c:" + Self.mainContainer).withCString { ytext(doc, $0) })
        textSubscription = ytext_observe(roots.text, Unmanaged.passUnretained(self).toOpaque()) { state, event in
            // Runs inside the commit: copy everything out, the event dies with the callback.
            guard let state, let event else { return }
            let page = Unmanaged<YrsPageDocument>.fromOpaque(state).takeUnretainedValue()
            MainActor.assumeIsolated {
                page.capturedDeltas.append(YrsPageDocument.readDelta(event))
            }
        }
        var options = YUndoManagerOptions(capture_timeout_millis: Int32(undoCaptureMilliseconds))
        undoManager = yundo_manager(doc, &options)
        yundo_manager_add_scope(undoManager, roots.text)
        Self.localOrigin.withCString { yundo_manager_add_origin(undoManager, UInt32(Self.localOrigin.utf8.count), $0) }
    }

    deinit {
        if let undoManager {
            yundo_manager_destroy(undoManager)
        }
        if let textSubscription {
            yunobserve(textSubscription)
        }
    }

    /// Writes what a brand-new page starts with: the format version, the `main` container entry
    /// and the final newline. Only the device that creates the page calls this.
    public func initialize() {
        write(system: true) { txn, arena in
            mapSet(roots.meta, "formatVersion", arena.input(.number(1)), txn, arena)
            mapSet(roots.containers, Self.mainContainer, arena.sharedMap([("kind", arena.input(.string("flow")))]), txn, arena)
            if ytext_len(roots.text, txn) == 0 {
                ytext_insert(roots.text, txn, 0, arena.cString("\n"), arena.pointer(to: arena.object([])))
            }
        }
    }

    // MARK: Reading

    public var text: String {
        read { txn in Self.string(roots.text, txn) }
    }

    public var length: Int {
        read { txn in Int(ytext_len(roots.text, txn)) }
    }

    public var runs: [TextRun] {
        read { txn in
            var count: UInt32 = 0
            guard let chunks = ytext_chunks(roots.text, txn, &count) else { return [] }
            defer { ychunks_destroy(chunks, count) }
            var runs: [TextRun] = []
            for i in 0..<Int(count) {
                let chunk = chunks[i]
                var attributes: Attributes = [:]
                if let format = chunk.fmt {
                    for j in 0..<Int(chunk.fmt_len) {
                        if let key = format[j].key, let value = format[j].value, let attribute = YrsValue(value.pointee).attribute {
                            attributes[String(cString: key)] = attribute
                        }
                    }
                }
                let text = if case .string(let s) = YrsValue(chunk.data) { s } else { Self.embedPlaceholder }
                runs.append(TextRun(text: text, attributes: attributes))
            }
            return runs
        }
    }

    // MARK: Editing

    public func edit(_ body: (any PageTextEditor) -> Void) {
        write { txn, arena in
            var mirror = Array(Self.string(roots.text, txn).utf16)
            if mirror.last != 0x0A {
                ytext_insert(roots.text, txn, UInt32(mirror.count), arena.cString("\n"), arena.pointer(to: arena.object([])))
                mirror.append(0x0A)
            }
            body(Editor(text: roots.text, txn: txn, arena: arena, mirror: mirror))
        }
    }

    @MainActor
    private final class Editor: PageTextEditor {
        private let textBranch: UnsafeMutablePointer<Branch>
        private let txn: OpaquePointer
        private let arena: InputArena
        private var mirror: [UInt16]

        init(text: UnsafeMutablePointer<Branch>, txn: OpaquePointer, arena: InputArena, mirror: [UInt16]) {
            textBranch = text
            self.txn = txn
            self.arena = arena
            self.mirror = mirror
        }

        var length: Int { mirror.count }

        var text: String { String(decoding: mirror, as: UTF16.self) }

        func insert(_ text: String, at index: Int, attributes: Attributes) {
            let units = Array(text.utf16).filter { $0 != 0 } // a C string cannot carry NUL
            guard !units.isEmpty else { return }
            guard index >= 0, index <= mirror.count - 1, isBoundary(index) else {
                assertionFailure("Text is inserted before the final newline, never inside a surrogate pair.")
                return
            }
            let fields = attributes.sorted { $0.key < $1.key }.map { ($0.key, arena.input($0.value)) }
            ytext_insert(textBranch, txn, UInt32(index), arena.cString(String(decoding: units, as: UTF16.self)), arena.pointer(to: arena.object(fields)))
            mirror.insert(contentsOf: units, at: index)
        }

        func delete(at index: Int, count: Int) {
            guard count != 0 else { return }
            guard index >= 0, count > 0, index + count <= mirror.count - 1, isBoundary(index), isBoundary(index + count) else {
                assertionFailure("The range is outside the text, includes the final newline or splits a surrogate pair.")
                return
            }
            ytext_remove_range(textBranch, txn, UInt32(index), UInt32(count))
            mirror.removeSubrange(index..<(index + count))
        }

        func format(at index: Int, count: Int, attributes: AttributeChanges) {
            guard count != 0, !attributes.isEmpty else { return }
            guard index >= 0, count > 0, index + count <= mirror.count, isBoundary(index), isBoundary(index + count) else {
                assertionFailure("The range is outside the text or splits a surrogate pair.")
                return
            }
            let fields = attributes.sorted { $0.key < $1.key }.map { ($0.key, arena.input($0.value)) }
            ytext_format(textBranch, txn, UInt32(index), UInt32(count), arena.pointer(to: arena.object(fields)))
        }

        func setBlock(newlineAt newlineIndex: Int, block: String?, indent: Int, checked: Bool) {
            guard newlineIndex >= 0, newlineIndex < mirror.count, mirror[newlineIndex] == 0x0A,
                  (0...PageAttribute.maxIndent).contains(indent) else {
                assertionFailure("Block attributes belong on the newline that ends the paragraph; indent is 0-8.")
                return
            }
            format(at: newlineIndex, count: 1, attributes: [
                PageAttribute.block: block.map { .string($0) },
                PageAttribute.indent: indent == 0 ? nil : .number(Double(indent)),
                PageAttribute.checked: checked ? .bool(true) : nil,
            ])
        }

        private func isBoundary(_ index: Int) -> Bool {
            guard index > 0, index < mirror.count else { return true }
            return !(UTF16.isLeadSurrogate(mirror[index - 1]) && UTF16.isTrailSurrogate(mirror[index]))
        }
    }

    // MARK: Undo

    public var canUndo: Bool {
        yundo_manager_undo_stack_len(undoManager) > 0
    }

    public var canRedo: Bool {
        yundo_manager_redo_stack_len(undoManager) > 0
    }

    @discardableResult
    public func undo() -> Bool {
        guard canUndo else { return false }
        run(.undo) { _ = yundo_manager_undo(undoManager) }
        return true
    }

    @discardableResult
    public func redo() -> Bool {
        guard canRedo else { return false }
        run(.undo) { _ = yundo_manager_redo(undoManager) }
        return true
    }

    public func breakUndoGroup() {
        yundo_manager_stop(undoManager)
    }

    // MARK: Observation

    public func observeText(_ handler: @escaping @MainActor (TextChange) -> Void) -> ChangeObservation {
        let id = nextObserverId
        nextObserverId += 1
        observers[id] = handler
        return ChangeObservation { [weak self] in
            MainActor.assumeIsolated {
                _ = self?.observers.removeValue(forKey: id)
            }
        }
    }

    override func didCommit(_ source: ChangeSource) {
        // Normally one delta per operation. Should an undo ever commit more than one transaction,
        // the deltas are reported in order, each relative to the text left by the one before.
        let deltas = capturedDeltas
        capturedDeltas.removeAll()
        for delta in deltas where !delta.isEmpty {
            let change = TextChange(delta: delta, source: source)
            for handler in observers.sorted(by: { $0.key < $1.key }).map(\.value) {
                handler(change)
            }
        }
    }

    // MARK: Plumbing

    private static func string(_ text: UnsafeMutablePointer<Branch>, _ txn: OpaquePointer) -> String {
        guard let chars = ytext_string(text, txn) else { return "" }
        defer { ystring_destroy(chars) }
        return String(cString: chars)
    }

    private static func readDelta(_ event: UnsafePointer<YTextEvent>) -> [DeltaOp] {
        var count: UInt32 = 0
        guard let delta = ytext_event_delta(event, &count) else { return [] }
        defer { ytext_delta_destroy(delta, count) }
        var ops: [DeltaOp] = []
        for i in 0..<Int(count) {
            let d = delta[i]
            var values: [(String, YrsValue)] = []
            if let attributes = d.attributes {
                for j in 0..<Int(d.attributes_len) {
                    if let key = attributes[j].key {
                        values.append((String(cString: key), YrsValue(attributes[j].value)))
                    }
                }
            }
            switch Int32(d.tag) {
            case Y_EVENT_CHANGE_RETAIN:
                var changes: AttributeChanges = [:]
                for (key, value) in values {
                    if let attribute = value.attribute {
                        changes[key] = .some(attribute)
                    } else if value.isNullish {
                        changes[key] = .some(nil)
                    }
                }
                ops.append(.retain(count: Int(d.len), attributes: changes.isEmpty ? nil : changes))
            case Y_EVENT_CHANGE_DELETE:
                ops.append(.delete(count: Int(d.len)))
            case Y_EVENT_CHANGE_ADD:
                var attributes: Attributes = [:]
                for (key, value) in values {
                    if let attribute = value.attribute {
                        attributes[key] = attribute
                    }
                }
                let text = if let insert = d.insert, case .string(let s) = YrsValue(insert.pointee) { s } else { embedPlaceholder }
                ops.append(.insert(text: text, attributes: attributes))
            default:
                break
            }
        }
        return ops
    }
}

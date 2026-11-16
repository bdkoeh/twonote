import CYrs
import Foundation
import TwoNoteDocuments

/// A value read from a Yrs map or text attribute.
package enum YrsValue {
    case null
    case undefined
    case bool(Bool)
    case number(Double)
    case string(String)
    case map(UnsafeMutablePointer<Branch>)
    case other

    /// The value as an attribute: bool, string or number; anything else is nil.
    package var attribute: AttributeValue? {
        switch self {
        case .bool(let b): .bool(b)
        case .number(let n): .number(n)
        case .string(let s): .string(s)
        default: nil
        }
    }

    package var isNullish: Bool {
        switch self {
        case .null, .undefined: true
        default: false
        }
    }

    init(_ output: YOutput) {
        switch Int32(output.tag) {
        case Y_JSON_BOOL: self = .bool(output.value.flag != 0)
        case Y_JSON_NUM: self = .number(output.value.num)
        case Y_JSON_INT: self = .number(Double(output.value.integer)) // a BigInt written by a client that broke the rules
        case Y_JSON_STR: self = output.value.str.map { .string(String(cString: $0)) } ?? .null
        case Y_JSON_NULL: self = .null
        case Y_JSON_UNDEF: self = .undefined
        case Y_MAP: self = output.value.y_type.map { .map($0) } ?? .null
        default: self = .other
        }
    }
}

/// Owns the C memory behind the inputs of one write transaction; freed after the commit.
package final class InputArena {
    private var strings: [UnsafeMutablePointer<CChar>] = []
    private var keyArrays: [UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>] = []
    private var valueArrays: [UnsafeMutablePointer<YInput>] = []
    private var counts: [Int] = []

    package func cString(_ string: String) -> UnsafeMutablePointer<CChar> {
        let p = strdup(string)!
        strings.append(p)
        return p
    }

    /// Numbers are always written as doubles (PROTOCOL.md 5.2).
    package func input(_ value: AttributeValue?) -> YInput {
        switch value {
        case nil: yinput_null()
        case .bool(let b): yinput_bool(b ? 1 : 0)
        case .number(let n): yinput_float(n)
        case .string(let s): yinput_string(cString(s))
        }
    }

    /// A plain JSON object (used for text attributes).
    package func object(_ fields: [(String, YInput)]) -> YInput {
        let (keys, values) = arrays(fields)
        return yinput_json_map(keys, values, UInt32(fields.count))
    }

    /// A nested shared map with initial entries.
    package func sharedMap(_ fields: [(String, YInput)]) -> YInput {
        let (keys, values) = arrays(fields)
        return yinput_ymap(keys, values, UInt32(fields.count))
    }

    /// A stable pointer to an input, for the calls that take one.
    package func pointer(to input: YInput) -> UnsafeMutablePointer<YInput> {
        let p = UnsafeMutablePointer<YInput>.allocate(capacity: 1)
        p.initialize(to: input)
        valueArrays.append(p)
        counts.append(1)
        return p
    }

    private func arrays(_ fields: [(String, YInput)])
        -> (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>, UnsafeMutablePointer<YInput>) {
        let n = max(fields.count, 1)
        let keys = UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>.allocate(capacity: n)
        keys.initialize(repeating: nil, count: n)
        let values = UnsafeMutablePointer<YInput>.allocate(capacity: n)
        values.initialize(repeating: yinput_null(), count: n)
        for (i, field) in fields.enumerated() {
            keys[i] = cString(field.0)
            values[i] = field.1
        }
        keyArrays.append(keys)
        valueArrays.append(values)
        counts.append(n)
        return (keys, values)
    }

    deinit {
        strings.forEach { free($0) }
        keyArrays.forEach { $0.deallocate() }
        valueArrays.forEach { $0.deallocate() }
    }
}

/// Base of the two Yjs documents of PROTOCOL.md section 5: one Yrs document with UTF-16 text
/// offsets. Lives on the main actor. Events are raised after the transaction has committed, so
/// handlers may read the document and see exactly the state the event describes; they must not
/// change it.
@MainActor
public class YrsDocument {
    /// Transaction origin of user edits; the undo manager tracks only this one.
    static let localOrigin = "local"
    /// Transaction origin of this client's own housekeeping writes; never undone.
    static let systemOrigin = "system"
    static let remoteOrigin = "remote"

    /// The 32-character hex id this document is stored and encrypted under.
    public let docId: String

    /// A Yjs v1 update produced by this replica (edit, undo or redo) that has to reach the other
    /// replicas. Called before `onChanged`, so the edit is in the outbox before anyone hears of it.
    public var onLocalUpdate: ((Data) -> Void)?

    /// The document content changed, for whatever reason. Called once per transaction.
    public var onChanged: ((ChangeSource) -> Void)?

    /// True once the server deleted this document (or its notebook); further edits are not synced.
    public private(set) var isDeleted = false

    nonisolated(unsafe) let doc: UnsafeMutablePointer<YDoc>
    nonisolated(unsafe) private var updateSubscription: UnsafeMutablePointer<YSubscription>?
    private var current: ChangeSource?
    private var changed = false
    private var produced: [Data] = []

    package init(docId: String) {
        precondition(Self.isValidId(docId), "A document id is exactly 32 lowercase hex characters.")
        self.docId = docId

        // A fresh client id per session: re-using one after losing local state would corrupt the
        // document. 53 bits so that JavaScript Yjs peers can represent it.
        var options = yoptions()
        options.id = UInt64.random(in: 0..<(1 << 53)) | 1
        options.encoding = UInt8(Y_OFFSET_UTF16)
        doc = ydoc_new_with_options(options)
        updateSubscription = ydoc_observe_updates_v1(doc, Unmanaged.passUnretained(self).toOpaque()) { state, length, bytes in
            // Runs inside the commit, on the committing (main) thread.
            guard let state, let bytes, length > 2 else { return } // 2 bytes or fewer carry nothing
            let update = Data(bytes: bytes, count: Int(length))
            let document = Unmanaged<YrsDocument>.fromOpaque(state).takeUnretainedValue()
            MainActor.assumeIsolated {
                document.changed = true
                if document.current == .local || document.current == .undo {
                    document.produced.append(update)
                }
            }
        }
    }

    deinit {
        if let updateSubscription {
            yunobserve(updateSubscription)
        }
        ydoc_destroy(doc)
    }

    static func isValidId(_ id: String) -> Bool {
        id.utf8.count == 32 && id.utf8.allSatisfy { ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x66) }
    }

    // MARK: Replication

    /// Merges a Yjs v1 update from another replica. Merging is idempotent and commutative.
    /// Returns false, leaving the document untouched, when the bytes are not a valid update.
    @discardableResult
    public func applyUpdate(_ update: Data) -> Bool {
        var ok = true
        run(.remote) {
            guard let txn = Self.remoteOrigin.withCString({ ydoc_write_transaction(doc, UInt32(Self.remoteOrigin.utf8.count), $0) }) else {
                ok = false
                return
            }
            ok = update.withUnsafeBytes { raw in
                ytransaction_apply(txn, raw.bindMemory(to: CChar.self).baseAddress, UInt32(raw.count)) == 0
            }
            ytransaction_commit(txn)
        }
        return ok
    }

    /// The whole document as one Yjs v1 update (the plaintext of a `snapshot` blob).
    public func encodeState() -> Data {
        encodeDiff(from: nil)
    }

    /// This replica's Yjs state vector (v1).
    public func encodeStateVector() -> Data {
        read { txn in
            var length: UInt32 = 0
            guard let bytes = ytransaction_state_vector_v1(txn, &length) else { return Data() }
            defer { ybinary_destroy(bytes, length) }
            return Data(bytes: bytes, count: Int(length))
        }
    }

    /// Everything this replica has that a replica with `stateVector` lacks, as a v1 update.
    public func encodeDiff(from stateVector: Data?) -> Data {
        read { txn in
            var length: UInt32 = 0
            let bytes: UnsafeMutablePointer<CChar>? = if let stateVector, !stateVector.isEmpty {
                stateVector.withUnsafeBytes { raw in
                    ytransaction_state_diff_v1(txn, raw.bindMemory(to: CChar.self).baseAddress, UInt32(raw.count), &length)
                }
            } else {
                ytransaction_state_diff_v1(txn, nil, 0, &length)
            }
            guard let bytes else { return Data() }
            defer { ybinary_destroy(bytes, length) }
            return Data(bytes: bytes, count: Int(length))
        }
    }

    /// Marks the document as deleted on the server. Called by the sync layer.
    public func markDeleted() {
        isDeleted = true
    }

    // MARK: Transactions

    /// Runs a read transaction. Yrs allows one transaction at a time, so this cannot be used
    /// from inside an edit.
    package func read<T>(_ body: (OpaquePointer) -> T) -> T {
        precondition(current == nil, "The document cannot be read from inside its own edit.")
        guard let txn = ydoc_read_transaction(doc) else {
            preconditionFailure("Yrs refused a read transaction.")
        }
        defer { ytransaction_commit(txn) }
        return body(txn)
    }

    /// Runs a write transaction as a user edit, or as housekeeping when `system` is true.
    package func write(system: Bool = false, _ body: (OpaquePointer, InputArena) -> Void) {
        run(.local) {
            let origin = system ? Self.systemOrigin : Self.localOrigin
            guard let txn = origin.withCString({ ydoc_write_transaction(doc, UInt32(origin.utf8.count), $0) }) else {
                preconditionFailure("Yrs refused a write transaction.")
            }
            let arena = InputArena()
            body(txn, arena)
            ytransaction_commit(txn)
            withExtendedLifetime(arena) {}
        }
    }

    /// Runs `action` (which commits one or more transactions) and then raises the events.
    func run(_ source: ChangeSource, _ action: () -> Void) {
        precondition(current == nil, "A document cannot be changed from inside one of its own change handlers.")
        current = source
        changed = false
        produced.removeAll()
        action()
        let updates = produced
        let didChange = changed
        produced.removeAll()
        current = nil

        for update in updates {
            onLocalUpdate?(update)
        }
        if didChange {
            didCommit(source)
            onChanged?(source)
        }
    }

    /// Called after a transaction that changed something, before `onChanged`.
    func didCommit(_ source: ChangeSource) {}

    // MARK: Maps

    package func rootMap(_ name: String) -> UnsafeMutablePointer<Branch> {
        name.withCString { ymap(doc, $0) }
    }

    package func mapGet(_ map: UnsafeMutablePointer<Branch>, _ key: String, _ txn: OpaquePointer) -> YrsValue? {
        guard let output = key.withCString({ ymap_get(map, txn, $0) }) else { return nil }
        defer { youtput_destroy(output) }
        return YrsValue(output.pointee)
    }

    package func mapEntries(_ map: UnsafeMutablePointer<Branch>, _ txn: OpaquePointer) -> [(key: String, value: YrsValue)] {
        guard let iterator = ymap_iter(map, txn) else { return [] }
        defer { ymap_iter_destroy(iterator) }
        var entries: [(key: String, value: YrsValue)] = []
        while let entry = ymap_iter_next(iterator) {
            if let key = entry.pointee.key, let value = entry.pointee.value {
                entries.append((String(cString: key), YrsValue(value.pointee)))
            }
            ymap_entry_destroy(entry)
        }
        return entries
    }

    package func mapSet(_ map: UnsafeMutablePointer<Branch>, _ key: String, _ value: YInput, _ txn: OpaquePointer, _ arena: InputArena) {
        ymap_insert(map, txn, arena.cString(key), arena.pointer(to: value))
    }
}

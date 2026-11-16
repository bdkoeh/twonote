// A stand-in for the real page document, for tests and the editor spike. It is NOT the wire
// format and never syncs with a real client: it is a small replicated text (an RGA: every code
// unit has an id and remembers what it was inserted after; deletions leave tombstones;
// attributes are last-writer-wins per code unit and key) with just enough behaviour to exercise
// an editor the way the Yjs document will: local edits, late remote edits that were made
// against an older state, and undo of own edits only.
//
// Replicas of one page are created from the same seed with different `site` numbers and
// exchange `InMemoryPageText.Update`s, normally through an `InMemoryPageLink`.

import Foundation
import TwoNoteDocuments

@MainActor
public final class InMemoryPageText: PageText {
    // MARK: Replicated state

    struct ItemID: Hashable, Sendable, Comparable {
        var clock: Int
        var site: Int

        static func < (a: ItemID, b: ItemID) -> Bool {
            a.clock != b.clock ? a.clock < b.clock : a.site < b.site
        }
    }

    struct Stamped: Sendable {
        var value: AttributeValue?
        var stamp: ItemID
    }

    struct Item {
        var id: ItemID
        var unit: UInt16
        var deleted = false
        var attributes: [String: Stamped] = [:]

        var visibleAttributes: Attributes {
            var result: Attributes = [:]
            for (key, stamped) in attributes {
                if let value = stamped.value { result[key] = value }
            }
            return result
        }
    }

    enum Op: Sendable {
        case insert(id: ItemID, after: ItemID?, unit: UInt16, attributes: Attributes)
        case delete(id: ItemID)
        case format(id: ItemID, key: String, value: AttributeValue?, stamp: ItemID)
    }

    /// What one transaction did, as sent to the other replicas.
    public struct Update: Sendable {
        var ops: [Op]
    }

    public let site: Int
    private var items: [Item] = []
    private var clock = 0
    private var visibleCount = 0

    // MARK: Transactions, undo, observers

    private struct Before {
        var wasVisible: Bool
        var attributes: Attributes
    }

    /// What is needed to take a transaction back.
    private struct UndoRecord {
        var inserted: [ItemID] = []
        /// `chained`: the item directly followed the previous entry when it was deleted, so on
        /// undo it comes back directly behind it (a surrogate pair must never come apart).
        var deleted: [(id: ItemID, unit: UInt16, attributes: Attributes, chained: Bool)] = []
        var formats: [(id: ItemID, key: String, old: AttributeValue?)] = []
        var isEmpty: Bool { inserted.isEmpty && deleted.isEmpty && formats.isEmpty }

        mutating func append(_ other: UndoRecord) {
            inserted += other.inserted
            deleted += other.deleted
            formats += other.formats
        }
    }

    private var touched: [ItemID: Before] = [:]
    private var insertedInTransaction: Set<ItemID> = []
    private var transactionOps: [Op] = []
    private var record = UndoRecord()
    private var inTransaction = false
    private var notifying = false

    private var undoStack: [UndoRecord] = []
    private var redoStack: [UndoRecord] = []
    private var groupOpen = false
    private var lastEditTime: TimeInterval = 0

    private var observers: [Int: @MainActor (TextChange) -> Void] = [:]
    private var nextObserver = 0

    /// Edits closer together than this merge into one undo step (0: every edit is its own step).
    public var undoCaptureInterval: TimeInterval = 0
    /// Receives every transaction this replica originates (edits, undo, redo).
    public var onUpdate: ((Update) -> Void)?
    /// Transactions made here / received, for tests.
    public private(set) var localTransactions = 0
    public private(set) var remoteTransactions = 0

    /// All replicas of a page must be created from the same seed. Seeding is not an edit: it
    /// cannot be undone and is not sent anywhere.
    public init(site: Int, seed: [TextRun] = [TextRun(text: "\n")]) {
        precondition(site > 0, "site 0 is the seed")
        self.site = site
        for run in seed {
            for unit in run.text.utf16 {
                clock += 1
                var item = Item(id: ItemID(clock: clock, site: 0), unit: unit)
                for (key, value) in run.attributes {
                    item.attributes[key] = Stamped(value: value, stamp: ItemID(clock: 0, site: 0))
                }
                items.append(item)
            }
        }
        visibleCount = items.count
    }

    // MARK: PageText

    public var length: Int { visibleCount }

    public var text: String {
        String(decoding: items.lazy.filter { !$0.deleted }.map(\.unit), as: UTF16.self)
    }

    public var runs: [TextRun] {
        var result: [TextRun] = []
        var buffer: [UInt16] = []
        var current: Attributes?
        for item in items where !item.deleted {
            let attributes = item.visibleAttributes
            if attributes != current {
                if let current, !buffer.isEmpty {
                    result.append(TextRun(text: String(decoding: buffer, as: UTF16.self), attributes: current))
                }
                buffer.removeAll(keepingCapacity: true)
                current = attributes
            }
            buffer.append(item.unit)
        }
        if let current, !buffer.isEmpty {
            result.append(TextRun(text: String(decoding: buffer, as: UTF16.self), attributes: current))
        }
        return result
    }

    public func edit(_ body: (any PageTextEditor) -> Void) {
        precondition(!notifying, "edit must not be called from inside a change handler")
        precondition(!inTransaction, "edits do not nest")
        begin()
        let editor = Editor(page: self)
        if lastVisibleIndex().map({ items[$0].unit != newlineUnit }) ?? true {
            insertLocal([newlineUnit], atVisible: visibleCount, attributes: [:], allowAtEnd: true)
        }
        body(editor)
        editor.page = nil
        let finished = record
        guard let change = commit(source: .local) else { return }
        localTransactions += 1
        let now = Date.timeIntervalSinceReferenceDate
        if groupOpen, undoCaptureInterval > 0, now - lastEditTime < undoCaptureInterval, !undoStack.isEmpty {
            undoStack[undoStack.count - 1].append(finished)
        } else {
            undoStack.append(finished)
        }
        groupOpen = true
        lastEditTime = now
        redoStack.removeAll()
        notify(change)
    }

    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }

    @discardableResult
    public func undo() -> Bool {
        guard let entry = undoStack.popLast() else { return false }
        groupOpen = false
        let inverse = revert(entry)
        redoStack.append(inverse)
        return true
    }

    @discardableResult
    public func redo() -> Bool {
        guard let entry = redoStack.popLast() else { return false }
        groupOpen = false
        let inverse = revert(entry)
        undoStack.append(inverse)
        return true
    }

    public func breakUndoGroup() {
        groupOpen = false
    }

    public func observeText(_ handler: @escaping @MainActor (TextChange) -> Void) -> ChangeObservation {
        let id = nextObserver
        nextObserver += 1
        observers[id] = handler
        return ChangeObservation { [weak self] in
            MainActor.assumeIsolated {
                _ = self?.observers.removeValue(forKey: id)
            }
        }
    }

    // MARK: Remote updates

    /// Merges a transaction another replica made. Reported to observers with source `.remote`.
    public func apply(_ update: Update) {
        precondition(!notifying && !inTransaction, "an update cannot be merged from inside a change handler")
        begin()
        for op in update.ops { integrate(op) }
        remoteTransactions += 1
        if let change = commit(source: .remote, send: false) {
            notify(change)
        }
    }

    // MARK: Editor

    private final class Editor: PageTextEditor {
        weak var page: InMemoryPageText?

        init(page: InMemoryPageText) {
            self.page = page
        }

        private var live: InMemoryPageText {
            guard let page else { preconditionFailure("the editor was used outside its edit") }
            return page
        }

        var length: Int { live.length }
        var text: String { live.text }

        func insert(_ text: String, at index: Int, attributes: Attributes) {
            live.insertLocal(Array(text.utf16), atVisible: index, attributes: attributes, allowAtEnd: false)
        }

        func delete(at index: Int, count: Int) {
            live.deleteLocal(atVisible: index, count: count)
        }

        func format(at index: Int, count: Int, attributes: AttributeChanges) {
            live.formatLocal(atVisible: index, count: count, changes: attributes)
        }

        func setBlock(newlineAt newlineIndex: Int, block: String?, indent: Int, checked: Bool) {
            let page = live
            precondition(page.unit(atVisible: newlineIndex) == newlineUnit, "setBlock needs the index of a newline")
            var changes: AttributeChanges = [:]
            changes.updateValue(block.map { AttributeValue.string($0) }, forKey: PageAttribute.block)
            changes.updateValue(indent != 0 ? AttributeValue.number(Double(indent)) : nil, forKey: PageAttribute.indent)
            changes.updateValue(checked ? AttributeValue.bool(true) : nil, forKey: PageAttribute.checked)
            page.formatLocal(atVisible: newlineIndex, count: 1, changes: changes)
        }
    }

    // MARK: Local operations

    private func insertLocal(_ units: [UInt16], atVisible index: Int, attributes: Attributes, allowAtEnd: Bool) {
        guard !units.isEmpty else { return }
        precondition(index >= 0 && (allowAtEnd ? index <= visibleCount : index < visibleCount),
                     "insert position must be before the final newline")
        precondition(!splitsSurrogatePair(atVisible: index), "insert would split a surrogate pair")
        var at = index == visibleCount ? items.count : itemIndex(ofVisible: index)
        // Directly after the visible predecessor (tombstones that follow it stay behind the new text).
        var after: ItemID?
        var probe = at - 1
        while probe >= 0 && items[probe].deleted { probe -= 1 }
        if probe >= 0 {
            after = items[probe].id
            at = probe + 1
        } else {
            at = 0
        }
        for unit in units {
            clock += 1
            let id = ItemID(clock: clock, site: site)
            var item = Item(id: id, unit: unit)
            for (key, value) in attributes {
                item.attributes[key] = Stamped(value: value, stamp: id)
            }
            items.insert(item, at: at)
            visibleCount += 1
            insertedInTransaction.insert(id)
            record.inserted.append(id)
            transactionOps.append(.insert(id: id, after: after, unit: unit, attributes: attributes))
            after = id
            at += 1
        }
    }

    private func deleteLocal(atVisible index: Int, count: Int) {
        guard count > 0 else { return }
        precondition(index >= 0 && index + count <= visibleCount - 1, "the final newline cannot be deleted")
        precondition(!splitsSurrogatePair(atVisible: index) && !splitsSurrogatePair(atVisible: index + count),
                     "delete would split a surrogate pair")
        var at = itemIndex(ofVisible: index)
        var left = count
        while left > 0 {
            if !items[at].deleted {
                remember(at)
                record.deleted.append((items[at].id, items[at].unit, items[at].visibleAttributes, left < count))
                items[at].deleted = true
                visibleCount -= 1
                transactionOps.append(.delete(id: items[at].id))
                left -= 1
            }
            at += 1
        }
    }

    private func formatLocal(atVisible index: Int, count: Int, changes: AttributeChanges) {
        guard count > 0, !changes.isEmpty else { return }
        precondition(index >= 0 && index + count <= visibleCount, "format range is outside the text")
        var at = itemIndex(ofVisible: index)
        var left = count
        while left > 0 {
            if !items[at].deleted {
                for (key, value) in changes.sorted(by: { $0.key < $1.key }) {
                    let old = items[at].attributes[key]?.value
                    if old == value { continue }
                    remember(at)
                    clock += 1
                    let stamp = ItemID(clock: clock, site: site)
                    items[at].attributes[key] = Stamped(value: value, stamp: stamp)
                    record.formats.append((items[at].id, key, old))
                    transactionOps.append(.format(id: items[at].id, key: key, value: value, stamp: stamp))
                }
                left -= 1
            }
            at += 1
        }
    }

    /// Undoes what `entry` describes, as a new transaction; returns what undoes that again.
    private func revert(_ entry: UndoRecord) -> UndoRecord {
        precondition(!notifying && !inTransaction, "undo cannot run from inside a change handler")
        begin()
        // Formats first (they refer to the items as they were), then text.
        for (id, key, old) in entry.formats.reversed() {
            guard let at = index(of: id), !items[at].deleted, items[at].attributes[key]?.value != old else { continue }
            remember(at)
            clock += 1
            let stamp = ItemID(clock: clock, site: site)
            record.formats.append((id, key, items[at].attributes[key]?.value))
            items[at].attributes[key] = Stamped(value: old, stamp: stamp)
            transactionOps.append(.format(id: id, key: key, value: old, stamp: stamp))
        }
        for id in entry.inserted {
            guard let at = index(of: id), !items[at].deleted else { continue }
            if isFinalNewline(at) { continue }
            remember(at)
            record.deleted.append((id, items[at].unit, items[at].visibleAttributes, UTF16.isTrailSurrogate(items[at].unit)))
            items[at].deleted = true
            visibleCount -= 1
            transactionOps.append(.delete(id: id))
        }
        // Deleted text comes back as new items, each right behind the tombstone it replaces.
        var previous: ItemID?
        for (tombstone, unit, attributes, chained) in entry.deleted {
            let origin = chained ? previous ?? tombstone : tombstone
            guard let at = index(of: origin) else { continue }
            clock += 1
            let id = ItemID(clock: clock, site: site)
            var item = Item(id: id, unit: unit)
            for (key, value) in attributes {
                item.attributes[key] = Stamped(value: value, stamp: id)
            }
            items.insert(item, at: at + 1)
            visibleCount += 1
            insertedInTransaction.insert(id)
            record.inserted.append(id)
            transactionOps.append(.insert(id: id, after: origin, unit: unit, attributes: attributes))
            previous = id
        }
        let inverse = record
        if let change = commit(source: .undo) {
            notify(change)
        }
        return inverse
    }

    // MARK: Integration of remote operations

    private var lookupHint = 0

    private func index(of id: ItemID) -> Int? {
        // Runs of operations walk forward through the text; try the neighbourhood of the last hit first.
        let lo = max(0, lookupHint - 2)
        let hi = min(items.count, lookupHint + 3)
        for i in lo..<hi where items[i].id == id {
            lookupHint = i
            return i
        }
        guard let found = items.firstIndex(where: { $0.id == id }) else { return nil }
        lookupHint = found
        return found
    }

    private func integrate(_ op: Op) {
        switch op {
        case .insert(let id, let after, let unit, let attributes):
            clock = max(clock, id.clock)
            if index(of: id) != nil { return }
            var at = 0
            if let after {
                guard let origin = index(of: after) else {
                    preconditionFailure("update arrived before the one it depends on")
                }
                at = origin + 1
            }
            // RGA: items inserted at the same place by others, with a later id, stay in front.
            while at < items.count && items[at].id > id { at += 1 }
            var item = Item(id: id, unit: unit)
            for (key, value) in attributes {
                item.attributes[key] = Stamped(value: value, stamp: id)
            }
            items.insert(item, at: at)
            lookupHint = at
            visibleCount += 1
            insertedInTransaction.insert(id)
        case .delete(let id):
            guard let at = index(of: id), !items[at].deleted else { return }
            remember(at)
            items[at].deleted = true
            visibleCount -= 1
        case .format(let id, let key, let value, let stamp):
            clock = max(clock, stamp.clock)
            guard let at = index(of: id) else { return }
            if let existing = items[at].attributes[key], existing.stamp > stamp { return }
            remember(at)
            items[at].attributes[key] = Stamped(value: value, stamp: stamp)
        }
    }

    // MARK: Transaction bookkeeping

    private func begin() {
        inTransaction = true
        touched.removeAll(keepingCapacity: true)
        insertedInTransaction.removeAll(keepingCapacity: true)
        transactionOps.removeAll(keepingCapacity: true)
        record = UndoRecord()
    }

    private func remember(_ at: Int) {
        let id = items[at].id
        if insertedInTransaction.contains(id) || touched[id] != nil { return }
        touched[id] = Before(wasVisible: !items[at].deleted, attributes: items[at].visibleAttributes)
    }

    /// Ends the transaction: sends it to the other replicas and returns the change for observers
    /// (nil when nothing visible changed).
    private func commit(source: ChangeSource, send: Bool = true) -> TextChange? {
        inTransaction = false
        let ops = transactionOps
        transactionOps.removeAll(keepingCapacity: true)
        let delta = makeDelta()
        touched.removeAll(keepingCapacity: true)
        insertedInTransaction.removeAll(keepingCapacity: true)
        record = UndoRecord()
        if send, !ops.isEmpty {
            onUpdate?(Update(ops: ops))
        }
        return delta.isEmpty ? nil : TextChange(delta: delta, source: source)
    }

    /// The delta from the text before the transaction to the text now.
    private func makeDelta() -> [DeltaOp] {
        if touched.isEmpty && insertedInTransaction.isEmpty { return [] }
        var delta: [DeltaOp] = []
        var retained = 0
        var insertUnits: [UInt16] = []
        var insertAttributes: Attributes = [:]
        var deleted = 0
        var formatCount = 0
        var formatChanges: AttributeChanges = [:]

        func flushRetain() {
            if retained > 0 { delta.append(.retain(count: retained, attributes: nil)); retained = 0 }
        }
        func flushInsert() {
            if !insertUnits.isEmpty {
                delta.append(.insert(text: String(decoding: insertUnits, as: UTF16.self), attributes: insertAttributes))
                insertUnits.removeAll()
            }
        }
        func flushDelete() {
            if deleted > 0 { delta.append(.delete(count: deleted)); deleted = 0 }
        }
        func flushFormat() {
            if formatCount > 0 { delta.append(.retain(count: formatCount, attributes: formatChanges)); formatCount = 0 }
        }

        for item in items {
            if insertedInTransaction.contains(item.id) {
                if item.deleted { continue }
                let attributes = item.visibleAttributes
                flushRetain(); flushDelete(); flushFormat()
                if !insertUnits.isEmpty && attributes != insertAttributes { flushInsert() }
                insertAttributes = attributes
                insertUnits.append(item.unit)
                continue
            }
            guard let before = touched[item.id] else {
                if !item.deleted {
                    flushInsert(); flushDelete(); flushFormat()
                    retained += 1
                }
                continue
            }
            if !before.wasVisible { continue }
            if item.deleted {
                flushRetain(); flushInsert(); flushFormat()
                deleted += 1
                continue
            }
            let now = item.visibleAttributes
            var changes: AttributeChanges = [:]
            for (key, value) in now where before.attributes[key] != value { changes.updateValue(value, forKey: key) }
            for key in before.attributes.keys where now[key] == nil { changes.updateValue(nil, forKey: key) }
            if changes.isEmpty {
                flushInsert(); flushDelete(); flushFormat()
                retained += 1
            } else {
                flushRetain(); flushInsert(); flushDelete()
                if formatCount > 0 && !Self.same(changes, formatChanges) { flushFormat() }
                formatChanges = changes
                formatCount += 1
            }
        }
        flushInsert(); flushDelete(); flushFormat()
        // Trailing plain retains say nothing.
        return delta
    }

    private static func same(_ a: AttributeChanges, _ b: AttributeChanges) -> Bool {
        guard a.count == b.count else { return false }
        for (key, value) in a {
            guard let other = b[key], other == value else { return false }
        }
        return true
    }

    private func notify(_ change: TextChange) {
        notifying = true
        defer { notifying = false }
        for id in observers.keys.sorted() {
            observers[id]?(change)
        }
    }

    // MARK: Index helpers

    /// Index in `items` of the `visible`-th undeleted item.
    private func itemIndex(ofVisible visible: Int) -> Int {
        precondition(visible >= 0 && visible < visibleCount, "index is outside the text")
        var seen = 0
        for (i, item) in items.enumerated() where !item.deleted {
            if seen == visible { return i }
            seen += 1
        }
        preconditionFailure("unreachable")
    }

    private func lastVisibleIndex() -> Int? {
        items.lastIndex(where: { !$0.deleted })
    }

    private func isFinalNewline(_ at: Int) -> Bool {
        lastVisibleIndex() == at
    }

    private func unit(atVisible index: Int) -> UInt16 {
        items[itemIndex(ofVisible: index)].unit
    }

    private func splitsSurrogatePair(atVisible index: Int) -> Bool {
        guard index > 0 && index < visibleCount else { return false }
        return UTF16.isLeadSurrogate(unit(atVisible: index - 1)) && UTF16.isTrailSurrogate(unit(atVisible: index))
    }
}

/// Carries updates between two replicas, in order, either after a delay or when told to.
@MainActor
public final class InMemoryPageLink {
    public let a: InMemoryPageText
    public let b: InMemoryPageText
    /// nil: updates wait until `deliver...` is called. Otherwise they arrive this much later.
    public var delay: TimeInterval?
    /// While paused nothing is delivered (two devices offline from each other).
    public var isPaused = false {
        didSet {
            if oldValue && !isPaused && delay != nil { deliverAll() }
        }
    }
    public private(set) var delivered = 0

    private var toA: [InMemoryPageText.Update] = []
    private var toB: [InMemoryPageText.Update] = []

    public init(_ a: InMemoryPageText, _ b: InMemoryPageText, delay: TimeInterval? = nil) {
        self.a = a
        self.b = b
        self.delay = delay
        a.onUpdate = { [weak self] update in self?.enqueue(update, forA: false) }
        b.onUpdate = { [weak self] update in self?.enqueue(update, forA: true) }
    }

    public var pendingToA: Int { toA.count }
    public var pendingToB: Int { toB.count }
    public var isIdle: Bool { toA.isEmpty && toB.isEmpty }

    private func enqueue(_ update: InMemoryPageText.Update, forA: Bool) {
        if forA { toA.append(update) } else { toB.append(update) }
        guard let delay else { return }
        // Always later, never from inside the sender's edit.
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, !self.isPaused else { return }
            if forA { self.deliverNextToA() } else { self.deliverNextToB() }
        }
    }

    @discardableResult
    public func deliverNextToA() -> Bool {
        guard !toA.isEmpty else { return false }
        a.apply(toA.removeFirst())
        delivered += 1
        return true
    }

    @discardableResult
    public func deliverNextToB() -> Bool {
        guard !toB.isEmpty else { return false }
        b.apply(toB.removeFirst())
        delivered += 1
        return true
    }

    /// Delivers until both directions are empty (a delivery never produces new updates).
    public func deliverAll() {
        while deliverNextToA() || deliverNextToB() {}
    }
}

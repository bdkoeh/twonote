// Both directions of the binding, without any UI:
//
//  * view -> page: `Reconciler.plan` diffs the view's text against the shadow and says what to
//    write to the page (one edit) and how the shadow changes.
//  * page -> view: `DeltaStep.steps` turns a delta into ranged edits in running coordinates, and
//    `SelectionTransform` carries a selection (or any position) through them.

import TwoNoteDocuments

// MARK: - view -> page

/// One write to the page, in the coordinates the text has at that point of the edit.
public enum PlanOp: Equatable, Sendable {
    case delete(at: Int, count: Int)
    case insert(at: Int, text: String, attributes: Attributes)
    case setBlock(newlineAt: Int, block: BlockAttrs)

    @MainActor
    public func apply(to editor: any PageTextEditor) {
        switch self {
        case .delete(let at, let count):
            editor.delete(at: at, count: count)
        case .insert(let at, let text, let attributes):
            editor.insert(text, at: at, attributes: attributes)
        case .setBlock(let newline, let block):
            editor.setBlock(newlineAt: newline, block: block.block, indent: block.indent, checked: block.checked)
        }
    }
}

public struct ReconcilePlan: Equatable, Sendable {
    /// The replacement in the text.
    public var edit: TextEdit
    /// The cells that replace the deleted range in the shadow.
    public var inserted: [Cell]
    /// Block change of the paragraph mark that follows the edit (index in the new text).
    public var survivor: (index: Int, block: BlockAttrs)?
    /// What to write to the page, in order.
    public var ops: [PlanOp]

    public static func == (a: ReconcilePlan, b: ReconcilePlan) -> Bool {
        a.edit == b.edit && a.inserted == b.inserted && a.ops == b.ops
            && a.survivor?.index == b.survivor?.index && a.survivor?.block == b.survivor?.block
    }

    /// First and last (the newline) index, in the new text, of the paragraphs whose look may have changed.
    public func affectedRange(in shadow: ShadowModel) -> ClosedRange<Int> {
        let from = shadow.paragraphStart(edit.start)
        let to = shadow.paragraphEnd(edit.start + edit.insertCount)
        return from...max(from, to)
    }

    public func apply(to shadow: inout ShadowModel) {
        shadow.replace(edit.start..<edit.start + edit.deleteCount, with: inserted)
        if let survivor {
            shadow[survivor.index].block = survivor.block
        }
    }

    @MainActor
    public func write(to editor: any PageTextEditor) {
        for op in ops { op.apply(to: editor) }
    }
}

public enum Reconciler {
    /// Works out what the user did to the view since it last agreed with the shadow.
    ///
    /// - Parameters:
    ///   - shadow: the last agreed state; must end with a newline.
    ///   - now: the view's text; must end with a newline.
    ///   - caret: the caret position in `now` (or -1), to place edits inside runs of equal characters.
    ///   - inlineOfInserted: reads the inline attributes the view holds for a range of `now`.
    ///
    /// The view decides the text and the inline attributes of what was inserted. Block attributes
    /// follow rules, because a text view has no notion of them:
    ///  * an inserted paragraph mark continues the paragraph it splits (Return in a list item makes
    ///    another item);
    ///  * when a deletion joins paragraphs, the joined paragraph keeps the look of the one the
    ///    deletion started in, unless nothing of that one is left;
    ///  * Return at the end of a heading starts a plain paragraph, Return in a ticked to-do an
    ///    unticked one.
    /// Returns nil when the texts are equal.
    public static func plan(shadow: ShadowModel, now: [UInt16], caret: Int,
                            inlineOfInserted: (Range<Int>) -> [InlineAttrs]) -> ReconcilePlan? {
        precondition(shadow.endsWithNewline && now.last == newlineUnit, "both texts must end with the final newline")
        let edit = TextEdit.diff(shadow.units, now, caretHint: caret)
        if edit.isEmpty { return nil }

        let insertedRange = edit.start..<edit.start + edit.insertCount
        let deletedRange = edit.start..<edit.start + edit.deleteCount
        let startBlock = shadow.block(at: edit.start)
        let inlines = edit.insertCount > 0 ? inlineOfInserted(insertedRange) : []
        precondition(inlines.count == edit.insertCount)

        var inserted: [Cell] = []
        inserted.reserveCapacity(edit.insertCount)
        for (k, i) in insertedRange.enumerated() {
            let unit = now[i]
            inserted.append(Cell(unit: unit, inline: inlines[k], block: unit == newlineUnit ? startBlock : BlockAttrs()))
        }

        // The paragraph mark that ends the paragraph after the edit. It is never part of the
        // deletion: the diff keeps the final newline.
        let survivorOld = shadow.paragraphEnd(deletedRange.upperBound)
        let survivorBefore = shadow[survivorOld].block
        var survivorBlock = survivorBefore
        let joinsParagraphs = shadow.units[deletedRange].contains(newlineUnit)
        if joinsParagraphs && edit.start != shadow.paragraphStart(edit.start) {
            survivorBlock = startBlock
        }
        if edit.deleteCount == 0 && edit.insertCount == 1 && now[edit.start] == newlineUnit {
            let shown = survivorBlock.effective
            if shown.isHeading && survivorOld == edit.start {
                survivorBlock.block = nil
            }
            if shown.block == "todo" && shown.checked {
                survivorBlock.checked = false
            }
        }

        var ops: [PlanOp] = []
        if edit.deleteCount > 0 {
            ops.append(.delete(at: edit.start, count: edit.deleteCount))
        }
        // Inserted text, grouped into runs of identical attributes (each newline on its own).
        var k = 0
        while k < inserted.count {
            let cell = inserted[k]
            var m = k + 1
            if !cell.isNewline {
                while m < inserted.count && !inserted[m].isNewline && inserted[m].inline == cell.inline { m += 1 }
            }
            var attributes = cell.inline.attributes
            if cell.isNewline {
                attributes.merge(cell.block.attributes) { _, new in new }
            }
            ops.append(.insert(at: edit.start + k, text: String(decoding: inserted[k..<m].map(\.unit), as: UTF16.self),
                               attributes: attributes))
            k = m
        }
        let survivorNew = survivorOld - edit.deleteCount + edit.insertCount
        var survivor: (index: Int, block: BlockAttrs)?
        if survivorBlock != survivorBefore {
            survivor = (survivorNew, survivorBlock)
            ops.append(.setBlock(newlineAt: survivorNew, block: survivorBlock))
        }
        return ReconcilePlan(edit: edit, inserted: inserted, survivor: survivor, ops: ops)
    }
}

// MARK: - page -> view

/// One ranged change, positions being those of the text after all earlier steps.
public enum DeltaStep: Equatable, Sendable {
    case format(range: Range<Int>, changes: AttributeChanges)
    case insert(at: Int, cells: [Cell])
    case delete(range: Range<Int>)

    public static func steps(for delta: [DeltaOp]) -> [DeltaStep] {
        var steps: [DeltaStep] = []
        var pos = 0
        for op in delta {
            switch op {
            case .retain(let count, let attributes):
                if let attributes, !attributes.isEmpty, count > 0 {
                    steps.append(.format(range: pos..<pos + count, changes: attributes))
                }
                pos += count
            case .insert(let text, let attributes):
                let cells = Cell.cells(text: text, attributes: attributes)
                if !cells.isEmpty {
                    steps.append(.insert(at: pos, cells: cells))
                    pos += cells.count
                }
            case .delete(let count):
                if count > 0 { steps.append(.delete(range: pos..<pos + count)) }
            }
        }
        return steps
    }

    /// The range of the result this step touched (empty for a deletion).
    public var touched: Range<Int> {
        switch self {
        case .format(let range, _): return range
        case .insert(let at, let cells): return at..<at + cells.count
        case .delete(let range): return range.lowerBound..<range.lowerBound
        }
    }
}

extension ShadowModel {
    /// Applies one step. Returns false when the step does not fit the text (the caller then
    /// reloads everything from the page).
    public mutating func apply(_ step: DeltaStep) -> Bool {
        switch step {
        case .format(let range, let changes):
            guard range.upperBound <= count else { return false }
            for i in range { self[i] = self[i].applying(changes) }
        case .insert(let at, let cells):
            guard at <= count else { return false }
            replace(at..<at, with: cells)
        case .delete(let range):
            guard range.upperBound <= count else { return false }
            replace(range, with: [])
        }
        return true
    }
}

/// Carries a selection through changes made by someone else.
public struct SelectionTransform: Equatable, Sendable {
    public var start: Int
    public var end: Int
    private let isCaret: Bool

    public init(start: Int, end: Int) {
        self.start = start
        self.end = end
        self.isCaret = start == end
    }

    /// Text inserted exactly at a caret goes after it; at the edges of a selection it stays outside.
    public mutating func apply(_ step: DeltaStep) {
        switch step {
        case .format:
            break
        case .insert(let at, let cells):
            if start > at || (start == at && !isCaret) { start += cells.count }
            if end > at { end += cells.count }
        case .delete(let range):
            start = Self.afterDelete(start, range)
            end = Self.afterDelete(end, range)
        }
    }

    public static func afterDelete(_ x: Int, _ range: Range<Int>) -> Int {
        x <= range.lowerBound ? x : x >= range.upperBound ? x - range.count : range.lowerBound
    }

    /// A single position that sticks to the character after it.
    public static func position(_ x: Int, through step: DeltaStep) -> Int {
        switch step {
        case .format: return x
        case .insert(let at, let cells): return x >= at ? x + cells.count : x
        case .delete(let range): return afterDelete(x, range)
        }
    }
}

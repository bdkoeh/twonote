#if canImport(UIKit)
import UIKit
import TwoNoteDocuments

/// Two-way binding between one `EditorTextView` (TextKit 2) and one page text.
///
/// Design (the Windows client's RichEditBinding, ported):
///  * A shadow model holds the last state the view and the page agreed on. Index parity is
///    exact: page index == text-storage index, final newline included. The text system shows an
///    empty line after that newline; the caret is kept out of it.
///  * view -> page is RECONCILIATION, not event translation: `syncLocal` diffs the storage
///    against the shadow and writes the difference as one page edit. Typing, autocorrect, paste,
///    dictation, drag and drop and IME commits need no special cases. The view decides the text
///    and the inline attributes of inserted text (they come from `typingAttributes`, which the
///    binding sets); block attributes follow the rules in `Reconciler`. Formatting commands are
///    model-first: page, shadow, then the storage is re-rendered from the shadow.
///  * page -> view applies the delta of a remote change or an undo as ranged storage edits,
///    carries the selection and the scroll position through it, and re-renders the touched
///    paragraphs. Our own writes happen under `applying`, so they are never read back as edits.
///  * While an IME composition is active (marked text) nothing is read or written: page changes
///    are queued. When the composition ends, the composed text is lifted out, the queued changes
///    are applied to the agreed state, and the text is put back where its place has moved to.
///  * Native undo is off; undo and redo go to the page, which only undoes this device's edits.
///
/// The binding takes over the text view's `delegate`, its text storage's delegate and its
/// layout manager's delegate.
@MainActor
public final class PageTextBinding: NSObject {
    public let textView: EditorTextView
    public let page: any PageText
    public private(set) var theme = EditorTheme()
    public private(set) var shadow = ShadowModel()

    /// Called after anything that can change `formatting` (selection, edits, remote changes).
    public var onStateChange: (() -> Void)?

    // Counters for tests and diagnostics.
    public private(set) var localTransactions = 0
    public private(set) var remoteDeltas = 0
    public private(set) var fullResets = 0
    public private(set) var queuedChanges = 0
    public private(set) var rebases = 0
    public private(set) var selectionRestores = 0
    public private(set) var scrollRestores = 0
    public private(set) var forbiddenCharactersRemoved = 0

    private var applying = false       // we are writing to the storage or selection ourselves
    private var syncing = false        // inside a reconciliation
    private var ownEdit = false        // inside our own page.edit
    private var storageDirty = false   // the storage's text changed and has not been reconciled
    private var settleScheduled = false
    // What the storage edits since the last reconciliation touched: first index, and how much
    // of the end was left alone. Everything in between is re-rendered, whatever the diff says
    // (typing over a newline with a newline is no change to the text, but the new one has no
    // block attributes in the storage).
    private var dirtyLow = Int.max
    private var dirtyTail = Int.max
    private var queued: [TextChange] = []
    private var pendingInline: InlineAttrs?
    private var observation: ChangeObservation?

    private var storage: NSTextStorage { textView.textStorage }

    public init(textView: EditorTextView, page: any PageText) {
        precondition(textView.textLayoutManager != nil, "the editor needs TextKit 2")
        self.textView = textView
        self.page = page
        super.init()
        textView.binding = self
        textView.delegate = self
        storage.delegate = self
        textView.textLayoutManager?.delegate = self
        fullReset()
        fullResets = 0
        observation = page.observeText { [weak self] change in self?.pageChanged(change) }

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        tap.delegate = self
        textView.addGestureRecognizer(tap)
        textView.registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (view: EditorTextView, _: UITraitCollection) in
            view.binding?.contentSizeChanged()
        }
    }

    /// Stops following the page.
    public func detach() {
        observation?.cancel()
        observation = nil
        if textView.binding === self { textView.binding = nil }
    }

    /// True while an IME composition (marked text) is in progress.
    public var isComposing: Bool { textView.markedTextRange != nil }

    /// True while page changes have to wait.
    public var isBusy: Bool { applying || syncing || isComposing }

    /// Still on TextKit 2? (UIKit falls back to TextKit 1 if anything touches `layoutManager`.)
    public var usesTextKit2: Bool { textView.textLayoutManager != nil }

    // MARK: - Storage access

    private func storageUnits() -> [UInt16] {
        let string = storage.string as NSString
        var units = [UInt16](repeating: 0, count: string.length)
        if !units.isEmpty {
            string.getCharacters(&units, range: NSRange(location: 0, length: string.length))
        }
        return units
    }

    private static func string(_ units: some Sequence<UInt16>) -> String {
        String(decoding: Array(units), as: UTF16.self)
    }

    /// Runs `body` as our own storage edit: not read back, one layout pass.
    private func writeStorage(_ body: () -> Void) {
        let outer = applying
        applying = true
        defer { applying = outer }
        if let content = textView.textLayoutManager?.textContentManager {
            content.performEditingTransaction(body)
        } else {
            storage.beginEditing()
            body()
            storage.endEditing()
        }
    }

    private func setSelection(_ range: NSRange) {
        guard textView.selectedRange != range else { return }
        let outer = applying
        applying = true
        textView.selectedRange = range
        applying = outer
    }

    // MARK: - Rendering (shadow -> storage attributes)

    private func context(forParagraphEndingAt newline: Int) -> ParagraphContext {
        let block = shadow[newline].block.effective
        var context = ParagraphContext()
        if block.block == "ol" {
            context.ordinal = shadow.ordinal(paragraphEndingAt: newline)
        } else if block.block == "code" {
            let start = shadow.paragraphStart(newline)
            let before = start > 0 ? shadow[start - 1].block.effective : BlockAttrs()
            let after = newline + 1 < shadow.count ? shadow.block(at: newline + 1).effective : BlockAttrs()
            if start == 0 || before != block { context.codeEdge |= 1 }
            if newline + 1 >= shadow.count || after != block { context.codeEdge |= 2 }
        }
        return context
    }

    /// Makes the storage attributes of the paragraphs covering `range` what the shadow says.
    /// `spread` also revisits the neighbours whose look depends on these (numbering, code edges).
    private func render(_ range: ClosedRange<Int>, spread: Bool) {
        guard shadow.count > 0, storage.length == shadow.count else { return }
        let last = shadow.count - 1
        var start = shadow.paragraphStart(min(max(range.lowerBound, 0), last))
        var end = shadow.paragraphEnd(min(max(range.upperBound, 0), last))
        if spread {
            if start > 0 { start = shadow.paragraphStart(start - 1) }
            while end < last {
                end = shadow.paragraphEnd(end + 1)
                let block = shadow[end].block.effective
                if block.block != "ol" && block.indent == 0 { break }
            }
        }
        var paragraphStart = start
        while paragraphStart <= end {
            let newline = shadow.paragraphEnd(paragraphStart)
            let block = shadow[newline].block
            let context = context(forParagraphEndingAt: newline)
            var i = paragraphStart
            while i <= newline {
                var j = i + 1
                if i < newline {
                    while j < newline && shadow[j].inline == shadow[i].inline { j += 1 }
                }
                let want = theme.attributes(for: shadow[i], paragraph: block, context: context)
                let target = NSRange(location: i, length: j - i)
                var effective = NSRange()
                let have = storage.attributes(at: i, longestEffectiveRange: &effective, in: target)
                if effective != target || !(have as NSDictionary).isEqual(to: want) {
                    storage.setAttributes(want, range: target)
                }
                i = j
            }
            paragraphStart = newline + 1
        }
    }

    /// Loads the whole view from the page. Used at start and as the safety net when a ranged
    /// apply did not produce the expected text (counted in `fullResets`).
    public func fullReset() {
        writeStorage(fullResetCore)
        storageDirty = false
        pendingInline = nil
        updateTypingAttributes()
    }

    private func fullResetCore() {
        fullResets += 1
        shadow = ShadowModel(runs: page.runs)
        storage.replaceCharacters(in: NSRange(location: 0, length: storage.length), with: shadow.text)
        if storage.length != shadow.count {
            // The page holds a lone surrogate; the view cannot mirror it index for index.
            shadow = ShadowModel(cells: [])
            storage.replaceCharacters(in: NSRange(location: 0, length: storage.length), with: "")
            return
        }
        if shadow.count > 0 { render(0...shadow.count - 1, spread: false) }
    }

    private func contentSizeChanged() {
        theme = EditorTheme(traits: textView.traitCollection)
        guard shadow.count > 0, !isComposing else { return }
        writeStorage { render(0...shadow.count - 1, spread: false) }
        updateTypingAttributes()
    }

    // MARK: - view -> page

    /// Brings the page up to date with whatever the view holds, and applies queued page changes.
    /// Idempotent; does nothing while an IME composition is active.
    public func syncLocal() {
        guard !isBusy else { return }
        if !queued.isEmpty {
            flushQueued()
        } else if storageDirty {
            reconcile()
        }
    }

    private func scheduleSettle() {
        guard !settleScheduled else { return }
        settleScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.settleScheduled = false
            self.syncLocal()
        }
    }

    /// Removes what must not reach the page and restores the final newline. Returns true when
    /// the final newline had to be put back.
    private func sanitizeStorage() -> Bool {
        let units = storageUnits()
        var remove: [Int] = []
        for (i, unit) in units.enumerated() {
            if TextSanitizer.isForbidden(unit) {
                remove.append(i)
            } else if UTF16.isLeadSurrogate(unit) {
                if i + 1 >= units.count || !UTF16.isTrailSurrogate(units[i + 1]) { remove.append(i) }
            } else if UTF16.isTrailSurrogate(unit) {
                if i == 0 || !UTF16.isLeadSurrogate(units[i - 1]) { remove.append(i) }
            }
        }
        if !remove.isEmpty {
            forbiddenCharactersRemoved += remove.count
            writeStorage {
                for i in remove.reversed() {
                    storage.deleteCharacters(in: NSRange(location: i, length: 1))
                }
            }
        }
        let string = storage.string as NSString
        if string.length == 0 || string.character(at: string.length - 1) != newlineUnit {
            writeStorage { storage.append(NSAttributedString(string: "\n")) }
            return true
        }
        return false
    }

    /// The page must end with a newline before anything can be written to it (PROTOCOL.md 5.2).
    private func ensureShadowNewline() {
        guard !shadow.endsWithNewline else { return }
        ownEdit = true
        page.edit { _ in }
        ownEdit = false
        localTransactions += 1
        shadow.replace(shadow.count..<shadow.count, with: [Cell(unit: newlineUnit)])
    }

    private func inlineFromStorage(_ range: Range<Int>) -> [InlineAttrs] {
        var result: [InlineAttrs] = []
        result.reserveCapacity(range.count)
        storage.enumerateAttributes(in: NSRange(location: range.lowerBound, length: range.count)) { attributes, run, _ in
            result.append(contentsOf: repeatElement(InlineAttrs(storage: attributes), count: run.length))
        }
        return result
    }

    private func reconcile() {
        syncing = true
        defer { syncing = false }
        storageDirty = false
        if !shadow.endsWithNewline && storage.length == shadow.count && storageUnits() == shadow.units {
            return // the page content has not arrived yet; showing it is not an edit
        }
        let repaired = sanitizeStorage()
        ensureShadowNewline()
        let now = storageUnits()
        let selection = textView.selectedRange
        let last = shadow.count - 1
        let touchedLow = max(0, min(dirtyLow, now.count - 1))
        let touchedHigh = dirtyTail == Int.max ? -1 : min(max(now.count - dirtyTail - 1, touchedLow), now.count - 1)
        dirtyLow = Int.max
        dirtyTail = Int.max
        guard let plan = Reconciler.plan(shadow: shadow, now: now, caret: NSMaxRange(selection),
                                         inlineOfInserted: inlineFromStorage) else {
            writeStorage {
                if touchedHigh >= touchedLow { render(touchedLow...touchedHigh, spread: false) }
                if repaired { render(last...last, spread: false) }
            }
            return
        }
        let deleted = plan.edit.start..<plan.edit.start + plan.edit.deleteCount
        let structural = plan.survivor != nil || shadow.units[deleted].contains(newlineUnit)
            || plan.inserted.contains(where: \.isNewline)
        ownEdit = true
        page.edit { plan.write(to: $0) }
        ownEdit = false
        localTransactions += 1
        plan.apply(to: &shadow)
        writeStorage {
            var range = plan.affectedRange(in: shadow)
            if touchedHigh >= touchedLow {
                range = min(range.lowerBound, touchedLow)...max(range.upperBound, min(touchedHigh, shadow.count - 1))
            }
            render(range, spread: structural)
            if repaired { render(shadow.count - 1...shadow.count - 1, spread: false) }
        }
        storageDirty = false
    }

    // MARK: - page -> view

    private func pageChanged(_ change: TextChange) {
        if ownEdit { return } // made by this binding: view and shadow already agree
        if isBusy || storageDirty || !queued.isEmpty {
            // Mid-composition, mid-reconciliation, or the view holds an edit the page has not
            // seen: the change waits (this handler must not edit the page either).
            queued.append(change)
            queuedChanges += 1
            if !isComposing { scheduleSettle() }
            return
        }
        apply(change)
        onStateChange?()
    }

    private func flushQueued() {
        guard !isBusy, !queued.isEmpty else { return }
        let changes = queued
        queued.removeAll()
        if storageDirty {
            rebase(over: changes)
        } else {
            for change in changes { apply(change) }
        }
        updateTypingAttributes()
        onStateChange?()
    }

    private struct ScrollAnchor {
        var position: Int
        var offsetInView: CGFloat
    }

    private func captureScrollAnchor() -> ScrollAnchor? {
        guard textView.window != nil, shadow.count > 0, textView.contentSize.height > textView.bounds.height else { return nil }
        let top = textView.contentOffset.y + textView.adjustedContentInset.top
        guard top > 1 else { return nil } // at the very top the view simply stays there
        let point = CGPoint(x: textView.textContainerInset.left + 8, y: top + 2)
        guard let position = textView.closestPosition(to: point) else { return nil }
        let index = textView.offset(from: textView.beginningOfDocument, to: position)
        return ScrollAnchor(position: index, offsetInView: textView.caretRect(for: position).minY - textView.contentOffset.y)
    }

    private func restore(_ anchor: ScrollAnchor) {
        let index = min(max(anchor.position, 0), max(0, shadow.count - 1))
        guard let position = textView.position(from: textView.beginningOfDocument, offset: index) else { return }
        textView.layoutIfNeeded()
        var offset = textView.contentOffset
        offset.y = textView.caretRect(for: position).minY - anchor.offsetInView
        let inset = textView.adjustedContentInset
        let maximum = max(-inset.top, textView.contentSize.height - textView.bounds.height + inset.bottom)
        offset.y = min(max(offset.y, -inset.top), maximum)
        if abs(offset.y - textView.contentOffset.y) > 0.5 {
            textView.setContentOffset(offset, animated: false)
            scrollRestores += 1
        }
    }

    /// Applies a change someone else made to the page (or an undo) to shadow and view.
    private func apply(_ change: TextChange) {
        remoteDeltas += 1
        let steps = DeltaStep.steps(for: change.delta)
        let before = textView.selectedRange
        var selection = SelectionTransform(start: before.location, end: NSMaxRange(before))
        var anchor = captureScrollAnchor()
        var low = Int.max, high = -1, lastChange = -1
        var structural = false
        var fits = true
        writeStorage {
            for step in steps {
                switch step {
                case .format(let range, let changes):
                    fits = shadow.apply(step)
                    if changes.keys.contains(where: { BlockAttrs.keys.contains($0) }) { structural = true }
                    low = min(low, range.lowerBound)
                    high = max(high, range.upperBound - 1)
                    lastChange = range.upperBound
                case .insert(let at, let cells):
                    fits = at <= storage.length && shadow.apply(step)
                    if fits {
                        storage.replaceCharacters(in: NSRange(location: at, length: 0), with: Self.string(cells.map(\.unit)))
                    }
                    if cells.contains(where: \.isNewline) { structural = true }
                    low = min(low, at)
                    high = max(high, at + cells.count)
                    lastChange = at + cells.count
                case .delete(let range):
                    if range.upperBound <= shadow.count, shadow.units[range].contains(newlineUnit) { structural = true }
                    fits = range.upperBound <= storage.length && shadow.apply(step)
                    if fits {
                        storage.deleteCharacters(in: NSRange(location: range.lowerBound, length: range.count))
                    }
                    high = max(high - range.count, range.lowerBound)
                    low = min(low, range.lowerBound)
                    lastChange = range.lowerBound
                }
                if !fits { break }
                selection.apply(step)
                if let current = anchor {
                    anchor?.position = SelectionTransform.position(current.position, through: step)
                }
            }
            // The cheap, decisive check: ranged edits must have produced exactly the page text.
            if !fits || storage.length != shadow.count || storageUnits() != shadow.units {
                fullResetCore()
                return
            }
            if high >= 0 && shadow.count > 0 {
                render(min(low, shadow.count - 1)...min(max(high, low), shadow.count - 1), spread: structural)
            }
        }

        let last = max(0, shadow.count - 1)
        var start = selection.start, end = selection.end
        if change.source == .undo && lastChange >= 0 {
            start = lastChange
            end = lastChange
        }
        start = min(max(start, 0), last)
        end = min(max(end, start), last)
        let wanted = NSRange(location: start, length: end - start)
        if textView.selectedRange != wanted {
            setSelection(wanted)
            selectionRestores += 1
        }
        if let anchor, change.source != .undo {
            restore(anchor)
        }
        updateTypingAttributes()
    }

    /// The view holds an edit the page has not seen (normally a just-finished IME composition)
    /// and the page has moved on. Lift the edit out, bring view and shadow up to date, then put
    /// the edit back where its place went and reconcile it as a normal local edit.
    private func rebase(over changes: [TextChange]) {
        rebases += 1
        _ = sanitizeStorage()
        let now = storageUnits()
        let edit = TextEdit.diff(shadow.units, now, caretHint: NSMaxRange(textView.selectedRange))
        storageDirty = false
        if edit.isEmpty {
            for change in changes { apply(change) }
            return
        }
        let typed = storage.attributedSubstring(from: NSRange(location: edit.start, length: edit.insertCount))
        let original = Self.string(shadow.units[edit.start..<edit.start + edit.deleteCount])
        writeStorage {
            storage.replaceCharacters(in: NSRange(location: edit.start, length: edit.insertCount), with: original)
            if shadow.count > 0 {
                render(edit.start...min(edit.start + edit.deleteCount, shadow.count - 1), spread: true)
            }
        }
        var place = SelectionTransform(start: edit.start, end: edit.start + edit.deleteCount)
        for change in changes {
            for step in DeltaStep.steps(for: change.delta) { place.apply(step) }
            apply(change)
        }
        let last = max(0, shadow.count - 1)
        let start = min(max(place.start, 0), last)
        let end = min(max(place.end, start), last)
        writeStorage {
            storage.replaceCharacters(in: NSRange(location: start, length: end - start), with: typed)
        }
        setSelection(NSRange(location: start + typed.length, length: 0))
        storageDirty = true
        reconcile()
    }

    // MARK: - Typing attributes

    /// Inline attributes text typed at `caret` gets: those of the character before it in the
    /// paragraph, else of what follows (for an empty paragraph, its paragraph mark). A link only
    /// continues inside itself, not at its edges.
    private func derivedInline(at caret: Int) -> InlineAttrs {
        guard shadow.count > 0 else { return InlineAttrs() }
        let index = min(max(caret, 0), shadow.count - 1)
        var inline: InlineAttrs
        if index > shadow.paragraphStart(index) {
            inline = shadow[index - 1].inline
            if inline.link != shadow[index].inline.link { inline.link = nil }
        } else {
            inline = shadow[index].inline
            inline.link = nil
        }
        return inline
    }

    private func typingInline() -> InlineAttrs {
        if let pendingInline { return pendingInline }
        let selection = textView.selectedRange
        if selection.length > 0 && selection.location < shadow.count {
            return shadow[selection.location].inline
        }
        return derivedInline(at: selection.location)
    }

    private func updateTypingAttributes() {
        guard !isComposing, shadow.count > 0 else { return }
        let block = shadow.block(at: min(textView.selectedRange.location, shadow.count - 1))
        let cell = Cell(unit: 0x61, inline: typingInline())
        textView.typingAttributes = theme.attributes(for: cell, paragraph: block, context: ParagraphContext())
    }

    // MARK: - Typing rules the view cannot know

    /// Return on an empty list item ends the list (or steps one level out) instead of adding a line.
    func handleInsert(_ text: String) -> Bool {
        guard text == "\n", !isBusy else { return false }
        syncLocal()
        let selection = textView.selectedRange
        guard selection.length == 0, shadow.endsWithNewline, selection.location < shadow.count else { return false }
        let start = shadow.paragraphStart(selection.location)
        let newline = shadow.paragraphEnd(selection.location)
        let block = shadow[newline].block.effective
        guard start == newline, block.isList else { return false }
        updateBlocks(in: start..<start) { current in
            current.indent > 0
                ? BlockAttrs(block: current.block, indent: current.indent - 1, checked: current.checked)
                : BlockAttrs()
        }
        return true
    }

    /// Backspace at the start of a paragraph first removes its block type, then its indent, and
    /// only then joins it to the paragraph above.
    func handleDeleteBackward() -> Bool {
        guard !isBusy else { return false }
        syncLocal()
        let selection = textView.selectedRange
        guard selection.length == 0, shadow.endsWithNewline, selection.location < shadow.count,
              selection.location == shadow.paragraphStart(selection.location) else { return false }
        let block = shadow.block(at: selection.location).effective
        if block.block != nil {
            updateBlocks(in: selection.location..<selection.location) { BlockAttrs(indent: $0.indent) }
            return true
        }
        if block.indent > 0 {
            updateBlocks(in: selection.location..<selection.location) { BlockAttrs(indent: $0.indent - 1) }
            return true
        }
        return false
    }

    // MARK: - Commands

    /// What the toolbar shows for the current selection.
    public struct Formatting: Equatable, Sendable {
        public var inline = InlineAttrs()
        public var block = BlockAttrs()
        public var hasSelection = false
        public var canUndo = false
        public var canRedo = false
    }

    public var formatting: Formatting {
        var result = Formatting(canUndo: page.canUndo, canRedo: page.canRedo)
        guard shadow.count > 0 else { return result }
        let selection = selectedRange
        result.hasSelection = !selection.isEmpty
        result.block = shadow.block(at: min(selection.lowerBound, shadow.count - 1)).effective
        if selection.isEmpty {
            result.inline = typingInline()
            result.inline.link = linkRange(at: selection.lowerBound)?.url
        } else {
            for key in InlineAttrs.keys where key != PageAttribute.link {
                if allHave(key, in: selection) { result.inline.set(key, .bool(true)) }
            }
            result.inline.link = linkRange(at: selection.lowerBound)?.url
        }
        return result
    }

    /// The selection as a range of page indexes.
    public var selectedRange: Range<Int> {
        let range = textView.selectedRange
        return range.location..<NSMaxRange(range)
    }

    private func beginCommand() -> Bool {
        guard !isBusy else { return false }
        syncLocal()
        guard !storageDirty, queued.isEmpty else { return false }
        ensureShadowNewline()
        if storage.length != shadow.count {
            writeStorage { storage.append(NSAttributedString(string: "\n")) }
            writeStorage { render(shadow.count - 1...shadow.count - 1, spread: false) }
        }
        return shadow.count > 0
    }

    private func edit(_ body: (any PageTextEditor) -> Void) {
        ownEdit = true
        page.edit(body)
        ownEdit = false
        localTransactions += 1
    }

    /// Moves the ends of a range off the middle of surrogate pairs and into the text.
    private func aligned(_ range: Range<Int>) -> Range<Int> {
        func fix(_ index: Int) -> Int {
            let i = min(max(index, 0), shadow.count)
            if i > 0 && i < shadow.count && UTF16.isTrailSurrogate(shadow.units[i]) && UTF16.isLeadSurrogate(shadow.units[i - 1]) {
                return i - 1
            }
            return i
        }
        let lower = fix(range.lowerBound)
        return lower..<max(lower, fix(range.upperBound))
    }

    /// True when every character of the range (paragraph marks aside) carries the attribute.
    public func allHave(_ key: String, in range: Range<Int>) -> Bool {
        let range = aligned(range)
        var any = false
        for i in range where !shadow[i].isNewline {
            if shadow[i].inline.value(for: key) == nil { return false }
            any = true
        }
        return any
    }

    /// Sets or removes one inline attribute on a range (model-first).
    public func setInline(_ key: String, _ value: AttributeValue?, in range: Range<Int>) {
        guard beginCommand() else { return }
        let range = aligned(range)
        guard !range.isEmpty, range.contains(where: { shadow[$0].inline.value(for: key) != value }) else { return }
        var changes: AttributeChanges = [:]
        changes.updateValue(value, forKey: key)
        edit { $0.format(at: range.lowerBound, count: range.count, attributes: changes) }
        for i in range { shadow[i].inline.set(key, value) }
        writeStorage { render(range.lowerBound...range.upperBound - 1, spread: false) }
        updateTypingAttributes()
        onStateChange?()
    }

    /// Toggles bold, italic, underline, strike or code on the selection or, at a caret, for
    /// what is typed next.
    public func toggleInline(_ key: String) {
        guard beginCommand() else { return }
        let selection = selectedRange
        if selection.isEmpty {
            var inline = typingInline()
            inline.set(key, inline.value(for: key) == nil ? .bool(true) : nil)
            pendingInline = inline
            updateTypingAttributes()
            onStateChange?()
        } else {
            setInline(key, allHave(key, in: selection) ? nil : .bool(true), in: selection)
        }
    }

    /// The link around a position: the run of characters carrying the same URL.
    public func linkRange(at position: Int) -> (range: Range<Int>, url: String)? {
        func url(_ i: Int) -> String? { i >= 0 && i < shadow.count ? shadow[i].inline.link : nil }
        let at = url(position) != nil ? position : url(position - 1) != nil ? position - 1 : -1
        guard at >= 0, let found = url(at) else { return nil }
        var start = at, end = at + 1
        while url(start - 1) == found { start -= 1 }
        while url(end) == found { end += 1 }
        return (start..<end, found)
    }

    /// Sets (or with nil removes) the link on the selection; at a caret, on the link around it.
    public func setLink(_ url: String?, in range: Range<Int>? = nil) {
        let trimmed = url?.trimmingCharacters(in: .whitespacesAndNewlines)
        let value: AttributeValue? = (trimmed?.isEmpty ?? true) ? nil : .string(trimmed!)
        var target = range ?? selectedRange
        if target.isEmpty, let around = linkRange(at: target.lowerBound) { target = around.range }
        setInline(PageAttribute.link, value, in: target)
    }

    /// Inserts `text` at the selection as a link to `url`.
    public func insertLink(text: String, url: String) {
        guard beginCommand(), let range = textView.selectedTextRange else { return }
        let clean = TextSanitizer.plainText(text).replacingOccurrences(of: "\n", with: " ")
        guard !clean.isEmpty else { return }
        let start = selectedRange.lowerBound
        textView.replace(range, withText: clean)
        syncLocal()
        setInline(PageAttribute.link, .string(url), in: start..<start + clean.utf16.count)
    }

    /// Changes the block attributes of every paragraph touching the range (model-first).
    public func updateBlocks(in range: Range<Int>? = nil, _ change: (BlockAttrs) -> BlockAttrs) {
        guard beginCommand() else { return }
        let range = range ?? selectedRange
        let last = shadow.count - 1
        let start = min(max(range.lowerBound, 0), last)
        var end = min(max(range.upperBound, start), last)
        if end > start && shadow[end - 1].isNewline {
            end -= 1 // a selection ending right after a paragraph mark does not include the next paragraph
        }
        var changes: [(newline: Int, block: BlockAttrs)] = []
        var paragraph = shadow.paragraphStart(start)
        while paragraph <= end {
            let newline = shadow.paragraphEnd(paragraph)
            let before = shadow[newline].block
            var after = change(before.effective)
            after.indent = min(max(after.indent, 0), PageAttribute.maxIndent)
            if after.block != "todo" { after.checked = false }
            if after != before { changes.append((newline, after)) }
            paragraph = newline + 1
        }
        guard let first = changes.first, let final = changes.last else { return }
        edit { editor in
            for (newline, block) in changes {
                editor.setBlock(newlineAt: newline, block: block.block, indent: block.indent, checked: block.checked)
            }
        }
        for (newline, block) in changes { shadow[newline].block = block }
        writeStorage { render(first.newline...final.newline, spread: true) }
        updateTypingAttributes()
        onStateChange?()
    }

    /// Makes the selected paragraphs `block` (nil: plain paragraphs), keeping their indent.
    public func setBlock(_ block: String?) {
        updateBlocks { BlockAttrs(block: block, indent: $0.indent) }
    }

    /// Like `setBlock`, but back to a plain paragraph when the first selected paragraph already is `block`.
    public func toggleBlock(_ block: String) {
        let current = formatting.block.block
        setBlock(current == block ? nil : block)
    }

    public func indent(by delta: Int) {
        updateBlocks { BlockAttrs(block: $0.block, indent: $0.indent + delta, checked: $0.checked) }
    }

    /// Ticks or unticks the to-do paragraph containing `position`.
    public func toggleChecked(paragraphAt position: Int) {
        updateBlocks(in: position..<position) { current in
            current.block == "todo" ? BlockAttrs(block: "todo", indent: current.indent, checked: !current.checked) : current
        }
    }

    @discardableResult
    public func undo() -> Bool {
        guard !isBusy else { return false }
        syncLocal()
        pendingInline = nil
        let done = page.undo()
        onStateChange?()
        return done
    }

    @discardableResult
    public func redo() -> Bool {
        guard !isBusy else { return false }
        syncLocal()
        pendingInline = nil
        let done = page.redo()
        onStateChange?()
        return done
    }

    // MARK: - Checkboxes

    private func fragment(containing index: Int) -> BlockLayoutFragment? {
        guard let layout = textView.textLayoutManager,
              let location = layout.location(layout.documentRange.location, offsetBy: index) else { return nil }
        var found: BlockLayoutFragment?
        layout.enumerateTextLayoutFragments(from: location, options: [.ensuresLayout]) { fragment in
            found = fragment as? BlockLayoutFragment
            return false
        }
        return found
    }

    /// The newline index of the to-do paragraph whose checkbox is at `point` (text view coordinates).
    public func checkboxParagraph(at point: CGPoint) -> Int? {
        guard let layout = textView.textLayoutManager, shadow.count > 0 else { return nil }
        let inset = textView.textContainerInset
        let inContainer = CGPoint(x: point.x - inset.left, y: point.y - inset.top)
        guard let fragment = layout.textLayoutFragment(for: inContainer) as? BlockLayoutFragment,
              fragment.info?.block.block == "todo", let marker = fragment.markerRect else { return nil }
        let frame = fragment.layoutFragmentFrame
        let local = CGPoint(x: inContainer.x - frame.minX, y: inContainer.y - frame.minY)
        guard marker.insetBy(dx: -6, dy: -4).contains(local) else { return nil }
        let start = layout.offset(from: layout.documentRange.location, to: fragment.rangeInElement.location)
        return shadow.paragraphEnd(min(max(start, 0), shadow.count - 1))
    }

    /// The centre of the list marker of the paragraph containing `index` (text view coordinates).
    public func markerCenter(forParagraphAt index: Int) -> CGPoint? {
        guard shadow.count > 0, let fragment = fragment(containing: shadow.paragraphStart(index)),
              let marker = fragment.markerRect else { return nil }
        let frame = fragment.layoutFragmentFrame
        let inset = textView.textContainerInset
        return CGPoint(x: frame.minX + marker.midX + inset.left, y: frame.minY + marker.midY + inset.top)
    }

    @objc private func handleTap(_ recognizer: UITapGestureRecognizer) {
        guard recognizer.state == .ended, let newline = checkboxParagraph(at: recognizer.location(in: textView)) else { return }
        toggleChecked(paragraphAt: newline)
    }

    // MARK: - Verification (tests)

    /// The storage as cells: text plus the page attributes it holds. Block attributes are read
    /// from every character, so strays on ordinary text show up as differences.
    public func storageCells() -> [Cell] {
        let units = storageUnits()
        var cells: [Cell] = []
        cells.reserveCapacity(units.count)
        storage.enumerateAttributes(in: NSRange(location: 0, length: storage.length)) { attributes, run, _ in
            let inline = InlineAttrs(storage: attributes)
            let block = BlockAttrs(storage: attributes)
            for i in run.location..<NSMaxRange(run) {
                cells.append(Cell(unit: units[i], inline: inline, block: block))
            }
        }
        return cells
    }

    /// nil when view, shadow and page agree; otherwise what differs.
    public func verify() -> String? {
        guard usesTextKit2 else { return "the text view fell back to TextKit 1" }
        let pageCells = ShadowModel(runs: page.runs).cells
        if pageCells != shadow.cells {
            return "shadow differs from page:\n" + Self.firstDifference(ShadowModel.dump(shadow.cells), ShadowModel.dump(pageCells))
        }
        let view = storageCells()
        if view != shadow.cells {
            return "view differs from shadow:\n" + Self.firstDifference(ShadowModel.dump(view), ShadowModel.dump(shadow.cells))
        }
        return nil
    }

    private static func firstDifference(_ a: String, _ b: String) -> String {
        let x = Array(a.unicodeScalars), y = Array(b.unicodeScalars)
        var i = 0
        while i < x.count && i < y.count && x[i] == y[i] { i += 1 }
        func excerpt(_ s: [Unicode.Scalar]) -> String {
            var out = String.UnicodeScalarView()
            out.append(contentsOf: s[max(0, i - 30)..<min(s.count, i + 40)])
            return String(out).replacingOccurrences(of: "\n", with: "⏎")
        }
        return "  at \(i): \(excerpt(x))\n  vs    : \(excerpt(y))"
    }
}

// MARK: - UIKit callbacks

extension PageTextBinding: UITextViewDelegate {
    public func textViewDidChange(_ textView: UITextView) {
        guard !applying, !syncing, !isComposing else { return }
        syncLocal()
        updateTypingAttributes()
        onStateChange?()
    }

    public func textViewDidChangeSelection(_ textView: UITextView) {
        guard !applying, !syncing, !isComposing else { return }
        let edited = storageDirty
        syncLocal()
        if !edited { page.breakUndoGroup() }
        // Keep the caret out of the empty line after the final newline.
        let selection = textView.selectedRange
        let last = max(0, storage.length - 1)
        if storage.length > 0 && NSMaxRange(selection) > last {
            let start = min(selection.location, last)
            setSelection(NSRange(location: start, length: last - start))
        }
        pendingInline = nil
        updateTypingAttributes()
        onStateChange?()
    }

    public func textViewDidEndEditing(_ textView: UITextView) {
        syncLocal()
    }
}

extension PageTextBinding: @preconcurrency NSTextStorageDelegate {
    public func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorage.EditActions,
                            range editedRange: NSRange, changeInLength delta: Int) {
        guard !applying, editedMask.contains(.editedCharacters) else { return }
        storageDirty = true
        dirtyLow = min(dirtyLow, editedRange.location)
        dirtyTail = min(dirtyTail, max(0, textStorage.length - NSMaxRange(editedRange)))
        // Normally textViewDidChange reconciles within this same event; this covers edits
        // UIKit makes without telling the delegate.
        scheduleSettle()
    }
}

extension PageTextBinding: @preconcurrency NSTextLayoutManagerDelegate {
    public func textLayoutManager(_ textLayoutManager: NSTextLayoutManager,
                                  textLayoutFragmentFor location: any NSTextLocation,
                                  in textElement: NSTextElement) -> NSTextLayoutFragment {
        BlockLayoutFragment(textElement: textElement, range: textElement.elementRange)
    }
}

extension PageTextBinding: UIGestureRecognizerDelegate {
    public func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        !isBusy && checkboxParagraph(at: gestureRecognizer.location(in: textView)) != nil
    }
}
#endif

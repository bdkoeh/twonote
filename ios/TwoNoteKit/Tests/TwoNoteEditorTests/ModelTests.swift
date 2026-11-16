import Testing
import TwoNoteDocuments
@testable import TwoNoteEditor

private func u(_ s: String) -> [UInt16] { Array(s.utf16) }

@Suite struct TextEditDiffTests {
    @Test func equalTextsGiveNoEdit() {
        #expect(TextEdit.diff(u("abc\n"), u("abc\n")).isEmpty)
    }

    @Test func insertDeleteReplace() {
        #expect(TextEdit.diff(u("abc\n"), u("abXc\n")) == TextEdit(start: 2, deleteCount: 0, insertCount: 1))
        #expect(TextEdit.diff(u("abc\n"), u("ac\n")) == TextEdit(start: 1, deleteCount: 1, insertCount: 0))
        #expect(TextEdit.diff(u("abc\n"), u("aXYc\n")) == TextEdit(start: 1, deleteCount: 1, insertCount: 2))
    }

    @Test func finalNewlineIsNeverPartOfTheEdit() {
        #expect(TextEdit.diff(u("a\n"), u("a\n\n"), caretHint: 2) == TextEdit(start: 1, deleteCount: 0, insertCount: 1))
        #expect(TextEdit.diff(u("abc\ndef\n"), u("\n")) == TextEdit(start: 0, deleteCount: 7, insertCount: 0))
        #expect(TextEdit.diff(u("abc\n"), u("abc\nX\n"), caretHint: 5) == TextEdit(start: 3, deleteCount: 0, insertCount: 2))
    }

    @Test func caretHintPlacesEditsInsideRunsOfEqualCharacters() {
        // "aaaa" -> "aaaaa": the new "a" is wherever the caret is.
        #expect(TextEdit.diff(u("aaaa\n"), u("aaaaa\n"), caretHint: 1).start == 0)
        #expect(TextEdit.diff(u("aaaa\n"), u("aaaaa\n"), caretHint: 3).start == 2)
        #expect(TextEdit.diff(u("aaaa\n"), u("aaaaa\n"), caretHint: 5).start == 4)
        // Newline typed between two newlines.
        #expect(TextEdit.diff(u("a\n\n\nb\n"), u("a\n\n\n\nb\n"), caretHint: 3).start == 2)
    }

    @Test func surrogatePairsAreNeverSplit() {
        // U+1F600 and U+1F601 share the high surrogate.
        let high = TextEdit.diff(u("a\u{1F600}b\n"), u("a\u{1F601}b\n"))
        #expect(high == TextEdit(start: 1, deleteCount: 2, insertCount: 2))
        // U+1F600 (D83D DE00) and U+1F200 (D83C DE00) share the low surrogate.
        let low = TextEdit.diff(u("a\u{1F600}b\n"), u("a\u{1F200}b\n"))
        #expect(low == TextEdit(start: 1, deleteCount: 2, insertCount: 2))
    }
}

@Suite struct ShadowModelTests {
    private let runs = [
        TextRun(text: "Title"),
        TextRun(text: "\n", attributes: ["block": .string("h1")]),
        TextRun(text: "one "),
        TextRun(text: "bold", attributes: ["bold": .bool(true)]),
        TextRun(text: "\n", attributes: ["block": .string("ol")]),
        TextRun(text: "deep"),
        TextRun(text: "\n", attributes: ["block": .string("ul"), "indent": .number(1)]),
        TextRun(text: "two"),
        TextRun(text: "\n", attributes: ["block": .string("ol")]),
        TextRun(text: "x"),
        TextRun(text: "\n", attributes: ["block": .string("mystery"), "indent": .number(12), "checked": .bool(true)]),
    ]

    @Test func runsRoundTrip() {
        let model = ShadowModel(runs: runs)
        #expect(model.runs == runs)
        #expect(model.text == "Title\none bold\ndeep\ntwo\nx\n")
        #expect(model.units == u(model.text))
    }

    @Test func paragraphHelpers() {
        let model = ShadowModel(runs: runs)
        #expect(model.paragraphStart(0) == 0)
        #expect(model.paragraphStart(5) == 0)
        #expect(model.paragraphStart(6) == 6)
        #expect(model.paragraphEnd(0) == 5)
        #expect(model.paragraphEnd(5) == 5)
        #expect(model.paragraphEnd(6) == 14)
        #expect(model.block(at: 8) == BlockAttrs(block: "ol"))
        #expect(model.paragraphEnd(model.count) == model.count - 1)
    }

    @Test func unknownBlockValuesSurviveButAreNotShown() {
        let model = ShadowModel(runs: runs)
        let raw = model.block(at: model.count - 1)
        #expect(raw == BlockAttrs(block: "mystery", indent: 12, checked: true))
        #expect(raw.effective == BlockAttrs(block: nil, indent: 8, checked: false))
    }

    @Test func ordinalsSkipDeeperParagraphs() {
        let model = ShadowModel(runs: runs)
        #expect(model.ordinal(paragraphEndingAt: 14) == 1)
        #expect(model.ordinal(paragraphEndingAt: 23) == 2)
    }

    @Test func sanitizer() {
        #expect(TextSanitizer.plainText("a\r\nb\rc\u{2029}d\u{FFFC}e\u{2028}f") == "a\nb\nc\nde\u{2028}f")
    }
}

@Suite struct ReconcilerTests {
    private func model(_ runs: [TextRun]) -> ShadowModel { ShadowModel(runs: runs) }
    private let plainInline: (Range<Int>) -> [InlineAttrs] = { Array(repeating: InlineAttrs(), count: $0.count) }

    @Test func typingProducesOneInsert() throws {
        let shadow = model([TextRun(text: "ab\n")])
        let plan = try #require(Reconciler.plan(shadow: shadow, now: u("aXb\n"), caret: 2) { range in
            Array(repeating: InlineAttrs(bold: true), count: range.count)
        })
        #expect(plan.ops == [.insert(at: 1, text: "X", attributes: ["bold": .bool(true)])])
        var after = shadow
        plan.apply(to: &after)
        #expect(after.runs == [TextRun(text: "a"), TextRun(text: "X", attributes: ["bold": .bool(true)]), TextRun(text: "b\n")])
    }

    @Test func returnInListContinuesTheList() throws {
        let shadow = model([TextRun(text: "item"), TextRun(text: "\n", attributes: ["block": .string("ul"), "indent": .number(2)])])
        let plan = try #require(Reconciler.plan(shadow: shadow, now: u("it\nem\n"), caret: 3, inlineOfInserted: plainInline))
        #expect(plan.ops == [.insert(at: 2, text: "\n", attributes: ["block": .string("ul"), "indent": .number(2)])])
    }

    @Test func returnAtEndOfHeadingStartsPlainParagraph() throws {
        let shadow = model([TextRun(text: "Head"), TextRun(text: "\n", attributes: ["block": .string("h2")])])
        let plan = try #require(Reconciler.plan(shadow: shadow, now: u("Head\n\n"), caret: 5, inlineOfInserted: plainInline))
        #expect(plan.ops == [
            .insert(at: 4, text: "\n", attributes: ["block": .string("h2")]),
            .setBlock(newlineAt: 5, block: BlockAttrs()),
        ])
        var after = shadow
        plan.apply(to: &after)
        #expect(after.block(at: 0).block == "h2")
        #expect(after.block(at: 5).block == nil)
    }

    @Test func returnInMiddleOfHeadingKeepsBothHalvesHeadings() throws {
        let shadow = model([TextRun(text: "Head"), TextRun(text: "\n", attributes: ["block": .string("h2")])])
        let plan = try #require(Reconciler.plan(shadow: shadow, now: u("He\nad\n"), caret: 3, inlineOfInserted: plainInline))
        #expect(plan.survivor == nil)
    }

    @Test func returnInTickedTodoStartsUntickedOne() throws {
        let shadow = model([TextRun(text: "done"), TextRun(text: "\n", attributes: ["block": .string("todo"), "checked": .bool(true)])])
        let plan = try #require(Reconciler.plan(shadow: shadow, now: u("done\n\n"), caret: 5, inlineOfInserted: plainInline))
        var after = shadow
        plan.apply(to: &after)
        #expect(after[4].block == BlockAttrs(block: "todo", checked: true))
        #expect(after[5].block == BlockAttrs(block: "todo", checked: false))
    }

    @Test func joiningParagraphsKeepsTheFirstOnesLook() throws {
        let shadow = model([
            TextRun(text: "item"), TextRun(text: "\n", attributes: ["block": .string("ul")]),
            TextRun(text: "plain\n"),
        ])
        // Backspace at the start of "plain".
        let plan = try #require(Reconciler.plan(shadow: shadow, now: u("itemplain\n"), caret: 4, inlineOfInserted: plainInline))
        #expect(plan.ops == [.delete(at: 4, count: 1), .setBlock(newlineAt: 9, block: BlockAttrs(block: "ul"))])
    }

    @Test func deletingWholeParagraphsLeavesTheNextOneAlone() throws {
        let shadow = model([
            TextRun(text: "item"), TextRun(text: "\n", attributes: ["block": .string("ul")]),
            TextRun(text: "head"), TextRun(text: "\n", attributes: ["block": .string("h1")]),
        ])
        let plan = try #require(Reconciler.plan(shadow: shadow, now: u("head\n"), caret: 0, inlineOfInserted: plainInline))
        #expect(plan.ops == [.delete(at: 0, count: 5)])
    }

    @Test func pastedLinesBecomeSeparateInserts() throws {
        let shadow = model([TextRun(text: "ab\n")])
        let plan = try #require(Reconciler.plan(shadow: shadow, now: u("a1\n2b\n"), caret: 4, inlineOfInserted: plainInline))
        #expect(plan.ops == [
            .insert(at: 1, text: "1", attributes: [:]),
            .insert(at: 2, text: "\n", attributes: [:]),
            .insert(at: 3, text: "2", attributes: [:]),
        ])
    }
}

@Suite struct DeltaTests {
    @Test func stepsUseRunningCoordinates() {
        let steps = DeltaStep.steps(for: [
            .retain(count: 2, attributes: nil),
            .insert(text: "XY", attributes: [:]),
            .delete(count: 3),
            .retain(count: 1, attributes: ["bold": .bool(true)]),
        ])
        #expect(steps.count == 3)
        #expect(steps[0].touched == 2..<4)
        #expect(steps[1] == .delete(range: 4..<7))
        #expect(steps[2].touched == 4..<5)
    }

    @Test func selectionTransformRules() {
        let x = Cell.cells(text: "x", attributes: [:])
        let xx = Cell.cells(text: "xx", attributes: [:])
        // Caret: remote text typed exactly at the caret goes after it.
        var caret = SelectionTransform(start: 3, end: 3)
        caret.apply(.insert(at: 3, cells: xx))
        #expect(caret.start == 3 && caret.end == 3)
        caret.apply(.insert(at: 1, cells: xx))
        #expect(caret.start == 5 && caret.end == 5)
        caret.apply(.delete(range: 0..<2))
        #expect(caret.start == 3 && caret.end == 3)
        caret.apply(.delete(range: 2..<9))
        #expect(caret.start == 2 && caret.end == 2)

        // Selection: text inserted at either edge stays outside, inside it grows.
        var sel = SelectionTransform(start: 3, end: 6)
        sel.apply(.insert(at: 3, cells: x))
        #expect(sel.start == 4 && sel.end == 7)
        sel.apply(.insert(at: 7, cells: x))
        #expect(sel.start == 4 && sel.end == 7)
        sel.apply(.insert(at: 5, cells: x))
        #expect(sel.start == 4 && sel.end == 8)
        sel.apply(.delete(range: 2..<5))
        #expect(sel.start == 2 && sel.end == 5)
    }
}

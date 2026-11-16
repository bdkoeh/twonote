import UIKit
import XCTest
import TwoNoteDocuments
import TwoNoteEditor

/// Real UITextViews (TextKit 2) in the host app's window, driven the way UIKit drives them for
/// user input, each bound to its own replica of one page.
@MainActor
final class BindingTests: XCTestCase {
    private var harness: Harness!

    override func tearDown() async throws {
        harness?.tearDown()
        harness = nil
    }

    private func start(_ seed: [TextRun]) throws -> Harness {
        let h = try Harness(seed: seed)
        harness = h
        XCTAssertTrue(h.bindingA.usesTextKit2 && h.bindingB.usesTextKit2)
        return h
    }

    private var everything: [TextRun] {
        [
            txt("Title"), para("h1"),
            txt("plain "), txt("bold", ["bold": .bool(true)]), txt(" "), txt("italic", ["italic": .bool(true)]), txt(" "),
            txt("under", ["underline": .bool(true)]), txt(" "), txt("strike", ["strike": .bool(true)]), txt(" "),
            txt("code", ["code": .bool(true)]), txt(" "), txt("link", ["link": .string("https://example.com")]), para(),
            txt("Two"), para("h2"), txt("Three"), para("h3"),
            txt("bullet"), para("ul"), txt("deeper"), para("ul", indent: 1),
            txt("first"), para("ol"), txt("second"), para("ol"),
            txt("open"), para("todo"), txt("done"), para("todo", checked: true),
            txt("let x = 1"), para("code"), txt("print(x)"), para("code"),
            txt("soft\u{2028}break 😀"), para(indent: 3),
            txt("future"), para("callout", indent: 2),
            txt("end"), para(),
        ]
    }

    // MARK: Scripted

    func testInitialRenderHoldsEveryAttribute() throws {
        let h = try start(everything)
        XCTAssertTrue(h.converge("initial"))
        XCTAssertEqual(h.viewA.plain, h.a.text)
        XCTAssertEqual(h.bindingA.fullResets, 0)
        // Unknown block values survive in the view's attributes and are simply not drawn.
        let cells = h.bindingA.storageCells()
        XCTAssertTrue(cells.contains { $0.block.block == "callout" })
        XCTAssertNil(h.viewA.textStorage.attribute(.link, at: 40, effectiveRange: nil))
    }

    /// Whether UIKit tells the delegate about programmatic input (a finding either way: the
    /// binding also reconciles from the text storage's own notification).
    func testProgrammaticInputReachesThePageWithoutHelp() throws {
        let h = try start([txt("abc\n")])
        h.viewA.type("x", at: 1)
        XCTAssertEqual(h.a.text, "axbc\n", "insertText")
        h.viewA.deleteBackward()
        XCTAssertEqual(h.a.text, "abc\n", "deleteBackward")
        h.viewA.replace(try XCTUnwrap(h.viewA.textRange(0, 2)), withText: "ZZZ")
        XCTAssertEqual(h.a.text, "ZZZc\n", "replace(_:withText:)")
        h.viewA.setMarkedText("ka", selectedRange: NSRange(location: 2, length: 0))
        XCTAssertEqual(h.a.text, "ZZZc\n", "marked text must not reach the page")
        h.viewA.unmarkText()
        XCTAssertEqual(h.a.text.count, 7, "unmarkText")
        XCTAssertTrue(h.converge("end"))
    }

    func testTypingAndDeletingReachTheOtherView() throws {
        let h = try start([txt("Hello world\n")])
        h.viewA.type("X", at: 5)
        XCTAssertTrue(h.converge("insert"))
        XCTAssertEqual(h.viewB.plain, "HelloX world\n")
        h.viewA.type("😀", at: 0)
        h.viewA.type("\n", at: 3)
        XCTAssertTrue(h.converge("emoji and newline"))
        XCTAssertEqual(h.viewB.plain, "😀H\nelloX world\n")
        h.viewA.select(4)
        h.viewA.deleteBackward()
        XCTAssertTrue(h.converge("join"))
        h.viewA.type("\u{2028}", at: 2)
        h.viewB.type("B", at: h.b.length - 1)
        XCTAssertTrue(h.converge("soft break and B typing"))
        XCTAssertEqual(h.viewA.plain, "😀\u{2028}HelloX worldB\n")
        // Select all, delete: only the final newline is left.
        h.viewA.select(0, h.viewA.textStorage.length)
        h.viewA.deleteBackward()
        XCTAssertTrue(h.converge("delete all"))
        XCTAssertEqual(h.b.text, "\n")
        // Typing after the final newline is impossible: the caret is kept in front of it.
        h.viewA.select(1)
        XCTAssertEqual(h.viewA.selectedRange.location, 0)
        h.viewA.insertText("again")
        XCTAssertTrue(h.converge("type into empty page"))
        XCTAssertEqual(h.b.text, "again\n")
        XCTAssertEqual(h.bindingA.fullResets + h.bindingB.fullResets, 0)
    }

    func testTypingAttributes() throws {
        let link: Attributes = ["link": .string("https://example.com")]
        let h = try start([
            txt("ab"), txt("cd", ["bold": .bool(true)]), txt("ef"), para(),
            txt("\n", ["italic": .bool(true)]),
            txt("go "), txt("link", link), txt(" end"), para(),
        ])
        let a = h.bindingA
        h.viewA.type("X", at: 3)
        XCTAssertTrue(a.shadow[3].inline.bold, "typed inside a bold run")
        h.viewA.type("Y", at: 8)
        XCTAssertTrue(a.shadow[8].inline.italic, "typed into an empty paragraph whose mark is italic")
        h.viewA.type("Z", at: 15)
        XCTAssertEqual(a.shadow[15].inline.link, "https://example.com", "typed inside a link")
        h.viewA.type("W", at: 13)
        XCTAssertNil(a.shadow[13].inline.link, "typed in front of a link")
        let afterLink = try XCTUnwrap(a.linkRange(at: 15)).range.upperBound
        h.viewA.type("V", at: afterLink)
        XCTAssertNil(a.shadow[afterLink].inline.link, "typed behind a link")
        // Bold switched on at a caret applies to what is typed next, and keeps going.
        h.viewA.select(0)
        a.toggleInline("bold")
        XCTAssertTrue(a.formatting.inline.bold)
        h.viewA.insertText("Q")
        h.viewA.insertText("R")
        XCTAssertTrue(a.shadow[0].inline.bold && a.shadow[1].inline.bold)
        XCTAssertFalse(a.shadow[2].inline.bold)
        XCTAssertTrue(h.converge("typing attributes"))
    }

    func testListAndHeadingRules() throws {
        let h = try start([
            txt("one"), para("ul"), txt("Head"), para("h2"), txt("done"), para("todo", checked: true), txt("tail"), para(),
        ])
        let a = h.bindingA
        let original = h.a.text
        h.viewA.type("\n", at: 3)
        XCTAssertEqual(a.shadow.block(at: 4).block, "ul", "Return in a list item makes another item")
        XCTAssertEqual(h.viewA.selectedRange.location, 4)
        h.viewA.insertText("\n")
        XCTAssertNil(a.shadow.block(at: 4).block, "Return on an empty item ends the list")
        XCTAssertEqual(h.a.text.utf16.count, original.utf16.count + 1)
        h.viewA.deleteBackward()
        XCTAssertEqual(h.a.text, original, "Backspace joins the empty paragraph to the item above")
        XCTAssertEqual(a.shadow.block(at: 0).block, "ul")
        XCTAssertTrue(h.converge("list return rules"))

        h.viewA.type("\n", at: 8)
        XCTAssertEqual(a.shadow.block(at: 4).block, "h2")
        XCTAssertNil(a.shadow.block(at: 9).block, "Return at the end of a heading starts a plain paragraph")
        h.viewA.type("\n", at: 14)
        XCTAssertEqual(a.shadow[14].block, BlockAttrs(block: "todo", checked: true))
        XCTAssertEqual(a.shadow[15].block, BlockAttrs(block: "todo"), "Return in a ticked to-do starts an unticked one")
        XCTAssertTrue(h.converge("heading and todo rules"))

        let before = h.a.text
        h.viewA.select(0)
        h.viewA.deleteBackward()
        XCTAssertNil(a.shadow.block(at: 0).block, "Backspace at the start of a list item removes the block")
        XCTAssertEqual(h.a.text, before)
        a.indent(by: 2)
        h.viewA.deleteBackward()
        XCTAssertEqual(a.shadow.block(at: 0).indent, 1, "then Backspace steps the indent out")
        h.viewA.deleteBackward()
        XCTAssertEqual(a.shadow.block(at: 0).indent, 0)
        XCTAssertEqual(h.a.text, before)
        XCTAssertTrue(h.converge("backspace rules"))
    }

    func testCommands() throws {
        let h = try start([txt("alpha beta gamma\n"), txt("second\n")])
        let a = h.bindingA
        h.viewA.select(6, 4)
        a.toggleInline("bold")
        XCTAssertTrue(a.formatting.inline.bold && a.formatting.hasSelection)
        XCTAssertTrue(h.converge("bold"))
        XCTAssertTrue(h.bindingB.allHave("bold", in: 6..<10))
        XCTAssertFalse(h.bindingB.allHave("bold", in: 5..<10))
        a.toggleInline("bold")
        XCTAssertFalse(a.formatting.inline.bold)

        h.viewA.select(0, 5)
        for key in ["italic", "underline", "strike", "code"] { a.toggleInline(key) }
        XCTAssertEqual(h.a.runs.first, txt("alpha", ["italic": .bool(true), "underline": .bool(true), "strike": .bool(true), "code": .bool(true)]))
        XCTAssertTrue(h.converge("inline toggles"))

        h.viewA.select(11, 5)
        a.setLink(" https://x.test ")
        XCTAssertEqual(a.linkRange(at: 12)?.range, 11..<16)
        h.viewA.select(13)
        XCTAssertEqual(a.formatting.inline.link, "https://x.test")
        a.setLink(nil)
        XCTAssertNil(a.linkRange(at: 12))
        h.viewA.select(16)
        a.insertLink(text: "site", url: "https://s.test")
        XCTAssertEqual(h.a.text, "alpha beta gammasite\nsecond\n")
        XCTAssertEqual(a.linkRange(at: 17)?.range, 16..<20)
        XCTAssertTrue(h.converge("links"))

        h.viewA.select(0, 25)
        a.setBlock("ol")
        XCTAssertEqual(a.shadow.block(at: 0).block, "ol")
        XCTAssertEqual(a.shadow.block(at: 22).block, "ol")
        XCTAssertEqual(a.formatting.block.block, "ol")
        a.indent(by: 20)
        XCTAssertEqual(a.shadow.block(at: 22).indent, 8)
        a.indent(by: -20)
        XCTAssertEqual(a.shadow.block(at: 22).indent, 0)
        a.toggleBlock("ol")
        XCTAssertNil(a.shadow.block(at: 0).block)
        a.setBlock("todo")
        a.toggleChecked(paragraphAt: 2)
        XCTAssertTrue(a.shadow.block(at: 0).checked)
        XCTAssertFalse(a.shadow.block(at: 22).checked)
        XCTAssertTrue(h.converge("blocks"))
        XCTAssertTrue(h.bindingB.shadow.block(at: 0).checked)
        a.setBlock("ul")
        XCTAssertFalse(a.shadow.block(at: 0).checked, "checked only exists on to-dos")
        XCTAssertTrue(a.formatting.canUndo)
        XCTAssertTrue(h.converge("end"))
        XCTAssertEqual(h.bindingA.fullResets + h.bindingB.fullResets, 0)
    }

    func testRemoteEditsKeepSelectionAndCaret() throws {
        let h = try start([txt("0123456789abcdefghij\n")])
        func selection() -> [Int] { [h.viewB.selectedRange.location, h.viewB.selectedRange.length] }
        h.viewB.select(8, 4)
        h.viewA.type("XX", at: 2)
        XCTAssertTrue(h.converge("before"))
        XCTAssertEqual(selection(), [10, 4], "edit before the selection")
        h.viewA.type("YY", at: 18)
        XCTAssertTrue(h.converge("after"))
        XCTAssertEqual(selection(), [10, 4], "edit after the selection")
        h.viewA.type("Z", at: 12)
        XCTAssertTrue(h.converge("inside"))
        XCTAssertEqual(selection(), [10, 5], "edit inside the selection")
        h.viewA.type("S", at: 10)
        h.viewA.type("E", at: 16)
        XCTAssertTrue(h.converge("edges"))
        XCTAssertEqual(selection(), [11, 5], "text typed at the edges stays outside")
        h.viewA.select(9, 4)
        h.viewA.deleteBackward()
        XCTAssertTrue(h.converge("delete across start"))
        XCTAssertEqual(selection(), [9, 3], "deletion across the selection's start")

        h.viewB.select(5)
        h.viewA.type("Q", at: 5)
        XCTAssertTrue(h.converge("at caret"))
        XCTAssertEqual(selection(), [5, 0], "remote text typed at the caret goes after it")
        h.viewA.type("P", at: 0)
        XCTAssertTrue(h.converge("before caret"))
        XCTAssertEqual(selection(), [6, 0])
        h.viewA.select(0, 3)
        h.viewA.deleteBackward()
        XCTAssertTrue(h.converge("delete before caret"))
        XCTAssertEqual(selection(), [3, 0])
        h.bindingA.setInline("bold", .bool(true), in: 0..<8)
        h.bindingA.setBlock("ul")
        XCTAssertTrue(h.converge("format only"))
        XCTAssertEqual(selection(), [3, 0], "formatting does not move the caret")
        XCTAssertEqual(h.bindingB.fullResets, 0)
    }

    func testMarkedTextSurvivesRemoteEdits() throws {
        let h = try start([txt("abc def ghi\n\nxyz\n")])
        h.viewA.smartInsertDeleteType = .no // otherwise deleting a word also takes the space before it
        XCTAssertTrue(h.viewB.becomeFirstResponder())
        h.viewB.select(4)
        h.viewB.setMarkedText("にほ", selectedRange: NSRange(location: 2, length: 0))
        XCTAssertTrue(h.bindingB.isComposing)

        h.viewA.type("START ", at: 0)
        h.viewA.type("!", at: h.a.length - 1)
        h.bindingA.setInline("bold", .bool(true), in: 6..<9)
        h.link.deliverAll()
        h.pump()
        XCTAssertEqual(h.bindingB.queuedChanges, 3, "remote changes wait while composing")
        XCTAssertTrue(h.bindingB.isComposing, "the composition is still active")
        XCTAssertEqual(h.viewB.plain, "abc にほdef ghi\n\nxyz\n", "nothing was applied to the view under the composition")
        XCTAssertEqual(h.viewB.offset(from: h.viewB.beginningOfDocument, to: try XCTUnwrap(h.viewB.markedTextRange).start), 4)

        h.viewB.setMarkedText("にほん", selectedRange: NSRange(location: 3, length: 0))
        XCTAssertEqual(h.b.text, "START abc def ghi\n\nxyz!\n", "the page has the remote edits but not the composition")
        h.viewB.unmarkText()
        h.pump()
        XCTAssertFalse(h.bindingB.isComposing)
        XCTAssertTrue(h.converge("after composition"))
        XCTAssertEqual(h.a.text, "START abc にほんdef ghi\n\nxyz!\n")
        XCTAssertEqual(h.bindingB.rebases, 1)
        XCTAssertTrue(h.bindingB.allHave("bold", in: 6..<9))
        XCTAssertEqual(h.viewB.selectedRange, NSRange(location: 13, length: 0), "caret behind the composed text")

        // The other side deletes the text around the composition.
        h.viewB.select(15)
        h.viewB.setMarkedText("か", selectedRange: NSRange(location: 1, length: 0))
        h.viewA.select(6, 14)
        h.viewA.deleteBackward()
        h.link.deliverAll()
        XCTAssertTrue(h.bindingB.isComposing)
        h.viewB.unmarkText()
        h.pump()
        XCTAssertTrue(h.converge("composition whose surroundings were deleted"))
        XCTAssertEqual(h.a.text, "START か\n\nxyz!\n")

        // A composition that is abandoned.
        h.viewB.select(0)
        h.viewB.setMarkedText("zz", selectedRange: NSRange(location: 2, length: 0))
        h.viewA.type("#", at: 0)
        h.link.deliverAll()
        h.viewB.setMarkedText("", selectedRange: NSRange(location: 0, length: 0))
        h.viewB.unmarkText()
        h.pump()
        XCTAssertTrue(h.converge("abandoned composition"))
        XCTAssertEqual(h.a.text, "#START か\n\nxyz!\n")
        XCTAssertEqual(h.bindingB.fullResets, 0)
    }

    func testUndoOnlyUndoesOwnEdits() throws {
        let h = try start([txt("base\n")])
        h.viewA.type("AAA", at: 0)
        XCTAssertTrue(h.converge("1"))
        h.viewB.type("BBB", at: 0)
        XCTAssertTrue(h.converge("2"))
        h.viewA.type("CC", at: h.a.length - 1)
        XCTAssertTrue(h.converge("3"))
        XCTAssertEqual(h.a.text, "BBBAAAbaseCC\n")

        XCTAssertTrue(h.bindingA.undo())
        XCTAssertTrue(h.converge("undo CC"))
        XCTAssertEqual(h.a.text, "BBBAAAbase\n")
        XCTAssertEqual(h.viewA.selectedRange, NSRange(location: 10, length: 0), "caret goes to the undone change")
        let manager = try XCTUnwrap(h.viewA.undoManager)
        XCTAssertTrue(manager.canUndo)
        manager.undo() // what shake / three-finger swipe / the keyboard's undo call
        XCTAssertTrue(h.converge("undo AAA"))
        XCTAssertEqual(h.a.text, "BBBbase\n", "B's edit stays")
        XCTAssertFalse(h.bindingA.undo())
        XCTAssertTrue(manager.canRedo)
        manager.redo()
        XCTAssertTrue(h.converge("redo AAA"))
        XCTAssertEqual(h.a.text, "BBBAAAbase\n")
        XCTAssertTrue(h.bindingB.undo())
        XCTAssertTrue(h.converge("B undo"))
        XCTAssertEqual(h.a.text, "AAAbase\n")
        // Undo of a format and of a block change.
        h.bindingA.setInline("italic", .bool(true), in: 0..<3)
        h.bindingA.setBlock("h1")
        XCTAssertTrue(h.bindingA.undo())
        XCTAssertTrue(h.bindingA.undo())
        XCTAssertTrue(h.converge("undo formats"))
        XCTAssertEqual(h.a.runs, [txt("AAAbase\n")])
    }

    func testRemoteEditsKeepScrollPosition() throws {
        let lines = (0..<160).map { "Line \($0) of a page that is long enough to scroll\n" }.joined()
        let h = try start([txt(lines)])
        h.viewB.layoutIfNeeded()
        h.pump(0.2)
        XCTAssertGreaterThan(h.viewB.contentSize.height, 2500)
        h.viewB.setContentOffset(CGPoint(x: 0, y: 1800), animated: false)
        h.pump(0.2)

        func anchor() throws -> (index: Int, y: CGFloat) {
            let point = CGPoint(x: 40, y: h.viewB.contentOffset.y + 200)
            let position = try XCTUnwrap(h.viewB.closestPosition(to: point))
            let index = h.bindingB.shadow.paragraphStart(h.viewB.offset(from: h.viewB.beginningOfDocument, to: position))
            let start = try XCTUnwrap(h.viewB.position(from: h.viewB.beginningOfDocument, offset: index))
            return (index, h.viewB.caretRect(for: start).minY - h.viewB.contentOffset.y)
        }
        func y(of index: Int) throws -> CGFloat {
            let start = try XCTUnwrap(h.viewB.position(from: h.viewB.beginningOfDocument, offset: index))
            return h.viewB.caretRect(for: start).minY - h.viewB.contentOffset.y
        }

        let before = try anchor()
        let inserted = String(repeating: "A new line from the other device\n", count: 30)
        h.viewA.type(inserted, at: 0)
        XCTAssertTrue(h.converge("insert above"))
        h.pump(0.1)
        XCTAssertEqual(try y(of: before.index + inserted.utf16.count), before.y, accuracy: 2, "text inserted above the viewport")
        XCTAssertGreaterThan(h.bindingB.scrollRestores, 0)

        let middle = try anchor()
        h.viewA.select(0, inserted.utf16.count)
        h.viewA.deleteBackward()
        XCTAssertTrue(h.converge("delete above"))
        h.pump(0.1)
        XCTAssertEqual(try y(of: middle.index - inserted.utf16.count), middle.y, accuracy: 2, "text deleted above the viewport")

        let below = try anchor()
        h.viewA.type("tail\n", at: h.a.length - 1)
        XCTAssertTrue(h.converge("insert below"))
        XCTAssertEqual(try y(of: below.index), below.y, accuracy: 2, "text inserted below the viewport")
    }

    func testCheckboxHitTesting() throws {
        let h = try start([txt("title"), para("h1"), txt("open"), para("todo"), txt("done"), para("todo", checked: true), txt("bullet"), para("ul")])
        h.viewA.layoutIfNeeded()
        h.pump(0.1)
        let open = try XCTUnwrap(h.bindingA.markerCenter(forParagraphAt: 7))
        XCTAssertEqual(h.bindingA.checkboxParagraph(at: open), 10)
        let done = try XCTUnwrap(h.bindingA.markerCenter(forParagraphAt: 12))
        XCTAssertEqual(h.bindingA.checkboxParagraph(at: done), 15)
        XCTAssertGreaterThan(done.y, open.y)
        XCTAssertNil(h.bindingA.checkboxParagraph(at: CGPoint(x: open.x + 60, y: open.y)), "the text is not the checkbox")
        let bullet = try XCTUnwrap(h.bindingA.markerCenter(forParagraphAt: 17))
        XCTAssertNil(h.bindingA.checkboxParagraph(at: bullet), "a bullet is not a checkbox")
        XCTAssertNil(h.bindingA.markerCenter(forParagraphAt: 0), "a heading has no marker")
        h.bindingA.toggleChecked(paragraphAt: try XCTUnwrap(h.bindingA.checkboxParagraph(at: open)))
        XCTAssertTrue(h.converge("tick"))
        XCTAssertTrue(h.bindingB.shadow[10].block.checked)
    }

    func testDynamicTypeRerendersWithoutEdits() throws {
        let h = try start(everything)
        func size() -> CGFloat { (h.viewA.textStorage.attribute(.font, at: 8, effectiveRange: nil) as? UIFont)?.pointSize ?? 0 }
        let normal = size()
        let transactions = h.bindingA.localTransactions
        h.window.traitOverrides.preferredContentSizeCategory = .accessibilityExtraLarge
        h.pump(0.2)
        XCTAssertGreaterThan(size(), normal + 4, "fonts follow Dynamic Type")
        XCTAssertEqual(h.bindingA.localTransactions, transactions, "re-rendering is not an edit")
        h.viewA.type("x", at: 8)
        XCTAssertTrue(h.converge("after size change"))
    }

    func testPlainTextInsertionIsSanitised() throws {
        let h = try start([txt("ab\n")])
        h.viewA.select(1)
        h.viewA.insertPlainText("x\r\ny\u{2029}z\u{FFFC}")
        XCTAssertTrue(h.converge("paste"))
        XCTAssertEqual(h.a.text, "ax\ny\nzb\n")
        // Something forbidden that got into the storage some other way is removed, not synced.
        h.viewA.textStorage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "\u{FFFC}q\r")
        h.bindingA.syncLocal()
        XCTAssertTrue(h.converge("forbidden"))
        XCTAssertEqual(h.a.text, "qax\ny\nzb\n")
        XCTAssertEqual(h.bindingA.forbiddenCharactersRemoved, 2)
    }

    func testLargePageTypingCost() throws {
        let paragraph = "The quick brown fox jumps over the lazy dog and keeps running through the page. "
        let text = (0..<800).map { "\($0) " + paragraph + "\n" }.joined()
        let started = Date()
        let h = try start([txt(text)])
        let load = Date().timeIntervalSince(started)
        let middle = h.bindingA.shadow.paragraphStart(h.a.length / 2)
        h.viewA.select(middle)
        let typing = Date()
        for _ in 0..<50 { h.viewA.insertText("k") }
        let perKey = Date().timeIntervalSince(typing) / 50
        let remote = Date()
        for i in 0..<50 { h.viewB.type("r", at: 10 + i); h.link.deliverAll() }
        let perRemote = Date().timeIntervalSince(remote) / 50
        print(String(format: "LARGE PAGE: %d UTF-16 units, load both views %.0f ms, local keystroke %.2f ms, type+remote apply %.2f ms (debug build, in-memory page included)",
                     h.a.length, load * 1000, perKey * 1000, perRemote * 1000))
        XCTAssertTrue(h.converge("large page"))
        XCTAssertLessThan(perKey, 0.25)
    }
}

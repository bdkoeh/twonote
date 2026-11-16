#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
import XCTest
import TwoNoteDocuments
@testable import TwoNoteEditor

/// Real NSTextViews (TextKit 2) in a real window, driven the way AppKit drives them for user
/// input, each bound to its own replica of one page. The first tests mirror the UIKit
/// binding's tests in Spikes/EditorSpike/Tests/BindingTests.swift one for one; the Mac-only
/// ones (keys, menus, find bar, clicks, live merging under a caret) follow.
@MainActor
final class AppKitBindingTests: XCTestCase {
    private var harness: MacHarness!

    override func tearDown() async throws {
        harness?.tearDown()
        harness = nil
    }

    private func start(_ seed: [TextRun]) -> MacHarness {
        let h = MacHarness(seed: seed)
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

    // MARK: Mirrors of the UIKit binding's tests

    func testInitialRenderHoldsEveryAttribute() {
        let h = start(everything)
        XCTAssertTrue(h.converge("initial"))
        XCTAssertEqual(h.viewA.plain, h.a.text)
        XCTAssertEqual(h.bindingA.fullResets, 0)
        // Unknown block values survive in the view's attributes and are simply not drawn.
        let cells = h.bindingA.storageCells()
        XCTAssertTrue(cells.contains { $0.block.block == "callout" })
        // A link is shown and followed by the text view (its `.link`); plain text has none.
        XCTAssertNil(h.viewA.textStorage?.attribute(.link, at: 8, effectiveRange: nil))
        let linkAt = (h.a.text as NSString).range(of: "link").location
        XCTAssertEqual(h.viewA.textStorage?.attribute(.link, at: linkAt, effectiveRange: nil) as? String, "https://example.com")
    }

    /// Whether AppKit tells the delegate about programmatic input (the binding also reconciles
    /// from the text storage's own notification).
    func testProgrammaticInputReachesThePageWithoutHelp() {
        let h = start([txt("abc\n")])
        h.viewA.type("x", at: 1)
        XCTAssertEqual(h.a.text, "axbc\n", "insertText")
        h.viewA.backspace()
        XCTAssertEqual(h.a.text, "abc\n", "deleteBackward")
        h.viewA.replace(range: 0, 2, with: "ZZZ")
        XCTAssertEqual(h.a.text, "ZZZc\n", "insertText with a replacement range")
        h.viewA.mark("ka", caret: 2)
        XCTAssertEqual(h.a.text, "ZZZc\n", "marked text must not reach the page")
        h.viewA.unmarkText()
        h.pump()
        XCTAssertEqual(h.a.text.count, 7, "unmarkText")
        XCTAssertTrue(h.converge("end"))
    }

    func testTypingAndDeletingReachTheOtherView() {
        let h = start([txt("Hello world\n")])
        h.viewA.type("X", at: 5)
        XCTAssertTrue(h.converge("insert"))
        XCTAssertEqual(h.viewB.plain, "HelloX world\n")
        h.viewA.type("😀", at: 0)
        h.viewA.type("\n", at: 3)
        XCTAssertTrue(h.converge("emoji and newline"))
        XCTAssertEqual(h.viewB.plain, "😀H\nelloX world\n")
        h.viewA.select(4)
        h.viewA.backspace()
        XCTAssertTrue(h.converge("join"))
        h.viewA.type("\u{2028}", at: 2)
        h.viewB.type("B", at: h.b.length - 1)
        XCTAssertTrue(h.converge("soft break and B typing"))
        XCTAssertEqual(h.viewA.plain, "😀\u{2028}HelloX worldB\n")
        // Select all, delete: only the final newline is left.
        h.viewA.select(0, h.viewA.textStorage!.length)
        h.viewA.backspace()
        XCTAssertTrue(h.converge("delete all"))
        XCTAssertEqual(h.b.text, "\n")
        // Typing after the final newline is impossible: the caret is kept in front of it.
        h.viewA.select(1)
        XCTAssertEqual(h.viewA.selection.location, 0)
        h.viewA.typeText("again")
        XCTAssertTrue(h.converge("type into empty page"))
        XCTAssertEqual(h.b.text, "again\n")
        XCTAssertEqual(h.bindingA.fullResets + h.bindingB.fullResets, 0)
    }

    func testTypingAttributes() throws {
        let link: Attributes = ["link": .string("https://example.com")]
        let h = start([
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
        h.viewA.typeText("Q")
        h.viewA.typeText("R")
        XCTAssertTrue(a.shadow[0].inline.bold && a.shadow[1].inline.bold)
        XCTAssertFalse(a.shadow[2].inline.bold)
        XCTAssertTrue(h.converge("typing attributes"))
    }

    func testListAndHeadingRules() {
        let h = start([
            txt("one"), para("ul"), txt("Head"), para("h2"), txt("done"), para("todo", checked: true), txt("tail"), para(),
        ])
        let a = h.bindingA
        let original = h.a.text
        h.viewA.type("\n", at: 3)
        XCTAssertEqual(a.shadow.block(at: 4).block, "ul", "Return in a list item makes another item")
        XCTAssertEqual(h.viewA.selection.location, 4)
        h.viewA.typeText("\n")
        XCTAssertNil(a.shadow.block(at: 4).block, "Return on an empty item ends the list")
        XCTAssertEqual(h.a.text.utf16.count, original.utf16.count + 1)
        h.viewA.backspace()
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
        h.viewA.backspace()
        XCTAssertNil(a.shadow.block(at: 0).block, "Backspace at the start of a list item removes the block")
        XCTAssertEqual(h.a.text, before)
        a.indent(by: 2)
        h.viewA.backspace()
        XCTAssertEqual(a.shadow.block(at: 0).indent, 1, "then Backspace steps the indent out")
        h.viewA.backspace()
        XCTAssertEqual(a.shadow.block(at: 0).indent, 0)
        XCTAssertEqual(h.a.text, before)
        XCTAssertTrue(h.converge("backspace rules"))
    }

    func testCommands() {
        let h = start([txt("alpha beta gamma\n"), txt("second\n")])
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

    func testRemoteEditsKeepSelectionAndCaret() {
        let h = start([txt("0123456789abcdefghij\n")])
        func selection() -> [Int] { [h.viewB.selection.location, h.viewB.selection.length] }
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
        h.viewA.backspace()
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
        h.viewA.backspace()
        XCTAssertTrue(h.converge("delete before caret"))
        XCTAssertEqual(selection(), [3, 0])
        h.bindingA.setInline("bold", .bool(true), in: 0..<8)
        h.bindingA.setBlock("ul")
        XCTAssertTrue(h.converge("format only"))
        XCTAssertEqual(selection(), [3, 0], "formatting does not move the caret")
        XCTAssertEqual(h.bindingB.fullResets, 0)
    }

    func testMarkedTextSurvivesRemoteEdits() {
        let h = start([txt("abc def ghi\n\nxyz\n")])
        h.viewA.smartInsertDeleteEnabled = false // otherwise deleting a word also takes the space before it
        XCTAssertTrue(h.window.makeFirstResponder(h.viewB))
        h.viewB.select(4)
        h.viewB.mark("にほ", caret: 2)
        XCTAssertTrue(h.bindingB.isComposing)

        h.viewA.type("START ", at: 0)
        h.viewA.type("!", at: h.a.length - 1)
        h.bindingA.setInline("bold", .bool(true), in: 6..<9)
        h.link.deliverAll()
        h.pump()
        XCTAssertEqual(h.bindingB.queuedChanges, 3, "remote changes wait while composing")
        XCTAssertTrue(h.bindingB.isComposing, "the composition is still active")
        XCTAssertEqual(h.viewB.plain, "abc にほdef ghi\n\nxyz\n", "nothing was applied to the view under the composition")
        XCTAssertEqual(h.viewB.markedRange().location, 4)

        h.viewB.mark("にほん", caret: 3)
        XCTAssertEqual(h.b.text, "START abc def ghi\n\nxyz!\n", "the page has the remote edits but not the composition")
        h.viewB.unmarkText()
        h.pump()
        XCTAssertFalse(h.bindingB.isComposing)
        XCTAssertTrue(h.converge("after composition"))
        XCTAssertEqual(h.a.text, "START abc にほんdef ghi\n\nxyz!\n")
        XCTAssertEqual(h.bindingB.rebases, 1)
        XCTAssertTrue(h.bindingB.allHave("bold", in: 6..<9))
        XCTAssertEqual(h.viewB.selection, NSRange(location: 13, length: 0), "caret behind the composed text")

        // The other side deletes the text around the composition.
        h.viewB.select(15)
        h.viewB.mark("か", caret: 1)
        h.viewA.select(6, 14)
        h.viewA.backspace()
        h.link.deliverAll()
        XCTAssertTrue(h.bindingB.isComposing)
        h.viewB.unmarkText()
        h.pump()
        XCTAssertTrue(h.converge("composition whose surroundings were deleted"))
        XCTAssertEqual(h.a.text, "START か\n\nxyz!\n")

        // A composition that is abandoned.
        h.viewB.select(0)
        h.viewB.mark("zz", caret: 2)
        h.viewA.type("#", at: 0)
        h.link.deliverAll()
        h.viewB.mark("", caret: 0)
        h.viewB.unmarkText()
        h.pump()
        XCTAssertTrue(h.converge("abandoned composition"))
        XCTAssertEqual(h.a.text, "#START か\n\nxyz!\n")
        XCTAssertEqual(h.bindingB.fullResets, 0)
    }

    func testUndoOnlyUndoesOwnEdits() throws {
        let h = start([txt("base\n")])
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
        XCTAssertEqual(h.viewA.selection, NSRange(location: 10, length: 0), "caret goes to the undone change")
        let manager = try XCTUnwrap(h.viewA.undoManager)
        XCTAssertTrue(manager.canUndo)
        manager.undo() // what Edit > Undo and ⌘Z end up calling
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
        let h = start([txt(lines)])
        h.viewB.layOutEverything()
        h.pump(0.2)
        XCTAssertGreaterThan(h.viewB.frame.height, 2500)
        h.viewB.scroll(toTop: 1800)
        h.pump(0.2)
        XCTAssertEqual(h.viewB.scrollTop, 1800, accuracy: 1)

        // Where a line is on screen: laid out the way the view draws it (its viewport).
        func anchor() throws -> (index: Int, y: CGFloat) {
            h.viewB.textLayoutManager?.textViewportLayoutController.layoutViewport()
            let point = CGPoint(x: 40, y: h.viewB.scrollTop + 200)
            let index = try XCTUnwrap(h.bindingB.lineStart(at: point))
            return (index, try XCTUnwrap(h.bindingB.lineTop(ofCharacterAt: index)) - h.viewB.scrollTop)
        }
        func y(of index: Int) throws -> CGFloat {
            h.viewB.textLayoutManager?.textViewportLayoutController.layoutViewport()
            return try XCTUnwrap(h.bindingB.lineTop(ofCharacterAt: index)) - h.viewB.scrollTop
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
        h.viewA.backspace()
        XCTAssertTrue(h.converge("delete above"))
        h.pump(0.1)
        XCTAssertEqual(try y(of: middle.index - inserted.utf16.count), middle.y, accuracy: 2, "text deleted above the viewport")

        let below = try anchor()
        h.viewA.type("tail\n", at: h.a.length - 1)
        XCTAssertTrue(h.converge("insert below"))
        XCTAssertEqual(try y(of: below.index), below.y, accuracy: 2, "text inserted below the viewport")
    }

    func testCheckboxHitTesting() throws {
        let h = start([txt("title"), para("h1"), txt("open"), para("todo"), txt("done"), para("todo", checked: true), txt("bullet"), para("ul")])
        h.viewA.layOutEverything()
        h.pump(0.1)
        let open = try XCTUnwrap(h.bindingA.markerCenter(forParagraphAt: 7))
        XCTAssertEqual(h.bindingA.checkboxParagraph(at: open), 10)
        let done = try XCTUnwrap(h.bindingA.markerCenter(forParagraphAt: 12))
        XCTAssertEqual(h.bindingA.checkboxParagraph(at: done), 15)
        XCTAssertGreaterThan(done.y, open.y, "flipped coordinates: further down is larger")
        XCTAssertNil(h.bindingA.checkboxParagraph(at: CGPoint(x: open.x + 60, y: open.y)), "the text is not the checkbox")
        let bullet = try XCTUnwrap(h.bindingA.markerCenter(forParagraphAt: 17))
        XCTAssertNil(h.bindingA.checkboxParagraph(at: bullet), "a bullet is not a checkbox")
        XCTAssertNil(h.bindingA.markerCenter(forParagraphAt: 0), "a heading has no marker")
        h.bindingA.toggleChecked(paragraphAt: try XCTUnwrap(h.bindingA.checkboxParagraph(at: open)))
        XCTAssertTrue(h.converge("tick"))
        XCTAssertTrue(h.bindingB.shadow[10].block.checked)
    }

    /// The Mac counterpart of the Dynamic Type test: another text size re-renders, but is no edit.
    func testThemeChangeRerendersWithoutEdits() {
        let h = start(everything)
        func size() -> CGFloat { (h.viewA.textStorage?.attribute(.font, at: 8, effectiveRange: nil) as? NSFont)?.pointSize ?? 0 }
        let normal = size()
        let transactions = h.bindingA.localTransactions
        h.bindingA.setTheme(EditorTheme(bodySize: 20))
        h.pump(0.1)
        XCTAssertGreaterThan(size(), normal + 4, "fonts follow the theme")
        XCTAssertEqual(h.bindingA.localTransactions, transactions, "re-rendering is not an edit")
        h.viewA.type("x", at: 8)
        XCTAssertTrue(h.converge("after size change"))
    }

    func testPlainTextInsertionIsSanitised() {
        let h = start([txt("ab\n")])
        h.viewA.select(1)
        h.viewA.insertPlainText("x\r\ny\u{2029}z\u{FFFC}")
        XCTAssertTrue(h.converge("paste"))
        XCTAssertEqual(h.a.text, "ax\ny\nzb\n")
        // Something forbidden that got into the storage some other way is removed, not synced.
        h.viewA.textStorage?.replaceCharacters(in: NSRange(location: 0, length: 0), with: "\u{FFFC}q\r")
        h.bindingA.syncLocal()
        XCTAssertTrue(h.converge("forbidden"))
        XCTAssertEqual(h.a.text, "qax\ny\nzb\n")
        XCTAssertEqual(h.bindingA.forbiddenCharactersRemoved, 2)
    }

    func testLargePageTypingCost() {
        let paragraph = "The quick brown fox jumps over the lazy dog and keeps running through the page. "
        let text = (0..<800).map { "\($0) " + paragraph + "\n" }.joined()
        let started = Date()
        let h = start([txt(text)])
        let load = Date().timeIntervalSince(started)
        let middle = h.bindingA.shadow.paragraphStart(h.a.length / 2)
        h.viewA.select(middle)
        let typing = Date()
        for _ in 0..<50 { h.viewA.typeText("k") }
        let perKey = Date().timeIntervalSince(typing) / 50
        let remote = Date()
        for i in 0..<50 { h.viewB.type("r", at: 10 + i); h.link.deliverAll() }
        let perRemote = Date().timeIntervalSince(remote) / 50
        print(String(format: "LARGE PAGE (AppKit): %d UTF-16 units, load both views %.0f ms, local keystroke %.2f ms, type+remote apply %.2f ms (debug build, in-memory page included)",
                     h.a.length, load * 1000, perKey * 1000, perRemote * 1000))
        XCTAssertTrue(h.converge("large page"))
        XCTAssertLessThan(perKey, 0.25)
    }

    // MARK: Mac only

    /// Return, Option-Return, Shift-Return (line break), Tab and Shift-Tab arrive as the
    /// responder actions the key bindings send, not as insertText.
    func testKeyActions() {
        let h = start([txt("item"), para("ul"), txt("body"), para()])
        let a = h.bindingA
        h.viewA.select(4)
        h.viewA.insertNewline(nil)
        XCTAssertEqual(h.a.text, "item\n\nbody\n")
        XCTAssertEqual(a.shadow.block(at: 5).block, "ul", "Return in a list item makes another item")
        h.viewA.insertNewline(nil)
        XCTAssertNil(a.shadow.block(at: 5).block, "Return on the empty item ends the list")
        XCTAssertEqual(h.a.text, "item\n\nbody\n", "and inserts nothing")
        h.viewA.typeText("x")
        h.viewA.insertLineBreak(nil)
        h.viewA.typeText("y")
        XCTAssertEqual(h.a.text, "item\nx\u{2028}y\nbody\n", "Shift-Return is a line break inside the paragraph")
        h.viewA.insertTab(nil)
        XCTAssertEqual(a.shadow.block(at: 5).indent, 1, "Tab indents the paragraph")
        XCTAssertEqual(h.a.text, "item\nx\u{2028}y\nbody\n", "and inserts no tab character")
        h.viewA.insertBacktab(nil)
        XCTAssertEqual(a.shadow.block(at: 5).indent, 0, "Shift-Tab outdents")
        h.viewA.select(5)
        h.viewA.insertNewlineIgnoringFieldEditor(nil)
        XCTAssertEqual(h.a.text, "item\n\nx\u{2028}y\nbody\n")
        XCTAssertTrue(h.converge("keys"))
    }

    /// Edit > Undo and Edit > Redo are enabled from the page's own history.
    func testUndoMenuItemsFollowThePage() {
        let h = start([txt("one\n")])
        let undo = NSMenuItem(title: "Undo", action: #selector(EditorTextView.undo(_:)), keyEquivalent: "z")
        let redo = NSMenuItem(title: "Redo", action: #selector(EditorTextView.redo(_:)), keyEquivalent: "Z")
        XCTAssertFalse(h.viewA.validateUserInterfaceItem(undo))
        h.viewA.type("x", at: 0)
        XCTAssertTrue(h.viewA.validateUserInterfaceItem(undo))
        XCTAssertFalse(h.viewA.validateUserInterfaceItem(redo))
        h.viewA.undo(nil)
        XCTAssertEqual(h.a.text, "one\n")
        XCTAssertTrue(h.viewA.validateUserInterfaceItem(redo))
        h.viewA.redo(nil)
        XCTAssertEqual(h.a.text, "xone\n")
        XCTAssertTrue(h.converge("menu undo"))
    }

    /// A click on a checkbox ticks it; a click on the text does not.
    func testClickOnCheckbox() throws {
        let h = start([txt("task"), para("todo"), txt("plain"), para()])
        h.viewA.layOutEverything()
        let box = try XCTUnwrap(h.bindingA.markerCenter(forParagraphAt: 0))
        XCTAssertTrue(h.bindingA.handleClick(at: box))
        XCTAssertTrue(h.bindingA.shadow[4].block.checked)
        XCTAssertFalse(h.bindingA.handleClick(at: CGPoint(x: box.x + 80, y: box.y)))
        XCTAssertTrue(h.bindingA.handleClick(at: box))
        XCTAssertFalse(h.bindingA.shadow[4].block.checked)
        XCTAssertTrue(h.converge("clicks"))
    }

    /// The find bar, the context menu and the menus around the text must not knock the view
    /// off TextKit 2 or let attributes in behind the page's back.
    func testFindBarAndContextMenuKeepTextKit2() throws {
        let h = start(everything)
        let find = NSMenuItem(title: "Find", action: #selector(NSTextView.performFindPanelAction(_:)), keyEquivalent: "f")
        find.tag = Int(NSFindPanelAction.showFindPanel.rawValue)
        h.viewA.performFindPanelAction(find)
        h.pump(0.1)
        XCTAssertTrue(h.bindingA.usesTextKit2, "the find bar")
        let event = try XCTUnwrap(NSEvent.mouseEvent(
            with: .rightMouseDown, location: h.viewA.convert(CGPoint(x: 60, y: 30), to: nil), modifierFlags: [], timestamp: 0,
            windowNumber: h.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        let menu = h.viewA.menu(for: event)
        let actions = (menu?.items ?? []).flatMap { [$0] + ($0.submenu?.items ?? []) }.compactMap { $0.action.map(NSStringFromSelector) }
        XCTAssertFalse(actions.contains("orderFrontFontPanel:"), "no Font submenu")
        XCTAssertTrue(h.bindingA.usesTextKit2, "the context menu")
        XCTAssertNil(h.bindingA.verify())
    }

    /// Someone else types while this view's user keeps typing at the caret: every remote change
    /// merges into the view at once and the caret never jumps; what both typed ends up in place.
    func testLiveMergeUnderATypingCaret() {
        let h = start([txt("Shopping: "), para("h2"), txt("milk"), para("ul"), txt("eggs"), para("ul")])
        h.window.makeFirstResponder(h.viewB)
        h.viewB.select(h.b.text.utf16.count - 1) // at the end of "eggs"
        var expectedCaret = h.viewB.selection.location
        for (i, word) in [" and", " bread", " and", " jam"].enumerated() {
            h.viewB.typeText(word)
            expectedCaret += word.utf16.count
            // Meanwhile the other device changes the heading and adds an item at the top of the list.
            h.viewA.type("\(i)", at: 8 + i)
            h.viewA.type("x\n", at: 12 + i)
            h.link.deliverAll()
            expectedCaret += 3 // the digit and the new item, both above the caret
            XCTAssertEqual(h.viewB.selection, NSRange(location: expectedCaret, length: 0), "caret after round \(i)")
            XCTAssertTrue(h.checkViews("round \(i)"))
        }
        XCTAssertTrue(h.converge("live"))
        XCTAssertEqual(h.b.text, "Shopping0123: \nx\nx\nx\nx\nmilk\neggs and bread and jam\n")
        XCTAssertEqual(h.bindingB.fullResets, 0)
        XCTAssertGreaterThan(h.bindingB.remoteDeltas, 7)
    }

    /// A remote change that arrives while this view holds an edit it has not reconciled yet
    /// (written to the storage without a text-view notification) waits for it and is merged
    /// with it, not lost under it.
    func testRemoteChangeDuringUnreconciledEdit() {
        let h = start([txt("abc\n")])
        h.viewB.textStorage?.replaceCharacters(in: NSRange(location: 3, length: 0), with: "Z")
        h.viewA.type("1", at: 0)
        h.link.deliverAll()
        h.pump(0.05)
        XCTAssertTrue(h.converge("merged"))
        XCTAssertEqual(h.a.text, "1abcZ\n")
        XCTAssertEqual(h.bindingB.fullResets, 0)
    }

    // MARK: Soak

    func testSoakConcurrent() {
        soak(seed: ProcessInfo.processInfo.environment["SOAK_SEED"].flatMap { UInt64($0) } ?? 20261115,
             steps: ProcessInfo.processInfo.environment["SOAK_STEPS"].flatMap { Int($0) } ?? 1500)
    }

    private func soak(seed: UInt64, steps: Int) {
        var rng = SplitMix64(seed: seed)
        let h = start([
            txt("Soak"), para("h1"), txt("first "), txt("bold", ["bold": .bool(true)]), txt(" text"), para(),
            txt("item"), para("ul"), txt("task"), para("todo", checked: true), txt("last line"), para(),
        ])
        let alphabet = ["a", "b", "c", " ", " ", "\n", "\n", "é", "😀", "中", "\u{2028}", "word ", "x", "1. "]
        let inlineKeys = ["bold", "italic", "underline", "strike", "code"]
        let blocks: [String?] = [nil, "h1", "h2", "h3", "ul", "ol", "todo", "code"]
        var composing = [false, false]
        var counts: [String: Int] = [:]

        func safe(_ binding: PageTextBinding, _ index: Int) -> Int {
            let units = binding.shadow.units
            let i = min(max(index, 0), max(0, units.count - 1))
            if i > 0 && i < units.count && UTF16.isTrailSurrogate(units[i]) && UTF16.isLeadSurrogate(units[i - 1]) { return i - 1 }
            return i
        }
        func randomRange(_ binding: PageTextBinding, maxLength: Int) -> NSRange {
            let count = binding.shadow.count
            let start = safe(binding, Int.random(in: 0..<max(1, count), using: &rng))
            let end = safe(binding, min(count - 1, start + Int.random(in: 0...maxLength, using: &rng)))
            return NSRange(location: start, length: max(0, end - start))
        }
        func randomText() -> String {
            (0..<Int.random(in: 1...3, using: &rng)).map { _ in alphabet.randomElement(using: &rng)! }.joined()
        }

        for step in 0..<steps {
            let which = Int.random(in: 0...1, using: &rng)
            let binding = h.bindings[which]
            let view = binding.textView
            var op = ""
            let roll = Int.random(in: 0..<100, using: &rng)
            if composing[which] {
                if roll < 35 {
                    op = "ime-update"
                    let text = ["か", "かな", "にほん", "中文"].randomElement(using: &rng)!
                    view.mark(text, caret: text.utf16.count)
                } else {
                    op = roll < 90 ? "ime-commit" : "ime-cancel"
                    if op == "ime-cancel" { view.mark("", caret: 0) }
                    view.unmarkText()
                    composing[which] = false
                    binding.syncLocal()
                }
            } else {
                switch roll {
                case 0..<26:
                    op = "type"
                    view.setSelectedRange(randomRange(binding, maxLength: 0))
                    view.typeText(randomText())
                case 26..<34:
                    op = "replace-selection"
                    view.setSelectedRange(randomRange(binding, maxLength: 12))
                    view.typeText(randomText())
                case 34..<44:
                    op = "backspace"
                    view.setSelectedRange(randomRange(binding, maxLength: Bool.random(using: &rng) ? 0 : 10))
                    view.backspace()
                case 44..<49:
                    op = "replace-range"
                    let range = randomRange(binding, maxLength: 8)
                    view.replace(range: range.location, range.length, with: Bool.random(using: &rng) ? randomText() : "")
                case 49..<52:
                    op = "return-return"
                    view.setSelectedRange(randomRange(binding, maxLength: 0))
                    view.insertNewline(nil)
                    view.insertNewline(nil)
                case 52..<60:
                    op = "toggle-inline"
                    view.setSelectedRange(randomRange(binding, maxLength: 15))
                    binding.toggleInline(inlineKeys.randomElement(using: &rng)!)
                    if view.selection.length == 0 { view.typeText("T") }
                case 60..<64:
                    op = "link"
                    view.setSelectedRange(randomRange(binding, maxLength: 10))
                    binding.setLink(Bool.random(using: &rng) ? "https://example.com/\(step % 3)" : nil)
                case 64..<72:
                    op = "set-block"
                    view.setSelectedRange(randomRange(binding, maxLength: 30))
                    binding.setBlock(blocks.randomElement(using: &rng)!)
                case 72..<77:
                    op = "indent"
                    view.setSelectedRange(randomRange(binding, maxLength: 20))
                    if Bool.random(using: &rng) { view.insertTab(nil) } else { view.insertBacktab(nil) }
                case 77..<80:
                    op = "toggle-checked"
                    binding.toggleChecked(paragraphAt: Int.random(in: 0..<binding.shadow.count, using: &rng))
                case 80..<86:
                    op = Bool.random(using: &rng) ? "undo" : "redo"
                    if op == "undo" { view.undo(nil) } else { view.redo(nil) }
                case 86..<92:
                    op = "ime-start"
                    view.setSelectedRange(randomRange(binding, maxLength: Bool.random(using: &rng) ? 0 : 4))
                    view.mark("か", caret: 1)
                    if binding.isComposing { composing[which] = true } else { op = "ime-start(no marked text)" }
                case 92..<95:
                    op = "trim"
                    if binding.shadow.count > 1200 {
                        view.setSelectedRange(NSRange(location: 0, length: safe(binding, 900)))
                        view.backspace()
                    }
                default:
                    op = "deliver-some"
                    for _ in 0..<Int.random(in: 1...4, using: &rng) {
                        if Bool.random(using: &rng) { h.link.deliverNextToA() } else { h.link.deliverNextToB() }
                    }
                }
            }
            counts[op, default: 0] += 1
            let label = "seed \(seed) step \(step) op \(op) on \(which == 0 ? "A" : "B")"
            guard h.checkViews(label) else { return }
            if step % 60 == 59 && !composing[0] && !composing[1] {
                guard h.converge(label + " (drain)") else { return }
            }
        }
        for (i, binding) in h.bindings.enumerated() where composing[i] {
            binding.textView.unmarkText()
            binding.syncLocal()
        }
        h.pump(0.05)
        XCTAssertTrue(h.converge("seed \(seed) final"))
        let ops = counts.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
        print("SOAK (AppKit) seed \(seed): \(steps) steps; \(ops); fullResets A=\(h.bindingA.fullResets) B=\(h.bindingB.fullResets) rebases A=\(h.bindingA.rebases) B=\(h.bindingB.rebases)")
    }
}
#endif

#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
import XCTest
import TwoNoteDocuments
@testable import TwoNoteEditor

/// Two real NSTextViews (TextKit 2) in scroll views in a real window, each bound to its own
/// replica of one page; updates travel between the replicas only when the test says so. The
/// AppKit twin of the editor spike's UIKit harness.
@MainActor
final class MacHarness {
    let window: NSWindow
    let a: InMemoryPageText
    let b: InMemoryPageText
    let link: InMemoryPageLink
    let viewA = EditorTextView()
    let viewB = EditorTextView()
    let bindingA: PageTextBinding
    let bindingB: PageTextBinding

    init(seed: [TextRun]) {
        _ = NSApplication.shared
        window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 900, height: 460),
                          styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 460))
        window.contentView = content

        a = InMemoryPageText(site: 1, seed: seed)
        b = InMemoryPageText(site: 2, seed: seed)
        link = InMemoryPageLink(a, b)
        let scrollA = viewA.scrollable()
        let scrollB = viewB.scrollable()
        scrollA.frame = NSRect(x: 0, y: 0, width: 450, height: 420)
        scrollB.frame = NSRect(x: 450, y: 0, width: 450, height: 420)
        content.addSubview(scrollA)
        content.addSubview(scrollB)
        for view in [viewA, viewB] {
            view.frame = NSRect(origin: .zero, size: scrollA.contentSize)
        }
        bindingA = PageTextBinding(textView: viewA, page: a)
        bindingB = PageTextBinding(textView: viewB, page: b)
        window.orderFront(nil)
        content.layoutSubtreeIfNeeded()
    }

    func tearDown() {
        bindingA.detach()
        bindingB.detach()
        window.orderOut(nil)
        window.close()
    }

    var bindings: [PageTextBinding] { [bindingA, bindingB] }

    func pump(_ seconds: TimeInterval = 0.02) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    /// Each view equals its own replica (text and page attributes), and is still TextKit 2.
    @discardableResult
    func checkViews(_ label: String, file: StaticString = #filePath, line: UInt = #line) -> Bool {
        for (name, binding) in [("A", bindingA), ("B", bindingB)] where !binding.isComposing {
            binding.syncLocal()
            if let problem = binding.verify() {
                XCTFail("\(label): view \(name): \(problem)", file: file, line: line)
                return false
            }
        }
        return true
    }

    /// Delivers everything, then: views equal their replicas, replicas equal each other.
    @discardableResult
    func converge(_ label: String, file: StaticString = #filePath, line: UInt = #line) -> Bool {
        bindingA.syncLocal()
        bindingB.syncLocal()
        link.deliverAll()
        guard checkViews(label, file: file, line: line) else { return false }
        if a.runs != b.runs {
            XCTFail("\(label): replicas differ:\n\(ShadowModel(runs: a.runs).dump)\n----\n\(ShadowModel(runs: b.runs).dump)", file: file, line: line)
            return false
        }
        if bindingA.storageCells() != bindingB.storageCells() {
            XCTFail("\(label): the two views differ", file: file, line: line)
            return false
        }
        if !a.text.hasSuffix("\n") {
            XCTFail("\(label): the final newline is gone", file: file, line: line)
            return false
        }
        return true
    }
}

extension EditorTextView {
    /// Places the caret (or a selection) the way a click or drag would.
    func select(_ location: Int, _ length: Int = 0) {
        setSelectedRange(NSRange(location: location, length: length))
    }

    /// Types at the caret the way the keyboard does (through the input system's insertText).
    func typeText(_ text: String) {
        insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
    }

    /// Types at a position.
    func type(_ text: String, at location: Int) {
        select(location)
        typeText(text)
    }

    /// The input system replacing a range (autocorrect, a dictation result).
    func replace(range location: Int, _ length: Int, with text: String) {
        insertText(text, replacementRange: NSRange(location: location, length: length))
    }

    func backspace() {
        deleteBackward(nil)
    }

    func mark(_ text: String, caret: Int) {
        setMarkedText(text, selectedRange: NSRange(location: caret, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
    }

    var plain: String { textStorage?.string ?? "" }

    var selection: NSRange { selectedRange() }

    var scrollTop: CGFloat {
        guard let clip = enclosingScrollView?.contentView else { return 0 }
        return clip.bounds.minY + clip.contentInsets.top
    }

    func scroll(toTop y: CGFloat) {
        guard let scroll = enclosingScrollView else { return }
        scroll.contentView.scroll(to: CGPoint(x: 0, y: y - scroll.contentView.contentInsets.top))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    /// Lays out the whole text, so the frame and positions are exact.
    func layOutEverything() {
        guard let layout = textLayoutManager else { return }
        layout.ensureLayout(for: layout.documentRange)
        layout.textViewportLayoutController.layoutViewport()
    }
}

func txt(_ text: String, _ attributes: Attributes = [:]) -> TextRun { TextRun(text: text, attributes: attributes) }
func para(_ block: String? = nil, indent: Int = 0, checked: Bool = false) -> TextRun {
    var attributes: Attributes = [:]
    if let block { attributes["block"] = .string(block) }
    if indent != 0 { attributes["indent"] = .number(Double(indent)) }
    if checked { attributes["checked"] = .bool(true) }
    return TextRun(text: "\n", attributes: attributes)
}
#endif

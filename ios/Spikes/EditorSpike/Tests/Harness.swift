import UIKit
import XCTest
import TwoNoteDocuments
import TwoNoteEditor

/// Deterministic generator so a failing soak can be repeated from its seed.
struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Two real text views in a real window, each bound to its own replica of one page; updates
/// travel between the replicas only when the test says so.
@MainActor
final class Harness {
    let window: UIWindow
    let a: InMemoryPageText
    let b: InMemoryPageText
    let link: InMemoryPageLink
    let viewA = EditorTextView()
    let viewB = EditorTextView()
    let bindingA: PageTextBinding
    let bindingB: PageTextBinding

    init(seed: [TextRun]) throws {
        var scene: UIWindowScene?
        let deadline = Date().addingTimeInterval(15)
        while scene == nil && Date() < deadline {
            scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
            if scene == nil { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
        }
        let found = try XCTUnwrap(scene, "the host app has no window scene")
        window = UIWindow(windowScene: found)
        let controller = UIViewController()
        controller.view.backgroundColor = .systemBackground
        window.rootViewController = controller
        window.makeKeyAndVisible()

        a = InMemoryPageText(site: 1, seed: seed)
        b = InMemoryPageText(site: 2, seed: seed)
        link = InMemoryPageLink(a, b)
        bindingA = PageTextBinding(textView: viewA, page: a)
        bindingB = PageTextBinding(textView: viewB, page: b)

        let bounds = controller.view.bounds.inset(by: UIEdgeInsets(top: 80, left: 0, bottom: 0, right: 0))
        let half = bounds.width / 2
        viewA.frame = CGRect(x: bounds.minX, y: bounds.minY, width: half, height: min(bounds.height, 420))
        viewB.frame = CGRect(x: bounds.minX + half, y: bounds.minY, width: half, height: min(bounds.height, 420))
        controller.view.addSubview(viewA)
        controller.view.addSubview(viewB)
        controller.view.layoutIfNeeded()
    }

    func tearDown() {
        bindingA.detach()
        bindingB.detach()
        window.isHidden = true
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
    /// Places the caret (or a selection) the way a tap or drag would.
    func select(_ location: Int, _ length: Int = 0) {
        selectedRange = NSRange(location: location, length: length)
    }

    /// Types at a position the way the keyboard does.
    func type(_ text: String, at location: Int) {
        select(location)
        insertText(text)
    }

    func textRange(_ location: Int, _ length: Int) -> UITextRange? {
        guard let start = position(from: beginningOfDocument, offset: location),
              let end = position(from: start, offset: length) else { return nil }
        return textRange(from: start, to: end)
    }

    var plain: String { textStorage.string }
}

func txt(_ text: String, _ attributes: Attributes = [:]) -> TextRun { TextRun(text: text, attributes: attributes) }
func para(_ block: String? = nil, indent: Int = 0, checked: Bool = false) -> TextRun {
    var attributes: Attributes = [:]
    if let block { attributes["block"] = .string(block) }
    if indent != 0 { attributes["indent"] = .number(Double(indent)) }
    if checked { attributes["checked"] = .bool(true) }
    return TextRun(text: "\n", attributes: attributes)
}

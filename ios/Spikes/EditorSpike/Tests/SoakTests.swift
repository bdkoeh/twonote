import UIKit
import XCTest
import TwoNoteDocuments
import TwoNoteEditor

/// Randomised mixed operations on both views. Reproducible: the seed is printed and can be set
/// with the SOAK_SEED environment variable (TEST_RUNNER_SOAK_SEED for xcodebuild); SOAK_STEPS
/// sets the number of operations per phase.
@MainActor
final class SoakTests: XCTestCase {
    private var harness: Harness!

    override func tearDown() async throws {
        harness?.tearDown()
        harness = nil
    }

    private let alphabet = ["a", "b", "c", " ", " ", "\n", "\n", "é", "😀", "中", "\u{2028}", "word ", "x", "1. "]
    private let inlineKeys = ["bold", "italic", "underline", "strike", "code"]
    private let blocks: [String?] = [nil, "h1", "h2", "h3", "ul", "ol", "todo", "code"]

    private var seed: UInt64 {
        ProcessInfo.processInfo.environment["SOAK_SEED"].flatMap { UInt64($0) } ?? 20261114
    }

    private var steps: Int {
        ProcessInfo.processInfo.environment["SOAK_STEPS"].flatMap { Int($0) } ?? 2500
    }

    /// Every operation is followed by full delivery: after each step both views equal the page
    /// and each other.
    func testSoakInStep() throws {
        try soak(seed: seed, steps: steps, concurrent: false)
    }

    /// Updates arrive late and in batches, so both sides edit against stale state; IME
    /// compositions stay open across remote changes. Each view must equal its own replica after
    /// every step, and everything must converge whenever the link drains.
    func testSoakConcurrent() throws {
        try soak(seed: seed &+ 1, steps: steps, concurrent: true)
    }

    private func soak(seed: UInt64, steps: Int, concurrent: Bool) throws {
        var rng = SplitMix64(seed: seed)
        let h = try Harness(seed: [
            txt("Soak"), para("h1"), txt("first "), txt("bold", ["bold": .bool(true)]), txt(" text"), para(),
            txt("item"), para("ul"), txt("task"), para("todo", checked: true), txt("last line"), para(),
        ])
        harness = h
        print("SOAK start: seed \(seed), \(steps) steps, \(concurrent ? "concurrent" : "in step")")
        var counts: [String: Int] = [:]
        var composing: [Bool] = [false, false]
        let started = Date()

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
                // A composition is open on this view: update it, or finish it.
                if roll < 35 {
                    op = "ime-update"
                    let text = ["か", "かな", "にほん", "中文"].randomElement(using: &rng)!
                    view.setMarkedText(text, selectedRange: NSRange(location: text.utf16.count, length: 0))
                } else {
                    op = roll < 90 ? "ime-commit" : "ime-cancel"
                    if op == "ime-cancel" { view.setMarkedText("", selectedRange: NSRange(location: 0, length: 0)) }
                    view.unmarkText()
                    composing[which] = false
                    binding.syncLocal()
                }
            } else {
                switch roll {
                case 0..<26:
                    op = "type"
                    let range = randomRange(binding, maxLength: 0)
                    view.selectedRange = range
                    view.insertText(randomText())
                case 26..<34:
                    op = "replace-selection"
                    view.selectedRange = randomRange(binding, maxLength: 12)
                    view.insertText(randomText())
                case 34..<44:
                    op = "backspace"
                    view.selectedRange = randomRange(binding, maxLength: Bool.random(using: &rng) ? 0 : 10)
                    view.deleteBackward()
                case 44..<49:
                    op = "replace-range"
                    let range = randomRange(binding, maxLength: 8)
                    if let target = view.textRange(range.location, range.length) {
                        view.replace(target, withText: Bool.random(using: &rng) ? randomText() : "")
                    }
                case 49..<52:
                    op = "return-return"
                    view.selectedRange = randomRange(binding, maxLength: 0)
                    view.insertText("\n")
                    view.insertText("\n")
                case 52..<60:
                    op = "toggle-inline"
                    view.selectedRange = randomRange(binding, maxLength: 15)
                    binding.toggleInline(inlineKeys.randomElement(using: &rng)!)
                    if view.selectedRange.length == 0 { view.insertText("T") }
                case 60..<64:
                    op = "link"
                    view.selectedRange = randomRange(binding, maxLength: 10)
                    binding.setLink(Bool.random(using: &rng) ? "https://example.com/\(step % 3)" : nil)
                case 64..<72:
                    op = "set-block"
                    view.selectedRange = randomRange(binding, maxLength: 30)
                    binding.setBlock(blocks.randomElement(using: &rng)!)
                case 72..<77:
                    op = "indent"
                    view.selectedRange = randomRange(binding, maxLength: 20)
                    binding.indent(by: Bool.random(using: &rng) ? 1 : -1)
                case 77..<80:
                    op = "toggle-checked"
                    binding.toggleChecked(paragraphAt: Int.random(in: 0..<binding.shadow.count, using: &rng))
                case 80..<86:
                    op = Bool.random(using: &rng) ? "undo" : "redo"
                    if op == "undo" { binding.undo() } else { binding.redo() }
                case 86..<92:
                    op = "ime-start"
                    view.selectedRange = randomRange(binding, maxLength: Bool.random(using: &rng) ? 0 : 4)
                    view.setMarkedText("か", selectedRange: NSRange(location: 1, length: 0))
                    if binding.isComposing {
                        composing[which] = true
                    } else {
                        op = "ime-start(no marked text)"
                    }
                case 92..<95:
                    op = "trim"
                    if binding.shadow.count > 1200 {
                        view.selectedRange = NSRange(location: 0, length: safe(binding, 900))
                        view.deleteBackward()
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
            if concurrent {
                guard h.checkViews(label) else { return report(h, counts, started, failedAt: label) }
                if step % 60 == 59 && !composing[0] && !composing[1] {
                    guard h.converge(label + " (drain)") else { return report(h, counts, started, failedAt: label) }
                }
            } else if !composing[0] && !composing[1] {
                guard h.converge(label) else { return report(h, counts, started, failedAt: label) }
            } else {
                h.link.deliverAll() // remote changes arrive under the open composition
            }
        }
        for (i, binding) in h.bindings.enumerated() where composing[i] {
            binding.textView.unmarkText()
            binding.syncLocal()
        }
        h.pump(0.05)
        XCTAssertTrue(h.converge("seed \(seed) final"))
        report(h, counts, started, failedAt: nil)
    }

    private func report(_ h: Harness, _ counts: [String: Int], _ started: Date, failedAt: String?) {
        let total = counts.values.reduce(0, +)
        let ops = counts.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
        print("SOAK \(failedAt == nil ? "PASSED" : "FAILED at \(failedAt!)"): \(total) operations in \(String(format: "%.1f", Date().timeIntervalSince(started))) s")
        print("SOAK ops: \(ops)")
        for (name, b) in [("A", h.bindingA), ("B", h.bindingB)] {
            print("SOAK \(name): localTransactions=\(b.localTransactions) remoteDeltas=\(b.remoteDeltas) queuedChanges=\(b.queuedChanges) rebases=\(b.rebases) fullResets=\(b.fullResets) selectionRestores=\(b.selectionRestores) forbiddenRemoved=\(b.forbiddenCharactersRemoved) textKit2=\(b.usesTextKit2) length=\(b.shadow.count)")
        }
    }
}

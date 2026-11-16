import Testing
import TwoNoteDocuments
@testable import TwoNoteEditor

/// The binding's two directions without a text view: a "control" that only knows text and inline
/// attributes (like a text storage), reconciled against a page replica. The UIKit binding runs
/// the same plan/step code; its own tests run on the simulator.
@MainActor
private final class FakeView {
    let page: InMemoryPageText
    var shadow: ShadowModel
    var control: [Cell]
    var caret = 0
    private var ownEdit = false
    private var observation: ChangeObservation?

    init(page: InMemoryPageText) {
        self.page = page
        shadow = ShadowModel(runs: page.runs)
        control = shadow.cells
        observation = page.observeText { [unowned self] change in
            if ownEdit { return }
            var selection = SelectionTransform(start: caret, end: caret)
            for step in DeltaStep.steps(for: change.delta) {
                let fits = shadow.apply(step)
                #expect(fits)
                selection.apply(step)
            }
            control = shadow.cells
            caret = selection.start
        }
    }

    /// The user replaces `deleting` units at `at` with `text`, typed with `inline`.
    func type(_ text: String, at: Int, deleting: Int = 0, inline: InlineAttrs = InlineAttrs()) {
        let cells = text.utf16.map { Cell(unit: $0, inline: inline) }
        control.replaceSubrange(at..<at + deleting, with: cells)
        caret = at + cells.count
        sync()
    }

    func sync() {
        let control = self.control
        guard let plan = Reconciler.plan(shadow: shadow, now: control.map(\.unit), caret: caret,
                                         inlineOfInserted: { $0.map { control[$0].inline } }) else { return }
        ownEdit = true
        page.edit { plan.write(to: $0) }
        ownEdit = false
        plan.apply(to: &shadow)
        self.control = shadow.cells
    }
}

@MainActor
@Suite struct ReconcileLoopTests {
    @Test func typedTextReachesTheOtherView() {
        let seed = [TextRun(text: "one"), TextRun(text: "\n", attributes: ["block": .string("ul")]), TextRun(text: "two\n")]
        let a = InMemoryPageText(site: 1, seed: seed), b = InMemoryPageText(site: 2, seed: seed)
        let link = InMemoryPageLink(a, b)
        let va = FakeView(page: a), vb = FakeView(page: b)
        vb.caret = 5
        va.type("X", at: 1, inline: InlineAttrs(bold: true))
        va.type("\n", at: 4)
        link.deliverAll()
        #expect(a.text == "oXne\n\ntwo\n")
        #expect(vb.shadow.runs == b.runs)
        #expect(va.shadow.runs == a.runs)
        #expect(a.runs == b.runs)
        #expect(vb.caret == 7)
        #expect(vb.shadow.block(at: 5).block == "ul")
    }

    @Test(arguments: [UInt64(11), 12, 13, 14, 15, 16])
    func randomisedTwoViews(seed: UInt64) {
        var rng = SplitMix64(seed: seed)
        let seedRuns = [
            TextRun(text: "Title"), TextRun(text: "\n", attributes: ["block": .string("h1")]),
            TextRun(text: "item"), TextRun(text: "\n", attributes: ["block": .string("todo"), "checked": .bool(true)]),
            TextRun(text: "body text\n"),
        ]
        let a = InMemoryPageText(site: 1, seed: seedRuns), b = InMemoryPageText(site: 2, seed: seedRuns)
        let link = InMemoryPageLink(a, b)
        let views = [FakeView(page: a), FakeView(page: b)]
        let alphabet = ["a", "b", " ", "\n", "\n", "\u{1F600}", "\u{2028}", "é", "aa"]
        for step in 0..<2000 {
            let view = views.randomElement(using: &rng)!
            let length = view.shadow.count
            switch Int.random(in: 0..<10, using: &rng) {
            case 0...4:
                let at = safeIndex(view.page, Int.random(in: 0..<length, using: &rng))
                let end = safeIndex(view.page, min(length - 1, at + (Bool.random(using: &rng) ? 0 : Int.random(in: 0...6, using: &rng))))
                let text = (0..<Int.random(in: 0...3, using: &rng)).map { _ in alphabet.randomElement(using: &rng)! }.joined()
                view.type(text, at: at, deleting: max(0, end - at),
                          inline: InlineAttrs(bold: Bool.random(using: &rng), link: Bool.random(using: &rng) ? "https://example.com" : nil))
            case 5:
                // Select all, delete: the control is left with nothing but the final newline.
                view.type("", at: 0, deleting: length - 1)
            case 6:
                if Bool.random(using: &rng) { view.page.undo() } else { view.page.redo() }
            default:
                if Bool.random(using: &rng) { link.deliverNextToA() } else { link.deliverNextToB() }
            }
            for v in views {
                #expect(v.shadow.runs == v.page.runs, "seed \(seed) step \(step): view and page differ")
                #expect(v.caret >= 0 && v.caret <= v.shadow.count)
            }
            if step % 40 == 39 {
                link.deliverAll()
                #expect(views[0].shadow.runs == views[1].shadow.runs, "seed \(seed) step \(step): views differ")
                #expect(a.text.hasSuffix("\n") && !hasLoneSurrogate(a.text))
            }
        }
    }
}

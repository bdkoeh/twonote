import Testing
import TwoNoteDocuments
@testable import TwoNoteEditor

/// Deterministic generator so a failing run can be repeated from its seed.
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

@MainActor
private func replicas(_ seed: [TextRun] = [TextRun(text: "\n")]) -> (InMemoryPageText, InMemoryPageText, InMemoryPageLink) {
    let a = InMemoryPageText(site: 1, seed: seed)
    let b = InMemoryPageText(site: 2, seed: seed)
    return (a, b, InMemoryPageLink(a, b))
}

/// Applies deltas to a copy of the text, to prove that the reported deltas describe the changes.
@MainActor
private final class Follower {
    var model: ShadowModel
    var sources: [ChangeSource] = []
    private var observation: ChangeObservation?

    init(_ page: InMemoryPageText) {
        model = ShadowModel(runs: page.runs)
        observation = page.observeText { [unowned self] change in
            sources.append(change.source)
            for step in DeltaStep.steps(for: change.delta) {
                let fits = model.apply(step)
                #expect(fits)
            }
        }
    }
}

@MainActor
@Suite struct InMemoryPageTextTests {
    @Test func localEditsReportExactDeltas() {
        let (a, _, _) = replicas([TextRun(text: "hello\n")])
        var changes: [TextChange] = []
        let observation = a.observeText { changes.append($0) }
        a.edit { $0.insert("XY", at: 2, attributes: ["bold": .bool(true)]) }
        a.edit { $0.delete(at: 0, count: 1) }
        a.edit { $0.format(at: 1, count: 2, attributes: ["italic": .bool(true)]) }
        a.edit { $0.setBlock(newlineAt: $0.length - 1, block: "todo", indent: 2, checked: true) }
        observation.cancel()
        a.edit { $0.insert("z", at: 0, attributes: [:]) }

        #expect(a.text == "zeXYllo\n")
        #expect(changes.map(\.source) == [.local, .local, .local, .local])
        #expect(changes[0].delta == [.retain(count: 2, attributes: nil), .insert(text: "XY", attributes: ["bold": .bool(true)])])
        #expect(changes[1].delta == [.delete(count: 1)])
        #expect(changes[2].delta == [.retain(count: 1, attributes: nil), .retain(count: 2, attributes: ["italic": .bool(true)])])
        #expect(changes[3].delta == [
            .retain(count: 6, attributes: nil),
            .retain(count: 1, attributes: ["block": .string("todo"), "indent": .number(2), "checked": .bool(true)]),
        ])
        #expect(a.runs.last == TextRun(text: "\n", attributes: ["block": .string("todo"), "indent": .number(2), "checked": .bool(true)]))
    }

    @Test func editAppendsTheMissingFinalNewline() {
        let a = InMemoryPageText(site: 1, seed: [TextRun(text: "abc")])
        a.edit { _ in }
        #expect(a.text == "abc\n")
        let empty = InMemoryPageText(site: 1, seed: [])
        empty.edit { $0.insert("x", at: 0, attributes: [:]) }
        #expect(empty.text == "x\n")
    }

    @Test func concurrentEditsConverge() {
        let (a, b, link) = replicas([TextRun(text: "hello world\n")])
        let fa = Follower(a), fb = Follower(b)
        a.edit { $0.insert("AAA", at: 5, attributes: [:]) }
        b.edit { $0.insert("BBB", at: 5, attributes: [:]) }
        a.edit { $0.delete(at: 0, count: 2) }
        b.edit { $0.format(at: 0, count: 5, attributes: ["bold": .bool(true)]) }
        b.edit { $0.insert("\n", at: 11, attributes: ["block": .string("ul")]) }
        #expect(a.text != b.text)
        link.deliverAll()
        #expect(a.runs == b.runs)
        #expect(a.text.hasSuffix("\n"))
        #expect(fa.model.runs == a.runs)
        #expect(fb.model.runs == b.runs)
        #expect(fa.sources.contains(.remote) && fb.sources.contains(.remote))
    }

    @Test func undoOnlyTakesBackOwnEdits() {
        let (a, b, link) = replicas([TextRun(text: "base\n")])
        let fa = Follower(a), fb = Follower(b)
        a.edit { $0.insert("A1 ", at: 0, attributes: [:]) }
        link.deliverAll()
        b.edit { $0.insert("B1 ", at: 0, attributes: [:]) }
        link.deliverAll()
        a.edit { $0.format(at: 0, count: 4, attributes: ["bold": .bool(true)]) }
        link.deliverAll()
        #expect(a.text == "B1 A1 base\n")

        #expect(a.undo())            // the bold
        #expect(a.undo())            // "A1 "
        #expect(!a.undo())
        #expect(!b.canRedo)
        link.deliverAll()
        #expect(a.text == "B1 base\n")
        #expect(a.runs == b.runs)
        #expect(a.runs == [TextRun(text: "B1 base\n")])

        #expect(a.redo())
        #expect(a.redo())
        #expect(!a.redo())
        link.deliverAll()
        #expect(a.text == "B1 A1 base\n")
        #expect(a.runs == b.runs)

        #expect(b.undo())
        link.deliverAll()
        #expect(a.text == "A1 base\n")
        #expect(a.runs == b.runs)
        #expect(fa.model.runs == a.runs)
        #expect(fb.model.runs == b.runs)
        #expect(fa.sources.contains(.undo))
    }

    @Test func undoOfDeletionBringsTheTextBackWithItsFormatting() {
        let (a, b, link) = replicas([
            TextRun(text: "ab"), TextRun(text: "cd", attributes: ["italic": .bool(true)]), TextRun(text: "ef\n"),
        ])
        a.edit { $0.delete(at: 1, count: 4) }
        link.deliverAll()
        b.edit { $0.insert("!", at: 1, attributes: [:]) }
        link.deliverAll()
        #expect(a.text == "a!f\n")
        a.undo()
        link.deliverAll()
        #expect(a.runs == b.runs)
        #expect(a.text.count == 8)
        #expect(a.runs.contains(TextRun(text: "cd", attributes: ["italic": .bool(true)])))
    }

    @Test func aNewEditClearsRedo() {
        let (a, _, _) = replicas([TextRun(text: "\n")])
        a.edit { $0.insert("x", at: 0, attributes: [:]) }
        a.undo()
        #expect(a.canRedo)
        a.edit { $0.insert("y", at: 0, attributes: [:]) }
        #expect(!a.canRedo)
    }

    /// Random edits on both replicas with updates arriving late.
    @Test(arguments: [UInt64(1), 2, 3, 4, 5, 6, 7, 8])
    func randomisedConvergence(seed: UInt64) {
        var rng = SplitMix64(seed: seed)
        let (a, b, link) = replicas([TextRun(text: "seed text\n")])
        let fa = Follower(a), fb = Follower(b)
        let alphabet = Array("ab \n\u{1F600}\u{2028}é".unicodeScalars).map { String($0) }
        for step in 0..<1500 {
            let page = Bool.random(using: &rng) ? a : b
            switch Int.random(in: 0..<10, using: &rng) {
            case 0...3:
                let text = (0..<Int.random(in: 1...4, using: &rng)).map { _ in alphabet.randomElement(using: &rng)! }.joined()
                let at = safeIndex(page, Int.random(in: 0..<page.length, using: &rng))
                page.edit { $0.insert(text, at: at, attributes: Bool.random(using: &rng) ? ["bold": .bool(true)] : [:]) }
            case 4...5:
                guard page.length > 1 else { continue }
                let at = safeIndex(page, Int.random(in: 0..<page.length - 1, using: &rng))
                let end = safeIndex(page, min(page.length - 1, at + Int.random(in: 1...5, using: &rng)))
                if end > at { page.edit { $0.delete(at: at, count: end - at) } }
            case 6:
                let at = safeIndex(page, Int.random(in: 0..<page.length, using: &rng))
                let end = safeIndex(page, min(page.length, at + Int.random(in: 1...6, using: &rng)))
                let on = Bool.random(using: &rng)
                if end > at { page.edit { $0.format(at: at, count: end - at, attributes: ["italic": on ? .bool(true) : nil]) } }
            case 7:
                let units = Array(page.text.utf16)
                let newlines = units.indices.filter { units[$0] == newlineUnit }
                let at = newlines.randomElement(using: &rng)!
                page.edit { $0.setBlock(newlineAt: at, block: ["ul", "ol", "todo", nil].randomElement(using: &rng)!,
                                        indent: Int.random(in: 0...3, using: &rng), checked: Bool.random(using: &rng)) }
            case 8:
                if Bool.random(using: &rng) { page.undo() } else { page.redo() }
            default:
                if Bool.random(using: &rng) { link.deliverNextToA() } else { link.deliverNextToB() }
            }
            #expect(fa.model.runs == a.runs, "seed \(seed) step \(step): A's deltas do not add up")
            #expect(fb.model.runs == b.runs, "seed \(seed) step \(step): B's deltas do not add up")
            if step % 50 == 49 {
                link.deliverAll()
                #expect(a.runs == b.runs, "seed \(seed) step \(step): replicas differ")
                #expect(a.text.hasSuffix("\n"))
                #expect(!hasLoneSurrogate(a.text), "seed \(seed) step \(step)")
            }
        }
    }
}

/// Moves an index off the middle of a surrogate pair.
@MainActor
func safeIndex(_ page: any PageText, _ index: Int) -> Int {
    let units = Array(page.text.utf16)
    if index > 0 && index < units.count && UTF16.isTrailSurrogate(units[index]) && UTF16.isLeadSurrogate(units[index - 1]) {
        return index - 1
    }
    return index
}

func hasLoneSurrogate(_ text: String) -> Bool {
    text.unicodeScalars.contains("\u{FFFD}")
}

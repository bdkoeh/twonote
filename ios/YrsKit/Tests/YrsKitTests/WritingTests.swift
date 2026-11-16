import CYrs
import Foundation
import Testing
import TwoNoteDocuments
@testable import YrsKit

/// Edits made through this implementation: deltas, undo, convergence between two replicas, and
/// docs/crdt-fixtures-swift.json, which the Windows test suite reads back
/// (`TWONOTE_WRITE_CRDT_FIXTURES=1 swift test` rewrites it).
@MainActor
@Suite("writing")
struct WritingTests {
    static let pageId = "00112233445566778899aabbccddeeff"
    static let notebookId = "0f1e2d3c4b5a69788796a5b4c3d2e1f0"

    /// A page with a local mirror kept up to date from the change events, and the updates it produced.
    @MainActor
    final class Replica {
        let page = YrsPageDocument(pageId: WritingTests.pageId)
        var model = Model()
        var updates: [Data] = []
        var sources: [ChangeSource] = []
        private var observation: ChangeObservation?

        init() {
            page.onLocalUpdate = { [unowned self] in updates.append($0) }
            observation = page.observeText { [unowned self] change in
                model.apply(change.delta)
                sources.append(change.source)
            }
        }

        func takeUpdates() -> [Data] {
            defer { updates.removeAll() }
            return updates
        }

        func check(_ comment: Comment) {
            #expect(normalise(model.runs) == normalise(page.runs), comment)
        }
    }

    typealias Step = (name: String, action: @MainActor (YrsPageDocument) -> Void)

    static let steps: [Step] = [
        ("initialize", { $0.initialize() }),
        ("insert plain text", { $0.edit { $0.insert("Hello world", at: 0, attributes: [:]) } }),
        ("bold a word", { $0.edit { $0.format(at: 6, count: 5, attributes: ["bold": .bool(true)]) } }),
        ("insert with attributes", { $0.edit { $0.insert(" and more", at: 11, attributes: ["italic": .bool(true), "underline": .bool(true)]) } }),
        ("heading 2", { $0.edit { $0.setBlock(newlineAt: 20, block: "h2", indent: 0, checked: false) } }),
        ("second paragraph", { $0.edit {
            $0.insert("\nbuy milk", at: 20, attributes: [:])
            $0.setBlock(newlineAt: 20, block: "h2", indent: 0, checked: false)
            $0.setBlock(newlineAt: 29, block: "todo", indent: 3, checked: true)
        } }),
        ("link and code", { $0.edit {
            $0.insert("\nsee site or run ls", at: 29, attributes: [:])
            $0.setBlock(newlineAt: 29, block: "todo", indent: 3, checked: true)
            $0.setBlock(newlineAt: 48, block: nil, indent: 0, checked: false)
            $0.format(at: 34, count: 4, attributes: ["link": .string("https://example.org/x?y=z#w")])
            $0.format(at: 46, count: 2, attributes: ["code": .bool(true), "strike": .bool(true)])
        } }),
        ("emoji and soft break", { $0.edit { $0.insert("\u{1F680} caf\u{E9} line\u{2028}break \u{4F60}\u{597D} ", at: 30, attributes: [:]) } }),
        ("bulleted item", { $0.edit {
            let end = $0.length - 1
            $0.insert("\nfirst", at: end, attributes: [:])
            $0.setBlock(newlineAt: $0.length - 1, block: "ul", indent: 1, checked: false)
        } }),
        ("delete a range", { $0.edit { $0.delete(at: 0, count: 6) } }),
        ("remove bold", { $0.edit { $0.format(at: 0, count: 5, attributes: ["bold": nil]) } }),
        ("code block", { $0.edit { $0.setBlock(newlineAt: $0.length - 1, block: "code", indent: 0, checked: false) } }),
        ("undo", { #expect($0.undo()) }),
        ("redo", { #expect($0.redo()) }),
        ("undo again", { #expect($0.undo()) }),
    ]

    @Test func editsReportDeltasAndReplicate() {
        let a = Replica()
        let b = Replica()
        for step in Self.steps {
            step.action(a.page)
            a.page.breakUndoGroup()
            a.check("local \(step.name)")
            for update in a.takeUpdates() {
                #expect(b.page.applyUpdate(update))
            }
            b.check("remote \(step.name)")
            #expect(normalise(a.page.runs) == normalise(b.page.runs), "converged after \(step.name)")
        }
        #expect(a.sources.contains(.local) && a.sources.contains(.undo) && !a.sources.contains(.remote))
        #expect(b.sources.allSatisfy { $0 == .remote })
        #expect(b.updates.isEmpty, "applying remote updates produces no local updates")
        #expect(a.page.text.hasSuffix("\n"))
    }

    @Test func undoOnlyUndoesOwnEdits() {
        let a = Replica()
        let b = Replica()
        a.page.initialize()
        a.page.edit { $0.insert("mine", at: 0, attributes: [:]) }
        a.takeUpdates().forEach { b.page.applyUpdate($0) }
        b.page.edit { $0.insert(" theirs", at: 4, attributes: ["bold": .bool(true)]) }
        b.takeUpdates().forEach { a.page.applyUpdate($0) }
        #expect(a.page.text == "mine theirs\n")

        #expect(!b.page.canRedo)
        #expect(a.page.undo())
        #expect(a.page.text == " theirs\n", "undo removed only this replica's text")
        #expect(!a.page.canUndo, "the remote edit is not on the undo stack")
        a.takeUpdates().forEach { b.page.applyUpdate($0) }
        #expect(b.page.text == " theirs\n")
        #expect(a.page.redo())
        #expect(a.page.text == "mine theirs\n")
        a.check("after redo")
    }

    @Test func undoGroupsEditsWithinTheCaptureWindowAndBreaksOnRequest() {
        let page = YrsPageDocument(pageId: Self.pageId, undoCaptureMilliseconds: 60_000)
        page.initialize()
        page.edit { $0.insert("a", at: 0, attributes: [:]) }
        page.edit { $0.insert("b", at: 1, attributes: [:]) }
        page.breakUndoGroup()
        page.edit { $0.insert("c", at: 2, attributes: [:]) }
        #expect(page.undo())
        #expect(page.text == "ab\n")
        #expect(page.undo())
        #expect(page.text == "\n", "initialize is housekeeping and is never undone")
        #expect(!page.canUndo)
    }

    @Test func concurrentEditsConverge() {
        let a = Replica()
        let b = Replica()
        a.page.initialize()
        a.page.edit { $0.insert("The quick brown fox", at: 0, attributes: [:]) }
        a.takeUpdates().forEach { b.page.applyUpdate($0) }

        a.page.edit {
            $0.format(at: 4, count: 11, attributes: ["italic": .bool(true)])
            $0.insert("very ", at: 10, attributes: [:])
        }
        b.page.edit {
            $0.delete(at: 4, count: 6)
            $0.insert(" jumps", at: $0.length - 1, attributes: [:])
            $0.setBlock(newlineAt: $0.length - 1, block: "ol", indent: 0, checked: false)
        }
        let fromA = a.takeUpdates(), fromB = b.takeUpdates()
        fromB.forEach { a.page.applyUpdate($0) }
        fromA.forEach { b.page.applyUpdate($0) }
        #expect(normalise(a.page.runs) == normalise(b.page.runs))
        a.check("a")
        b.check("b")
    }

    @Test func aPageWithoutItsFinalNewlineGetsOneOnTheFirstEdit() {
        let page = YrsPageDocument(pageId: Self.pageId)
        #expect(page.text == "")
        page.edit { editor in
            #expect(editor.text == "\n")
            editor.insert("x", at: 0, attributes: [:])
        }
        #expect(page.text == "x\n")
    }

    @Test func stateVectorDiffCarriesOnlyWhatIsMissing() {
        let a = YrsPageDocument(pageId: Self.pageId)
        a.initialize()
        a.edit { $0.insert("one", at: 0, attributes: [:]) }
        let b = YrsPageDocument(pageId: Self.pageId)
        #expect(b.applyUpdate(a.encodeState()))
        a.edit { $0.insert(" two", at: 3, attributes: [:]) }
        let diff = a.encodeDiff(from: b.encodeStateVector())
        #expect(diff.count < a.encodeState().count)
        #expect(b.applyUpdate(diff))
        #expect(b.text == "one two\n")
    }

    // MARK: The file for the Windows tests

    @Test func writeFixtureFileWhenAsked() throws {
        guard ProcessInfo.processInfo.environment["TWONOTE_WRITE_CRDT_FIXTURES"] == "1" else { return }

        // Page, step by step.
        let a = Replica()
        var steps: [String] = []
        for step in Self.steps {
            step.action(a.page)
            a.page.breakUndoGroup()
            steps.append(object([
                ("name", string(step.name)),
                ("updates", array(a.takeUpdates().map { string($0.hex) })),
                ("runs", runsJson(a.page.runs)),
            ]))
        }
        let page = object([("docId", string(Self.pageId)), ("steps", array(steps)), ("snapshot", string(a.page.encodeState().hex))])

        // Concurrent edits.
        let one = Replica(), two = Replica()
        one.page.initialize()
        one.page.edit { $0.insert("The quick brown fox", at: 0, attributes: [:]) }
        let base = one.page.encodeState()
        _ = one.takeUpdates()
        two.page.applyUpdate(base)
        one.page.edit {
            $0.format(at: 4, count: 11, attributes: ["italic": .bool(true)])
            $0.insert("very ", at: 10, attributes: [:])
        }
        two.page.edit {
            $0.delete(at: 4, count: 6)
            $0.insert(" jumps", at: $0.length - 1, attributes: [:])
            $0.setBlock(newlineAt: $0.length - 1, block: "ol", indent: 0, checked: false)
        }
        let fromOne = one.takeUpdates(), fromTwo = two.takeUpdates()
        try #require(fromOne.count == 1 && fromTwo.count == 1)
        one.page.applyUpdate(fromTwo[0])
        two.page.applyUpdate(fromOne[0])
        try #require(normalise(one.page.runs) == normalise(two.page.runs))
        let concurrent = object([
            ("docId", string(Self.pageId)), ("base", string(base.hex)),
            ("a", string(fromOne[0].hex)), ("b", string(fromTwo[0].hex)), ("runs", runsJson(one.page.runs)),
        ])

        // Notebook tree, written with raw map operations in the shape of PROTOCOL.md 5.1.
        let tree = YrsDocument(docId: Self.notebookId)
        var treeUpdates: [Data] = []
        tree.onLocalUpdate = { treeUpdates.append($0) }
        // (Type annotations: without them Swift 6.4 reports "no member 'rootMap'" here.)
        let meta: UnsafeMutablePointer<Branch> = tree.rootMap("meta")
        let sections: UnsafeMutablePointer<Branch> = tree.rootMap("sections")
        let pages: UnsafeMutablePointer<Branch> = tree.rootMap("pages")
        let s1 = "11111111111111111111111111111111", s2 = "22222222222222222222222222222222"
        let p1 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", p2 = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
        tree.write(system: true) { txn, arena in
            tree.mapSet(meta, "formatVersion", arena.input(.number(1)), txn, arena)
            tree.mapSet(meta, "title", arena.input(.string("Phone notes \u{1F4F1}")), txn, arena)
        }
        tree.write { txn, arena in
            tree.mapSet(sections, s1, arena.sharedMap([
                ("title", arena.input(.string("From the phone"))), ("order", arena.input(.string("V"))), ("deleted", arena.input(.bool(false))),
            ]), txn, arena)
            tree.mapSet(sections, s2, arena.sharedMap([
                ("title", arena.input(.string("Gone"))), ("order", arena.input(.string("K"))), ("deleted", arena.input(.bool(false))),
            ]), txn, arena)
        }
        tree.write { txn, arena in
            for (id, title, order) in [(p1, "First page", "V"), (p2, "Second \u{2013} page", "k")] {
                tree.mapSet(pages, id, arena.sharedMap([
                    ("sectionId", arena.input(.string(s1))), ("title", arena.input(.string(title))), ("order", arena.input(.string(order))),
                    ("deleted", arena.input(.bool(false))),
                    ("createdAt", arena.input(.number(1_763_164_800_000))), ("updatedAt", arena.input(.number(1_763_164_800_000))),
                ]), txn, arena)
            }
        }
        tree.write { txn, arena in
            // Later changes to nested maps: rename, touch, delete flag.
            guard case .map(let page)? = tree.mapGet(pages, p1, txn), case .map(let section)? = tree.mapGet(sections, s2, txn) else {
                Issue.record("nested maps are missing")
                return
            }
            tree.mapSet(page, "title", arena.input(.string("First page, renamed")), txn, arena)
            tree.mapSet(page, "updatedAt", arena.input(.number(1_763_164_860_000)), txn, arena)
            tree.mapSet(section, "deleted", arena.input(.bool(true)), txn, arena)
        }
        let readBack = tree.read { txn in
            tree.mapEntries(pages, txn).compactMap { entry -> String? in
                guard case .map(let page) = entry.value, case .string(let title)? = tree.mapGet(page, "title", txn) else { return nil }
                return title
            }.sorted()
        }
        #expect(readBack == ["First page, renamed", "Second \u{2013} page"])

        let notebook = object([
            ("notebookId", string(Self.notebookId)),
            ("updates", array(treeUpdates.map { string($0.hex) })),
            ("title", string("Phone notes \u{1F4F1}")),
            // Display order: by `order` compared byte by byte ("K" < "V").
            ("sections", array([
                object([("id", string(s2)), ("title", string("Gone")), ("order", string("K")), ("deleted", "true")]),
                object([("id", string(s1)), ("title", string("From the phone")), ("order", string("V")), ("deleted", "false")]),
            ])),
            ("pages", array([
                object([("id", string(p1)), ("sectionId", string(s1)), ("title", string("First page, renamed")), ("order", string("V")),
                        ("deleted", "false"), ("createdAt", "1763164800000"), ("updatedAt", "1763164860000")]),
                object([("id", string(p2)), ("sectionId", string(s1)), ("title", string("Second \u{2013} page")), ("order", string("k")),
                        ("deleted", "false"), ("createdAt", "1763164800000"), ("updatedAt", "1763164800000")]),
            ])),
        ])

        let file = object([
            ("description", string("Yjs v1 updates written by the iOS client (Yrs via its C API), in the shape of crdt-fixtures.json. The Windows test suite reads them back.")),
            ("page", page), ("concurrent", concurrent), ("notebook", notebook),
        ])
        try (file + "\n").write(to: FixtureTests.docs.appendingPathComponent("crdt-fixtures-swift.json"), atomically: true, encoding: .utf8)
    }

    // MARK: JSON with a fixed key order

    private func string(_ s: String) -> String {
        let data = try! JSONSerialization.data(withJSONObject: [s])
        return String(String(decoding: data, as: UTF8.self).dropFirst().dropLast())
    }

    private func object(_ fields: [(String, String)]) -> String {
        "{" + fields.map { string($0.0) + ":" + $0.1 }.joined(separator: ",") + "}"
    }

    private func array(_ items: [String]) -> String {
        "[" + items.joined(separator: ",") + "]"
    }

    private func runsJson(_ runs: [TextRun]) -> String {
        array(runs.map { run in
            let attributes = run.attributes.sorted { $0.key < $1.key }.map { key, value -> (String, String) in
                switch value {
                case .bool(let b): (key, b ? "true" : "false")
                case .string(let s): (key, string(s))
                case .number(let n): (key, n == n.rounded() ? String(Int(n)) : String(n))
                }
            }
            return object([("text", string(run.text)), ("attributes", object(attributes))])
        })
    }
}

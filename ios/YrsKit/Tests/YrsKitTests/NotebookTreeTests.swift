import Foundation
import Testing
import TwoNoteDocuments
import YrsKit

@Suite("fractional index")
struct FractionalIndexTests {
    @Test func firstKeyAndSimpleNeighbours() {
        #expect(FractionalIndex.between(nil, nil) == "V")
        #expect(FractionalIndex.between("V", nil) == "W")
        #expect(FractionalIndex.between(nil, "V") == "U")
        #expect(FractionalIndex.between("V", "W") == "VV")
        #expect(FractionalIndex.between("V", "VV") == "VG")
        #expect(FractionalIndex.between("V", "W1") == "W")
        #expect(FractionalIndex.between("z", nil) == "z1")
        #expect(FractionalIndex.between(nil, "1") == "0y")
        #expect(FractionalIndex.between(nil, "01") == "00y")
    }

    @Test(arguments: ["", "V0", "a-b", "\u{E9}"])
    func malformedKeysAreRejected(key: String) {
        #expect(!FractionalIndex.isValid(key))
        #expect(FractionalIndex.between(key, nil) == nil)
        #expect(FractionalIndex.between(nil, key) == nil)
    }

    @Test func keysInTheWrongOrderAreRejected() {
        #expect(FractionalIndex.between("W", "V") == nil)
        #expect(FractionalIndex.between("V", "V") == nil)
    }

    @Test(arguments: [1, 2, 3])
    func randomInsertionsKeepAStrictOrder(seed: UInt64) throws {
        var state = seed &* 0x9E37_79B9_7F4A_7C15
        func next(_ bound: Int) -> Int {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int((state >> 33) % UInt64(bound))
        }
        var keys: [String] = []
        for _ in 0..<3000 {
            let at = next(keys.count + 1)
            let key = try #require(FractionalIndex.between(at > 0 ? keys[at - 1] : nil, at < keys.count ? keys[at] : nil))
            #expect(FractionalIndex.isValid(key))
            keys.insert(key, at: at)
        }
        for i in 1..<keys.count {
            #expect(FractionalIndex.precedes(keys[i - 1], keys[i]), "\(keys[i - 1]) !< \(keys[i])")
        }
        #expect(keys == keys.sorted { Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8)) })
    }

    @Test func appendingAndPrependingAThousandItemsKeepsKeysShort() throws {
        var last: String?, first: String?
        for _ in 0..<1000 {
            let next = try #require(FractionalIndex.between(last, nil))
            #expect(last == nil || FractionalIndex.precedes(last!, next))
            last = next
            let previous = try #require(FractionalIndex.between(nil, first))
            #expect(first == nil || FractionalIndex.precedes(previous, first!))
            first = previous
        }
        #expect(last!.count <= 20)
        #expect(first!.count <= 40)
    }

    @Test func repeatedlySplittingTheSameGapAlwaysFindsRoom() throws {
        var low = "V", high = "W"
        for i in 0..<200 {
            let mid = try #require(FractionalIndex.between(low, high))
            #expect(FractionalIndex.precedes(low, mid) && FractionalIndex.precedes(mid, high))
            if i % 2 == 0 { high = mid } else { low = mid }
        }
    }
}

@MainActor
@Suite("notebook tree")
struct NotebookTreeTests {
    static let notebookId = "0f1e2d3c4b5a69788796a5b4c3d2e1f0"

    @Test func windowsFixtureReadsBackAsRecorded() throws {
        let data = try Data(contentsOf: FixtureTests.docs.appendingPathComponent("crdt-fixtures.json"))
        let root = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let nb = try #require(root["notebook"] as? [String: Any])
        let tree = YrsNotebookTree(notebookId: nb["notebookId"] as! String)
        for update in nb["updates"] as! [String] {
            #expect(tree.applyUpdate(Data(hex: update)))
        }
        #expect(tree.title == nb["title"] as! String)

        let sections = tree.sections(includeDeleted: true)
        let expectedSections = nb["sections"] as! [[String: Any]]
        #expect(sections.map(\.id) == expectedSections.map { $0["id"] as! String })
        #expect(sections.map(\.title) == expectedSections.map { $0["title"] as! String })
        #expect(sections.map(\.order) == expectedSections.map { $0["order"] as! String })
        #expect(sections.map(\.deleted) == expectedSections.map { $0["deleted"] as! Bool })

        // The file lists pages section by section in display order.
        let pages = sections.flatMap { tree.pages(inSection: $0.id, includeDeleted: true) }
        let expectedPages = nb["pages"] as! [[String: Any]]
        #expect(pages.map(\.id) == expectedPages.map { $0["id"] as! String })
        #expect(pages.map(\.sectionId) == expectedPages.map { $0["sectionId"] as! String })
        #expect(pages.map(\.title) == expectedPages.map { $0["title"] as! String })
        #expect(pages.map(\.order) == expectedPages.map { $0["order"] as! String })
        #expect(pages.map(\.deleted) == expectedPages.map { $0["deleted"] as! Bool })
        #expect(pages.map { $0.createdAt.timeIntervalSince1970 * 1000 } == expectedPages.map { ($0["createdAt"] as! NSNumber).doubleValue })
        #expect(pages.map { $0.updatedAt.timeIntervalSince1970 * 1000 } == expectedPages.map { ($0["updatedAt"] as! NSNumber).doubleValue })
        #expect(tree.sections().count == sections.filter { !$0.deleted }.count)
    }

    @Test func sectionsAndPagesKeepTheirOrderThroughAddMoveRenameDelete() {
        var clock = Date(timeIntervalSince1970: 1_763_164_800)
        let tree = YrsNotebookTree(notebookId: Self.notebookId) { clock }
        var updates: [Data] = []
        tree.onLocalUpdate = { updates.append($0) }

        tree.initialize(title: "Work")
        let inbox = tree.addSection(title: "Inbox")
        let ideas = tree.addSection(title: "Ideas")
        let first = tree.addSection(title: "First", at: 0)
        #expect(tree.sections().map(\.title) == ["First", "Inbox", "Ideas"])

        let p1 = tree.addPage(inSection: inbox, title: "Shopping")
        let p2 = tree.addPage(inSection: inbox, title: "Top", at: 0)
        let p3 = tree.addPage(inSection: ideas, title: "Moved")
        #expect(tree.pages(inSection: inbox).map(\.title) == ["Top", "Shopping"])

        clock = clock.addingTimeInterval(60)
        tree.renamePage(p1, title: "Shopping list")
        #expect(tree.page(p1)?.updatedAt == clock)
        #expect(tree.page(p1)?.createdAt == clock.addingTimeInterval(-60))

        tree.movePage(p3, toSection: inbox, at: 1)
        #expect(tree.pages(inSection: inbox).map(\.title) == ["Top", "Moved", "Shopping list"])
        #expect(tree.pages(inSection: ideas).isEmpty)

        tree.moveSection(first, to: nil)
        #expect(tree.sections().map(\.title) == ["Inbox", "Ideas", "First"])
        tree.renameSection(first, title: "Last")
        tree.setPageDeleted(p2)
        tree.setSectionDeleted(ideas)
        tree.setTitle("Work notes")
        #expect(tree.sections().map(\.title) == ["Inbox", "Last"])
        #expect(tree.sections(includeDeleted: true).count == 3)
        #expect(tree.pages(inSection: inbox).map(\.title) == ["Moved", "Shopping list"])
        #expect(tree.section(ideas)?.deleted == true)
        #expect(tree.page("ffffffffffffffffffffffffffffffff") == nil)

        // A second replica that gets the updates sees the same tree.
        let other = YrsNotebookTree(notebookId: Self.notebookId)
        updates.forEach { other.applyUpdate($0) }
        #expect(other.title == "Work notes")
        #expect(other.sections(includeDeleted: true) == tree.sections(includeDeleted: true))
        #expect(other.allPages(includeDeleted: true) == tree.allPages(includeDeleted: true))
    }

    @Test func concurrentInsertsAtTheSamePlaceBothSurviveAndTheNextInsertLandsAfterTheTie() {
        let a = YrsNotebookTree(notebookId: Self.notebookId)
        a.initialize(title: "n")
        let s = a.addSection(title: "s")
        let b = YrsNotebookTree(notebookId: Self.notebookId)
        b.applyUpdate(a.encodeState())

        var fromA: [Data] = [], fromB: [Data] = []
        a.onLocalUpdate = { fromA.append($0) }
        b.onLocalUpdate = { fromB.append($0) }
        a.addPage(inSection: s, title: "from a")
        b.addPage(inSection: s, title: "from b")
        fromB.forEach { a.applyUpdate($0) }
        fromA.forEach { b.applyUpdate($0) }
        #expect(a.pages(inSection: s) == b.pages(inSection: s))
        #expect(Set(a.pages(inSection: s).map(\.order)).count == 1, "both got the same order key")

        a.addPage(inSection: s, title: "between", at: 1)
        #expect(a.pages(inSection: s).map(\.title).last == "between")
    }

    @Test func aPageCanBeAddedUnderAGivenId() {
        let tree = YrsNotebookTree(notebookId: Self.notebookId)
        tree.initialize(title: "n")
        let s = tree.addSection(title: "s")
        let id = "00112233445566778899aabbccddeeff"
        #expect(tree.addPage(inSection: s, title: "given", id: id) == id)
        #expect(tree.page(id)?.title == "given")
        // Anything that is not a document id is ignored and a random id is used.
        for bad in ["", "xyz", "00112233445566778899AABBCCDDEEFF", "00112233445566778899aabbccddeeff00"] {
            let made = tree.addPage(inSection: s, title: "random", id: bad)
            #expect(made != bad && made.count == 32)
        }
        #expect(tree.pages(inSection: s).count == 5)
    }
}

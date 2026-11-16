import Foundation
import Testing
import TwoNoteDocuments
@testable import YrsKit

/// Replays docs/crdt-fixtures.json: Yjs updates written by the Windows client, and the state
/// every client must read back from them.
@MainActor
@Suite("docs/crdt-fixtures.json")
struct FixtureTests {
    static let docs = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("docs")

    let fixtures: [String: Any]

    init() throws {
        let data = try Data(contentsOf: Self.docs.appendingPathComponent("crdt-fixtures.json"))
        fixtures = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test func pageStepsReadBackAsRecorded() throws {
        let page = try #require(fixtures["page"] as? [String: Any])
        let steps = try #require(page["steps"] as? [[String: Any]])
        let document = YrsPageDocument(pageId: page["docId"] as! String)
        for step in steps {
            for update in step["updates"] as! [String] {
                #expect(document.applyUpdate(Data(hex: update)))
            }
            #expect(normalise(document.runs) == normalise(runs(step["runs"]!)), "step \(step["name"]!)")
        }
        #expect(document.text == document.runs.map(\.text).joined())
        #expect(document.length == document.text.utf16.count)

        let fromSnapshot = YrsPageDocument(pageId: document.docId)
        #expect(fromSnapshot.applyUpdate(Data(hex: page["snapshot"] as! String)))
        #expect(normalise(fromSnapshot.runs) == normalise(runs(steps.last!["runs"]!)))

        // Our own snapshot of the same state reads back the same on a third replica.
        let third = YrsPageDocument(pageId: document.docId)
        #expect(third.applyUpdate(document.encodeState()))
        #expect(normalise(third.runs) == normalise(document.runs))
    }

    @Test func remoteStepsArriveAsDeltasThatRebuildTheText() throws {
        // Apply every delta to a local model; it must end up equal to what the document says.
        let page = try #require(fixtures["page"] as? [String: Any])
        let document = YrsPageDocument(pageId: page["docId"] as! String)
        var model = Model()
        let observation = document.observeText { change in
            #expect(change.source == .remote)
            model.apply(change.delta)
        }
        for step in page["steps"] as! [[String: Any]] {
            for update in step["updates"] as! [String] {
                document.applyUpdate(Data(hex: update))
            }
            #expect(normalise(model.runs) == normalise(document.runs), "step \(step["name"]!)")
        }
        observation.cancel()
    }

    @Test func concurrentEditsConvergeInEitherOrder() throws {
        let c = try #require(fixtures["concurrent"] as? [String: Any])
        for order in [["a", "b"], ["b", "a"]] {
            let document = YrsPageDocument(pageId: c["docId"] as! String)
            #expect(document.applyUpdate(Data(hex: c["base"] as! String)))
            for name in order {
                #expect(document.applyUpdate(Data(hex: c[name] as! String)))
            }
            #expect(normalise(document.runs) == normalise(runs(c["runs"]!)), "order \(order)")
        }
    }

    @Test func invalidUpdateIsRefused() {
        let document = YrsPageDocument(pageId: "00112233445566778899aabbccddeeff")
        document.initialize()
        let before = document.runs
        #expect(!document.applyUpdate(Data([0xFF, 0xFF, 0xFF, 0xFF, 0x01, 0x02])))
        #expect(document.runs == before)
    }
}

// MARK: - Helpers shared by the tests

func runs(_ json: Any) -> [TextRun] {
    (json as! [[String: Any]]).map { run in
        var attributes: Attributes = [:]
        for (key, value) in run["attributes"] as! [String: Any] {
            // JSONSerialization gives NSNumber for both; a boolean NSNumber is the CFBoolean singleton.
            if let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() {
                attributes[key] = .bool(number.boolValue)
            } else if let number = value as? NSNumber {
                attributes[key] = .number(number.doubleValue)
            } else if let string = value as? String {
                attributes[key] = .string(string)
            }
        }
        return TextRun(text: run["text"] as! String, attributes: attributes)
    }
}

/// Merges neighbouring runs with equal attributes: where a boundary falls is not part of the contract.
func normalise(_ runs: [TextRun]) -> [TextRun] {
    var merged: [TextRun] = []
    for run in runs where !run.text.isEmpty {
        if let last = merged.last, last.attributes == run.attributes {
            merged[merged.count - 1].text += run.text
        } else {
            merged.append(run)
        }
    }
    return merged
}

/// A minimal editor-side model: UTF-16 units with attributes, changed only through deltas.
struct Model {
    var units: [UInt16] = []
    var attributes: [Attributes] = []

    mutating func apply(_ delta: [DeltaOp]) {
        var index = 0
        for op in delta {
            switch op {
            case .retain(let count, let changes):
                if let changes {
                    for i in index..<(index + count) {
                        for (key, value) in changes {
                            attributes[i][key] = value
                        }
                    }
                }
                index += count
            case .insert(let text, let attrs):
                let new = Array(text.utf16)
                units.insert(contentsOf: new, at: index)
                attributes.insert(contentsOf: Array(repeating: attrs, count: new.count), at: index)
                index += new.count
            case .delete(let count):
                units.removeSubrange(index..<(index + count))
                attributes.removeSubrange(index..<(index + count))
            }
        }
    }

    var runs: [TextRun] {
        var result: [(units: [UInt16], attributes: Attributes)] = []
        for (unit, attrs) in zip(units, attributes) {
            if let last = result.last, last.attributes == attrs {
                result[result.count - 1].units.append(unit)
            } else {
                result.append(([unit], attrs))
            }
        }
        return result.map { TextRun(text: String(decoding: $0.units, as: UTF16.self), attributes: $0.attributes) }
    }
}

extension Data {
    init(hex: String) {
        var bytes: [UInt8] = []
        var iterator = hex.utf8.makeIterator()
        func nibble(_ c: UInt8) -> UInt8 { c < 0x3A ? c - 0x30 : c - 0x57 }
        while let high = iterator.next(), let low = iterator.next() {
            bytes.append(nibble(high) << 4 | nibble(low))
        }
        self.init(bytes)
    }

    var hex: String {
        map { String(format: "%02x", $0) }.joined()
    }
}

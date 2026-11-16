import CYrs
import Foundation
import TwoNoteDocuments

/// A section entry of a notebook (PROTOCOL.md 5.1).
public struct SectionInfo: Equatable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var order: String
    public var deleted: Bool
}

/// A page entry of a notebook (PROTOCOL.md 5.1). `id` is also the docId of the page document.
public struct PageInfo: Equatable, Identifiable, Sendable {
    public var id: String
    public var sectionId: String
    public var title: String
    public var order: String
    public var deleted: Bool
    public var createdAt: Date
    public var updatedAt: Date
}

/// The notebook tree document of PROTOCOL.md 5.1 (`docId == notebookId`): the notebook title,
/// its sections and its page entries. Items are ordered by their fractional `order` string,
/// ties by id; deletion is a flag, never removal.
@MainActor
public final class YrsNotebookTree: YrsDocument {
    private var roots: (meta: UnsafeMutablePointer<Branch>, sections: UnsafeMutablePointer<Branch>, pages: UnsafeMutablePointer<Branch>)!
    private let now: () -> Date

    /// Creates an empty replica; fill it with `applyUpdate` or `initialize`.
    public init(notebookId: String, now: @escaping () -> Date = Date.init) {
        self.now = now
        super.init(docId: notebookId)
        roots = (rootMap("meta"), rootMap("sections"), rootMap("pages"))
    }

    public var notebookId: String { docId }

    /// The notebook title; empty until the first update has arrived.
    public var title: String {
        read { txn in Self.string(mapGet(roots.meta, "title", txn)) }
    }

    /// Writes the fields a brand-new notebook starts with. Only the device that creates the notebook calls this.
    public func initialize(title: String) {
        write(system: true) { txn, arena in
            mapSet(roots.meta, "formatVersion", arena.input(.number(1)), txn, arena)
            mapSet(roots.meta, "title", arena.input(.string(title)), txn, arena)
        }
    }

    public func setTitle(_ title: String) {
        write { txn, arena in mapSet(roots.meta, "title", arena.input(.string(title)), txn, arena) }
    }

    // MARK: Reading

    /// The sections in display order.
    public func sections(includeDeleted: Bool = false) -> [SectionInfo] {
        read { txn in readSections(txn, includeDeleted) }
    }

    /// The pages of one section in display order.
    public func pages(inSection sectionId: String, includeDeleted: Bool = false) -> [PageInfo] {
        read { txn in readPages(txn, includeDeleted).filter { $0.sectionId == sectionId } }
    }

    /// Every page of the notebook, ordered by section id and then display order.
    public func allPages(includeDeleted: Bool = false) -> [PageInfo] {
        read { txn in readPages(txn, includeDeleted) }
    }

    public func section(_ sectionId: String) -> SectionInfo? {
        read { txn in
            guard case .map(let map)? = mapGet(roots.sections, sectionId, txn) else { return nil }
            return readSection(txn, sectionId, map)
        }
    }

    public func page(_ pageId: String) -> PageInfo? {
        read { txn in
            guard case .map(let map)? = mapGet(roots.pages, pageId, txn) else { return nil }
            return readPage(txn, pageId, map)
        }
    }

    // MARK: Sections

    /// Adds a section at `index` among the visible sections (nil = at the end) and returns its id.
    @discardableResult
    public func addSection(title: String, at index: Int? = nil) -> String {
        let id = Self.newId()
        write { txn, arena in
            let order = Self.order(for: readSections(txn, false).map(\.order), at: index)
            mapSet(roots.sections, id, arena.sharedMap([
                ("title", arena.input(.string(title))),
                ("order", arena.input(.string(order))),
                ("deleted", arena.input(.bool(false))),
            ]), txn, arena)
        }
        return id
    }

    public func renameSection(_ sectionId: String, title: String) {
        write { txn, arena in
            guard let map = entry(roots.sections, sectionId, txn) else { return }
            mapSet(map, "title", arena.input(.string(title)), txn, arena)
        }
    }

    /// Moves a section to `index` among the other visible sections (nil = to the end).
    public func moveSection(_ sectionId: String, to index: Int?) {
        write { txn, arena in
            guard let map = entry(roots.sections, sectionId, txn) else { return }
            let others = readSections(txn, false).filter { $0.id != sectionId }.map(\.order)
            mapSet(map, "order", arena.input(.string(Self.order(for: others, at: index))), txn, arena)
        }
    }

    /// Sets or clears the `deleted` flag of a section. Its pages keep their own flags.
    public func setSectionDeleted(_ sectionId: String, _ deleted: Bool = true) {
        write { txn, arena in
            guard let map = entry(roots.sections, sectionId, txn) else { return }
            mapSet(map, "deleted", arena.input(.bool(deleted)), txn, arena)
        }
    }

    // MARK: Pages

    /// Adds a page entry at `index` among the visible pages of the section (nil = at the end)
    /// and returns the page id, which is the docId of its page document.
    /// - Parameter id: the page id to use instead of a new random one: 32 lowercase hex
    ///   characters that the caller drew at random and that are not in use. For a caller that
    ///   has to recognise the page it created after an interruption. Anything else is ignored.
    @discardableResult
    public func addPage(inSection sectionId: String, title: String, at index: Int? = nil, id: String? = nil) -> String {
        let id = id.flatMap { Self.isId($0) ? $0 : nil } ?? Self.newId()
        write { txn, arena in
            let siblings = readPages(txn, false).filter { $0.sectionId == sectionId }.map(\.order)
            let stamp = timestamp()
            mapSet(roots.pages, id, arena.sharedMap([
                ("sectionId", arena.input(.string(sectionId))),
                ("title", arena.input(.string(title))),
                ("order", arena.input(.string(Self.order(for: siblings, at: index)))),
                ("deleted", arena.input(.bool(false))),
                ("createdAt", arena.input(.number(stamp))),
                ("updatedAt", arena.input(.number(stamp))),
            ]), txn, arena)
        }
        return id
    }

    /// Renames a page and bumps its `updatedAt`.
    public func renamePage(_ pageId: String, title: String) {
        write { txn, arena in
            guard let map = entry(roots.pages, pageId, txn) else { return }
            mapSet(map, "title", arena.input(.string(title)), txn, arena)
            mapSet(map, "updatedAt", arena.input(.number(timestamp())), txn, arena)
        }
    }

    /// Moves a page into `sectionId` at `index` among its other visible pages (nil = to the end).
    public func movePage(_ pageId: String, toSection sectionId: String, at index: Int?) {
        write { txn, arena in
            guard let map = entry(roots.pages, pageId, txn) else { return }
            let others = readPages(txn, false).filter { $0.sectionId == sectionId && $0.id != pageId }.map(\.order)
            mapSet(map, "sectionId", arena.input(.string(sectionId)), txn, arena)
            mapSet(map, "order", arena.input(.string(Self.order(for: others, at: index))), txn, arena)
        }
    }

    /// Sets or clears the `deleted` flag of a page. The page document is removed later with `DELETE /docs`.
    public func setPageDeleted(_ pageId: String, _ deleted: Bool = true) {
        write { txn, arena in
            guard let map = entry(roots.pages, pageId, txn) else { return }
            mapSet(map, "deleted", arena.input(.bool(deleted)), txn, arena)
        }
    }

    /// Sets `updatedAt` of a page to now. Call when the page content was edited.
    public func touchPage(_ pageId: String) {
        write { txn, arena in
            guard let map = entry(roots.pages, pageId, txn) else { return }
            mapSet(map, "updatedAt", arena.input(.number(timestamp())), txn, arena)
        }
    }

    // MARK: Helpers

    /// Timestamps are whole milliseconds since the Unix epoch, written as doubles.
    private func timestamp() -> Double {
        (now().timeIntervalSince1970 * 1000).rounded(.down)
    }

    private static func isId(_ text: String) -> Bool {
        text.utf8.count == 32 && text.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    private static func newId() -> String {
        (0..<16).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
    }

    private func entry(_ map: UnsafeMutablePointer<Branch>, _ id: String, _ txn: OpaquePointer) -> UnsafeMutablePointer<Branch>? {
        guard case .map(let nested)? = mapGet(map, id, txn) else { return nil }
        return nested
    }

    /// The order key for position `index` in a sorted list of sibling keys. Keys this client
    /// cannot parse, and neighbours with identical keys (two devices inserted at the same place
    /// while offline), are stepped over: the item then lands after the tied group, which is the
    /// closest position that can be expressed.
    static func order(for siblingOrders: [String], at index: Int?) -> String {
        let keys = siblingOrders.filter(FractionalIndex.isValid) // already sorted
        let at = min(max(index ?? keys.count, 0), keys.count)
        let before = at > 0 ? keys[at - 1] : nil
        var after: String?
        for key in keys[at...] where before == nil || FractionalIndex.precedes(before!, key) {
            after = key
            break
        }
        return FractionalIndex.between(before, after) ?? FractionalIndex.first
    }

    private func readSections(_ txn: OpaquePointer, _ includeDeleted: Bool) -> [SectionInfo] {
        var list: [SectionInfo] = []
        for (id, value) in mapEntries(roots.sections, txn) {
            if case .map(let map) = value {
                let section = readSection(txn, id, map)
                if includeDeleted || !section.deleted {
                    list.append(section)
                }
            }
        }
        return list.sorted { Self.itemPrecedes($0.order, $0.id, $1.order, $1.id) }
    }

    private func readPages(_ txn: OpaquePointer, _ includeDeleted: Bool) -> [PageInfo] {
        var list: [PageInfo] = []
        for (id, value) in mapEntries(roots.pages, txn) {
            if case .map(let map) = value {
                let page = readPage(txn, id, map)
                if includeDeleted || !page.deleted {
                    list.append(page)
                }
            }
        }
        return list.sorted { a, b in
            if a.sectionId != b.sectionId {
                return FractionalIndex.precedes(a.sectionId, b.sectionId)
            }
            return Self.itemPrecedes(a.order, a.id, b.order, b.id)
        }
    }

    private static func itemPrecedes(_ orderA: String, _ idA: String, _ orderB: String, _ idB: String) -> Bool {
        orderA != orderB ? FractionalIndex.precedes(orderA, orderB) : FractionalIndex.precedes(idA, idB)
    }

    private func readSection(_ txn: OpaquePointer, _ id: String, _ map: UnsafeMutablePointer<Branch>) -> SectionInfo {
        SectionInfo(id: id, title: Self.string(mapGet(map, "title", txn)), order: Self.string(mapGet(map, "order", txn)),
                    deleted: Self.flag(mapGet(map, "deleted", txn)))
    }

    private func readPage(_ txn: OpaquePointer, _ id: String, _ map: UnsafeMutablePointer<Branch>) -> PageInfo {
        PageInfo(id: id, sectionId: Self.string(mapGet(map, "sectionId", txn)), title: Self.string(mapGet(map, "title", txn)),
                 order: Self.string(mapGet(map, "order", txn)), deleted: Self.flag(mapGet(map, "deleted", txn)),
                 createdAt: Self.time(mapGet(map, "createdAt", txn)), updatedAt: Self.time(mapGet(map, "updatedAt", txn)))
    }

    private static func string(_ value: YrsValue?) -> String {
        if case .string(let s)? = value { s } else { "" }
    }

    private static func flag(_ value: YrsValue?) -> Bool {
        if case .bool(true)? = value { true } else { false }
    }

    private static func time(_ value: YrsValue?) -> Date {
        guard case .number(let ms)? = value, ms.isFinite, ms > -6.2e13, ms < 2.5e14 else {
            return Date(timeIntervalSince1970: 0)
        }
        return Date(timeIntervalSince1970: ms.rounded(.towardZero) / 1000)
    }
}

// The editor's shadow of the page text: one cell per UTF-16 code unit, so a cell index is at the
// same time a page-text index and a text-storage index. Platform neutral (no UIKit).
//
// Port of the Windows client's RichModel.cs.

import TwoNoteDocuments

/// "\n", the paragraph mark.
public let newlineUnit: UInt16 = 0x0A
/// U+2028, the soft line break inside a paragraph.
public let softBreakUnit: UInt16 = 0x2028

/// Inline attributes of PROTOCOL.md 5.2 for one UTF-16 code unit.
public struct InlineAttrs: Equatable, Hashable, Sendable {
    public var bold = false
    public var italic = false
    public var underline = false
    public var strike = false
    public var code = false
    public var link: String?

    public init(bold: Bool = false, italic: Bool = false, underline: Bool = false, strike: Bool = false,
                code: Bool = false, link: String? = nil) {
        self.bold = bold
        self.italic = italic
        self.underline = underline
        self.strike = strike
        self.code = code
        self.link = link
    }

    public static let keys = PageAttribute.inlineKeys

    public func value(for key: String) -> AttributeValue? {
        switch key {
        case PageAttribute.bold: return bold ? .bool(true) : nil
        case PageAttribute.italic: return italic ? .bool(true) : nil
        case PageAttribute.underline: return underline ? .bool(true) : nil
        case PageAttribute.strike: return strike ? .bool(true) : nil
        case PageAttribute.code: return code ? .bool(true) : nil
        case PageAttribute.link: return link.map { .string($0) }
        default: return nil
        }
    }

    public mutating func set(_ key: String, _ value: AttributeValue?) {
        let on = value == .bool(true)
        switch key {
        case PageAttribute.bold: bold = on
        case PageAttribute.italic: italic = on
        case PageAttribute.underline: underline = on
        case PageAttribute.strike: strike = on
        case PageAttribute.code: code = on
        case PageAttribute.link:
            if case .string(let url)? = value { link = url } else { link = nil }
        default: break
        }
    }

    public func with(_ key: String, _ value: AttributeValue?) -> InlineAttrs {
        var copy = self
        copy.set(key, value)
        return copy
    }

    /// The attributes as an insert carries them (set values only).
    public var attributes: Attributes {
        var result: Attributes = [:]
        for key in Self.keys {
            if let v = value(for: key) { result[key] = v }
        }
        return result
    }

    var dump: String {
        var parts: [String] = []
        if bold { parts.append("b") }
        if italic { parts.append("i") }
        if underline { parts.append("u") }
        if strike { parts.append("s") }
        if code { parts.append("code") }
        if let link { parts.append("link=" + link) }
        return parts.joined(separator: ",")
    }
}

/// Block attributes carried by the newline that ends a paragraph. Stored raw (as found in the
/// page) so values this client does not understand survive; `effective` is what can be shown.
public struct BlockAttrs: Equatable, Hashable, Sendable {
    public var block: String?
    public var indent = 0
    public var checked = false

    public init(block: String? = nil, indent: Int = 0, checked: Bool = false) {
        self.block = block
        self.indent = indent
        self.checked = checked
    }

    public static let keys = PageAttribute.blockKeys

    public var effective: BlockAttrs {
        let known = block.flatMap { PageAttribute.blockTypes.contains($0) ? $0 : nil }
        return BlockAttrs(block: known, indent: min(max(indent, 0), PageAttribute.maxIndent),
                          checked: known == "todo" && checked)
    }

    public var isList: Bool { block == "ul" || block == "ol" || block == "todo" }
    public var isHeading: Bool { block == "h1" || block == "h2" || block == "h3" }

    public func value(for key: String) -> AttributeValue? {
        switch key {
        case PageAttribute.block: return block.map { .string($0) }
        case PageAttribute.indent: return indent != 0 ? .number(Double(indent)) : nil
        case PageAttribute.checked: return checked ? .bool(true) : nil
        default: return nil
        }
    }

    public mutating func set(_ key: String, _ value: AttributeValue?) {
        switch key {
        case PageAttribute.block:
            if case .string(let name)? = value { block = name } else { block = nil }
        case PageAttribute.indent:
            if case .number(let n)? = value, n.isFinite { indent = Int(min(max(n, -1000), 1000)) } else { indent = 0 }
        case PageAttribute.checked:
            checked = value == .bool(true)
        default: break
        }
    }

    /// The attributes as an inserted newline carries them (set values only).
    public var attributes: Attributes {
        var result: Attributes = [:]
        for key in Self.keys {
            if let v = value(for: key) { result[key] = v }
        }
        return result
    }

    var dump: String {
        var parts: [String] = []
        if let block { parts.append(block) }
        if indent != 0 { parts.append("indent=\(indent)") }
        if checked { parts.append("checked") }
        return parts.joined(separator: ",")
    }
}

/// One UTF-16 code unit of the page text with its attributes. `block` only means something on "\n".
public struct Cell: Equatable, Sendable {
    public var unit: UInt16
    public var inline: InlineAttrs
    public var block: BlockAttrs

    public init(unit: UInt16, inline: InlineAttrs = InlineAttrs(), block: BlockAttrs = BlockAttrs()) {
        self.unit = unit
        self.inline = inline
        self.block = block
    }

    public var isNewline: Bool { unit == newlineUnit }

    /// Applies attribute changes the way the page does: inline keys anywhere, block keys on "\n" only.
    public func applying(_ changes: AttributeChanges) -> Cell {
        var cell = self
        for (key, value) in changes {
            cell.inline.set(key, value)
            if cell.isNewline { cell.block.set(key, value) }
        }
        return cell
    }

    public static func cells(text: String, attributes: Attributes) -> [Cell] {
        var inline = InlineAttrs()
        var block = BlockAttrs()
        for (key, value) in attributes {
            inline.set(key, value)
            block.set(key, value)
        }
        return text.utf16.map { Cell(unit: $0, inline: inline, block: $0 == newlineUnit ? block : BlockAttrs()) }
    }
}

/// The last state the text view and the page agreed on.
public struct ShadowModel: Equatable, Sendable {
    public private(set) var cells: [Cell] = []
    /// The text alone, kept beside `cells` because every reconciliation diffs against it.
    public private(set) var units: [UInt16] = []

    public init() {}

    public init(cells: [Cell]) {
        self.cells = cells
        self.units = cells.map(\.unit)
    }

    public init(runs: [TextRun]) {
        self.init(cells: runs.flatMap { Cell.cells(text: $0.text, attributes: $0.attributes) })
    }

    public var count: Int { cells.count }
    public var text: String { String(decoding: units, as: UTF16.self) }
    public var endsWithNewline: Bool { units.last == newlineUnit }

    public subscript(index: Int) -> Cell {
        get { cells[index] }
        set {
            cells[index] = newValue
            units[index] = newValue.unit
        }
    }

    public mutating func replace(_ range: Range<Int>, with newCells: [Cell]) {
        cells.replaceSubrange(range, with: newCells)
        units.replaceSubrange(range, with: newCells.map(\.unit))
    }

    public func paragraphStart(_ position: Int) -> Int {
        var pos = min(max(position, 0), cells.count)
        while pos > 0 && units[pos - 1] != newlineUnit { pos -= 1 }
        return pos
    }

    /// Index of the newline that ends the paragraph containing `position` (or count - 1).
    public func paragraphEnd(_ position: Int) -> Int {
        var pos = min(max(position, 0), max(0, cells.count - 1))
        while pos < cells.count - 1 && units[pos] != newlineUnit { pos += 1 }
        return pos
    }

    /// Raw block attributes of the paragraph containing `position`.
    public func block(at position: Int) -> BlockAttrs {
        cells.isEmpty ? BlockAttrs() : cells[paragraphEnd(position)].block
    }

    /// The number a numbered-list paragraph shows, given the newline that ends it: 1 + the numbered
    /// paragraphs of the same indent directly above, deeper paragraphs in between not counting.
    public func ordinal(paragraphEndingAt newline: Int) -> Int {
        let mine = cells[newline].block.effective
        var number = 1
        var end = paragraphStart(newline) - 1
        while end >= 0 {
            let other = cells[end].block.effective
            if other.indent < mine.indent { break }
            if other.indent == mine.indent {
                if other.block != "ol" { break }
                number += 1
            }
            end = paragraphStart(end) - 1
        }
        return number
    }

    /// The model as runs of equal attributes, the shape `PageText.runs` has (known attributes only).
    public var runs: [TextRun] { Self.runs(of: cells[...]) }

    public static func runs(of cells: ArraySlice<Cell>) -> [TextRun] {
        var result: [TextRun] = []
        var buffer: [UInt16] = []
        var current: Attributes?
        func flush() {
            if let current, !buffer.isEmpty {
                result.append(TextRun(text: String(decoding: buffer, as: UTF16.self), attributes: current))
            }
            buffer.removeAll(keepingCapacity: true)
        }
        for cell in cells {
            var attributes = cell.inline.attributes
            if cell.isNewline {
                attributes.merge(cell.block.attributes) { _, new in new }
            }
            if attributes != current {
                flush()
                current = attributes
            }
            buffer.append(cell.unit)
        }
        flush()
        return result
    }

    /// Canonical dump for convergence assertions: runs merged, defaults omitted.
    public static func dump(_ cells: [Cell], effectiveBlocks: Bool = false) -> String {
        var out = ""
        var i = 0
        while i < cells.count {
            let c = cells[i]
            if c.isNewline {
                let b = effectiveBlocks ? c.block.effective : c.block
                out += "\\n[\(c.inline.dump)|\(b.dump)]\n"
                i += 1
                continue
            }
            var j = i
            while j < cells.count && !cells[j].isNewline && cells[j].inline == c.inline { j += 1 }
            out += String(decoding: cells[i..<j].map(\.unit), as: UTF16.self)
            let a = c.inline.dump
            if !a.isEmpty { out += "{\(a)}" }
            out += "|"
            i = j
        }
        return out
    }

    public var dump: String { Self.dump(cells) }
}

/// A single contiguous replacement that turns one text into another.
public struct TextEdit: Equatable, Sendable {
    public var start: Int
    public var deleteCount: Int
    public var insertCount: Int

    public init(start: Int = 0, deleteCount: Int = 0, insertCount: Int = 0) {
        self.start = start
        self.deleteCount = deleteCount
        self.insertCount = insertCount
    }

    public var isEmpty: Bool { deleteCount == 0 && insertCount == 0 }

    /// Common prefix/suffix diff. The suffix is matched first and always keeps at least the final
    /// unit when both texts end the same (both end with the paragraph mark), so the final newline
    /// of the page is never deleted. `caretHint` (caret position in `now`) resolves the ambiguity
    /// of edits inside runs of identical characters: the edit is placed so that it ends at the caret.
    public static func diff(_ old: [UInt16], _ now: [UInt16], caretHint: Int = -1) -> TextEdit {
        if old == now { return TextEdit() }

        let maxCommon = min(old.count, now.count)
        var suffixCap = maxCommon
        if caretHint >= 0 && caretHint <= now.count {
            suffixCap = min(suffixCap, now.count - caretHint)
        }
        let minSuffix = !old.isEmpty && !now.isEmpty && old[old.count - 1] == now[now.count - 1] ? 1 : 0
        suffixCap = max(suffixCap, minSuffix)

        var suffix = 0
        while suffix < suffixCap && old[old.count - 1 - suffix] == now[now.count - 1 - suffix] { suffix += 1 }

        var prefix = 0
        let prefixCap = maxCommon - suffix
        while prefix < prefixCap && old[prefix] == now[prefix] { prefix += 1 }

        // The caret hint may have stopped the suffix early; if the prefix did not use the slack, extend it.
        while suffix < maxCommon - prefix && old[old.count - 1 - suffix] == now[now.count - 1 - suffix] { suffix += 1 }

        // Never cut a surrogate pair in half (replacing one emoji with another shares the high
        // surrogate): the page stores UTF-8 and cannot hold a lone surrogate.
        if prefix > 0 && UTF16.isLeadSurrogate(old[prefix - 1]) { prefix -= 1 }
        if suffix > 0 && UTF16.isTrailSurrogate(old[old.count - suffix]) { suffix -= 1 }

        return TextEdit(start: prefix, deleteCount: old.count - prefix - suffix, insertCount: now.count - prefix - suffix)
    }
}

/// Characters that must never reach the page: other paragraph separators (the text system would
/// see a paragraph where the page has none) and embedded objects.
public enum TextSanitizer {
    public static func isForbidden(_ unit: UInt16) -> Bool {
        switch unit {
        case 0x0D, 0x0C, 0x85, 0x2029, 0xFFFC: return true
        default: return false
        }
    }

    /// Plain text as it may be inserted: line ends normalised to "\n", embedded objects removed.
    public static func plainText(_ text: String) -> String {
        var out: [UInt16] = []
        var previousWasCR = false
        for unit in text.utf16 {
            defer { previousWasCR = unit == 0x0D }
            switch unit {
            case 0x0D, 0x85, 0x2029, 0x0C: out.append(newlineUnit)
            case 0x0A: if !previousWasCR { out.append(newlineUnit) }
            case 0xFFFC: break
            default: out.append(unit)
            }
        }
        return String(decoding: out, as: UTF16.self)
    }
}

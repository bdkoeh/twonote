#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
import TwoNoteDocuments

/// Fonts, colours and metrics of the Mac editor. The page attributes it writes are the same
/// `tn.*` keys the UIKit theme writes (Model/StorageAttributes.swift); only the look differs.
/// Colours are the system's dynamic colours, so light, dark, the accent colour and increased
/// contrast follow the system without a re-render.
@MainActor
public final class EditorTheme {
    public nonisolated static let indentStep: CGFloat = 24
    public nonisolated static let markerZone: CGFloat = 26
    public nonisolated static let codePadding: CGFloat = 10

    /// Point size of body text (headings are sized from it).
    public let bodySize: CGFloat
    private var fonts: [String: NSFont] = [:]
    private var paragraphStyles: [String: NSParagraphStyle] = [:]

    public init(bodySize: CGFloat = 14) {
        self.bodySize = bodySize
    }

    /// Title, Heading, Subheading - the sizes Notes on the Mac uses for its styles, relative to body.
    private func base(_ block: String?) -> NSFont {
        switch block {
        case "h1": return .systemFont(ofSize: (bodySize * 1.72).rounded(), weight: .bold)
        case "h2": return .systemFont(ofSize: (bodySize * 1.29).rounded(), weight: .bold)
        case "h3": return .systemFont(ofSize: (bodySize * 1.08).rounded(), weight: .semibold)
        case "code": return .monospacedSystemFont(ofSize: (bodySize * 0.9).rounded(), weight: .regular)
        default: return .systemFont(ofSize: bodySize)
        }
    }

    func font(block: String?, inline: InlineAttrs) -> NSFont {
        let key = "\(block ?? "")|\(inline.bold)|\(inline.italic)|\(inline.code)"
        if let cached = fonts[key] { return cached }
        var font = base(block)
        if inline.code && block != "code" {
            font = .monospacedSystemFont(ofSize: (font.pointSize * 0.9).rounded(), weight: inline.bold ? .bold : .regular)
        }
        var symbolic = font.fontDescriptor.symbolicTraits
        if inline.bold { symbolic.insert(.bold) }
        if inline.italic { symbolic.insert(.italic) }
        if symbolic != font.fontDescriptor.symbolicTraits,
           let changed = NSFont(descriptor: font.fontDescriptor.withSymbolicTraits(symbolic), size: font.pointSize) {
            font = changed
        }
        fonts[key] = font
        return font
    }

    func paragraphStyle(_ block: BlockAttrs) -> NSParagraphStyle {
        let key = "\(block.block ?? "")|\(block.indent)"
        if let cached = paragraphStyles[key] { return cached }
        let style = NSMutableParagraphStyle()
        var indent = CGFloat(block.indent) * Self.indentStep
        switch block.block {
        case "ul", "ol", "todo":
            indent += Self.markerZone
            style.paragraphSpacing = 3
        case "code":
            indent += Self.codePadding
            style.tailIndent = -Self.codePadding
            style.lineBreakMode = .byCharWrapping
        case "h1":
            style.paragraphSpacingBefore = 12
            style.paragraphSpacing = 6
        case "h2":
            style.paragraphSpacingBefore = 10
            style.paragraphSpacing = 4
        case "h3":
            style.paragraphSpacingBefore = 6
            style.paragraphSpacing = 3
        default:
            style.paragraphSpacing = 5
        }
        style.firstLineHeadIndent = indent
        style.headIndent = indent
        style.lineSpacing = 1
        let result = style.copy() as! NSParagraphStyle
        paragraphStyles[key] = result
        return result
    }

    /// Everything the storage holds for one cell: its page attributes plus the look that follows
    /// from them and from the paragraph it is in. `paragraph` is the paragraph's raw block.
    func attributes(for cell: Cell, paragraph: BlockAttrs, context: ParagraphContext) -> [NSAttributedString.Key: Any] {
        let shown = paragraph.effective
        let inline = cell.inline
        var result: [NSAttributedString.Key: Any] = [
            .font: font(block: shown.block, inline: inline),
            .paragraphStyle: paragraphStyle(shown),
        ]
        var colour = shown.checked ? NSColor.secondaryLabelColor : NSColor.labelColor
        if inline.bold { result[.tnBold] = true }
        if inline.italic { result[.tnItalic] = true }
        if inline.underline { result[.tnUnderline] = true }
        if inline.strike {
            result[.tnStrike] = true
            result[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
        }
        if inline.code {
            result[.tnCode] = true
            if shown.block != "code" { result[.backgroundColor] = NSColor.quaternarySystemFill }
        }
        if let link = inline.link {
            result[.tnLink] = link
            // The text view draws it with its link attributes and follows it on a click.
            result[.link] = link
            colour = .linkColor
        }
        if inline.underline || inline.link != nil {
            result[.underlineStyle] = NSUnderlineStyle.single.rawValue
        }
        result[.foregroundColor] = colour
        if cell.isNewline {
            if let block = cell.block.block { result[.tnBlock] = block }
            if cell.block.indent != 0 { result[.tnIndent] = cell.block.indent }
            if cell.block.checked { result[.tnChecked] = true }
            if context.ordinal != 0 { result[.tnOrdinal] = context.ordinal }
            if context.codeEdge != 0 { result[.tnCodeEdge] = context.codeEdge }
        }
        return result
    }
}
#endif

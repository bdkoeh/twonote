#if canImport(UIKit)
import UIKit
import TwoNoteDocuments

/// Fonts, colours and metrics. Rebuilt when Dynamic Type changes.
@MainActor
public final class EditorTheme {
    public nonisolated static let indentStep: CGFloat = 26
    public nonisolated static let markerZone: CGFloat = 30
    public nonisolated static let codePadding: CGFloat = 12

    private var fonts: [String: UIFont] = [:]
    private var paragraphStyles: [String: NSParagraphStyle] = [:]
    private let traits: UITraitCollection?

    public init(traits: UITraitCollection? = nil) {
        self.traits = traits
    }

    private func base(_ block: String?) -> UIFont {
        switch block {
        case "h1": return weighted(.title1, .bold)
        case "h2": return weighted(.title2, .bold)
        case "h3": return weighted(.title3, .semibold)
        case "code":
            let size = UIFont.preferredFont(forTextStyle: .body, compatibleWith: traits).pointSize
            return UIFont.monospacedSystemFont(ofSize: (size * 0.88).rounded(), weight: .regular)
        default: return UIFont.preferredFont(forTextStyle: .body, compatibleWith: traits)
        }
    }

    private func weighted(_ style: UIFont.TextStyle, _ weight: UIFont.Weight) -> UIFont {
        let size = UIFont.preferredFont(forTextStyle: style, compatibleWith: traits).pointSize
        return UIFont.systemFont(ofSize: size, weight: weight)
    }

    func font(block: String?, inline: InlineAttrs) -> UIFont {
        let key = "\(block ?? "")|\(inline.bold)|\(inline.italic)|\(inline.code)"
        if let cached = fonts[key] { return cached }
        var font = base(block)
        if inline.code && block != "code" {
            font = UIFont.monospacedSystemFont(ofSize: (font.pointSize * 0.9).rounded(), weight: inline.bold ? .bold : .regular)
        }
        var symbolic = font.fontDescriptor.symbolicTraits
        if inline.bold { symbolic.insert(.traitBold) }
        if inline.italic { symbolic.insert(.traitItalic) }
        if symbolic != font.fontDescriptor.symbolicTraits, let descriptor = font.fontDescriptor.withSymbolicTraits(symbolic) {
            font = UIFont(descriptor: descriptor, size: font.pointSize)
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
            style.paragraphSpacing = 4
        case "code":
            indent += Self.codePadding
            style.tailIndent = -Self.codePadding
            style.lineBreakMode = .byCharWrapping
        case "h1":
            style.paragraphSpacingBefore = 14
            style.paragraphSpacing = 6
        case "h2":
            style.paragraphSpacingBefore = 12
            style.paragraphSpacing = 4
        case "h3":
            style.paragraphSpacingBefore = 8
            style.paragraphSpacing = 4
        default:
            style.paragraphSpacing = 6
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
        var colour = shown.checked ? UIColor.secondaryLabel : UIColor.label
        if inline.bold { result[.tnBold] = true }
        if inline.italic { result[.tnItalic] = true }
        if inline.underline { result[.tnUnderline] = true }
        if inline.strike {
            result[.tnStrike] = true
            result[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
        }
        if inline.code {
            result[.tnCode] = true
            if shown.block != "code" { result[.backgroundColor] = UIColor.tertiarySystemFill }
        }
        if let link = inline.link {
            result[.tnLink] = link
            colour = .link
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

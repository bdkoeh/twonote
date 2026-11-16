#if canImport(UIKit)
import UIKit
import TwoNoteDocuments

/// Draws what a paragraph's block type adds around its text: the bullet, number or checkbox of
/// a list item and the background of a code block. Nothing is inserted into the text for these,
/// so text-storage indexes stay equal to page indexes. Everything it needs is read from the
/// attributes of the paragraph's newline.
final class BlockLayoutFragment: NSTextLayoutFragment {
    struct Info {
        var block: BlockAttrs
        var ordinal: Int
        var codeEdge: Int
        var font: UIFont
    }

    var info: Info? {
        guard let paragraph = textElement as? NSTextParagraph else { return nil }
        let text = paragraph.attributedString
        guard text.length > 0 else { return nil }
        let attributes = text.attributes(at: text.length - 1, effectiveRange: nil)
        let block = BlockAttrs(storage: attributes).effective
        guard block.block != nil, let font = attributes[.font] as? UIFont else { return nil }
        return Info(block: block, ordinal: (attributes[.tnOrdinal] as? Int) ?? 1,
                    codeEdge: (attributes[.tnCodeEdge] as? Int) ?? 0, font: font)
    }

    /// Where the first line's text starts and its baseline, relative to the fragment's origin.
    private var firstLineStart: CGPoint? {
        guard let line = textLineFragments.first else { return nil }
        let bounds = line.typographicBounds
        return CGPoint(x: bounds.minX + line.locationForCharacter(at: 0).x, y: bounds.minY + line.glyphOrigin.y)
    }

    /// The marker's box relative to the fragment's origin (also the checkbox's hit area).
    var markerRect: CGRect? {
        guard let info, info.block.isList, let start = firstLineStart, let line = textLineFragments.first else { return nil }
        let bounds = line.typographicBounds
        return CGRect(x: start.x - EditorTheme.markerZone, y: bounds.minY, width: EditorTheme.markerZone, height: bounds.height)
    }

    private var codeRect: CGRect? {
        guard let info, info.block.block == "code" else { return nil }
        let frame = layoutFragmentFrame
        let width = textLayoutManager?.textContainer?.size.width ?? frame.maxX
        let padding = textLayoutManager?.textContainer?.lineFragmentPadding ?? 5
        let left = padding + CGFloat(info.block.indent) * EditorTheme.indentStep
        // The empty line the text system adds after the final newline is not part of the block.
        var height = frame.height
        if textLineFragments.count > 1, let last = textLineFragments.last, last.characterRange.length == 0 {
            height = last.typographicBounds.minY
        }
        return CGRect(x: left - frame.minX, y: 0, width: max(0, width - padding - left), height: height)
    }

    override var renderingSurfaceBounds: CGRect {
        var bounds = super.renderingSurfaceBounds
        if let codeRect { bounds = bounds.union(codeRect) }
        if let markerRect { bounds = bounds.union(markerRect.insetBy(dx: -2, dy: -2)) }
        return bounds
    }

    override func draw(at point: CGPoint, in context: CGContext) {
        guard let info else {
            super.draw(at: point, in: context)
            return
        }
        UIGraphicsPushContext(context)
        if let rect = codeRect?.offsetBy(dx: point.x, dy: point.y) {
            var corners: UIRectCorner = []
            if info.codeEdge & 1 != 0 { corners.formUnion([.topLeft, .topRight]) }
            if info.codeEdge & 2 != 0 { corners.formUnion([.bottomLeft, .bottomRight]) }
            UIColor.secondarySystemFill.setFill()
            UIBezierPath(roundedRect: rect, byRoundingCorners: corners, cornerRadii: CGSize(width: 8, height: 8)).fill()
        }
        UIGraphicsPopContext()
        super.draw(at: point, in: context)
        guard info.block.isList, let start = firstLineStart, let box = markerRect else { return }
        UIGraphicsPushContext(context)
        defer { UIGraphicsPopContext() }
        let baseline = point.y + start.y
        let right = point.x + start.x - 8
        switch info.block.block {
        case "ul":
            let glyphs = ["\u{2022}", "\u{25E6}", "\u{25AA}"]
            draw(glyphs[info.block.indent % glyphs.count], font: info.font, rightEdge: right, baseline: baseline)
        case "ol":
            let font = UIFont.monospacedDigitSystemFont(ofSize: info.font.pointSize, weight: .regular)
            draw("\(info.ordinal).", font: font, rightEdge: right, baseline: baseline)
        default:
            let side = min(box.height, info.font.pointSize * 1.25)
            let configuration = UIImage.SymbolConfiguration(pointSize: side * 0.82, weight: .regular)
            let name = info.block.checked ? "checkmark.circle.fill" : "circle"
            let colour: UIColor = info.block.checked ? .tintColor : .tertiaryLabel
            if let image = UIImage(systemName: name, withConfiguration: configuration)?
                .withTintColor(colour, renderingMode: .alwaysOriginal) {
                let size = image.size
                image.draw(at: CGPoint(x: right - size.width, y: point.y + box.midY - size.height / 2))
            }
        }
    }

    private func draw(_ text: String, font: UIFont, rightEdge: CGFloat, baseline: CGFloat) {
        let string = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: UIColor.secondaryLabel])
        let size = string.size()
        string.draw(at: CGPoint(x: rightEdge - size.width, y: baseline - font.ascender))
    }
}
#endif

#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
import TwoNoteDocuments

/// Draws what a paragraph's block type adds around its text: the bullet, number or checkbox of
/// a list item and the background of a code block. Nothing is inserted into the text for these,
/// so text-storage indexes stay equal to page indexes. Everything it needs is read from the
/// attributes of the paragraph's newline. (The AppKit twin of UIKit/BlockLayoutFragment.swift.)
final class BlockLayoutFragment: NSTextLayoutFragment {
    struct Info {
        var block: BlockAttrs
        var ordinal: Int
        var codeEdge: Int
        var font: NSFont
    }

    var info: Info? {
        guard let paragraph = textElement as? NSTextParagraph else { return nil }
        let text = paragraph.attributedString
        guard text.length > 0 else { return nil }
        let attributes = text.attributes(at: text.length - 1, effectiveRange: nil)
        let block = BlockAttrs(storage: attributes).effective
        guard block.block != nil, let font = attributes[.font] as? NSFont else { return nil }
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

    /// The appearance the text view is drawn in (light, dark, increased contrast).
    private var appearance: NSAppearance {
        textLayoutManager?.textContainer?.textView?.effectiveAppearance ?? NSAppearance.currentDrawing()
    }

    override func draw(at point: CGPoint, in context: CGContext) {
        guard let info else {
            super.draw(at: point, in: context)
            return
        }
        let appearance = appearance
        if let rect = codeRect?.offsetBy(dx: point.x, dy: point.y) {
            appearance.performAsCurrentDrawingAppearance {
                context.saveGState()
                context.setFillColor(NSColor.secondarySystemFill.cgColor)
                context.addPath(Self.roundedRect(rect, radius: 6, top: info.codeEdge & 1 != 0, bottom: info.codeEdge & 2 != 0))
                context.fillPath()
                context.restoreGState()
            }
        }
        super.draw(at: point, in: context)
        guard info.block.isList, let start = firstLineStart, let box = markerRect else { return }
        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        defer { NSGraphicsContext.current = previous }
        appearance.performAsCurrentDrawingAppearance {
            let baseline = point.y + start.y
            let right = point.x + start.x - 7
            switch info.block.block {
            case "ul":
                let glyphs = ["\u{2022}", "\u{25E6}", "\u{25AA}"]
                draw(glyphs[info.block.indent % glyphs.count], font: info.font, rightEdge: right, baseline: baseline)
            case "ol":
                let font = NSFont.monospacedDigitSystemFont(ofSize: info.font.pointSize, weight: .regular)
                draw("\(info.ordinal).", font: font, rightEdge: right, baseline: baseline)
            default:
                let side = (min(box.height, info.font.pointSize * 1.3) * 0.86).rounded()
                let name = info.block.checked ? "checkmark.circle.fill" : "circle"
                var configuration = NSImage.SymbolConfiguration(pointSize: side, weight: .regular)
                configuration = configuration.applying(info.block.checked
                    ? NSImage.SymbolConfiguration(paletteColors: [.white, .controlAccentColor])
                    : NSImage.SymbolConfiguration(paletteColors: [.tertiaryLabelColor]))
                if let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(configuration) {
                    let size = image.size
                    let rect = CGRect(x: right - size.width, y: point.y + box.midY - size.height / 2, width: size.width, height: size.height)
                    image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
                }
            }
        }
    }

    private func draw(_ text: String, font: NSFont, rightEdge: CGFloat, baseline: CGFloat) {
        let string = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor])
        let size = string.size()
        string.draw(at: CGPoint(x: rightEdge - size.width, y: baseline - font.ascender))
    }

    /// A rectangle with rounded top and/or bottom corners (a run of code paragraphs is one box).
    static func roundedRect(_ rect: CGRect, radius: CGFloat, top: Bool, bottom: Bool) -> CGPath {
        let path = CGMutablePath()
        let r = min(radius, rect.width / 2, rect.height / 2)
        let t = top ? r : 0, b = bottom ? r : 0
        // Flipped coordinates: minY is the top.
        path.move(to: CGPoint(x: rect.minX + t, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - t, y: rect.minY))
        if t > 0 { path.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.minY), tangent2End: CGPoint(x: rect.maxX, y: rect.minY + t), radius: t) }
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - b))
        if b > 0 { path.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.maxY), tangent2End: CGPoint(x: rect.maxX - b, y: rect.maxY), radius: b) }
        path.addLine(to: CGPoint(x: rect.minX + b, y: rect.maxY))
        if b > 0 { path.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.maxY), tangent2End: CGPoint(x: rect.minX, y: rect.maxY - b), radius: b) }
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + t))
        if t > 0 { path.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.minY), tangent2End: CGPoint(x: rect.minX + t, y: rect.minY), radius: t) }
        path.closeSubpath()
        return path
    }
}
#endif

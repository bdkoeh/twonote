// Draws the app icon (original artwork: two overlapping note pages on a blue ground) and
// writes the three variants the asset catalog wants. Run on a Mac:
//
//   swift tools/make-icon.swift Sources/Assets.xcassets/AppIcon.appiconset
//
// AppIcon.png (light), AppIcon-Dark.png (dark ground), AppIcon-Tinted.png (grayscale; the
// system applies the user's tint).
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let size = 1024
let folder = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")

func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: r, green: g, blue: b, alpha: a)
}

struct Palette {
    var top: CGColor
    var bottom: CGColor
    var backPage: CGColor
    var frontPage: CGColor
    var lines: CGColor
    var accent: CGColor
}

func draw(_ palette: Palette, to name: String) {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let context = CGContext(
        data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: space,
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)! // opaque: an app icon has no alpha
    let s = CGFloat(size)

    // Ground: a top-to-bottom gradient. (CoreGraphics' origin is bottom-left.)
    let gradient = CGGradient(colorsSpace: space, colors: [palette.top, palette.bottom] as CFArray, locations: [0, 1])!
    context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: s), end: CGPoint(x: 0, y: 0), options: [])

    func page(center: CGPoint, angle: CGFloat, fill: CGColor, lines: CGColor?, accent: CGColor?) {
        let width = s * 0.46, height = s * 0.58, radius = s * 0.055
        context.saveGState()
        context.translateBy(x: center.x, y: center.y)
        context.rotate(by: angle * .pi / 180)
        let rect = CGRect(x: -width / 2, y: -height / 2, width: width, height: height)
        context.setShadow(offset: CGSize(width: 0, height: -s * 0.012), blur: s * 0.04, color: color(0, 0, 0, 0.28))
        context.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
        context.setFillColor(fill)
        context.fillPath()
        context.setShadow(offset: .zero, blur: 0, color: nil)
        if let lines {
            let inset = width * 0.16
            let thickness = s * 0.03
            var y = height / 2 - height * 0.2
            for (index, part) in [0.5, 1.0, 1.0, 0.72].enumerated() {
                let line = CGRect(x: -width / 2 + inset, y: y - thickness / 2, width: (width - 2 * inset) * part, height: thickness)
                context.addPath(CGPath(roundedRect: line, cornerWidth: thickness / 2, cornerHeight: thickness / 2, transform: nil))
                context.setFillColor(index == 0 ? (accent ?? lines) : lines)
                context.fillPath()
                y -= height * (index == 0 ? 0.2 : 0.15)
            }
        }
        context.restoreGState()
    }

    page(center: CGPoint(x: s * 0.42, y: s * 0.53), angle: 9, fill: palette.backPage, lines: nil, accent: nil)
    page(center: CGPoint(x: s * 0.57, y: s * 0.47), angle: -6, fill: palette.frontPage, lines: palette.lines, accent: palette.accent)

    let image = context.makeImage()!
    let url = folder.appendingPathComponent(name)
    let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { fatalError("could not write \(url.path)") }
    print("wrote \(url.path)")
}

draw(Palette(
    top: color(0.25, 0.56, 0.98), bottom: color(0.10, 0.30, 0.82),
    backPage: color(0.80, 0.89, 1.0), frontPage: color(1, 1, 1),
    lines: color(0.78, 0.82, 0.88), accent: color(0.16, 0.45, 0.95)), to: "AppIcon.png")
draw(Palette(
    top: color(0.13, 0.15, 0.20), bottom: color(0.05, 0.06, 0.09),
    backPage: color(0.22, 0.36, 0.62), frontPage: color(0.30, 0.56, 0.98),
    lines: color(0.80, 0.89, 1.0, 0.75), accent: color(1, 1, 1)), to: "AppIcon-Dark.png")
draw(Palette(
    top: color(0.16, 0.16, 0.16), bottom: color(0.05, 0.05, 0.05),
    backPage: color(0.50, 0.50, 0.50), frontPage: color(0.94, 0.94, 0.94),
    lines: color(0.55, 0.55, 0.55), accent: color(0.25, 0.25, 0.25)), to: "AppIcon-Tinted.png")

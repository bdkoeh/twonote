// Makes the Mac app icon from the iPhone's artwork (TwoNote/tools/make-icon.swift draws it):
// the artwork is set into the macOS icon shape - a rounded square 824 of 1024 points wide,
// centred, with the standard drop shadow below it and transparent margins - and written in
// every size the Mac asset catalog asks for. Run on a Mac:
//
//   swift tools/make-mac-icon.swift ../TwoNote/Sources/Assets.xcassets/AppIcon.appiconset/AppIcon.png \
//       Sources/Assets.xcassets/AppIcon.appiconset
//
// Icons drawn on this grid are shown as they are by macOS 26 and later; a full-bleed square
// would instead be shrunk into a grey tile.
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let arguments = CommandLine.arguments
guard arguments.count == 3 else {
    print("usage: make-mac-icon.swift <1024px artwork.png> <appiconset folder>")
    exit(1)
}
let source = URL(fileURLWithPath: arguments[1])
let folder = URL(fileURLWithPath: arguments[2])

guard let input = CGImageSourceCreateWithURL(source as CFURL, nil),
      let artwork = CGImageSourceCreateImageAtIndex(input, 0, nil) else {
    fatalError("cannot read \(source.path)")
}

/// The macOS app icon shape: a rounded square with continuous corners, drawn as a superellipse
/// (|x|^5 + |y|^5 = 1), which matches the system's icon template closely.
func iconShape(_ rect: CGRect) -> CGPath {
    let path = CGMutablePath()
    let a = rect.width / 2, cx = rect.midX, cy = rect.midY, n = 5.0
    let steps = 720
    for i in 0...steps {
        let t = Double(i) / Double(steps) * 2 * .pi
        let c = cos(t), s = sin(t)
        let x = cx + a * CGFloat(copysign(pow(abs(c), 2 / n), c))
        let y = cy + a * CGFloat(copysign(pow(abs(s), 2 / n), s))
        if i == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
    }
    path.closeSubpath()
    return path
}

func render(_ pixels: Int) -> CGImage {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let context = CGContext(
        data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0, space: space,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.interpolationQuality = .high
    let scale = CGFloat(pixels) / 1024
    context.scaleBy(x: scale, y: scale)
    // The grid: 824 x 824 centred horizontally, 100 from the top and 100 from the bottom; the
    // shadow falls a little below (CoreGraphics' origin is bottom-left).
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = iconShape(tile)
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -10), blur: 28, color: CGColor(gray: 0, alpha: 0.3))
    context.addPath(shape)
    context.setFillColor(CGColor(gray: 0, alpha: 1))
    context.fillPath()
    context.restoreGState()
    context.saveGState()
    context.addPath(shape)
    context.clip()
    context.draw(artwork, in: tile)
    context.restoreGState()
    // A hairline at the edge, as on the system's icons, so the tile holds on any desktop.
    context.addPath(shape)
    context.setStrokeColor(CGColor(gray: 0, alpha: 0.12))
    context.setLineWidth(2)
    context.strokePath()
    return context.makeImage()!
}

func write(_ image: CGImage, _ name: String) {
    let url = folder.appendingPathComponent(name)
    let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { fatalError("could not write \(url.path)") }
}

try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
var images: [[String: String]] = []
for points in [16, 32, 128, 256, 512] {
    for factor in [1, 2] {
        let name = "icon_\(points)x\(points)\(factor == 2 ? "@2x" : "").png"
        write(render(points * factor), name)
        images.append(["idiom": "mac", "size": "\(points)x\(points)", "scale": "\(factor)x", "filename": name])
        print("wrote \(name)")
    }
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
let json = try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
try json.write(to: folder.appendingPathComponent("Contents.json"))
print("wrote Contents.json")

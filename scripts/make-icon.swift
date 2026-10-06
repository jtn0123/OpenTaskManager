// Renders the app icon at 1024×1024 and writes every size the asset catalog needs.
// Usage: swift scripts/make-icon.swift App/Resources/Assets.xcassets/AppIcon.appiconset
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let outputDirectory = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
let canvas: CGFloat = 1024

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: alpha
    )
}

func render(size: Int) -> CGImage {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let scale = CGFloat(size) / canvas
    context.scaleBy(x: scale, y: scale)

    // macOS icon grid: an 824-pt rounded square centred on the canvas.
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let tilePath = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)

    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0x000000, 0.35))
    context.addPath(tilePath)
    context.setFillColor(color(0x0B1430))
    context.fillPath()
    context.restoreGState()

    context.saveGState()
    context.addPath(tilePath)
    context.clip()
    let background = CGGradient(colorsSpace: space, colors: [color(0x1A2B63), color(0x070D22)] as CFArray, locations: [0, 1])!
    context.drawLinearGradient(background, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])

    // Grid.
    context.setStrokeColor(color(0x8FB4FF, 0.10))
    context.setLineWidth(4)
    for index in 1..<4 {
        let y = tile.minY + tile.height * CGFloat(index) / 4
        context.move(to: CGPoint(x: tile.minX, y: y))
        context.addLine(to: CGPoint(x: tile.maxX, y: y))
    }
    for index in 1..<6 {
        let x = tile.minX + tile.width * CGFloat(index) / 6
        context.move(to: CGPoint(x: x, y: tile.minY))
        context.addLine(to: CGPoint(x: x, y: tile.maxY))
    }
    context.strokePath()

    // The trace: a quiet baseline, a spike, and a settle — a task manager at work.
    let samples: [CGFloat] = [0.30, 0.34, 0.28, 0.36, 0.33, 0.47, 0.42, 0.78, 0.62, 0.70, 0.52, 0.56, 0.44, 0.50, 0.46]
    let left = tile.minX - 10, right = tile.maxX + 10
    let bottom = tile.minY + 150, height: CGFloat = 520
    let points = samples.enumerated().map { index, value in
        CGPoint(x: left + (right - left) * CGFloat(index) / CGFloat(samples.count - 1), y: bottom + value * height)
    }
    let trace = CGMutablePath()
    trace.move(to: points[0])
    for index in 1..<points.count {
        let previous = points[index - 1], current = points[index]
        let mid = (previous.x + current.x) / 2
        trace.addCurve(to: current, control1: CGPoint(x: mid, y: previous.y), control2: CGPoint(x: mid, y: current.y))
    }

    let area = trace.mutableCopy()!
    area.addLine(to: CGPoint(x: right, y: tile.minY))
    area.addLine(to: CGPoint(x: left, y: tile.minY))
    area.closeSubpath()
    context.saveGState()
    context.addPath(area)
    context.clip()
    let fill = CGGradient(colorsSpace: space, colors: [color(0x3BD8FF, 0.55), color(0x3B7BFF, 0.0)] as CFArray, locations: [0, 1])!
    context.drawLinearGradient(fill, start: CGPoint(x: 512, y: bottom + height), end: CGPoint(x: 512, y: tile.minY), options: [])
    context.restoreGState()

    context.setLineCap(.round)
    context.setLineJoin(.round)
    context.addPath(trace)
    context.setShadow(offset: .zero, blur: 30, color: color(0x3BD8FF, 0.9))
    context.setStrokeColor(color(0x7DEBFF))
    context.setLineWidth(26)
    context.strokePath()
    context.restoreGState()

    // Subtle top highlight on the tile edge.
    context.addPath(tilePath)
    context.setStrokeColor(color(0xFFFFFF, 0.10))
    context.setLineWidth(4)
    context.strokePath()

    return context.makeImage()!
}

func write(_ image: CGImage, to url: URL) {
    let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, nil)
    CGImageDestinationFinalize(destination)
}

var entries: [[String: String]] = []
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = points * scale
        let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        write(render(size: pixels), to: outputDirectory.appendingPathComponent(name))
        entries.append(["idiom": "mac", "size": "\(points)x\(points)", "scale": "\(scale)x", "filename": name])
    }
}
let contents: [String: Any] = ["images": entries, "info": ["author": "xcode", "version": 1]]
let json = try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
try json.write(to: outputDirectory.appendingPathComponent("Contents.json"))
print("Wrote \(entries.count) icons to \(outputDirectory.path)")

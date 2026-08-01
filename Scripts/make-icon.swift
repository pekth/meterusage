import AppKit
import CoreGraphics

// Renders the meterusage app-icon master PNG.
//
// The mark is the same vertical fill gauge the menu bar draws (MeterGlyph in
// MenuBarLabel.swift): a rounded-rect outline with a fill rising from the
// bottom. Proportions are scaled straight from that view's 9x13 geometry so
// the icon and the status item read as the same object.

let canvas: CGFloat = 1024

// macOS icon grid: the art sits inside a rounded square inset from the canvas
// edge, rather than bleeding to it.
let plateInset: CGFloat = 100
let plateSide = canvas - plateInset * 2
let plateRadius = plateSide * 0.2237   // Big Sur superellipse approximation

// MeterGlyph's own numbers, scaled by (glyphWidth / 9).
let glyphWidth: CGFloat = 390
let scale = glyphWidth / 9
let glyphHeight = 13 * scale
let strokeWidth = 1 * scale
let outerRadius = 2.5 * scale
let innerRadius = 1.5 * scale
let padding = 2 * scale

// A reading with visible headroom: enough fill to read as "a meter", not so
// much that the icon looks like a permanent warning.
let fraction: CGFloat = 0.72

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> CGColor {
    CGColor(red: r / 255, green: g / 255, blue: b / 255, alpha: 1)
}

// MU.calm (dark variant) for the gauge; a deep slate plate so the mark holds
// up on both light and dark Finder backgrounds.
let calm = rgb(70, 200, 150)
let plateTop = rgb(46, 52, 62)
let plateBottom = rgb(26, 30, 38)

guard let context = CGContext(
    data: nil,
    width: Int(canvas),
    height: Int(canvas),
    bitsPerComponent: 8,
    bytesPerRow: 0,
    space: CGColorSpace(name: CGColorSpace.sRGB)!,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else {
    fatalError("could not create bitmap context")
}

// MARK: Plate

let plateRect = CGRect(x: plateInset, y: plateInset, width: plateSide, height: plateSide)
let plate = CGPath(roundedRect: plateRect, cornerWidth: plateRadius, cornerHeight: plateRadius, transform: nil)

context.saveGState()
context.addPath(plate)
context.clip()
let gradient = CGGradient(
    colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
    colors: [plateTop, plateBottom] as CFArray,
    locations: [0, 1]
)!
context.drawLinearGradient(
    gradient,
    start: CGPoint(x: 0, y: canvas),
    end: CGPoint(x: 0, y: 0),
    options: []
)
context.restoreGState()

// MARK: Gauge

let glyphRect = CGRect(
    x: (canvas - glyphWidth) / 2,
    y: (canvas - glyphHeight) / 2,
    width: glyphWidth,
    height: glyphHeight
)

// Outline: strokeBorder draws inside the bounds, so inset by half the width.
let outline = CGPath(
    roundedRect: glyphRect.insetBy(dx: strokeWidth / 2, dy: strokeWidth / 2),
    cornerWidth: outerRadius,
    cornerHeight: outerRadius,
    transform: nil
)
context.setStrokeColor(calm.copy(alpha: 0.45)!)
context.setLineWidth(strokeWidth)
context.addPath(outline)
context.strokePath()

let interior = glyphRect.insetBy(dx: padding, dy: padding)

// Track: the unfilled remainder, barely there. The menu-bar glyph can leave
// this empty because it is 13pt tall and reads as a single mark; at icon size
// the same emptiness makes the fill look like a floating pill rather than a
// level, so the track is what makes "72% used" legible here.
context.setFillColor(calm.copy(alpha: 0.16)!)
context.addPath(CGPath(roundedRect: interior, cornerWidth: innerRadius, cornerHeight: innerRadius, transform: nil))
context.fillPath()

// Fill: rises from the bottom of the padded interior, mirroring the view's
// `max(1.5, (height - 4) * fraction)`.
let fillHeight = max(1.5 * scale, interior.height * fraction)
let fillRect = CGRect(x: interior.minX, y: interior.minY, width: interior.width, height: fillHeight)
context.setFillColor(calm)
context.addPath(CGPath(roundedRect: fillRect, cornerWidth: innerRadius, cornerHeight: innerRadius, transform: nil))
context.fillPath()

// MARK: Write

guard let image = context.makeImage() else { fatalError("could not render image") }
let output = URL(fileURLWithPath: CommandLine.arguments[1])
let rep = NSBitmapImageRep(cgImage: image)
guard let data = rep.representation(using: .png, properties: [:]) else {
    fatalError("could not encode PNG")
}
try data.write(to: output)
print("wrote \(output.path)")

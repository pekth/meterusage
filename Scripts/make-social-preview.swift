import AppKit
import CoreGraphics

// Renders the GitHub social-preview card (1280x640) from the app icon master,
// so the repo card and the app itself carry the same mark.

let w: CGFloat = 1280, h: CGFloat = 640

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> CGColor {
    CGColor(red: r / 255, green: g / 255, blue: b / 255, alpha: 1)
}
let calm = rgb(70, 200, 150)
let bgTop = rgb(32, 37, 45)
let bgBottom = rgb(20, 23, 29)
let textColor = rgb(240, 240, 245)
let subText = rgb(150, 155, 165)

guard let ctx = CGContext(
    data: nil, width: Int(w), height: Int(h),
    bitsPerComponent: 8, bytesPerRow: 0,
    space: CGColorSpace(name: CGColorSpace.sRGB)!,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else { fatalError("context") }

// Background
let gradient = CGGradient(
    colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
    colors: [bgTop, bgBottom] as CFArray, locations: [0, 1]
)!
ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: h), end: CGPoint(x: 0, y: 0), options: [])

// The gauge, same 9:13 geometry as MeterGlyph, on the left.
let glyphWidth: CGFloat = 150
let scale = glyphWidth / 9
let glyphHeight = 13 * scale
let strokeWidth = 1 * scale
let outerRadius = 2.5 * scale
let innerRadius = 1.5 * scale
let padding = 2 * scale
let fraction: CGFloat = 0.72

let glyphRect = CGRect(x: 120, y: (h - glyphHeight) / 2, width: glyphWidth, height: glyphHeight)

ctx.setStrokeColor(calm.copy(alpha: 0.45)!)
ctx.setLineWidth(strokeWidth)
ctx.addPath(CGPath(roundedRect: glyphRect.insetBy(dx: strokeWidth / 2, dy: strokeWidth / 2),
                   cornerWidth: outerRadius, cornerHeight: outerRadius, transform: nil))
ctx.strokePath()

let interior = glyphRect.insetBy(dx: padding, dy: padding)
ctx.setFillColor(calm.copy(alpha: 0.16)!)
ctx.addPath(CGPath(roundedRect: interior, cornerWidth: innerRadius, cornerHeight: innerRadius, transform: nil))
ctx.fillPath()

let fillRect = CGRect(x: interior.minX, y: interior.minY,
                      width: interior.width, height: interior.height * fraction)
ctx.setFillColor(calm)
ctx.addPath(CGPath(roundedRect: fillRect, cornerWidth: innerRadius, cornerHeight: innerRadius, transform: nil))
ctx.fillPath()

// Text
func draw(_ string: String, size: CGFloat, weight: NSFont.Weight, color: CGColor, at point: CGPoint) {
    let font = NSFont.systemFont(ofSize: size, weight: weight)
    let attrs: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: NSColor(cgColor: color)!,
    ]
    let line = NSAttributedString(string: string, attributes: attrs)
    let gc = NSGraphicsContext(cgContext: ctx, flipped: false)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = gc
    line.draw(at: point)
    NSGraphicsContext.restoreGraphicsState()
}

let textX: CGFloat = 340
draw("meterusage", size: 96, weight: .semibold, color: textColor, at: CGPoint(x: textX, y: 352))
draw("How much AI coding quota you have left,", size: 38, weight: .regular, color: subText, at: CGPoint(x: textX, y: 286))
draw("in your menu bar.", size: 38, weight: .regular, color: subText, at: CGPoint(x: textX, y: 232))
draw("No API keys  ·  No telemetry  ·  MIT", size: 28, weight: .medium, color: calm, at: CGPoint(x: textX, y: 160))

guard let image = ctx.makeImage() else { fatalError("render") }
let rep = NSBitmapImageRep(cgImage: image)
guard let data = rep.representation(using: .png, properties: [:]) else { fatalError("encode") }
try data.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
print("wrote social preview")

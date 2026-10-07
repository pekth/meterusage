import AppKit
import Foundation

// Lossless rasterization of the same SF Symbol stand-ins used by ProviderMark.
// This is build-time asset tooling. The TypeScript app never invokes Swift.
let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
for (provider, symbol) in [("openRouter", "arrow.triangle.branch"), ("cursor", "cursorarrow.rays"), ("copilot", "terminal"), ("gemini", "diamond")] {
    guard let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil),
          let configured = image.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 24, weight: .medium)),
          let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: 32,
                                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                    isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
          let context = NSGraphicsContext(bitmapImageRep: rep) else {
        fatalError("Existing provider symbol unavailable: \(provider)")
    }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    configured.draw(in: NSRect(x: 0, y: 0, width: 32, height: 32))
    NSGraphicsContext.restoreGraphicsState()
    guard let png = rep.representation(using: .png, properties: [:]) else { fatalError("Cannot export symbol") }
    try png.write(to: output.appendingPathComponent("\(provider)-symbol.png"))
}

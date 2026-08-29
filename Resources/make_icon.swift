// Baut aus Resources/AppIcon-source.png (KI-generiert) das macOS-Iconset:
// skaliert auf das Apple-Icon-Raster (Inhalt ~82% der Canvas, Rest transparenter
// Rand) und maskiert als abgerundetes Quadrat im Big-Sur-Stil.
// Aufruf: swift make_icon.swift <source.png> <output-iconset-dir>
import AppKit

let args = CommandLine.arguments
guard args.count >= 3, let source = NSImage(contentsOfFile: args[1]) else {
    print("usage: swift make_icon.swift <source.png> <iconset-dir>")
    exit(1)
}
let outDir = URL(fileURLWithPath: args[2])
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

func savePNG(pixels: Int, name: String) {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    let s = CGFloat(pixels)
    // Apple-Icon-Raster: Inhalt 824/1024 der Canvas, Eckenradius ~22.37% davon
    let content = s * 824.0 / 1024.0
    let origin = (s - content) / 2
    let rect = NSRect(x: origin, y: origin, width: content, height: content)
    let radius = content * 0.2237
    let mask = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
    mask.addClip()
    source.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1.0)

    NSGraphicsContext.restoreGraphicsState()
    let data = rep.representation(using: .png, properties: [:])!
    try! data.write(to: outDir.appendingPathComponent(name))
}

for base in [16, 32, 128, 256, 512] {
    savePNG(pixels: base, name: "icon_\(base)x\(base).png")
    savePNG(pixels: base * 2, name: "icon_\(base)x\(base)@2x.png")
}
print("iconset written to \(outDir.path)")

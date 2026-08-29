// Rendert das App-Icon (abgerundetes Quadrat mit Farbverlauf + Einsammel-Symbol)
// als PNG-Set fuer iconutil. Aufruf: swift make_icon.swift <output-iconset-dir>
import AppKit

let outDir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset")
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

func drawIcon(size: CGFloat) -> NSImage {
    let img = NSImage(size: NSSize(width: size, height: size))
    img.lockFocus()
    let s = size
    let inset = s * 0.05
    let rect = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let path = NSBezierPath(roundedRect: rect, xRadius: s * 0.2, yRadius: s * 0.2)
    let gradient = NSGradient(starting: NSColor(calibratedRed: 0.98, green: 0.66, blue: 0.15, alpha: 1),
                              ending: NSColor(calibratedRed: 0.85, green: 0.33, blue: 0.09, alpha: 1))!
    gradient.draw(in: path, angle: -90)

    // Box unten
    let boxW = s * 0.52, boxH = s * 0.22
    let box = NSRect(x: (s - boxW) / 2, y: s * 0.2, width: boxW, height: boxH)
    let boxPath = NSBezierPath(roundedRect: box, xRadius: s * 0.03, yRadius: s * 0.03)
    NSColor.white.withAlphaComponent(0.95).setStroke()
    boxPath.lineWidth = s * 0.045
    boxPath.stroke()

    // Pfeil nach unten in die Box
    let arrow = NSBezierPath()
    let cx = s / 2
    let shaftW = s * 0.09
    let headW = s * 0.24
    let top = s * 0.78, headTop = s * 0.52, tip = s * 0.36
    arrow.move(to: NSPoint(x: cx - shaftW, y: top))
    arrow.line(to: NSPoint(x: cx + shaftW, y: top))
    arrow.line(to: NSPoint(x: cx + shaftW, y: headTop))
    arrow.line(to: NSPoint(x: cx + headW, y: headTop))
    arrow.line(to: NSPoint(x: cx, y: tip))
    arrow.line(to: NSPoint(x: cx - headW, y: headTop))
    arrow.line(to: NSPoint(x: cx - shaftW, y: headTop))
    arrow.close()
    NSColor.white.setFill()
    arrow.fill()

    img.unlockFocus()
    return img
}

func savePNG(_ image: NSImage, pixels: Int, name: String) {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
    NSGraphicsContext.restoreGraphicsState()
    let data = rep.representation(using: .png, properties: [:])!
    try! data.write(to: outDir.appendingPathComponent(name))
}

for base in [16, 32, 128, 256, 512] {
    let img = drawIcon(size: CGFloat(base))
    savePNG(img, pixels: base, name: "icon_\(base)x\(base).png")
    savePNG(img, pixels: base * 2, name: "icon_\(base)x\(base)@2x.png")
}
print("iconset written to \(outDir.path)")

// Rebuild: swift tools/generate_icon.swift /tmp/Hangar.iconset
//         iconutil -c icns /tmp/Hangar.iconset -o config/Hangar.icns
import AppKit

let destination = CommandLine.arguments.dropFirst().first ?? "/tmp/Hangar.iconset"
try FileManager.default.createDirectory(atPath: destination, withIntermediateDirectories: true)
func drawIcon(_ pixels: Int) -> Data {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                 bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                 isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    let scale = CGFloat(pixels) / 1024
    let transform = NSAffineTransform(); transform.scale(by: scale); transform.concat()
    let base = NSBezierPath(roundedRect: NSRect(x: 70, y: 70, width: 884, height: 884), xRadius: 194, yRadius: 194)
    NSGradient(starting: NSColor(calibratedRed: 0.16, green: 0.22, blue: 0.24, alpha: 1), ending: NSColor(calibratedRed: 0.055, green: 0.095, blue: 0.11, alpha: 1))!.draw(in: base, angle: -90)
    NSColor(calibratedRed: 0.42, green: 0.86, blue: 0.79, alpha: 1).setStroke()
    let roof = NSBezierPath(); roof.lineWidth = 49; roof.lineCapStyle = .round; roof.lineJoinStyle = .round
    roof.move(to: NSPoint(x: 254, y: 290)); roof.line(to: NSPoint(x: 254, y: 608))
    roof.line(to: NSPoint(x: 512, y: 770)); roof.line(to: NSPoint(x: 770, y: 608)); roof.line(to: NSPoint(x: 770, y: 290)); roof.stroke()
    let door = NSBezierPath(); door.lineWidth = 40; door.lineCapStyle = .round; door.lineJoinStyle = .round
    door.move(to: NSPoint(x: 382, y: 290)); door.line(to: NSPoint(x: 382, y: 564)); door.line(to: NSPoint(x: 642, y: 564)); door.line(to: NSPoint(x: 642, y: 290)); door.stroke()
    NSColor(calibratedWhite: 0.92, alpha: 1).setFill()
    for (y, h) in [(220.0, 50.0), (326.0, 42.0), (419.0, 33.0)] {
        NSBezierPath(roundedRect: NSRect(x: 498, y: y, width: 28, height: h), xRadius: 7, yRadius: 7).fill()
    }
    NSGraphicsContext.restoreGraphicsState()
    return bitmap.representation(using: .png, properties: [:])!
}
for size in [16, 32, 128, 256, 512] {
    try drawIcon(size).write(to: URL(fileURLWithPath: destination).appendingPathComponent("icon_\(size)x\(size).png"))
    try drawIcon(size * 2).write(to: URL(fileURLWithPath: destination).appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}

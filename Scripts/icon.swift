import AppKit
import Foundation

let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        let context = NSGraphicsContext.current!.cgContext
        context.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
        NSColor(calibratedRed: 0.08, green: 0.16, blue: 0.19, alpha: 1).setFill()
        NSBezierPath(
            roundedRect: NSRect(x: 48, y: 48, width: 928, height: 928), xRadius: 205, yRadius: 205
        ).fill()
        NSColor(calibratedRed: 0.55, green: 0.88, blue: 0.80, alpha: 1).setStroke()
        let wave = NSBezierPath()
        wave.lineWidth = 58
        wave.lineCapStyle = .round
        for (x, height) in [(300.0, 140.0), (440.0, 350.0), (580.0, 490.0), (720.0, 210.0)] {
            wave.move(to: NSPoint(x: x, y: 512 - height / 2))
            wave.line(to: NSPoint(x: x, y: 512 + height / 2))
        }
        wave.stroke()
        NSGraphicsContext.restoreGraphicsState()
        let data = bitmap.representation(using: .png, properties: [:])!
        let suffix = scale == 2 ? "@2x" : ""
        try data.write(to: output.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
    }
}

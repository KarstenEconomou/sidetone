import AppKit

@main
enum IconGenerator {
    static func main() throws {
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
                context.setShadow(
                    offset: CGSize(width: 0, height: -8), blur: 16,
                    color: NSColor.black.withAlphaComponent(0.25).cgColor)
                NSColor(srgbRed: 0.09, green: 0.10, blue: 0.22, alpha: 1).setFill()
                NSBezierPath(
                    roundedRect: NSRect(x: 96, y: 96, width: 832, height: 832),
                    xRadius: 186, yRadius: 186
                ).fill()
                context.setShadow(offset: .zero, blur: 0, color: nil)
                SidetoneGlyph.draw(in: NSRect(x: 264, y: 208, width: 608, height: 608))
                NSGraphicsContext.restoreGraphicsState()
                let data = bitmap.representation(using: .png, properties: [:])!
                let suffix = scale == 2 ? "@2x" : ""
                try data.write(
                    to: output.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
            }
        }
    }
}

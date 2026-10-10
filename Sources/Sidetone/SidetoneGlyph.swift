import AppKit

enum SidetoneGlyph {
    private static let heights: [CGFloat] = [0.76, 0.3, 1, 0.54, 0.78, 0.38, 0.18]
    private static let colors: [UInt32] = [
        0x7BECFD, 0x8DCDF8, 0xC9BAF8, 0xC6A1F9, 0xA190FD, 0x8685F0, 0x4C5CE2,
    ]

    static func menuBarImage(active: Bool) -> NSImage {
        let image = image(
            size: NSSize(width: 16, height: 16), template: true,
            lineWidth: active ? 1.75 : 1.5)
        image.accessibilityDescription = active ? "Sidetone is on" : "Sidetone is off"
        return image
    }

    static func image(size: NSSize, template: Bool = false, lineWidth: CGFloat? = nil) -> NSImage {
        let image = NSImage(size: size, flipped: false) { rect in
            draw(in: rect, lineWidth: lineWidth)
            return true
        }
        image.isTemplate = template
        return image
    }

    static func draw(in rect: NSRect, lineWidth: CGFloat? = nil) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        defer { context.restoreGState() }
        let width = lineWidth ?? rect.width * 0.085
        let spacing = (rect.width - width) / CGFloat(heights.count - 1)
        context.setLineWidth(width)
        context.setLineCap(.round)
        for (index, height) in heights.enumerated() {
            let rgb = colors[index]
            context.setStrokeColor(
                CGColor(
                    srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255,
                    green: CGFloat((rgb >> 8) & 0xFF) / 255,
                    blue: CGFloat(rgb & 0xFF) / 255, alpha: 1))
            let x = rect.minX + width / 2 + CGFloat(index) * spacing
            let halfHeight = max(0, (rect.height * height - width) / 2)
            context.move(to: CGPoint(x: x, y: rect.midY - halfHeight))
            context.addLine(to: CGPoint(x: x, y: rect.midY + halfHeight))
            context.strokePath()
        }
    }
}

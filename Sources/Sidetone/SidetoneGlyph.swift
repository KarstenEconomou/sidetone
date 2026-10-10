import AppKit

enum SidetoneGlyph {
    private static let heights: [CGFloat] = [0.76, 0.3, 1, 0.54, 0.78, 0.38, 0.18]
    private static let colors: [UInt32] = [
        0x7BECFD, 0x8DCDF8, 0xC9BAF8, 0xC6A1F9, 0xA190FD, 0x8685F0, 0x4C5CE2,
    ]

    static func image(size: NSSize, template: Bool = false, active: Bool = true) -> NSImage {
        let image = NSImage(size: size, flipped: false) { rect in
            draw(in: rect, active: active)
            return true
        }
        image.isTemplate = template
        return image
    }

    static func draw(in rect: NSRect, active: Bool = true) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        defer { context.restoreGState() }
        let width = rect.width * (active ? 0.085 : 0.065)
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

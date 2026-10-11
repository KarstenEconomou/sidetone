import AppKit
import SidetoneKit
import SwiftUI

@MainActor
enum KeyboardSwitchGlyph {
    private static let alps = makeImage(for: .alpsSKCMBlue)
    private static let topre = makeImage(for: .topre)
    private static let inkBlack = makeImage(for: .gateronInkBlack)
    private static let holyPanda = makeImage(for: .dropHolyPanda)
    private static let bucklingSpring = makeImage(for: .ibmBucklingSpring)

    static func image(for type: KeyboardSwitch) -> Image {
        let image =
            switch type {
            case .alpsSKCMBlue: alps
            case .topre: topre
            case .gateronInkBlack: inkBlack
            case .dropHolyPanda: holyPanda
            case .ibmBucklingSpring: bucklingSpring
            }
        return Image(nsImage: image).renderingMode(.template)
    }

    private static func makeImage(for type: KeyboardSwitch) -> NSImage {
        let image = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.saveGState()
            defer { context.restoreGState() }
            context.translateBy(x: rect.minX, y: rect.minY)
            context.scaleBy(x: rect.width / 16, y: rect.height / 16)
            context.setStrokeColor(CGColor(gray: 0, alpha: 1))
            context.setFillColor(CGColor(gray: 0, alpha: 0.3))
            context.setLineWidth(0.8)
            context.setLineCap(.round)
            context.setLineJoin(.round)

            switch type {
            case .alpsSKCMBlue:
                context.addPath(
                    CGPath(
                        roundedRect: CGRect(x: 2.5, y: 3.5, width: 11, height: 9),
                        cornerWidth: 0.8, cornerHeight: 0.8, transform: nil))
                context.addPath(
                    CGPath(
                        roundedRect: CGRect(x: 5, y: 6, width: 6, height: 4),
                        cornerWidth: 0.3, cornerHeight: 0.3, transform: nil))
                for y: CGFloat in [5, 11] {
                    context.move(to: CGPoint(x: 1, y: y))
                    context.addLine(to: CGPoint(x: 2.5, y: y))
                    context.move(to: CGPoint(x: 13.5, y: y))
                    context.addLine(to: CGPoint(x: 15, y: y))
                }
            case .topre:
                context.addEllipse(in: CGRect(x: 1.75, y: 1.75, width: 12.5, height: 12.5))
                context.move(to: CGPoint(x: 7, y: 11.87))
                context.addLine(to: CGPoint(x: 7, y: 10.5))
                context.addLine(to: CGPoint(x: 9, y: 10.5))
                context.addLine(to: CGPoint(x: 9, y: 11.87))
                context.addCurve(
                    to: CGPoint(x: 12, y: 8), control1: CGPoint(x: 10.73, y: 11.42),
                    control2: CGPoint(x: 12, y: 9.86))
                context.addCurve(
                    to: CGPoint(x: 9, y: 4.13), control1: CGPoint(x: 12, y: 6.14),
                    control2: CGPoint(x: 10.73, y: 4.58))
                context.addLine(to: CGPoint(x: 9, y: 5.5))
                context.addLine(to: CGPoint(x: 7, y: 5.5))
                context.addLine(to: CGPoint(x: 7, y: 4.13))
                context.addCurve(
                    to: CGPoint(x: 4, y: 8), control1: CGPoint(x: 5.27, y: 4.58),
                    control2: CGPoint(x: 4, y: 6.14))
                context.addCurve(
                    to: CGPoint(x: 7, y: 11.87), control1: CGPoint(x: 4, y: 9.86),
                    control2: CGPoint(x: 5.27, y: 11.42))
                context.closePath()
            case .gateronInkBlack, .dropHolyPanda:
                context.addPath(
                    CGPath(
                        roundedRect: CGRect(x: 2.5, y: 3, width: 11, height: 10),
                        cornerWidth: 0.8, cornerHeight: 0.8, transform: nil))
                context.drawPath(using: .fillStroke)
                context.move(to: CGPoint(x: 7, y: 11.5))
                context.addLine(to: CGPoint(x: 9, y: 11.5))
                context.addLine(to: CGPoint(x: 9, y: 9))
                context.addLine(to: CGPoint(x: 11.5, y: 9))
                context.addLine(to: CGPoint(x: 11.5, y: 7))
                context.addLine(to: CGPoint(x: 9, y: 7))
                context.addLine(to: CGPoint(x: 9, y: 4.5))
                context.addLine(to: CGPoint(x: 7, y: 4.5))
                context.addLine(to: CGPoint(x: 7, y: 7))
                context.addLine(to: CGPoint(x: 4.5, y: 7))
                context.addLine(to: CGPoint(x: 4.5, y: 9))
                context.addLine(to: CGPoint(x: 7, y: 9))
                context.closePath()
                if type == .gateronInkBlack {
                    context.setFillColor(CGColor(gray: 0, alpha: 1))
                    context.drawPath(using: .fillStroke)
                } else {
                    context.strokePath()
                }
            case .ibmBucklingSpring:
                context.addEllipse(in: CGRect(x: 1.75, y: 1.75, width: 12.5, height: 12.5))
                context.addEllipse(in: CGRect(x: 3.25, y: 3.25, width: 9.5, height: 9.5))
                context.addEllipse(in: CGRect(x: 6.4, y: 5.2, width: 3.2, height: 3.2))
            }
            context.drawPath(using: .eoFillStroke)
            return true
        }
        image.isTemplate = true
        return image
    }
}

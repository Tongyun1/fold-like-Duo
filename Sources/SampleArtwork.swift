import AppKit
import CoreImage

enum SampleArtwork {
    static func make() -> CIImage {
        let size = CGSize(width: 1200, height: 750)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor(calibratedRed: 0.035, green: 0.065, blue: 0.14, alpha: 1).setFill()
            rect.fill()

            let gradient = NSGradient(colors: [
                NSColor(calibratedRed: 0.10, green: 0.27, blue: 0.56, alpha: 1),
                NSColor(calibratedRed: 0.34, green: 0.22, blue: 0.64, alpha: 1),
                NSColor(calibratedRed: 0.07, green: 0.62, blue: 0.66, alpha: 1),
            ])
            gradient?.draw(in: rect, angle: -24)

            NSColor.white.withAlphaComponent(0.15).setFill()
            CGRect(x: 0, y: 712, width: 1200, height: 38).fill()
            drawText(L10n.text("HingeFlow     File     View"), at: CGPoint(x: 22, y: 720), size: 15, weight: .medium, color: .white)

            NSColor.white.withAlphaComponent(0.92).setFill()
            NSBezierPath(roundedRect: CGRect(x: 110, y: 170, width: 560, height: 400),
                         xRadius: 22,
                         yRadius: 22).fill()
            drawText(L10n.text("A desktop with depth."), at: CGPoint(x: 148, y: 500), size: 30, weight: .semibold)
            drawText(L10n.text("The far edge softens while the hinge stays sharp."), at: CGPoint(x: 148, y: 458), size: 17, color: .darkGray)

            let features = ["Real lid angle", "Live local capture", "Metal rendering", "Fail-clear safety", "No uploads"]
            for row in 0..<5 {
                NSColor.systemTeal.withAlphaComponent(0.75).setFill()
                NSBezierPath(ovalIn: CGRect(x: 150, y: 390 - row * 48, width: 13, height: 13)).fill()
                drawText(L10n.text(features[row]),
                         at: CGPoint(x: 180, y: 383 - row * 48),
                         size: 17)
            }

            for index in 0..<2 {
                let y = CGFloat(385 - index * 205)
                NSColor.white.withAlphaComponent(0.82).setFill()
                NSBezierPath(roundedRect: CGRect(x: 735, y: y, width: 350, height: 170),
                             xRadius: 24,
                             yRadius: 24).fill()
                drawText(L10n.text(index == 0 ? "Spatial glass" : "Responsive motion"),
                         at: CGPoint(x: 770, y: y + 115),
                         size: 23,
                         weight: .semibold)
                drawText(L10n.text(index == 0 ? "Blur · perspective · shadow" : "The hinge is the timeline"),
                         at: CGPoint(x: 770, y: y + 72),
                         size: 16,
                         color: .darkGray)
            }
            return true
        }
        var proposed = CGRect(origin: .zero, size: size)
        let cgImage = image.cgImage(forProposedRect: &proposed, context: nil, hints: nil)!
        return CIImage(cgImage: cgImage)
    }

    private static func drawText(_ value: String,
                                 at point: CGPoint,
                                 size: CGFloat,
                                 weight: NSFont.Weight = .regular,
                                 color: NSColor = .labelColor) {
        value.draw(at: point, withAttributes: [
            .font: NSFont.systemFont(ofSize: size, weight: weight),
            .foregroundColor: color,
        ])
    }
}

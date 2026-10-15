import AppKit
import SwiftUI

enum UsageColor {
    static func forPercent(_ percent: Double) -> Color {
        Color(nsColor: nsColor(percent))
    }

    static func nsColor(_ percent: Double) -> NSColor {
        switch percent {
        case ..<60: return .systemBlue
        case ..<85: return .systemOrange
        default: return .systemRed
        }
    }
}

enum MenuBarIcon {
    /// A small ring gauge filled to `percent`, tinted by severity. `nil` draws an empty ring
    /// (no data yet / error). The drawing handler runs at draw time, so the track color
    /// follows the menu bar's light/dark appearance.
    static func ring(percent: Double?, size: CGFloat = 15) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            let lineWidth: CGFloat = 2.4
            let inset = rect.insetBy(dx: lineWidth / 2 + 0.5, dy: lineWidth / 2 + 0.5)

            let track = NSBezierPath(ovalIn: inset)
            track.lineWidth = lineWidth
            NSColor.labelColor.withAlphaComponent(0.25).setStroke()
            track.stroke()

            guard let percent else {
                return true
            }
            let fraction = min(max(percent / 100, 0), 1)
            let center = NSPoint(x: rect.midX, y: rect.midY)
            let radius = inset.width / 2
            let arc = NSBezierPath()
            arc.appendArc(withCenter: center, radius: radius, startAngle: 90,
                          endAngle: 90 - 360 * fraction, clockwise: true)
            arc.lineWidth = lineWidth
            arc.lineCapStyle = .round
            UsageColor.nsColor(percent).setStroke()
            if fraction > 0 { arc.stroke() }

            if percent >= 100 {
                UsageColor.nsColor(percent).setFill()
                NSBezierPath(ovalIn: rect.insetBy(dx: size * 0.36, dy: size * 0.36)).fill()
            }
            return true
        }
        image.isTemplate = false
        return image
    }
}

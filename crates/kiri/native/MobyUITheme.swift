// Kiri Moby — native UI module.
import AppKit
import Foundation
import SwiftUI

enum KiriMenuBarIcon {
    static let image: NSImage = {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { _ in
            let center = NSPoint(x: 9, y: 9)
            let radius: CGFloat = 6.2

            func vertex(_ degrees: CGFloat) -> NSPoint {
                let radians = degrees * .pi / 180
                return NSPoint(x: center.x + radius * cos(radians),
                               y: center.y + radius * sin(radians))
            }

            let top = vertex(90)
            let topRight = vertex(30)
            let bottomRight = vertex(-30)
            let bottom = vertex(-90)
            let bottomLeft = vertex(-150)
            let topLeft = vertex(150)

            func face(_ vertices: [NSPoint], alpha: CGFloat) {
                let path = NSBezierPath()
                path.move(to: vertices[0])
                for vertex in vertices.dropFirst() { path.line(to: vertex) }
                path.close()
                NSColor.black.withAlphaComponent(alpha).setFill()
                path.fill()
            }

            // Source alpha represents the three light/dark faces. As a template
            // the artwork remains system black/white without a colored backing.
            face([top, topRight, bottomRight, center], alpha: 0.95)
            face([center, bottomRight, bottom, bottomLeft], alpha: 0.62)
            face([top, center, bottomLeft, topLeft], alpha: 0.38)

            // Cut transparent channels through the actual alpha mask.
            if let context = NSGraphicsContext.current {
                let original = context.compositingOperation
                context.compositingOperation = .destinationOut
                let gaps = NSBezierPath()
                gaps.lineWidth = 1.2
                gaps.lineJoinStyle = .round
                gaps.lineCapStyle = .round
                for corner in [top, bottomLeft, bottomRight] {
                    gaps.move(to: center)
                    gaps.line(to: corner)
                }
                NSColor.black.setStroke()
                gaps.stroke()
                context.compositingOperation = original
            }
            return true
        }
        image.isTemplate = true
        return image
    }()
}


/// Kiri API compatibility backed by ArcBox's system-adaptive semantic colors.
enum KiriPalette {
    static let blue = AppColors.accent
    static let mint = AppColors.running
    static let red = AppColors.error
    static func bg(_ light: Bool) -> Color { AppColors.background }
    static func panel(_ light: Bool) -> Color { AppColors.surfaceCard }
    static func raised(_ light: Bool) -> Color { AppColors.surfaceElevated }
    static func border(_ light: Bool) -> Color { AppColors.border }
    static func muted(_ light: Bool) -> Color { AppColors.textSecondary }
    static func faint(_ light: Bool) -> Color { AppColors.textMuted }
    static func title(_ light: Bool) -> Color { AppColors.text }
    static func link(_ light: Bool) -> Color { AppColors.accent }
}

/// Reusable native layout constraints. Keep toolbar space inside its owning column.
enum KiriLayoutMetrics {
    static let sidebarMin: CGFloat = 196
    static let sidebarIdeal: CGFloat = 204
    static let sidebarMax: CGFloat = 240
    static let contentMin: CGFloat = 316
    static let contentIdeal: CGFloat = 340
    static let contentMax: CGFloat = 600
    static let detailMin: CGFloat = 420
    static let containerRowHeight: CGFloat = 44
    static let sidebarStatusHeight: CGFloat = 44
    static let detailTabWidth: CGFloat = 240
    static let consoleHeaderHeight: CGFloat = 38
}

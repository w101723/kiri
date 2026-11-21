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


enum KiriPalette {
    static let blue = Color(red: 13/255, green: 110/255, blue: 253/255)
    static let mint = Color(red: 63/255, green: 182/255, blue: 139/255)
    static let red = Color(red: 248/255, green: 113/255, blue: 113/255)
    static func bg(_ light: Bool) -> Color {
        light ? Color(red: 249/255, green: 251/255, blue: 253/255)
              : Color(red: 15/255, green: 20/255, blue: 25/255)
    }
    static func panel(_ light: Bool) -> Color {
        light ? .white : Color(red: 23/255, green: 29/255, blue: 36/255)
    }
    static func raised(_ light: Bool) -> Color {
        light ? Color(red: 232/255, green: 238/255, blue: 245/255)
              : Color(red: 30/255, green: 37/255, blue: 45/255)
    }
    static func border(_ light: Bool) -> Color {
        light ? Color(red: 207/255, green: 217/255, blue: 227/255)
              : Color(red: 42/255, green: 49/255, blue: 58/255)
    }
    static func muted(_ light: Bool) -> Color {
        light ? Color(red: 83/255, green: 98/255, blue: 115/255)
              : Color(red: 152/255, green: 161/255, blue: 172/255)
    }
    static func faint(_ light: Bool) -> Color {
        light ? Color(red: 102/255, green: 117/255, blue: 136/255)
              : Color(red: 102/255, green: 112/255, blue: 124/255)
    }
    static func title(_ light: Bool) -> Color {
        light ? Color(red: 23/255, green: 33/255, blue: 46/255)
              : Color(red: 242/255, green: 240/255, blue: 235/255)
    }
    static func link(_ light: Bool) -> Color {
        light ? Color(red: 38/255, green: 114/255, blue: 207/255)
              : Color(red: 110/255, green: 168/255, blue: 254/255)
    }
}


/// Reusable native layout constraints. Keep toolbar space inside its owning column.
enum KiriLayoutMetrics {
    static let sidebarMin: CGFloat = 165
    static let sidebarIdeal: CGFloat = 180
    static let sidebarMax: CGFloat = 205
    static let contentMin: CGFloat = 280
    static let contentIdeal: CGFloat = 310
    static let contentMax: CGFloat = 440
    static let detailMin: CGFloat = 360
    static let containerRowHeight: CGFloat = 48
    static let sidebarStatusHeight: CGFloat = 44
    static let detailTabWidth: CGFloat = 210
    static let consoleHeaderHeight: CGFloat = 38
}

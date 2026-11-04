import AppKit
import PrettyFolderKit

/// The pointer just outside a corner of the rectangle: a curved arrow around the corner,
/// which says the picture turns.
enum TurnCursor {
    private static var cursors: [ResizeHandle: NSCursor] = [:]

    static func cursor(for corner: ResizeHandle) -> NSCursor {
        if let cursor = cursors[corner] { return cursor }
        let turns: CGFloat = switch corner {
        case .topRight: 0
        case .topLeft: 1
        case .bottomLeft: 2
        default: 3
        }
        let size = NSSize(width: 24, height: 24)
        let image = NSImage(size: size, flipped: false) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.translateBy(x: size.width / 2, y: size.height / 2)
            context.rotate(by: turns * .pi / 2)
            // An arc bowing out to the top right, with an arrowhead at each end.
            let arc = CGMutablePath()
            let center = CGPoint(x: -5, y: -5), radius: CGFloat = 12
            arc.addArc(center: center, radius: radius, startAngle: .pi * 0.08, endAngle: .pi * 0.42, clockwise: false)
            func head(at angle: CGFloat, pointing direction: CGFloat) -> CGPath {
                let tip = CGPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius)
                let along = CGVector(dx: -sin(angle) * direction, dy: cos(angle) * direction)
                let across = CGVector(dx: cos(angle), dy: sin(angle))
                let path = CGMutablePath()
                path.move(to: CGPoint(x: tip.x + along.dx * 4.5, y: tip.y + along.dy * 4.5))
                path.addLine(to: CGPoint(x: tip.x + across.dx * 4, y: tip.y + across.dy * 4))
                path.addLine(to: CGPoint(x: tip.x - across.dx * 4, y: tip.y - across.dy * 4))
                path.closeSubpath()
                return path
            }
            let heads = [head(at: .pi * 0.08, pointing: -1), head(at: .pi * 0.42, pointing: 1)]
            // White first, wider, so the black arrow has a rim on any background.
            for (color, width) in [(NSColor.white.cgColor, CGFloat(4)), (NSColor.black.cgColor, CGFloat(1.6))] {
                context.setStrokeColor(color)
                context.setFillColor(color)
                context.setLineWidth(width)
                context.setLineJoin(.round)
                context.addPath(arc)
                context.strokePath()
                for path in heads {
                    context.addPath(path)
                    context.drawPath(using: width > 2 ? .fillStroke : .fill)
                }
            }
            return true
        }
        let cursor = NSCursor(image: image, hotSpot: NSPoint(x: size.width / 2, y: size.height / 2))
        cursors[corner] = cursor
        return cursor
    }
}

extension ResizeHandle {
    /// The pointer over this handle.
    var cursor: NSCursor {
        if #available(macOS 15, *) {
            let position: NSCursor.FrameResizePosition = switch self {
            case .topLeft: .topLeft
            case .top: .top
            case .topRight: .topRight
            case .right: .right
            case .bottomRight: .bottomRight
            case .bottom: .bottom
            case .bottomLeft: .bottomLeft
            case .left: .left
            }
            return .frameResize(position: position, directions: .all)
        }
        switch self {
        case .left, .right: return .resizeLeftRight
        case .top, .bottom: return .resizeUpDown
        default: return .crosshair
        }
    }
}

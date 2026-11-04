import AppKit
import PrettyFolderKit

/// The lines the picture is lined up with while something moves, over the folder.
final class GuidesView: NSView {
    struct Look: Equatable {
        var guides: [SnapGuide]
        var side: CGFloat
        /// The rectangle, in the editor's coordinates: turned lines stay inside it.
        var frame: CGRect
    }

    var look: Look? {
        didSet { if look != oldValue { needsDisplay = true } }
    }

    override var isFlipped: Bool { true }

    /// The editor below takes the mouse.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let look else { return }
        NSColor.systemPink.setStroke()
        for guide in look.guides {
            let path = NSBezierPath()
            path.lineWidth = 1
            let position = guide.position * look.side
            let from = (guide.extent?.lowerBound ?? 0) * look.side
            let to = (guide.extent?.upperBound ?? 1) * look.side
            guard guide.tilt != 0 else {
                switch guide.axis {
                case .vertical:
                    path.move(to: NSPoint(x: position, y: from))
                    path.line(to: NSPoint(x: position, y: to))
                case .horizontal:
                    path.move(to: NSPoint(x: from, y: position))
                    path.line(to: NSPoint(x: to, y: position))
                }
                path.stroke()
                continue
            }
            // A turned line through the middle of its extent, across the rectangle it is in.
            let middle = (from + to) / 2
            let center = guide.axis == .vertical ? NSPoint(x: position, y: middle) : NSPoint(x: middle, y: position)
            // Counterclockwise on screen, with the y axis pointing down.
            let tilt = guide.tilt
            let direction = guide.axis == .vertical
                ? CGVector(dx: sin(tilt), dy: cos(tilt)) : CGVector(dx: cos(tilt), dy: -sin(tilt))
            let length = hypot(look.frame.width, look.frame.height)
            path.move(to: NSPoint(x: center.x - direction.dx * length, y: center.y - direction.dy * length))
            path.line(to: NSPoint(x: center.x + direction.dx * length, y: center.y + direction.dy * length))
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: look.frame).addClip()
            path.stroke()
            NSGraphicsContext.restoreGraphicsState()
        }
    }
}

/// The rectangle the picture is in and its handles, drawn over the folder: a thin line just
/// outside the picture, so none of it is hidden, and small handles. While something changes,
/// only the line shows, faintly; while the picture turns, by how much.
final class FrameView: NSView {
    struct Look: Equatable {
        /// The rectangle, in the editor's coordinates.
        var frame: CGRect
        var showsHandles: Bool
        /// The handle under the pointer, a little bigger.
        var hovered: ResizeHandle?
        /// The pointer is on the rectangle, or it is being moved.
        var isHighlighted: Bool
        var isFaint: Bool
        /// How far the picture is turned, while it is being turned.
        var turn: String?
    }

    var look: Look? {
        didSet { if look != oldValue { needsDisplay = true } }
    }

    override var isFlipped: Bool { true }

    /// The editor below takes the mouse.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let look else { return }
        let frame = look.frame
        let line: CGFloat = 1
        NSGraphicsContext.saveGraphicsState()
        // Outside the picture only, rim and all: none of its pixels change.
        let outside = NSBezierPath(rect: bounds)
        outside.append(NSBezierPath(rect: frame))
        outside.windingRule = .evenOdd
        outside.addClip()
        // A dark rim around the line keeps it in sight on light pictures.
        let rim = NSShadow()
        rim.shadowColor = NSColor.black.withAlphaComponent(look.isFaint ? 0.25 : 0.5)
        rim.shadowBlurRadius = 1.5
        rim.set()
        NSColor.white.withAlphaComponent(look.isFaint ? 0.55 : look.isHighlighted ? 1 : 0.85).setStroke()
        let outline = NSBezierPath(rect: frame.insetBy(dx: -line / 2, dy: -line / 2))
        outline.lineWidth = line
        outline.stroke()
        NSGraphicsContext.restoreGraphicsState()

        if look.showsHandles {
            NSGraphicsContext.saveGraphicsState()
            let lift = NSShadow()
            lift.shadowColor = NSColor.black.withAlphaComponent(0.35)
            lift.shadowBlurRadius = 1.5
            lift.shadowOffset = NSSize(width: 0, height: -0.5)
            lift.set()
            NSColor.white.setFill()
            for handle in ResizeHandle.allCases {
                let center = handle.position(in: frame)
                let radius: CGFloat = handle == look.hovered ? 4.5 : 3.5
                NSBezierPath(ovalIn: NSRect(x: center.x - radius, y: center.y - radius, width: 2 * radius, height: 2 * radius)).fill()
            }
            NSGraphicsContext.restoreGraphicsState()
        }

        if let turn = look.turn {
            drawLabel(turn, near: frame)
        }
    }

    /// A small label above the rectangle, or inside its top when there is no room above.
    private func drawLabel(_ text: String, near frame: CGRect) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.white,
        ]
        let string = NSAttributedString(string: text, attributes: attributes)
        let size = string.size()
        let pill = CGSize(width: size.width + 12, height: size.height + 4)
        let near = bounds.intersection(frame.insetBy(dx: -40, dy: -40))
        let visible = near.isNull ? bounds : near
        var origin = CGPoint(x: frame.midX - pill.width / 2, y: frame.minY - pill.height - 8)
        if origin.y < bounds.minY + 2 { origin.y = max(frame.minY, bounds.minY) + 8 }
        origin.x = min(max(origin.x, visible.minX + 2), visible.maxX - pill.width - 2)
        let rect = CGRect(origin: origin, size: pill)
        NSColor.black.withAlphaComponent(0.7).setFill()
        NSBezierPath(roundedRect: rect, xRadius: pill.height / 2, yRadius: pill.height / 2).fill()
        string.draw(at: CGPoint(x: rect.minX + 6, y: rect.minY + 2))
    }
}

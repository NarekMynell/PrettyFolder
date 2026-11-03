#if DEBUG
import AppKit
import SwiftUI

/// The stage every scene is drawn on.
enum Stage {
    /// Pixels per point in the frames.
    static let scale: CGFloat = 2
    static let framesPerSecond = 25.0

    /// Where the stage would be on screen, in Accessibility coordinates. The app's own
    /// layout code works in screen coordinates, so scenes hand it these.
    static let origin = CGPoint(x: 300, y: 240)

    /// A rectangle on the stage (top-left origin) in Accessibility coordinates.
    static func accessibilityRect(_ rect: CGRect) -> CGRect {
        rect.offsetBy(dx: origin.x, dy: origin.y)
    }

    /// A rectangle in AppKit screen coordinates back on the stage.
    static func stageRect(fromAppKit rect: NSRect) -> CGRect {
        let mainHeight = NSScreen.screens.first?.frame.maxY ?? 0
        return CGRect(x: rect.minX - origin.x, y: mainHeight - rect.maxY - origin.y, width: rect.width, height: rect.height)
    }

    /// A point on the stage in AppKit screen coordinates.
    static func appKitPoint(_ point: CGPoint) -> NSPoint {
        let mainHeight = NSScreen.screens.first?.frame.maxY ?? 0
        return NSPoint(x: point.x + origin.x, y: mainHeight - point.y - origin.y)
    }
}

// MARK: - Time

/// Starts and stops gently, the way a hand moves a mouse.
func ease(_ x: Double) -> Double {
    let x = min(max(x, 0), 1)
    return x < 0.5 ? 4 * x * x * x : 1 - pow(-2 * x + 2, 3) / 2
}

/// How far `t` is from `start` to `end`, between 0 and 1.
func progress(_ t: Double, _ start: Double, _ end: Double) -> Double {
    guard end > start else { return t >= end ? 1 : 0 }
    return min(max((t - start) / (end - start), 0), 1)
}

func mix(_ a: CGFloat, _ b: CGFloat, _ amount: Double) -> CGFloat {
    a + (b - a) * CGFloat(amount)
}

func mix(_ a: CGPoint, _ b: CGPoint, _ amount: Double) -> CGPoint {
    CGPoint(x: mix(a.x, b.x, amount), y: mix(a.y, b.y, amount))
}

/// Where the pointer is over time: it rests, then glides to the next stop on a slight arc.
struct PointerPath {
    private struct Leg {
        let from: CGPoint
        let to: CGPoint
        let start: Double
        let end: Double
        let arc: CGFloat
    }

    private var legs: [Leg] = []
    private(set) var end: CGPoint

    init(start: CGPoint) {
        end = start
    }

    mutating func move(to point: CGPoint, from start: Double, to finish: Double, arc: CGFloat = 0.1) {
        legs.append(Leg(from: end, to: point, start: start, end: finish, arc: arc))
        end = point
    }

    func position(at t: Double) -> CGPoint {
        guard let first = legs.first else { return end }
        if t <= first.start { return first.from }
        for leg in legs where t <= leg.end {
            if t < leg.start { return leg.from }
            let amount = ease(progress(t, leg.start, leg.end))
            let straight = mix(leg.from, leg.to, amount)
            // Bend sideways a little, most in the middle of the leg.
            let dx = leg.to.x - leg.from.x, dy = leg.to.y - leg.from.y
            let bend = leg.arc * CGFloat(sin(amount * .pi))
            return CGPoint(x: straight.x - dy * bend, y: straight.y + dx * bend)
        }
        return end
    }
}

// MARK: - Drawing

/// A bitmap to draw a frame into, in points with a top-left origin.
final class Bitmap {
    let context: CGContext
    let size: CGSize
    let scale: CGFloat

    init(size: CGSize, scale: CGFloat = Stage.scale) {
        self.size = size
        self.scale = scale
        context = CGContext(
            data: nil, width: Int((size.width * scale).rounded()), height: Int((size.height * scale).rounded()),
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.interpolationQuality = .high
        context.translateBy(x: 0, y: CGFloat(context.height))
        context.scaleBy(x: scale, y: -scale)
    }

    var image: CGImage { context.makeImage()! }

    /// Draws an image the right way up into `rect`.
    func draw(_ image: CGImage, in rect: CGRect, alpha: CGFloat = 1) {
        guard alpha > 0 else { return }
        context.saveGState()
        context.setAlpha(alpha)
        context.translateBy(x: rect.minX, y: rect.maxY)
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(origin: .zero, size: rect.size))
        context.restoreGState()
    }

    /// Runs AppKit drawing (text, NSImage, NSBezierPath) on this bitmap.
    func appKit(_ body: () -> Void) {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        body()
        NSGraphicsContext.restoreGraphicsState()
    }

    func withShadow(color: CGColor, blur: CGFloat, offset: CGSize = .zero, _ body: () -> Void) {
        context.saveGState()
        // Core Graphics shadow offsets ignore the flip, and are in device space.
        context.setShadow(offset: CGSize(width: offset.width * scale, height: -offset.height * scale), blur: blur * scale, color: color)
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        body()
        context.endTransparencyLayer()
        context.restoreGState()
    }
}

extension CGColor {
    static func hex(_ value: UInt32, alpha: CGFloat = 1) -> CGColor {
        CGColor(
            srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255, alpha: alpha
        )
    }
}

enum Scenery {
    /// A soft desktop picture, like the ones macOS ships: deep blue to violet to warm pink,
    /// with a couple of glows.
    static func wallpaper(size: CGSize) -> CGImage {
        let bitmap = Bitmap(size: size)
        let context = bitmap.context
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let base = CGGradient(
            colorsSpace: space,
            colors: [CGColor.hex(0x23306E), CGColor.hex(0x5B3FA8), CGColor.hex(0xC0659E)] as CFArray,
            locations: [0, 0.55, 1]
        )!
        context.drawLinearGradient(base, start: .zero, end: CGPoint(x: size.width, y: size.height), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        for (center, radius, color) in [
            (CGPoint(x: size.width * 0.82, y: size.height * 0.12), size.width * 0.45, CGColor.hex(0x7FA8FF, alpha: 0.35)),
            (CGPoint(x: size.width * 0.12, y: size.height * 0.95), size.width * 0.4, CGColor.hex(0xFF9F7A, alpha: 0.28)),
        ] {
            let glow = CGGradient(colorsSpace: space, colors: [color, color.copy(alpha: 0)!] as CFArray, locations: [0, 1])!
            context.drawRadialGradient(glow, startCenter: center, startRadius: 0, endCenter: center, endRadius: radius, options: [])
        }
        return bitmap.image
    }

    /// One item on the Desktop: its icon and its name below, the way Finder draws them.
    static func drawItem(
        on bitmap: Bitmap, icon: CGImage, frame: CGRect, name: String,
        selected: Bool = false, targeted: Bool = false, iconAlpha: CGFloat = 1
    ) {
        if selected || targeted {
            let highlight = CGPath(roundedRect: frame.insetBy(dx: -5, dy: -5), cornerWidth: 9, cornerHeight: 9, transform: nil)
            bitmap.context.addPath(highlight)
            bitmap.context.setFillColor(CGColor(gray: 0, alpha: targeted ? 0.32 : 0.24))
            bitmap.context.fillPath()
        }
        bitmap.draw(icon, in: frame, alpha: iconAlpha)
        drawLabel(name, on: bitmap, below: frame, selected: selected)
    }

    static func drawLabel(_ name: String, on bitmap: Bitmap, below frame: CGRect, selected: Bool) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(selected ? 0 : 0.75)
        shadow.shadowBlurRadius = 2.5
        shadow.shadowOffset = NSSize(width: 0, height: -0.5)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white,
            .paragraphStyle: paragraph,
            .shadow: shadow,
        ]
        let text = NSAttributedString(string: name, attributes: attributes)
        let size = text.size()
        let rect = CGRect(x: frame.midX - size.width / 2, y: frame.maxY + 5, width: size.width, height: size.height)
        bitmap.appKit {
            if selected {
                let background = NSBezierPath(roundedRect: rect.insetBy(dx: -5, dy: -1), xRadius: 4, yRadius: 4)
                NSColor.systemBlue.setFill()
                background.fill()
            }
            text.draw(in: rect)
        }
    }

    /// An image file on the Desktop: Finder shows a thumbnail with a white edge.
    static func thumbnail(of picture: CGImage, fitting side: CGFloat) -> CGImage {
        let aspect = CGFloat(picture.width) / CGFloat(picture.height)
        let size = aspect >= 1 ? CGSize(width: side, height: side / aspect) : CGSize(width: side * aspect, height: side)
        let bitmap = Bitmap(size: CGSize(width: side, height: side))
        let rect = CGRect(x: (side - size.width) / 2, y: (side - size.height) / 2, width: size.width, height: size.height).insetBy(dx: 3, dy: 3)
        bitmap.withShadow(color: CGColor(gray: 0, alpha: 0.45), blur: 3, offset: CGSize(width: 0, height: 1)) {
            bitmap.context.setFillColor(CGColor(gray: 1, alpha: 1))
            bitmap.context.fill(rect)
        }
        bitmap.draw(picture, in: rect.insetBy(dx: 2.5, dy: 2.5))
        return bitmap.image
    }

    /// The pointer, its hot spot at `point`.
    static func drawCursor(_ cursor: NSCursor, at point: CGPoint, on bitmap: Bitmap) {
        let image = cursor.image
        let rect = CGRect(x: point.x - cursor.hotSpot.x, y: point.y - cursor.hotSpot.y, width: image.size.width, height: image.size.height)
        bitmap.appKit {
            image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
    }

    /// Two fingertips around the pointer, moving apart as `spread` goes from 0 to 1: a pinch.
    static func drawPinch(around point: CGPoint, spread: Double, alpha: Double, on bitmap: Bitmap) {
        guard alpha > 0 else { return }
        let distance = 12 + 16 * CGFloat(spread)
        bitmap.withShadow(color: CGColor(gray: 0, alpha: 0.35 * alpha), blur: 3, offset: CGSize(width: 0, height: 1)) {
            bitmap.appKit {
                for direction: CGFloat in [-1, 1] {
                    let center = CGPoint(x: point.x + direction * distance * 0.7, y: point.y - 8 + direction * distance * 0.7)
                    let tip = NSBezierPath(ovalIn: NSRect(x: center.x - 8, y: center.y - 8, width: 16, height: 16))
                    NSColor.white.withAlphaComponent(0.55 * alpha).setFill()
                    tip.fill()
                    NSColor.white.withAlphaComponent(0.9 * alpha).setStroke()
                    tip.lineWidth = 1.5
                    tip.stroke()
                }
            }
        }
    }

    /// Two fingertips on either side of the pointer, turned `degrees` counterclockwise around
    /// it: a twist.
    static func drawTwist(around point: CGPoint, degrees: Double, alpha: Double, on bitmap: Bitmap) {
        guard alpha > 0 else { return }
        let distance: CGFloat = 22
        // They start a little off the diagonal, the way two fingers rest on a trackpad.
        let angle = CGFloat((-35 + degrees) * .pi / 180)
        bitmap.withShadow(color: CGColor(gray: 0, alpha: 0.35 * alpha), blur: 3, offset: CGSize(width: 0, height: 1)) {
            bitmap.appKit {
                for direction: CGFloat in [-1, 1] {
                    // Counterclockwise on screen, with the y axis pointing down.
                    let center = CGPoint(x: point.x + direction * distance * cos(angle), y: point.y - 8 - direction * distance * sin(angle))
                    let tip = NSBezierPath(ovalIn: NSRect(x: center.x - 8, y: center.y - 8, width: 16, height: 16))
                    NSColor.white.withAlphaComponent(0.55 * alpha).setFill()
                    tip.fill()
                    NSColor.white.withAlphaComponent(0.9 * alpha).setStroke()
                    tip.lineWidth = 1.5
                    tip.stroke()
                }
            }
        }
    }

    /// A small mouse beside the pointer with its right button held down, shown as much as
    /// `alpha` says: a drag with the right button.
    static func drawRightButton(beside point: CGPoint, alpha: Double, on bitmap: Bitmap) {
        guard alpha > 0 else { return }
        let alpha = CGFloat(alpha)
        let body = CGRect(x: point.x + 15, y: point.y + 17, width: 18, height: 26)
        let split = body.minY + body.height * 0.42
        bitmap.withShadow(color: CGColor(gray: 0, alpha: 0.35 * alpha), blur: 3, offset: CGSize(width: 0, height: 1)) {
            bitmap.appKit {
                let shape = NSBezierPath(roundedRect: body, xRadius: 9, yRadius: 9)
                NSColor.white.withAlphaComponent(0.95 * alpha).setFill()
                shape.fill()
                // The right button, pressed.
                NSGraphicsContext.saveGraphicsState()
                shape.addClip()
                NSColor(srgbRed: 0.04, green: 0.52, blue: 1, alpha: alpha).setFill()
                NSBezierPath(rect: NSRect(x: body.midX, y: body.minY, width: body.width / 2, height: split - body.minY)).fill()
                NSGraphicsContext.restoreGraphicsState()
                let seams = NSBezierPath()
                seams.move(to: NSPoint(x: body.minX, y: split))
                seams.line(to: NSPoint(x: body.maxX, y: split))
                seams.move(to: NSPoint(x: body.midX, y: body.minY))
                seams.line(to: NSPoint(x: body.midX, y: split))
                seams.lineWidth = 1
                NSColor.black.withAlphaComponent(0.4 * alpha).setStroke()
                seams.stroke()
                shape.lineWidth = 1.2
                shape.stroke()
            }
        }
    }

    /// A window with the soft shadow macOS gives it.
    static func drawWindow(_ image: CGImage, at origin: CGPoint, size: CGSize, on bitmap: Bitmap, alpha: CGFloat = 1, scale: CGFloat = 1) {
        let scaled = CGSize(width: size.width * scale, height: size.height * scale)
        let rect = CGRect(x: origin.x + (size.width - scaled.width) / 2, y: origin.y + (size.height - scaled.height) / 2, width: scaled.width, height: scaled.height)
        bitmap.context.saveGState()
        bitmap.context.setAlpha(alpha)
        bitmap.withShadow(color: CGColor(gray: 0, alpha: 0.45), blur: 28, offset: CGSize(width: 0, height: 12)) {
            bitmap.draw(image, in: rect)
        }
        bitmap.context.restoreGState()
    }
}
#endif

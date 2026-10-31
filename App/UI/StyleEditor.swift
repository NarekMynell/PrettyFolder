import AppKit
import PrettyFolderKit
import SwiftUI

/// The standard folder icon with a rectangle on it that can be moved and resized.
/// The picture is previewed inside with exactly the geometry the renderer uses.
struct StyleEditor: View {
    @Binding var style: IconStyle
    let picture: NSImage?
    var isEnabled = true
    var side: CGFloat = 300

    @State private var dragStart: IconStyle?
    @State private var snappedToCenter = false

    /// The plain folder, rendered once at full size so it stays sharp at any editor size.
    private static let folderImage: Image = {
        if let bitmap = IconRenderer().render(nil, style: .standard, pixelSize: 1024) {
            return Image(decorative: bitmap, scale: 1)
        }
        return Image(nsImage: FolderArtwork.makeBaseIcon())
    }()
    private static let snapDistance = 0.012

    var body: some View {
        ZStack(alignment: .topLeading) {
            Canvas { context, size in
                draw(in: &context, size: size)
            }
            if isEnabled {
                frameOverlay
            }
        }
        .frame(width: side, height: side)
        .coordinateSpace(name: "editor")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Picture position"))
        .accessibilityValue(Text(accessibilityDescription))
    }

    // MARK: - Drawing

    private func draw(in context: inout GraphicsContext, size: CGSize) {
        context.draw(Self.folderImage, in: CGRect(origin: .zero, size: size))
        let target = IconGeometry.targetRect(for: style, canvas: size.width, flipped: true)

        guard let picture else {
            // No picture yet: show the area as a soft placeholder.
            let radius = IconGeometry.cornerRadius(for: target, canvas: size.width)
            context.fill(Path(roundedRect: target, cornerRadius: radius), with: .color(.white.opacity(0.35)))
            return
        }

        let drawn = IconGeometry.imageRect(imageSize: picture.size, in: target, mode: style.mode)
        let visible = IconGeometry.visibleRect(imageSize: picture.size, in: target, mode: style.mode)
        let radius = IconGeometry.cornerRadius(for: visible, canvas: size.width)
        let image = Image(nsImage: picture)

        if style.mode == .fill && isEnabled {
            // The cropped-away parts, faintly, so it's clear what Fill does.
            var ghost = context
            ghost.opacity = 0.18
            ghost.draw(image, in: drawn)
        }
        var clipped = context
        clipped.clip(to: Path(roundedRect: visible, cornerRadius: radius))
        clipped.draw(image, in: drawn)
    }

    // MARK: - Handles

    private var frameOverlay: some View {
        let target = IconGeometry.targetRect(for: style, canvas: side, flipped: true)
        return ZStack(alignment: .topLeading) {
            if snappedToCenter {
                Path { path in
                    path.move(to: CGPoint(x: side / 2, y: 0))
                    path.addLine(to: CGPoint(x: side / 2, y: side))
                }
                .stroke(Color.accentColor.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }
            Rectangle()
                .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
                .background(Color.white.opacity(0.001)) // makes the inside draggable
                .frame(width: target.width, height: target.height)
                .offset(x: target.minX, y: target.minY)
                .gesture(moveGesture)
                .onTapGesture(count: 2) { style.rect = IconStyle.standard.rect }
                .help("Drag to move. Drag the corners to resize; hold Shift to keep the proportions. Double-click to reset.")
            ForEach(Handle.allCases, id: \.self) { handle in
                let point = handle.position(in: target)
                HandleKnob()
                    .position(point)
                    .gesture(resizeGesture(handle))
            }
        }
        .frame(width: side, height: side, alignment: .topLeading)
    }

    private var moveGesture: some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .named("editor"))
            .onChanged { value in
                let start = dragStart ?? style
                dragStart = start
                var rect = start.rect
                rect.origin.x += value.translation.width / side
                rect.origin.y += value.translation.height / side
                // Snap the center to the middle of the icon.
                if abs(rect.midX - 0.5) < Self.snapDistance {
                    rect.origin.x = 0.5 - rect.width / 2
                    snappedToCenter = true
                } else {
                    snappedToCenter = false
                }
                style.rect = rect
            }
            .onEnded { _ in
                dragStart = nil
                snappedToCenter = false
            }
    }

    private func resizeGesture(_ handle: Handle) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("editor"))
            .onChanged { value in
                let start = dragStart ?? style
                dragStart = start
                let dx = value.translation.width / side
                let dy = value.translation.height / side
                let keepRatio = NSEvent.modifierFlags.contains(.shift) && handle.isCorner
                style.rect = handle.resize(start.rect, dx: dx, dy: dy, keepRatio: keepRatio)
            }
            .onEnded { _ in dragStart = nil }
    }

    private var accessibilityDescription: String {
        let percent = { (value: Double) in "\(Int((value * 100).rounded()))%" }
        return "\(percent(style.width)) wide, \(percent(style.height)) tall, \(style.mode == .fill ? "fill" : "fit")"
    }
}

private struct HandleKnob: View {
    var body: some View {
        Circle()
            .fill(.white)
            .overlay(Circle().strokeBorder(Color.accentColor, lineWidth: 1.5))
            .frame(width: 11, height: 11)
            .shadow(color: .black.opacity(0.25), radius: 1, y: 0.5)
            .contentShape(Circle().inset(by: -5))
    }
}

/// The eight resize handles and how each one moves the rectangle's edges.
private enum Handle: CaseIterable {
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left

    var isCorner: Bool { [.topLeft, .topRight, .bottomRight, .bottomLeft].contains(self) }

    private var movesLeft: Bool { [.topLeft, .left, .bottomLeft].contains(self) }
    private var movesRight: Bool { [.topRight, .right, .bottomRight].contains(self) }
    private var movesTop: Bool { [.topLeft, .top, .topRight].contains(self) }
    private var movesBottom: Bool { [.bottomLeft, .bottom, .bottomRight].contains(self) }

    func position(in rect: CGRect) -> CGPoint {
        let x = movesLeft ? rect.minX : movesRight ? rect.maxX : rect.midX
        let y = movesTop ? rect.minY : movesBottom ? rect.maxY : rect.midY
        return CGPoint(x: x, y: y)
    }

    /// Moves the edges this handle owns, never letting the rectangle flip or leave the canvas.
    func resize(_ rect: CGRect, dx: Double, dy: Double, keepRatio: Bool) -> CGRect {
        let minimum = IconStyle.minimumSide
        var left = rect.minX, right = rect.maxX, top = rect.minY, bottom = rect.maxY
        if movesLeft { left = min(max(0, left + dx), right - minimum) }
        if movesRight { right = max(min(1, right + dx), left + minimum) }
        if movesTop { top = min(max(0, top + dy), bottom - minimum) }
        if movesBottom { bottom = max(min(1, bottom + dy), top + minimum) }

        if keepRatio, rect.height > 0 {
            let ratio = rect.width / rect.height
            // Follow whichever side moved more and derive the other one.
            var width = right - left
            var height = bottom - top
            if abs(dx) >= abs(dy) { height = width / ratio } else { width = height * ratio }
            // Stay inside the canvas, from the fixed corner.
            let anchorX = movesLeft ? rect.maxX : rect.minX
            let anchorY = movesTop ? rect.maxY : rect.minY
            let maxWidth = movesLeft ? anchorX : 1 - anchorX
            let maxHeight = movesTop ? anchorY : 1 - anchorY
            let scale = min(1, maxWidth / max(width, .ulpOfOne), maxHeight / max(height, .ulpOfOne))
            width = max(width * scale, minimum)
            height = max(height * scale, minimum)
            left = movesLeft ? anchorX - width : anchorX
            top = movesTop ? anchorY - height : anchorY
            right = left + width
            bottom = top + height
        }
        return CGRect(x: left, y: top, width: right - left, height: bottom - top)
    }
}

/// The Fill / Fit switch with a word on what each does.
struct FitModePicker: View {
    @Binding var mode: FitMode

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("Scaling", selection: $mode) {
                Text("Fill").tag(FitMode.fill)
                Text("Fit").tag(FitMode.fit)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            Text(mode == .fill
                 ? "The picture covers the whole rectangle; edges that don't fit are cropped."
                 : "The whole picture is visible; it grows until it touches the rectangle's sides.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Loads a picture for previews: small enough to stay quick, sharp enough for the editor.
enum PreviewPicture {
    /// Always a bitmap: vectors are rasterized at full size, so tiny SVGs stay sharp too.
    static func load(_ url: URL) -> NSImage? {
        guard let picture = try? ImageLoader.load(contentsOf: url),
              let bitmap = picture.bitmap(maxSide: 1024)
        else { return nil }
        return NSImage(cgImage: bitmap, size: NSSize(width: bitmap.width, height: bitmap.height))
    }

    /// A made-up landscape for previewing the default look before any picture is chosen.
    static let sample: NSImage = {
        let width = 900, height = 600
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return NSImage() }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        let rect = NSRect(x: 0, y: 0, width: width, height: height)
        NSGradient(colors: [
            NSColor(srgbRed: 0.98, green: 0.62, blue: 0.45, alpha: 1),
            NSColor(srgbRed: 0.96, green: 0.80, blue: 0.62, alpha: 1),
            NSColor(srgbRed: 0.55, green: 0.73, blue: 0.95, alpha: 1),
        ])?.draw(in: rect, angle: 90)
        NSColor(srgbRed: 1, green: 0.93, blue: 0.7, alpha: 1).setFill()
        NSBezierPath(ovalIn: NSRect(x: 560, y: 300, width: 150, height: 150)).fill()
        let far = NSBezierPath()
        far.move(to: NSPoint(x: 0, y: 160))
        far.line(to: NSPoint(x: 230, y: 380))
        far.line(to: NSPoint(x: 420, y: 230))
        far.line(to: NSPoint(x: 640, y: 420))
        far.line(to: NSPoint(x: 900, y: 200))
        far.line(to: NSPoint(x: 900, y: 0))
        far.line(to: NSPoint(x: 0, y: 0))
        NSColor(srgbRed: 0.36, green: 0.42, blue: 0.62, alpha: 1).setFill()
        far.fill()
        let near = NSBezierPath()
        near.move(to: NSPoint(x: 0, y: 90))
        near.curve(to: NSPoint(x: 900, y: 120), controlPoint1: NSPoint(x: 300, y: 260), controlPoint2: NSPoint(x: 600, y: 20))
        near.line(to: NSPoint(x: 900, y: 0))
        near.line(to: NSPoint(x: 0, y: 0))
        NSColor(srgbRed: 0.2, green: 0.45, blue: 0.4, alpha: 1).setFill()
        near.fill()
        NSGraphicsContext.restoreGraphicsState()
        guard let image = context.makeImage() else { return NSImage() }
        return NSImage(cgImage: image, size: NSSize(width: width, height: height))
    }()
}

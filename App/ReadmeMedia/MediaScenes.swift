#if DEBUG
import AppKit
import PrettyFolderKit
import SwiftUI

/// The README's animations, shot frame by frame.
extension Studio {
    /// How a picture sits on a folder. Every one of these is made in the window: the frame
    /// anywhere from a corner to well past the folder, Fill or Fit, the picture turned.
    private struct Look {
        var style: IconStyle
        var placement: PicturePlacement = .natural

        static let standard = Look(style: .standard)
        /// A logo or a cut-out, the folder showing all around it.
        static let sticker = Look(style: IconStyle(x: 0.21, y: 0.31, width: 0.58, height: 0.52, mode: .fit))
    }

    private struct Folder {
        let name: String
        let picture: String?
        var look = Look.standard
    }

    private func icon(_ folder: Folder, side: CGFloat) throws -> CGImage {
        icon(try folder.picture.map(picture), style: folder.look.style, placement: folder.look.placement, side: side)
    }

    /// Folders on the Desktop, in a row.
    private func row(count: Int, side: CGFloat, top: CGFloat, spacing: CGFloat, width: CGFloat) -> [CGRect] {
        let first = width / 2 - spacing * CGFloat(count - 1) / 2
        return (0..<count).map { index in
            CGRect(x: first + spacing * CGFloat(index) - side / 2, y: top, width: side, height: side)
        }
    }

    /// Every animation is this big, to sit side by side with the others in the README.
    static let tile = CGSize(width: 416, height: 548)

    private func frameCount(_ seconds: Double) -> Int {
        Int((seconds * Stage.framesPerSecond).rounded())
    }

    // MARK: - Drag and drop

    /// Pictures dragged from the Desktop onto folders' Set as Icon badge: a photo, and a transparent
    /// logo on the checkerboard every drawing app shows nothing with, which leaves the folder showing
    /// all around it.
    func renderDrop() async throws {
        try await renderDrags(
            "drop",
            folders: [
                Folder(name: "Pets", picture: nil),
                Folder(name: "Startup", picture: nil),
            ],
            frames: row(count: 2, side: 150, top: 60, spacing: 190, width: Self.tile.width),
            drags: [
                Drag(file: "axolotl.jpg", target: 0, look: .standard, start: 0, at: CGPoint(x: 65, y: 340), side: 110),
                Drag(file: "bolt.svg", target: 1, look: .sticker, start: 3.7, at: CGPoint(x: 245, y: 340), clear: true, side: 110),
            ],
            seconds: 9.2, pointerStart: CGPoint(x: 208, y: 510), pointerEnd: CGPoint(x: 208, y: 480)
        )
    }

    /// A picture file on its way to a folder.
    private struct Drag {
        let file: String
        let target: Int
        let look: Look
        /// When this drag begins, in the scene.
        let start: Double
        /// Where the file is on the Desktop.
        let at: CGPoint
        /// It has nothing around it: shown on a checkerboard.
        var clear = false
        /// How big it is on the Desktop.
        var side: CGFloat = 96
        /// Where on the file the pointer holds it.
        /// By its bottom-right corner, it rides up and to the left of the pointer.
        var grab = CGPoint(x: 86, y: 74)
    }

    private func renderDrags(_ scene: String, folders: [Folder], frames: [CGRect], drags: [Drag], seconds: Double, pointerStart: CGPoint, pointerEnd: CGPoint) async throws {
        let size = Self.tile
        let wallpaper = Scenery.wallpaper(size: size)
        let names = folders.map(\.name)
        var icons = try zip(folders, frames).map { try icon($0, side: $1.width) }

        struct Prepared {
            let dropped: CGImage
            let frame: CGRect
            let thumbnail: CGImage
            let press: CGPoint
            let over: CGPoint
            let badgeFrame: CGRect
            let onBadge: CGPoint
            let badges: [DropBadgeModel.State: CGImage]
        }
        var prepared: [Prepared] = []
        var path = PointerPath(start: pointerStart)
        for drag in drags {
            let target = drag.target
            let droppedIcon = icon(try picture(drag.file), style: drag.look.style, placement: drag.look.placement, side: frames[target].width)

            // The picture file, as Finder shows it on the Desktop.
            let file = NSImage(contentsOf: pictureURL(drag.file))!.cgImage(forProposedRect: nil, context: nil, hints: nil)!
            let fileFrame = CGRect(origin: drag.at, size: CGSize(width: drag.side, height: drag.side))
            let thumbnail = drag.clear ? Scenery.clearThumbnail(of: file, fitting: drag.side) : Scenery.thumbnail(of: file, fitting: drag.side)

            // The badge, in each of its looks, where the app puts it for this folder.
            let pressPoint = CGPoint(x: fileFrame.minX + drag.grab.x, y: fileFrame.minY + drag.grab.y)
            let overFolder = CGPoint(x: frames[target].midX - 4, y: frames[target].midY + 8)
            let item = FinderItem(
                url: URL(fileURLWithPath: "/\(names[target])/"), layout: .icon,
                iconFrame: Stage.accessibilityRect(frames[target]), nameFrame: nil, rowFrame: nil
            )
            guard let badgeScreenFrame = DropBadgeController.frame(for: item, avoiding: Stage.appKitPoint(overFolder)) else {
                throw MediaError("The badge has nowhere to go")
            }
            let badgeFrame = Stage.stageRect(fromAppKit: badgeScreenFrame)
            let badgeModel = DropBadgeModel()
            badgeModel.fontSize = DropBadgeController.fontSize(for: item)
            var badges: [DropBadgeModel.State: CGImage] = [:]
            for state in [DropBadgeModel.State.ready, .targeted, .working, .done] {
                badgeModel.state = state
                let host = NSHostingView(rootView: DropBadgeContent(model: badgeModel))
                _ = sprite(of: host, size: badgeFrame.size)
                await settle(milliseconds: 450)
                badges[state] = sprite(of: host, size: badgeFrame.size)
                // Sharper when it can be: the spinner only draws in a window.
                if state != .working {
                    let renderer = ImageRenderer(content: DropBadgeContent(model: badgeModel).frame(width: badgeFrame.width, height: badgeFrame.height))
                    renderer.scale = Stage.scale
                    badges[state] = renderer.cgImage ?? badges[state]
                }
            }
            // On its symbol, low down: what's dragged hangs below it or off to the side, and the
            // title stays in sight.
            let onBadge = CGPoint(x: badgeFrame.minX + DropBadgeController.shadowMargin + 18, y: drag.grab.y < 20 ? badgeFrame.maxY - DropBadgeController.shadowMargin - 5 : badgeFrame.midY + 1)

            path.move(to: pressPoint, from: drag.start + 0.4, to: drag.start + 1.2)
            path.move(to: overFolder, from: drag.start + 1.45, to: drag.start + 2.55, arc: -0.12)
            path.move(to: onBadge, from: drag.start + 2.95, to: drag.start + 3.3, arc: 0)
            prepared.append(Prepared(dropped: droppedIcon, frame: fileFrame, thumbnail: thumbnail, press: pressPoint, over: overFolder,
                                     badgeFrame: badgeFrame, onBadge: onBadge, badges: badges))
        }
        path.move(to: pointerEnd, from: drags.last!.start + 4.7, to: drags.last!.start + 5.5)

        let badgeInset = DropBadgeController.shadowMargin
        let sequence = try frameSequence(scene)
        for index in 0..<frameCount(seconds) {
            // A frame's images go once it's written, not when the whole scene is done.
            try autoreleasepool {
                let t = Double(index) / Stage.framesPerSecond
                let pointer = path.position(at: t)
                // The drag under way or the last one done.
                let current = drags.lastIndex { t >= $0.start } ?? 0
                let drag = drags[current], ready = prepared[current]
                let local = t - drag.start
                let pressAt = 1.3, releaseAt = 3.45
                let badgeShownAt = 2.55 + 0.18, doneAt = 3.75, badgeHiddenAt = doneAt + 0.7
                let dragging = local >= pressAt && local < releaseAt
                let overBadge = dragging && local >= badgeShownAt && ready.badgeFrame.insetBy(dx: badgeInset, dy: badgeInset).contains(pointer)
                for (done, other) in zip(drags, prepared) where t >= done.start + doneAt { icons[done.target] = other.dropped }

                let bitmap = Bitmap(size: size)
                bitmap.draw(wallpaper, in: CGRect(origin: .zero, size: size))
                for (position, frame) in frames.enumerated() {
                    let targeted = dragging && position == drag.target && frame.contains(pointer) && !overBadge
                    // The folder takes the picture with a little bounce.
                    let landed = drags.first { $0.target == position }.map { t - $0.start - doneAt } ?? -1
                    let bounce = landed >= 0 && landed < 0.32 ? 1 + 0.07 * CGFloat(sin(landed / 0.32 * .pi)) : 1
                    let shown = frame.insetBy(dx: frame.width * (1 - bounce) / 2, dy: frame.height * (1 - bounce) / 2)
                    Scenery.drawItem(on: bitmap, icon: icons[position], frame: shown, name: names[position], targeted: targeted)
                }
                for (position, (other, file)) in zip(drags, prepared).enumerated() {
                    Scenery.drawItem(on: bitmap, icon: file.thumbnail, frame: file.frame, name: fileName(other),
                                     selected: position == current && local >= pressAt)
                }

                // The badge comes up a moment after the picture reaches the folder.
                for (other, file) in zip(drags, prepared) {
                    let at = t - other.start
                    if at >= badgeShownAt && at < badgeHiddenAt + 0.1 {
                        let state: DropBadgeModel.State = at >= doneAt ? .done : at >= releaseAt ? .working : overBadge ? .targeted : .ready
                        let fadeIn = progress(at, badgeShownAt, badgeShownAt + 0.12)
                        let fadeOut = 1 - progress(at, badgeHiddenAt, badgeHiddenAt + 0.1)
                        bitmap.draw(file.badges[state]!, in: file.badgeFrame, alpha: CGFloat(fadeIn * fadeOut))
                    }
                }

                if dragging {
                    // What is being dragged follows the pointer, a little see-through.
                    let offset = CGPoint(x: ready.frame.minX - ready.press.x, y: ready.frame.minY - ready.press.y)
                    let dragFrame = CGRect(x: pointer.x + offset.x, y: pointer.y + offset.y, width: ready.frame.width, height: ready.frame.height)
                    bitmap.context.saveGState()
                    bitmap.context.setAlpha(0.75)
                    Scenery.drawItem(on: bitmap, icon: ready.thumbnail, frame: dragFrame, name: fileName(drag), selected: true)
                    bitmap.context.restoreGState()
                }
                // Where the hand presses, and where it lets go.
                Scenery.drawClick(at: ready.press, amount: progress(local, pressAt - 0.05, pressAt + 0.35), on: bitmap)
                Scenery.drawClick(at: ready.onBadge, amount: progress(local, releaseAt - 0.05, releaseAt + 0.35), on: bitmap)
                Scenery.drawCursor(overBadge ? .dragCopy : .arrow, at: pointer, on: bitmap)
                try sequence.add(bitmap.image)
            }
        }
    }

    /// What a dragged file is called on the Desktop.
    private func fileName(_ drag: Drag) -> String {
        drag.file == "bolt.svg" ? "logo.svg" : drag.file
    }

    // MARK: - The buttons on a folder

    /// The three buttons on a folder, each used: one takes the picture off, one picks a new one
    /// from the panel it opens, and one opens the folder in the window.
    func renderButtons() async throws {
        typealias Action = HoverButtonsController.Action
        let size = Self.tile
        let wallpaper = Scenery.wallpaper(size: size)
        let name = "Nature", chosen = "frog.jpg"
        let frame = CGRect(x: 128, y: 170, width: 160, height: 160)
        let first = try icon(Folder(name: name, picture: "leaf.jpg"), side: frame.width)
        let plain = icon(nil, side: frame.width)
        let last = try icon(Folder(name: name, picture: chosen), side: frame.width)
        let all: [Action] = [.choose, .remove, .settings], withoutRemove: [Action] = [.choose, .settings]

        // The buttons, as the app lays them out on the folder: all three once it has a picture.
        struct Bar {
            let image: CGImage
            let frame: CGRect
        }
        let layouts = [3: HoverBarView.Layout(icon: Stage.appKitRect(frame), buttonCount: 3), 2: HoverBarView.Layout(icon: Stage.appKitRect(frame), buttonCount: 2)]
        func bar(_ actions: [Action], highlight: Action? = nil, pressed: Bool = false) -> Bar {
            let layout = layouts[actions.count]!
            let view = HoverBarView()
            view.configure(actions: actions, layout: layout)
            view.highlight(highlight, pressed: pressed)
            return Bar(image: sprite(of: view, size: layout.barFrame.size), frame: Stage.stageRect(fromAppKit: layout.barFrame))
        }
        func button(_ action: Action, in actions: [Action]) -> CGPoint {
            let layout = layouts[actions.count]!
            let index = CGFloat(actions.firstIndex(of: action)!)
            let bar = Stage.stageRect(fromAppKit: layout.barFrame)
            return CGPoint(
                x: bar.minX + layout.padding + index * (layout.buttonSize + layout.spacing) + layout.buttonSize / 2,
                y: bar.minY + layout.padding + layout.buttonSize / 2
            )
        }
        let bars: (rest: Bar, trash: Bar, trashPressed: Bar) = (bar(all), bar(all, highlight: .remove), bar(all, highlight: .remove, pressed: true))
        let plainBars: (rest: Bar, choose: Bar, choosePressed: Bar) = (bar(withoutRemove), bar(withoutRemove, highlight: .choose), bar(withoutRemove, highlight: .choose, pressed: true))
        let lastBars: (rest: Bar, settings: Bar, settingsPressed: Bar) = (bar(all), bar(all, highlight: .settings), bar(all, highlight: .settings, pressed: true))

        // The panel Choose opens.
        let files = ["turtle.jpg", chosen, "oranges.jpg", "peony.jpg", "aurora.jpg", "dragonfruit.jpg"]
        let panel = Scenery.OpenPanel(
            frame: CGRect(x: 73, y: 150, width: 270, height: 218),
            pictures: try files.map { file in
                (try picture(file).bitmap(maxSide: 512)!, file)
            }
        )
        let pick = files.firstIndex(of: chosen)!

        // The window it opens.
        let folder = try await makeFolder(name, picture: chosen)
        let controller = EditorWindowController(actions: actions)
        let window = controller.window!
        controller.model.show([folder])
        park(window)
        try await settleUntilShown(controller.model, in: window)
        let windowImage = snapshot(window)
        let windowSize = window.frame.size
        window.close()

        // What happens when. Remove:
        let shown = 1.0, onTrash = 1.6, trashPress = 1.85, trashRelease = 2.0
        // Choose, on the folder that has no picture now:
        let shownAgain = 2.2, onChoose = 2.8, choosePress = 3.05, chooseRelease = 3.2
        let panelShown = 3.25, picked = 4.1, openPress = 4.9, panelGone = 5.0, landed = 5.1
        // The window:
        let shownLast = 5.5, onSettings = 6.0, settingsPress = 6.25, settingsRelease = 6.4, windowShown = 6.5

        let over = CGPoint(x: frame.midX + 12, y: frame.midY + 24)
        let thumbnail = panel.thumbnails[pick].frame
        var path = PointerPath(start: CGPoint(x: 350, y: 490))
        path.move(to: over, from: 0.2, to: 0.9)
        path.move(to: button(.remove, in: all), from: 1.25, to: onTrash, arc: 0.05)
        path.move(to: button(.choose, in: withoutRemove), from: 2.45, to: onChoose, arc: 0.05)
        path.move(to: CGPoint(x: thumbnail.midX + 6, y: thumbnail.midY + 4), from: 3.5, to: 3.95, arc: 0.05)
        path.move(to: CGPoint(x: panel.open.midX, y: panel.open.midY), from: 4.3, to: 4.75, arc: 0.05)
        path.move(to: over, from: 5.05, to: 5.45, arc: 0.05)
        path.move(to: button(.settings, in: all), from: 5.65, to: onSettings, arc: 0.05)
        path.move(to: CGPoint(x: 22, y: 524), from: 7.0, to: 7.6)

        let windowScale: CGFloat = 1
        let windowOrigin = CGPoint(x: (size.width - windowSize.width) / 2, y: (size.height - windowSize.height) / 2)
        let sequence = try frameSequence("buttons")
        for index in 0..<frameCount(8.2) {
            // A frame's images go once it's written, not when the whole scene is done.
            try autoreleasepool {
                let t = Double(index) / Stage.framesPerSecond
                let pointer = path.position(at: t)

                let bitmap = Bitmap(size: size)
                bitmap.draw(wallpaper, in: CGRect(origin: .zero, size: size))
                let bounce = t >= landed && t < landed + 0.32 ? 1 + 0.07 * CGFloat(sin((t - landed) / 0.32 * .pi)) : 1
                let folderFrame = frame.insetBy(dx: frame.width * (1 - bounce) / 2, dy: frame.height * (1 - bounce) / 2)
                let image = t >= landed ? last : t >= trashRelease + 0.05 ? plain : first
                Scenery.drawItem(on: bitmap, icon: image, frame: folderFrame, name: name)

                var cursor = NSCursor.arrow
                if t >= shown && t < trashRelease {
                    let item = t >= trashPress ? bars.trashPressed : t >= onTrash ? bars.trash : bars.rest
                    drawBar(item.image, in: item.frame, alpha: CGFloat(progress(t, shown, shown + 0.12)), on: bitmap)
                    if t >= onTrash { cursor = .pointingHand }
                }
                if t >= shownAgain && t < chooseRelease {
                    let item = t >= choosePress ? plainBars.choosePressed : t >= onChoose ? plainBars.choose : plainBars.rest
                    drawBar(item.image, in: item.frame, alpha: CGFloat(progress(t, shownAgain, shownAgain + 0.12)), on: bitmap)
                    if t >= onChoose { cursor = .pointingHand }
                }
                if t >= shownLast && t < settingsRelease {
                    let item = t >= settingsPress ? lastBars.settingsPressed : t >= onSettings ? lastBars.settings : lastBars.rest
                    drawBar(item.image, in: item.frame, alpha: CGFloat(progress(t, shownLast, shownLast + 0.12)), on: bitmap)
                    if t >= onSettings { cursor = .pointingHand }
                }
                if t >= panelShown && t < panelGone + 0.15 {
                    let alpha = min(progress(t, panelShown, panelShown + 0.15), 1 - progress(t, panelGone, panelGone + 0.15))
                    Scenery.drawOpenPanel(panel, selected: t >= picked ? pick : nil, pressingOpen: t >= openPress, alpha: CGFloat(alpha), on: bitmap)
                }
                if t >= windowShown {
                    let appear = ease(progress(t, windowShown, windowShown + 0.25))
                    Scenery.drawWindow(
                        windowImage, at: windowOrigin, size: windowSize, on: bitmap,
                        alpha: CGFloat(appear), scale: windowScale * (0.94 + 0.06 * CGFloat(appear))
                    )
                }
                // Each click where the pointer is.
                for press in [trashPress, choosePress, picked, openPress, settingsPress] {
                    Scenery.drawClick(at: path.position(at: press), amount: progress(t, press - 0.05, press + 0.35), on: bitmap)
                }
                Scenery.drawCursor(cursor, at: pointer, on: bitmap)
                try sequence.add(bitmap.image)
            }
        }
    }

    /// The buttons on a folder, with the shadow the system gives their window.
    private func drawBar(_ image: CGImage, in frame: CGRect, alpha: CGFloat, on bitmap: Bitmap) {
        bitmap.context.saveGState()
        bitmap.context.setAlpha(alpha)
        bitmap.withShadow(color: CGColor(gray: 0, alpha: 0.4), blur: 7, offset: CGSize(width: 0, height: 2.5)) {
            bitmap.draw(image, in: frame)
        }
        bitmap.context.restoreGState()
    }

    // MARK: - The window

    /// What a hand does in the window for a while: pinch, drag the frame or a handle, hold the
    /// picture with the right button, or drag the dial; each by as much over its time.
    private enum Grip {
        /// Spreading two fingers until the frame is `exp(growth)` times as big.
        case pinch(growth: Double)
        case frame
        case handle(ResizeHandle)
        case picture
        case dial(degrees: Double)
    }

    private struct Hold {
        let grip: Grip
        let start: Double
        let end: Double

        /// How far the hand has got at `t`: done a little before letting go.
        func amount(at t: Double) -> Double { ease(progress(t, start, end - 0.15)) }
    }

    /// Something done at a moment in a scene. Scenes go on once it has been done.
    private struct Step {
        let time: Double
        /// A click shows where the pointer is.
        var clicks = true
        let action: (EditorModel, DesktopRow, Double) async -> Void
    }

    /// A scene in the window: where the pointer goes, what it holds when, and what is done.
    private struct WindowScript {
        var duration: Double
        var pointer: PointerPath
        var holds: [Hold] = []
        var steps: [Step] = []
        /// When the window comes up, if it isn't there from the start.
        var windowShownAt: Double?
        /// Drawn over the window: a question, keys being pressed, what is being dragged.
        var overlay: ((Bitmap, Double) -> Void)?
    }

    /// Where things are on the stage of a window scene, to plan it by.
    private struct WindowShot {
        let size: CGSize
        let windowOrigin: CGPoint
        let windowSize: CGSize
        /// How big the window is drawn: smaller when it shares the stage with folders.
        let scale: CGFloat
        let controls: WindowControls
        let row: DesktopRow

        func onStage(_ point: CGPoint) -> CGPoint {
            CGPoint(x: windowOrigin.x + point.x * scale, y: windowOrigin.y + point.y * scale)
        }

        func onStage(_ rect: CGRect) -> CGRect {
            let origin = onStage(rect.origin)
            return CGRect(x: origin.x, y: origin.y, width: rect.width * scale, height: rect.height * scale)
        }

        /// The picture's frame for `style`, on the stage.
        func pictureFrame(_ style: IconStyle) -> CGRect {
            let editor = controls.editor
            return onStage(IconGeometry.targetRect(for: style, canvas: editor.width, flipped: true).offsetBy(dx: editor.minX, dy: editor.minY))
        }

        var editor: CGRect { onStage(controls.editor) }
        var dial: CGRect { onStage(controls.dial) }
        var fill: CGPoint { onStage(CGPoint(x: controls.scaling.minX + controls.scaling.width / 4, y: controls.scaling.midY)) }
        var fit: CGPoint { onStage(CGPoint(x: controls.scaling.maxX - controls.scaling.width / 4, y: controls.scaling.midY)) }
        /// The buttons that turn the picture a quarter turn, on either side of the dial.
        var turnLeft: CGPoint { onStage(CGPoint(x: controls.dial.minX - 21, y: controls.dial.midY)) }
        var turnRight: CGPoint { onStage(CGPoint(x: controls.dial.maxX + 21, y: controls.dial.midY)) }
        var gear: CGPoint { onStage(CGPoint(x: windowSize.width - 27, y: 48)) }
        /// Save or Done.
        var lastButton: CGPoint {
            let button = controls.buttons.last ?? .zero
            return onStage(CGPoint(x: button.midX, y: button.midY))
        }
        /// Somewhere to rest the pointer, out of the way.
        var rest: CGPoint { CGPoint(x: 22, y: size.height - 24) }
    }

    /// What is on the Desktop above the window in a scene that has folders in it too.
    private struct DesktopItem {
        let name: String
        var picture: String?
        var look = Look.standard
        /// A picture file, and no folder.
        var isFile = false
        /// It changes along with what the window shows.
        var follows = false
        var isHidden = false
        var isSelected = false
    }

    /// The Desktop's items as they are at a moment in a scene.
    @MainActor
    private final class DesktopRow {
        var items: [DesktopItem]
        let frames: [CGRect]
        var icons: [CGImage] = []
        var previous: [CGImage?]
        var changedAt: [Double]
        var pictures: [SourceImage?] = []

        init(items: [DesktopItem], frames: [CGRect]) {
            self.items = items
            self.frames = frames
            previous = Array(repeating: nil, count: items.count)
            changedAt = Array(repeating: -10, count: items.count)
        }

        func set(_ index: Int, to icon: CGImage, at t: Double) {
            previous[index] = icons[index]
            icons[index] = icon
            changedAt[index] = t
        }

        func draw(on bitmap: Bitmap, at t: Double) {
            for index in items.indices where !items[index].isHidden {
                let frame = frames[index], name = items[index].name
                let fade = progress(t, changedAt[index], changedAt[index] + 0.2)
                if let before = previous[index], fade < 1 {
                    bitmap.draw(before, in: frame)
                    bitmap.draw(icons[index], in: frame, alpha: CGFloat(fade))
                    Scenery.drawLabel(name, on: bitmap, below: frame, selected: false)
                } else {
                    Scenery.drawItem(on: bitmap, icon: icons[index], frame: frame, name: name, selected: items[index].isSelected)
                }
            }
        }
    }

    /// Shoots a scene in the window, for `folders`: the folder and whatever `open` says, or the
    /// default look when that's nothing. With `desktop`, those items sit above a smaller window,
    /// following every change made in it. The pinch and the dial go through the
    /// editor's own code, step by step; drags through the same moving and snapping code they use.
    /// (A window off screen gets no events.)
    private func shootWindow(
        _ name: String,
        desktop: [DesktopItem] = [],
        open: () async throws -> [URL],
        picture pictureName: String? = nil,
        plan: (WindowShot, EditorModel) -> WindowScript
    ) async throws {
        let folders = try await open()
        let pictureForDrags = try pictureName.map(picture)
        let controller = EditorWindowController(actions: actions)
        let model = controller.model
        let window = controller.window!
        model.show(folders)
        park(window)
        if pictureName != nil {
            try await settleUntilShown(model, in: window)
        } else {
            for _ in 0..<40 where model.isLoadingPicture { await settle(window, milliseconds: 50) }
            await settle(window, milliseconds: 400)
        }

        let windowSize = window.frame.size
        guard let controls = controls(of: window) else { throw MediaError("Couldn't find the window's controls") }
        let size = Self.tile
        let scale: CGFloat = desktop.isEmpty ? 1 : 0.66
        let windowOrigin = desktop.isEmpty
            ? CGPoint(x: ((size.width - windowSize.width) / 2).rounded(), y: ((size.height - windowSize.height) / 2).rounded())
            : CGPoint(x: ((size.width - windowSize.width * scale) / 2).rounded(), y: (size.height - windowSize.height * scale - 14).rounded())

        let side84 = desktop.count > 2
        let row = DesktopRow(
            items: desktop,
            frames: desktop.isEmpty ? [] : self.row(count: desktop.count, side: side84 ? 86 : 112, top: side84 ? 42 : 26, spacing: side84 ? 102 : 150, width: size.width)
        )
        for (item, frame) in zip(desktop, row.frames) {
            let source = try item.picture.map(picture)
            row.pictures.append(source)
            if item.isFile {
                let file = NSImage(contentsOf: pictureURL(item.picture!))!.cgImage(forProposedRect: nil, context: nil, hints: nil)!
                row.icons.append(Scenery.thumbnail(of: file, fitting: frame.width))
            } else {
                row.icons.append(icon(source, style: item.look.style, placement: item.look.placement, side: frame.width))
            }
        }

        let shot = WindowShot(size: size, windowOrigin: windowOrigin, windowSize: windowSize, scale: scale, controls: controls, row: row)
        let script = plan(shot, model)
        let wallpaper = Scenery.wallpaper(size: size)
        let editorView = controls.editorView, dialView = controls.dialView
        let side = controls.editor.width
        let snapping = StyleEditor.snapping(side: side)

        func inWindow(_ point: CGPoint) -> CGPoint {
            CGPoint(x: (point.x - windowOrigin.x) / scale, y: (point.y - windowOrigin.y) / scale)
        }
        /// The editor's own view of a point in the window: what is there, the way it decides.
        func editorPoint(_ local: CGPoint) -> CGPoint {
            editorView.convert(NSPoint(x: local.x, y: windowSize.height - local.y), from: nil)
        }
        func pointerEvent(_ local: CGPoint) -> NSEvent {
            NSEvent.mouseEvent(
                with: .mouseMoved, location: NSPoint(x: local.x, y: windowSize.height - local.y), modifierFlags: [],
                timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0
            )!
        }

        var drawn = (style: model.style, placement: model.placement)
        var held: (index: Int, start: (style: IconStyle, placement: PicturePlacement, pointer: CGPoint, turn: Double))?
        var pinched = 0.0
        var pointerInEditor = false
        let sequence = try frameSequence(name)
        for index in 0..<frameCount(script.duration) {
            let t = Double(index) / Stage.framesPerSecond
            let pointer = script.pointer.position(at: t)
            let local = inWindow(pointer)

            let holding = script.holds.firstIndex { t >= $0.start && t < $0.end }
            if holding != held?.index {
                if let held {
                    switch script.holds[held.index].grip {
                    case .pinch: editorView.pinch(.ended, by: 0, modifiers: [])
                    case .dial: editorView.endDialTurn(restoring: false)
                    case .picture, .frame, .handle:
                        model.guides = []
                        model.isAdjusting = false
                        model.commit()
                    }
                }
                held = nil
                if let holding {
                    held = (holding, (model.style, model.placement, pointer, model.placement.rotation))
                    pinched = 0
                    switch script.holds[holding].grip {
                    case .pinch: editorView.pinch(.began, by: 0, modifiers: [])
                    case .dial:
                        guard editorView.beginDialTurn() else { throw MediaError("The dial wouldn't turn") }
                    case .picture, .frame, .handle:
                        model.beginChange(holding: true)
                        model.isAdjusting = true
                    }
                }
            }
            if let held {
                let hold = script.holds[held.index]
                let moved = CGSize(width: (pointer.x - held.start.pointer.x) / scale, height: (pointer.y - held.start.pointer.y) / scale)
                switch hold.grip {
                case .pinch(let growth):
                    let spread = growth * hold.amount(at: t)
                    editorView.pinch(.changed, by: spread - pinched, modifiers: [])
                    pinched = spread
                case .dial(let degrees):
                    editorView.dialTurn(to: (held.start.turn + degrees * hold.amount(at: t)).rounded(), modifiers: [], reach: TurnDialView.reach)
                case .frame:
                    let snapped = snapping.move(held.start.style.rect.offsetBy(dx: moved.width / side, dy: moved.height / side))
                    var style = model.style
                    style.rect = snapped.rect
                    model.style = style
                    model.guides = snapped.guides
                case .handle(let handle):
                    let resized = handle.resize(held.start.style.rect, dx: moved.width / side, dy: moved.height / side, keepRatio: false, fromCenter: false)
                    let snapped = snapping.resize(resized, moving: handle.edges, symmetric: false)
                    var style = model.style
                    style.rect = snapped.rect
                    model.style = style
                    model.guides = snapped.guides
                case .picture:
                    let placed = IconGeometry.placement(
                        held.start.placement, movedBy: moved,
                        imageSize: pictureForDrags?.size ?? .zero, style: model.style, canvas: side, folder: StyleEditorView.folderEdges
                    )
                    let snapped = snapping.pan(placed, imageSize: pictureForDrags?.size ?? .zero, style: model.style, canvas: side, folder: StyleEditorView.folderEdges)
                    model.placement = snapped.placement
                    model.guides = snapped.guides
                }
            } else {
                // Pointing, not holding: the editor shows what is under the pointer, and its
                // frame only while the pointer is over it.
                let inEditor = editorView.bounds.contains(editorPoint(local))
                if inEditor {
                    editorView.mouseMoved(with: pointerEvent(local))
                } else if pointerInEditor {
                    editorView.mouseExited(with: pointerEvent(local))
                }
                pointerInEditor = inEditor
            }
            for step in script.steps where index == frameCount(step.time) {
                await step.action(model, row, t)
            }
            await settle(window, milliseconds: 15)

            // What follows the window shows each change once it's written.
            if held == nil, model.style != drawn.style || model.placement != drawn.placement {
                drawn = (model.style, model.placement)
                for position in row.items.indices where row.items[position].follows {
                    row.set(position, to: icon(row.pictures[position], style: drawn.style, placement: drawn.placement, side: row.frames[position].width), at: t + 0.15)
                }
            }

            try autoreleasepool {
                let bitmap = Bitmap(size: size)
                bitmap.draw(wallpaper, in: CGRect(origin: .zero, size: size))
                row.draw(on: bitmap, at: t)
                let shown = script.windowShownAt.map { ease(progress(t, $0, $0 + 0.25)) } ?? 1
                if shown > 0 {
                    Scenery.drawWindow(
                        snapshot(window),
                        at: CGPoint(x: windowOrigin.x - windowSize.width * (1 - scale) / 2, y: windowOrigin.y - windowSize.height * (1 - scale) / 2),
                        size: windowSize, on: bitmap, alpha: CGFloat(shown), scale: scale
                    )
                }

                for hold in script.holds where t >= hold.start - 0.15 && t < hold.end + 0.2 {
                    let shown = min(progress(t, hold.start - 0.15, hold.start + 0.05), 1 - progress(t, hold.end - 0.05, hold.end + 0.15))
                    switch hold.grip {
                    case .picture:
                        let shown = min(progress(t, hold.start - 0.12, hold.start + 0.04), 1 - progress(t, hold.end, hold.end + 0.2))
                        Scenery.drawRightButton(beside: pointer, alpha: shown, on: bitmap)
                    case .pinch(let growth):
                        // Spreading to make the frame bigger, closing to make it smaller.
                        let amount = hold.amount(at: t)
                        Scenery.drawPinch(around: pointer, spread: growth < 0 ? 1 - amount : amount, alpha: shown, on: bitmap)
                    case .dial, .frame, .handle:
                        break
                    }
                }
                script.overlay?(bitmap, t)
                for step in script.steps where step.clicks {
                    Scenery.drawClick(at: script.pointer.position(at: step.time), amount: progress(t, step.time - 0.05, step.time + 0.35), on: bitmap)
                }
                let cursor: NSCursor = if let held {
                    switch script.holds[held.index].grip {
                    case .picture, .dial, .frame: NSCursor.closedHand
                    case .pinch, .handle: editorView.cursor(for: editorView.part(at: editorPoint(local)))
                    }
                } else if shot.dial.contains(pointer), dialView.isEnabled {
                    NSCursor.openHand
                } else if editorView.bounds.contains(editorPoint(local)) {
                    editorView.cursor(for: editorView.part(at: editorPoint(local)))
                } else {
                    NSCursor.arrow
                }
                Scenery.drawCursor(cursor, at: pointer, on: bitmap)
                try sequence.add(bitmap.image)
            }
        }
        window.close()
    }

    /// One folder with `picture` on it, in a window that fills the stage.
    private func shootWindow(_ name: String, folder: String, picture: String, plan: (WindowShot, EditorModel) -> WindowScript) async throws {
        try await shootWindow(name, open: { [try await makeFolder(folder, picture: picture)] }, picture: picture, plan: plan)
    }

    /// The frame: its handles give it any shape, it goes anywhere, and two fingers take it well past
    /// the folder's edges, where dragging it chooses the part that shows.
    func renderFrame() async throws {
        try await shootWindow("frame", folder: "Islands", picture: "lagoon.jpg") { shot, model in
            let frame = shot.pictureFrame(model.style)
            let corner = CGPoint(x: frame.maxX, y: frame.maxY)
            let shaped = CGPoint(x: corner.x - ReadmeTuning.shape.width, y: corner.y - ReadmeTuning.shape.height)
            let hold = CGPoint(x: (frame.minX + shaped.x) / 2, y: (frame.minY + shaped.y) / 2)
            let moved = CGPoint(x: hold.x + ReadmeTuning.anywhere.width, y: hold.y + ReadmeTuning.anywhere.height)
            var path = PointerPath(start: shot.rest)
            path.move(to: corner, from: 0.1, to: 0.55)
            path.move(to: shaped, from: 0.65, to: 1.35, arc: 0)
            path.move(to: hold, from: 1.5, to: 1.8)
            path.move(to: moved, from: 1.95, to: 2.65, arc: -0.05)
            path.move(to: CGPoint(x: moved.x, y: moved.y + 12), from: 4.45, to: 4.6, arc: 0)
            path.move(to: CGPoint(x: moved.x + ReadmeTuning.zoomSlide.width, y: moved.y + 12 + ReadmeTuning.zoomSlide.height), from: 4.7, to: 5.5, arc: 0.04)
            path.move(to: shot.rest, from: 5.9, to: 6.4)
            return WindowScript(
                duration: 6.7, pointer: path,
                holds: [Hold(grip: .handle(.bottomRight), start: 0.65, end: 1.45),
                        Hold(grip: .frame, start: 1.9, end: 2.8),
                        Hold(grip: .pinch(growth: log(ReadmeTuning.zoomFactor)), start: 2.95, end: 4.4),
                        Hold(grip: .frame, start: 4.65, end: 5.65)]
            )
        }
    }

    /// The picture in its frame: Fit or Fill, the right button chooses the part that shows, the dial
    /// and the buttons beside it turn it, and ⌘Z takes back the last step.
    func renderPicture() async throws {
        try await shootWindow("picture", folder: "Flamingos", picture: "flamingo.jpg") { shot, model in
            let frame = shot.pictureFrame(model.style)
            let over = CGPoint(x: frame.midX + 12, y: frame.midY - 4)
            let grab = CGPoint(x: shot.dial.midX - 2, y: shot.dial.midY + 5)
            let undone = 5.75
            var path = PointerPath(start: shot.rest)
            path.move(to: shot.fit, from: 0.1, to: 0.5)
            path.move(to: shot.fill, from: 1.05, to: 1.35, arc: 0)
            path.move(to: over, from: 1.6, to: 1.95)
            path.move(to: CGPoint(x: over.x, y: over.y + ReadmeTuning.tallSlide), from: 2.05, to: 2.85, arc: 0.02)
            path.move(to: grab, from: 3.0, to: 3.35)
            path.move(to: CGPoint(x: grab.x - CGFloat(ReadmeTuning.tilt) * TurnDialView.pointsPerDegree, y: grab.y), from: 3.45, to: 4.2, arc: 0)
            path.move(to: shot.turnRight, from: 4.4, to: 4.8, arc: 0.03)
            path.move(to: shot.rest, from: 6.2, to: 6.7)
            return WindowScript(
                duration: 7.0, pointer: path,
                holds: [Hold(grip: .picture, start: 2.0, end: 3.0),
                        Hold(grip: .dial(degrees: -ReadmeTuning.tilt), start: 3.45, end: 4.35)],
                steps: [Step(time: 0.6) { model, _, _ in model.setMode(.fit) },
                        Step(time: 1.45) { model, _, _ in model.setMode(.fill) },
                        Step(time: 4.9) { model, _, _ in model.rotatePicture(clockwise: true) },
                        Step(time: undone, clicks: false) { model, _, _ in model.undoManager?.undo() }],
                overlay: { bitmap, t in
                    Scenery.drawKeys(["⌘", "Z"], alpha: min(progress(t, undone - 0.1, undone), 1 - progress(t, undone + 0.55, undone + 0.65)), on: bitmap)
                }
            )
        }
    }

    /// Several folders: selected, right-clicked, given one picture by dropping it on the window, and
    /// from then on they change together.
    func renderSeveral() async throws {
        let names = ["Spain", "Greece", "Italy"], file = "beach.jpg"
        var opened: [URL] = []
        var items = names.map { DesktopItem(name: $0, follows: true) }
        items.append(DesktopItem(name: file, picture: file, isFile: true))
        try await shootWindow("several", desktop: items, open: {
            opened = []
            for name in names { opened.append(try await makeFolder(name)) }
            return opened
        }) { shot, model in
            let frames = shot.row.frames
            let boxFrom = CGPoint(x: frames[0].minX - 8, y: frames[0].minY - 12)
            let boxTo = CGPoint(x: frames[2].maxX + 2, y: frames[2].maxY + 26)
            let onFolder = CGPoint(x: frames[1].midX + 4, y: frames[1].midY + 6)
            let menu = Scenery.ContextMenu(
                items: ["Open", nil, "Move to Trash", nil, "Get Info", "Compress 3 Items", "Duplicate", nil, "Folder Picture…"],
                at: CGPoint(x: onFolder.x + 4, y: onFolder.y + 2)
            )
            let item = menu.items.count - 1
            let row = menu.row(item)
            let fileFrame = frames[3]
            let press = CGPoint(x: fileFrame.midX + 6, y: fileFrame.midY + 8)
            let onEditor = CGPoint(x: shot.editor.midX, y: shot.editor.midY + 14)
            let boxStart = 0.5, boxEnd = 1.05, opens = 1.45, chosen = 2.1, windowAt = 2.25, pressed = 2.85, release = 3.95
            var path = PointerPath(start: shot.rest)
            path.move(to: boxFrom, from: 0.05, to: 0.45)
            path.move(to: boxTo, from: boxStart, to: boxEnd, arc: 0)
            path.move(to: onFolder, from: 1.1, to: 1.35)
            path.move(to: CGPoint(x: row.midX - 30, y: row.midY), from: 1.55, to: 1.95, arc: 0.04)
            path.move(to: press, from: 2.3, to: 2.7, arc: 0.03)
            path.move(to: onEditor, from: 2.95, to: 3.8, arc: 0.08)
            path.move(to: CGPoint(x: onEditor.x, y: onEditor.y + 4), from: 4.4, to: 4.5, arc: 0)
            path.move(to: shot.rest, from: 5.85, to: 6.35)
            let frameOffset = CGPoint(x: fileFrame.minX - press.x, y: fileFrame.minY - press.y)
            let pointer = path
            return WindowScript(
                duration: 6.6, pointer: path,
                holds: [Hold(grip: .pinch(growth: log(ReadmeTuning.coverGrowth)), start: 4.55, end: 5.8)],
                steps: [
                    Step(time: 0.75, clicks: false) { _, row, _ in row.items[0].isSelected = true },
                    Step(time: 0.88, clicks: false) { _, row, _ in row.items[1].isSelected = true },
                    Step(time: 1.0, clicks: false) { _, row, _ in row.items[2].isSelected = true },
                    Step(time: opens) { _, _, _ in },
                    Step(time: chosen) { _, _, _ in },
                    Step(time: pressed) { _, row, _ in
                        for position in 0..<3 { row.items[position].isSelected = false }
                    },
                    Step(time: release) { [self] model, row, t in
                        await actions.apply(imageAt: pictureURL(file), to: opened)
                        model.reload()
                        for _ in 0..<200 where !model.hasPicture { await settle(milliseconds: 50) }
                        let source = try? picture(file)
                        for position in 0..<3 {
                            row.pictures[position] = source
                            row.set(position, to: icon(source, style: model.style, placement: model.placement, side: row.frames[position].width), at: t + 0.1 * Double(position))
                        }
                    },
                ],
                windowShownAt: windowAt,
                overlay: { bitmap, t in
                    if t >= boxStart, t < boxEnd + 0.1 {
                        let at = pointer.position(at: t)
                        let box = CGRect(x: boxFrom.x, y: boxFrom.y, width: at.x - boxFrom.x, height: at.y - boxFrom.y)
                        bitmap.context.setFillColor(CGColor(gray: 1, alpha: 0.18))
                        bitmap.context.fill(box)
                        bitmap.context.setStrokeColor(CGColor(gray: 1, alpha: 0.75))
                        bitmap.context.setLineWidth(1)
                        bitmap.context.stroke(box)
                    }
                    Scenery.drawContextMenu(menu, highlighted: t >= 1.8 ? item : nil, alpha: t >= opens && t < chosen ? CGFloat(progress(t, opens, opens + 0.1)) : 0, on: bitmap)
                    guard t >= pressed, t < release else { return }
                    let at = pointer.position(at: t)
                    let frame = CGRect(x: at.x + frameOffset.x, y: at.y + frameOffset.y, width: fileFrame.width, height: fileFrame.height)
                    Scenery.drawDropRing(around: shot.editor.insetBy(dx: -18, dy: -10), alpha: progress(t, 3.3, 3.6), on: bitmap)
                    bitmap.context.saveGState()
                    bitmap.context.setAlpha(0.75)
                    bitmap.draw(shot.row.icons[3], in: frame)
                    bitmap.context.restoreGState()
                }
            )
        }
    }

    /// Every folder at once: a copy keeps its picture and counts as a folder of its own, a new default
    /// look reaches them all after a question, and everything comes off again behind the gear.
    func renderEverything() async throws {
        let items = [DesktopItem(name: "Wildlife", picture: "frog.jpg"),
                     DesktopItem(name: "Summer", picture: "oranges.jpg"),
                     DesktopItem(name: "Summer copy", picture: "oranges.jpg", isHidden: true)]
        let newLook = Scenery.Question(
            title: "Update existing folders too?", message: "3 folders use the default look. They can switch to the new look now, or keep their current look while only new pictures get the new one.",
            buttons: [("Update All 3 Folders", NSColor.systemBlue), ("Only New Pictures", nil), ("Cancel", nil)],
            centeredAt: CGPoint(x: Self.tile.width / 2, y: 330)
        )
        let removal = Scenery.Question(
            title: "Remove the pictures from all 3 folders?", message: "The folders go back to the standard icon. The pictures themselves are not touched.",
            buttons: [("Remove 3 Pictures", NSColor.systemRed), ("Cancel", nil)],
            centeredAt: CGPoint(x: Self.tile.width / 2, y: 320)
        )
        // Behind the gear, as it is in the window with folders to act on.
        for item in items { _ = try await makeFolder(item.name, picture: item.picture) }
        let controller = EditorWindowController(actions: actions)
        let settingsView = NSHostingView(rootView: PreferencesView(settings: settings, model: controller.model, dismiss: {}))
        let settingsSize = settingsView.fittingSize
        _ = sprite(of: settingsView, size: settingsSize)
        await settle(milliseconds: 2500)
        let settingsSprite = sprite(of: settingsView, size: settingsSize)
        let panelScale: CGFloat = 0.8
        let panel = CGRect(
            x: Self.tile.width - settingsSize.width * panelScale - 12, y: 150,
            width: settingsSize.width * panelScale, height: settingsSize.height * panelScale
        )
        try await shootWindow("everything", desktop: items, open: { [] }) { shot, model in
            let from = shot.row.frames[1], to = shot.row.frames[2]
            let frame = shot.pictureFrame(model.style)
            let press = CGPoint(x: from.midX, y: from.midY + 6), land = CGPoint(x: to.midX, y: to.midY + 6)
            let removeAll = CGPoint(x: panel.midX - 40, y: panel.minY + panel.height * ReadmeTuning.removeAllRow)
            let dropped = 1.25, windowAt = 1.4, saved = 3.2, answered = 4.3, gearAt = 4.85, panelGone = 5.45, removed = 6.45
            var path = PointerPath(start: shot.rest)
            path.move(to: press, from: 0.05, to: 0.45)
            path.move(to: land, from: 0.55, to: 1.15, arc: -0.08)
            path.move(to: CGPoint(x: frame.midX + 6, y: frame.midY + 6), from: 1.45, to: 1.85)
            path.move(to: shot.lastButton, from: 2.75, to: 3.1)
            path.move(to: CGPoint(x: newLook.buttons[0].frame.midX + 40, y: newLook.buttons[0].frame.midY), from: 3.5, to: 4.1)
            path.move(to: shot.gear, from: 4.45, to: 4.75)
            path.move(to: removeAll, from: 5.0, to: 5.35)
            path.move(to: CGPoint(x: removal.buttons[0].frame.midX + 30, y: removal.buttons[0].frame.midY), from: 5.65, to: 6.3)
            path.move(to: shot.rest, from: 6.75, to: 7.2)
            let pointer = path
            return WindowScript(
                duration: 7.5, pointer: path,
                holds: [Hold(grip: .pinch(growth: log(0.62)), start: 1.9, end: 2.7)],
                steps: [
                    Step(time: 0.5, clicks: false) { _, _, _ in },
                    Step(time: dropped) { _, row, _ in row.items[2].isHidden = false },
                    Step(time: saved) { _, _, _ in },
                    Step(time: answered) { [self] model, row, t in
                        settings.defaultStyle = model.defaultDraft
                        for position in row.items.indices {
                            row.set(position, to: icon(row.pictures[position], style: settings.defaultStyle, side: row.frames[position].width), at: t + 0.1 * Double(position))
                        }
                    },
                    Step(time: gearAt) { _, _, _ in },
                    Step(time: panelGone) { _, _, _ in },
                    Step(time: removed) { [self] _, row, t in
                        for position in row.items.indices {
                            row.set(position, to: icon(nil, side: row.frames[position].width), at: t + 0.1 * Double(position))
                        }
                    },
                ],
                windowShownAt: windowAt,
                overlay: { bitmap, t in
                    Scenery.drawKeys(["⌥"], alpha: min(progress(t, 0.4, 0.5), 1 - progress(t, dropped, dropped + 0.1)), on: bitmap)
                    if t >= 0.5, t < dropped {
                        let at = pointer.position(at: t)
                        bitmap.context.saveGState()
                        bitmap.context.setAlpha(0.75)
                        bitmap.draw(shot.row.icons[1], in: CGRect(x: at.x - from.width / 2, y: at.y - from.height / 2 - 6, width: from.width, height: from.height))
                        bitmap.context.restoreGState()
                    }
                    if t >= saved, t < answered + 0.2 {
                        Scenery.drawQuestion(newLook, pressing: t >= answered - 0.1 ? 0 : nil,
                                             alpha: min(progress(t, saved, saved + 0.15), 1 - progress(t, answered, answered + 0.15)), on: bitmap)
                    }
                    if t >= gearAt, t < panelGone + 0.15 {
                        let alpha = min(progress(t, gearAt, gearAt + 0.15), 1 - progress(t, panelGone, panelGone + 0.15))
                        bitmap.context.saveGState()
                        bitmap.context.setAlpha(CGFloat(alpha))
                        bitmap.withShadow(color: CGColor(gray: 0, alpha: 0.5), blur: 20, offset: CGSize(width: 0, height: 8)) {
                            bitmap.context.addPath(CGPath(roundedRect: panel, cornerWidth: 14, cornerHeight: 14, transform: nil))
                            bitmap.context.setFillColor(CGColor.hex(0x262628))
                            bitmap.context.fillPath()
                        }
                        bitmap.draw(settingsSprite, in: panel)
                        bitmap.context.restoreGState()
                    }
                    if t >= panelGone, t < removed + 0.2 {
                        Scenery.drawQuestion(removal, pressing: t >= removed - 0.1 ? 0 : nil,
                                             alpha: min(progress(t, panelGone, panelGone + 0.15), 1 - progress(t, removed, removed + 0.15)), on: bitmap)
                    }
                }
            )
        }
        settings.defaultStyle = .standard
    }
}

/// Numbers that depend on the pictures: how far to zoom, slide and turn.
enum ReadmeTuning {
    /// What a handle takes off the frame, and where it goes then, in points of the window's folder (300).
    static let shape = CGSize(width: 96, height: 64)
    static let anywhere = CGSize(width: 62, height: 58)
    /// Far past the folder, from that frame.
    static let zoomFactor = 6.5
    /// Brings the palm island over the folder.
    static let zoomSlide = CGSize(width: -115, height: 0)
    /// From the flamingo's middle up to its head.
    static let tallSlide: CGFloat = 100
    /// How far the dial turns it.
    static let tilt = 18.0
    /// Past the folder's edges all around.
    static let coverGrowth = 2.45
    /// How far down behind the gear Remove All Pictures is.
    static let removeAllRow = 0.8
}

extension Stage {
    /// A rectangle on the stage in AppKit screen coordinates.
    static func appKitRect(_ rect: CGRect) -> NSRect {
        ScreenSpace.appKitRect(accessibilityRect(rect))
    }
}
#endif

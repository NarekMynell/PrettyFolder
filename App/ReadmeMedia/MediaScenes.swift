#if DEBUG
import AppKit
import PrettyFolderKit
import SwiftUI

/// The README's picture and animations, shot frame by frame.
extension Studio {
    /// How a picture sits on a folder. Every one of these is made in the window: the frame
    /// anywhere from a corner to well past the folder, Fill or Fit, the picture turned.
    private struct Look {
        var style: IconStyle
        var placement: PicturePlacement = .natural

        static let standard = Look(style: .standard)
        /// The whole folder, tab and all.
        static let cover = Look(style: IconStyle(x: 0, y: 0, width: 1, height: 1, mode: .fill))
        /// Edge to edge on the front.
        static let front = Look(style: IconStyle(x: 0, y: 0.29, width: 1, height: 0.71, mode: .fill))
        /// Small, in the bottom-right corner.
        static let corner = Look(style: IconStyle(x: 0.54, y: 0.5, width: 0.34, height: 0.27, mode: .fill))
        /// A small square in the middle.
        static let badge = Look(style: IconStyle(x: 0.33, y: 0.37, width: 0.34, height: 0.34, mode: .fill))

        /// A logo or a cut-out, the folder showing all around it.
        static let sticker = Look(style: IconStyle(x: 0.21, y: 0.31, width: 0.58, height: 0.52, mode: .fit))

        /// A frame `factor` times the folder: zoomed into the part at `x`, `y`.
        static func zoomed(_ factor: Double, x: Double = 0.5, y: Double = 0.5) -> Look {
            Look(style: IconStyle(x: 0.5 - factor / 2, y: 0.5 - factor / 2, width: factor, height: factor, mode: .fill),
                 placement: PicturePlacement(x: x, y: y))
        }

        /// The whole picture, turned `degrees` counterclockwise: a card laid on the folder.
        static func card(turned degrees: Double) -> Look {
            Look(style: IconStyle(x: 0.19, y: 0.36, width: 0.62, height: 0.45, mode: .fit),
                 placement: PicturePlacement(x: 0.5, y: 0.5, rotation: degrees))
        }
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

    private func frameCount(_ seconds: Double) -> Int {
        Int((seconds * Stage.framesPerSecond).rounded())
    }

    // MARK: - Depth

    /// Pictures that cover the whole folder, back and front, with its light and shade.
    func renderDepth() async throws {
        let size = CGSize(width: 760, height: 400)
        let bitmap = Bitmap(size: size)
        bitmap.draw(Scenery.wallpaper(size: size), in: CGRect(origin: .zero, size: size))
        let materials = [
            ("Recipes", "dragonfruit.jpg"), ("Wildlife", "frog.jpg"), ("Norway", "aurora.jpg"), ("Summer", "oranges.jpg"),
            ("Diving", "turtle.jpg"), ("Garden", "peony.jpg"), ("Design", "pineapple.jpg"), ("Vacation", "beach.jpg"),
        ]
        let frames = row(count: 4, side: 120, top: 32, spacing: 172, width: size.width)
            + row(count: 4, side: 120, top: 212, spacing: 172, width: size.width)
        for ((name, file), frame) in zip(materials, frames) {
            let folder = Folder(name: name, picture: file, look: .cover)
            Scenery.drawItem(on: bitmap, icon: try icon(folder, side: frame.width), frame: frame, name: name)
        }
        try write(bitmap.image, to: "depth.png")
    }

    // MARK: - Drag and drop

    /// A picture dragged from the Desktop onto a folder's Set as Icon badge. One picture and one
    /// folder, both big, so what the hand does is all there is to see.
    func renderDrop() async throws {
        try await renderDrags(
            "drop",
            folders: [Folder(name: "Pets", picture: nil)],
            frames: [CGRect(x: 385, y: 72, width: 195, height: 195)],
            // Held by its top-right corner, so it hangs down and to the left of the pointer and the badge stays in sight.
            drags: [Drag(file: "axolotl.jpg", target: 0, look: .standard, start: 0, at: CGPoint(x: 170, y: 106), side: 120, grab: CGPoint(x: 108, y: 8))],
            seconds: 6.6, pointerStart: CGPoint(x: 330, y: 372), pointerEnd: CGPoint(x: 545, y: 345)
        )
    }

    /// Transparent files, on the checkerboard every drawing app shows nothing with, dropped on
    /// folders: on the folder only the picture is left, the folder showing all around it.
    func renderClear() async throws {
        try await renderDrags(
            "clear",
            folders: [
                Folder(name: "Launch", picture: nil),
                Folder(name: "Wins", picture: "trophy.png", look: .sticker),
                Folder(name: "Startup", picture: nil),
                Folder(name: "Cats", picture: "cat.png", look: .sticker),
            ],
            frames: row(count: 4, side: 96, top: 88, spacing: 140, width: 720),
            drags: [
                Drag(file: "rocket.png", target: 0, look: .sticker, start: 0, at: CGPoint(x: 172, y: 272), clear: true),
                Drag(file: "bolt.svg", target: 2, look: .sticker, start: 3.7, at: CGPoint(x: 452, y: 272), clear: true),
            ],
            seconds: 9.6, pointerStart: CGPoint(x: 360, y: 395), pointerEnd: CGPoint(x: 340, y: 240)
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
        let size = CGSize(width: 720, height: 420)
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
    func renderHover() async throws {
        typealias Action = HoverButtonsController.Action
        let size = CGSize(width: 540, height: 400)
        let wallpaper = Scenery.wallpaper(size: size)
        let name = "Nature", chosen = "frog.jpg"
        let frame = CGRect(x: 210, y: 130, width: 120, height: 120)
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
            frame: CGRect(x: 135, y: 92, width: 270, height: 218),
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
        var path = PointerPath(start: CGPoint(x: 430, y: 372))
        path.move(to: over, from: 0.2, to: 0.9)
        path.move(to: button(.remove, in: all), from: 1.25, to: onTrash, arc: 0.05)
        path.move(to: button(.choose, in: withoutRemove), from: 2.45, to: onChoose, arc: 0.05)
        path.move(to: CGPoint(x: thumbnail.midX + 6, y: thumbnail.midY + 4), from: 3.5, to: 3.95, arc: 0.05)
        path.move(to: CGPoint(x: panel.open.midX, y: panel.open.midY), from: 4.3, to: 4.75, arc: 0.05)
        path.move(to: over, from: 5.05, to: 5.45, arc: 0.05)
        path.move(to: button(.settings, in: all), from: 5.65, to: onSettings, arc: 0.05)
        path.move(to: CGPoint(x: 448, y: 360), from: 7.0, to: 7.6)

        let windowScale: CGFloat = 0.72
        let windowOrigin = CGPoint(x: (size.width - windowSize.width) / 2, y: (size.height - windowSize.height) / 2)
        let sequence = try frameSequence("hover")
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

    /// What a hand does in the window for a while: pinch, twist, drag the frame, hold the
    /// picture with the right button, or drag the dial; each by as much over its time.
    private enum Grip {
        /// Spreading two fingers until the frame is `exp(growth)` times as big.
        case pinch(growth: Double)
        case twist(degrees: Double)
        case frame
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

    /// A scene in the window: where the pointer goes, what it holds when, and what is clicked.
    private struct WindowScript {
        var duration: Double
        var pointer: PointerPath
        var holds: [Hold] = []
        var clicks: [(time: Double, action: (EditorModel) -> Void)] = []
    }

    /// Where things are on the stage of a window scene, to plan it by.
    private struct WindowShot {
        let size: CGSize
        let windowOrigin: CGPoint
        let windowSize: CGSize
        let controls: WindowControls

        func onStage(_ point: CGPoint) -> CGPoint {
            CGPoint(x: windowOrigin.x + point.x, y: windowOrigin.y + point.y)
        }

        func onStage(_ rect: CGRect) -> CGRect {
            rect.offsetBy(dx: windowOrigin.x, dy: windowOrigin.y)
        }

        /// The picture's frame for `style`, on the stage.
        func pictureFrame(_ style: IconStyle) -> CGRect {
            let editor = controls.editor
            return onStage(IconGeometry.targetRect(for: style, canvas: editor.width, flipped: true).offsetBy(dx: editor.minX, dy: editor.minY))
        }

        var dial: CGRect { onStage(controls.dial) }
        var fill: CGPoint { onStage(CGPoint(x: controls.scaling.minX + controls.scaling.width / 4, y: controls.scaling.midY)) }
        var fit: CGPoint { onStage(CGPoint(x: controls.scaling.maxX - controls.scaling.width / 4, y: controls.scaling.midY)) }
        /// Somewhere to rest the pointer away from the window.
        var rest: CGPoint { CGPoint(x: windowOrigin.x / 2 + 40, y: size.height - 46) }
    }

    /// Shoots a scene in the window for a folder with `pictureName` on it, the folder on the
    /// Desktop beside it following every change. The pinch, the twist and the dial go through
    /// the editor's own code, step by step; the right-button drag through the same moving and
    /// snapping code it uses. (A window off screen gets no events.)
    private func shootWindow(
        _ name: String, folder folderName: String, picture pictureName: String, plan: (WindowShot, EditorModel) -> WindowScript
    ) async throws {
        let folder = try await makeFolder(folderName, picture: pictureName)
        let picture = try picture(pictureName)
        let controller = EditorWindowController(actions: actions)
        let model = controller.model
        let window = controller.window!
        model.show([folder])
        park(window)
        try await settleUntilShown(model, in: window)

        let windowSize = window.frame.size
        guard let controls = controls(of: window), controls.buttons.count == 4 else {
            throw MediaError("Couldn't find the window's controls")
        }
        let size = CGSize(width: 800, height: (windowSize.height + 64).rounded())
        let windowOrigin = CGPoint(x: size.width - windowSize.width - 52, y: ((size.height - windowSize.height) / 2).rounded())
        let shot = WindowShot(size: size, windowOrigin: windowOrigin, windowSize: windowSize, controls: controls)
        let script = plan(shot, model)
        let wallpaper = Scenery.wallpaper(size: size)
        let editorView = controls.editorView, dialView = controls.dialView
        let side = controls.editor.width
        let snapping = StyleEditor.snapping(side: side)

        func inWindow(_ point: CGPoint) -> CGPoint {
            CGPoint(x: point.x - windowOrigin.x, y: point.y - windowOrigin.y)
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

        // The folder on the Desktop, big enough to see it change.
        let folderFrame = CGRect(x: ((windowOrigin.x - 160) / 2).rounded(), y: (size.height / 2 - 96).rounded(), width: 160, height: 160)
        var desktop = (style: model.style, placement: model.placement)
        var previousIcon: CGImage?
        var currentIcon = icon(picture, style: desktop.style, placement: desktop.placement, side: folderFrame.width)
        var iconChangedAt = -10.0

        // Where things are, for whoever edits the frames into something else.
        let layout: [String: [Double]] = [
            "size": [size.width, size.height],
            "editor": [shot.onStage(controls.editor)].flatMap { [$0.minX, $0.minY, $0.width, $0.height] },
            "dial": [shot.dial].flatMap { [$0.minX, $0.minY, $0.width, $0.height] },
            "scaling": [shot.onStage(controls.scaling)].flatMap { [$0.minX, $0.minY, $0.width, $0.height] },
            "window": [windowOrigin.x, windowOrigin.y, windowSize.width, windowSize.height],
            "folder": [folderFrame.minX, folderFrame.minY, folderFrame.width, folderFrame.height],
        ]
        try JSONSerialization.data(withJSONObject: layout, options: [.sortedKeys]).write(to: output.appendingPathComponent("\(name).json"))

        var held: (index: Int, start: (style: IconStyle, placement: PicturePlacement, pointer: CGPoint, turn: Double))?
        var pinched = 0.0, twisted = 0.0
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
                    case .twist: editorView.twist(.ended, by: 0, modifiers: [])
                    case .dial: editorView.endDialTurn(restoring: false)
                    case .picture, .frame:
                        model.guides = []
                        model.isAdjusting = false
                        model.commit()
                    }
                }
                held = nil
                if let holding {
                    held = (holding, (model.style, model.placement, pointer, model.placement.rotation))
                    pinched = 0
                    twisted = 0
                    switch script.holds[holding].grip {
                    case .pinch: editorView.pinch(.began, by: 0, modifiers: [])
                    case .twist: editorView.twist(.began, by: 0, modifiers: [])
                    case .dial:
                        guard editorView.beginDialTurn() else { throw MediaError("The dial wouldn't turn") }
                    case .picture, .frame:
                        model.beginChange(holding: true)
                        model.isAdjusting = true
                    }
                }
            }
            if let held {
                let hold = script.holds[held.index]
                switch hold.grip {
                case .pinch(let growth):
                    let spread = growth * hold.amount(at: t)
                    editorView.pinch(.changed, by: spread - pinched, modifiers: [])
                    pinched = spread
                case .twist(let degrees):
                    let angle = degrees * hold.amount(at: t)
                    editorView.twist(.changed, by: angle - twisted, modifiers: [])
                    twisted = angle
                case .dial(let degrees):
                    editorView.dialTurn(to: (held.start.turn + degrees * hold.amount(at: t)).rounded(), modifiers: [], reach: TurnDialView.reach)
                case .frame:
                    let moved = held.start.style.rect.offsetBy(dx: (pointer.x - held.start.pointer.x) / side, dy: (pointer.y - held.start.pointer.y) / side)
                    let snapped = snapping.move(moved)
                    var style = model.style
                    style.rect = snapped.rect
                    model.style = style
                    model.guides = snapped.guides
                case .picture:
                    let moved = IconGeometry.placement(
                        held.start.placement, movedBy: CGSize(width: pointer.x - held.start.pointer.x, height: pointer.y - held.start.pointer.y),
                        imageSize: picture.size, style: model.style, canvas: side, folder: StyleEditorView.folderEdges
                    )
                    let snapped = snapping.pan(moved, imageSize: picture.size, style: model.style, canvas: side, folder: StyleEditorView.folderEdges)
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
            for click in script.clicks where index == frameCount(click.time) {
                click.action(model)
            }
            await settle(window, milliseconds: 15)

            // The folder on the Desktop shows each change once it's written.
            if held == nil, model.style != desktop.style || model.placement != desktop.placement {
                desktop = (model.style, model.placement)
                previousIcon = currentIcon
                currentIcon = icon(picture, style: desktop.style, placement: desktop.placement, side: folderFrame.width)
                iconChangedAt = t + 0.15
            }

            try autoreleasepool {
                let bitmap = Bitmap(size: size)
                bitmap.draw(wallpaper, in: CGRect(origin: .zero, size: size))
                let fade = progress(t, iconChangedAt, iconChangedAt + 0.2)
                if let previousIcon, fade < 1 {
                    bitmap.draw(previousIcon, in: folderFrame)
                    bitmap.draw(currentIcon, in: folderFrame, alpha: CGFloat(fade))
                } else {
                    bitmap.draw(currentIcon, in: folderFrame)
                }
                Scenery.drawLabel(folderName, on: bitmap, below: folderFrame, selected: false)
                Scenery.drawWindow(snapshot(window), at: windowOrigin, size: windowSize, on: bitmap)

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
                    case .twist(let degrees):
                        Scenery.drawTwist(around: pointer, degrees: degrees * hold.amount(at: t), alpha: shown, on: bitmap)
                    case .dial, .frame:
                        break
                    }
                }
                for click in script.clicks {
                    Scenery.drawClick(at: script.pointer.position(at: click.time), amount: progress(t, click.time - 0.05, click.time + 0.35), on: bitmap)
                }
                let cursor: NSCursor = if let held {
                    switch script.holds[held.index].grip {
                    case .picture, .dial, .frame: NSCursor.closedHand
                    case .pinch, .twist: editorView.cursor(for: editorView.part(at: editorPoint(local)))
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

    /// Any size, anywhere: a pinch makes the frame small, and dragging it puts the picture in
    /// the folder's corner.
    func renderSize() async throws {
        try await shootWindow("size", folder: "Code", picture: "robot.jpg") { shot, model in
            let frame = shot.pictureFrame(model.style)
            let over = CGPoint(x: frame.midX + 10, y: frame.midY + 6)
            let small = shot.pictureFrame(IconStyle(rect: IconGeometry.scaled(model.style.rect, by: ReadmeTuning.shrink), mode: .fill))
            let hold = CGPoint(x: small.midX + 3, y: small.midY + 2)
            var path = PointerPath(start: shot.rest)
            path.move(to: over, from: 0.3, to: 1.0)
            path.move(to: hold, from: 2.85, to: 3.15, arc: 0)
            path.move(to: CGPoint(x: hold.x + ReadmeTuning.cornerSlide.width, y: hold.y + ReadmeTuning.cornerSlide.height), from: 3.45, to: 4.55, arc: -0.05)
            path.move(to: shot.rest, from: 5.3, to: 6.0)
            return WindowScript(
                duration: 7.0, pointer: path,
                holds: [Hold(grip: .pinch(growth: log(ReadmeTuning.shrink)), start: 1.2, end: 2.7),
                        Hold(grip: .frame, start: 3.3, end: 4.7)]
            )
        }
    }

    /// Zooming into a part of a picture: a pinch makes the frame well bigger than the folder,
    /// then dragging the frame brings the part to show over the folder.
    func renderZoom() async throws {
        try await shootWindow("zoom", folder: "Islands", picture: "lagoon.jpg") { shot, model in
            let frame = shot.pictureFrame(model.style)
            let over = CGPoint(x: frame.midX + 16, y: frame.midY + 8)
            let hold = CGPoint(x: over.x - 4, y: over.y + 6)
            var path = PointerPath(start: shot.rest)
            path.move(to: over, from: 0.3, to: 1.0)
            path.move(to: hold, from: 3.1, to: 3.35, arc: 0)
            path.move(to: CGPoint(x: hold.x + ReadmeTuning.zoomSlide.width, y: hold.y + ReadmeTuning.zoomSlide.height), from: 3.6, to: 4.7, arc: 0.04)
            path.move(to: shot.rest, from: 5.4, to: 6.1)
            return WindowScript(
                duration: 7.2, pointer: path,
                holds: [Hold(grip: .pinch(growth: log(ReadmeTuning.zoomFactor)), start: 1.2, end: 2.8),
                        Hold(grip: .frame, start: 3.45, end: 4.85)]
            )
        }
    }

    /// Straightening a crooked photo with the dial, to any angle.
    func renderTurn() async throws {
        try await shootWindow("turn", folder: "Sunsets", picture: "horizon-crooked.jpg") { shot, model in
            let grab = CGPoint(x: shot.dial.midX - 2, y: shot.dial.midY + 5)
            let turn = ReadmeTuning.straighten, over = ReadmeTuning.turnOver
            var path = PointerPath(start: shot.rest)
            path.move(to: grab, from: 0.3, to: 1.1)
            path.move(to: CGPoint(x: grab.x - CGFloat(over) * TurnDialView.pointsPerDegree, y: grab.y), from: 1.4, to: 2.35, arc: 0)
            path.move(to: CGPoint(x: grab.x + CGFloat(turn) * TurnDialView.pointsPerDegree, y: grab.y), from: 2.6, to: 3.75, arc: 0)
            path.move(to: shot.rest, from: 4.4, to: 5.2)
            return WindowScript(duration: 6.2, pointer: path, holds: [
                Hold(grip: .dial(degrees: -over), start: 1.4, end: 2.5),
                Hold(grip: .dial(degrees: over + turn), start: 2.6, end: 3.9),
            ])
        }
    }

    /// Fill crops a tall picture, so the right button picks the part that shows; Fit shows all
    /// of it, and back to Fill.
    func renderFit() async throws {
        try await shootWindow("fit", folder: "Flamingos", picture: "flamingo.jpg") { shot, model in
            let frame = shot.pictureFrame(model.style)
            let over = CGPoint(x: frame.midX + 12, y: frame.midY - 4)
            let hold = CGPoint(x: over.x + 4, y: over.y - 2)
            var path = PointerPath(start: shot.rest)
            path.move(to: over, from: 0.3, to: 1.0)
            path.move(to: hold, from: 1.2, to: 1.4, arc: 0)
            path.move(to: CGPoint(x: hold.x, y: hold.y + ReadmeTuning.tallSlide), from: 1.65, to: 2.85, arc: 0.02)
            path.move(to: shot.fit, from: 3.4, to: 4.0)
            path.move(to: shot.fill, from: 5.2, to: 5.6, arc: 0)
            path.move(to: shot.rest, from: 6.5, to: 7.2)
            return WindowScript(
                duration: 8.2, pointer: path,
                holds: [Hold(grip: .picture, start: 1.5, end: 3.0)],
                clicks: [(4.2, { $0.setMode(.fit) }), (5.8, { $0.setMode(.fill) })]
            )
        }
    }

    /// The whole folder: a pinch makes the frame bigger than the folder, and the picture takes
    /// over its tab and all, in the folder's own light and shade.
    func renderCover() async throws {
        try await shootWindow("cover", folder: "Garden", picture: "peony.jpg") { shot, model in
            let frame = shot.pictureFrame(model.style)
            var path = PointerPath(start: shot.rest)
            path.move(to: CGPoint(x: frame.midX + 10, y: frame.midY + 6), from: 0.3, to: 1.0)
            path.move(to: shot.rest, from: 3.3, to: 4.0)
            return WindowScript(duration: 5.0, pointer: path, holds: [Hold(grip: .pinch(growth: log(ReadmeTuning.coverGrowth)), start: 1.2, end: 3.0)])
        }
    }
}

/// Numbers that depend on the pictures: how far to zoom, slide and turn.
enum ReadmeTuning {
    /// Small enough for a corner, and the way there, in points of the window's folder (300).
    static let shrink = 0.42
    static let cornerSlide = CGSize(width: 64, height: 40)
    /// Four times the folder.
    static let zoomFactor = 4 / IconStyle.standard.width
    /// Brings the palm island over the folder.
    static let zoomSlide = CGSize(width: -115, height: 0)
    static let straighten = 12.0
    /// How far past level the dial goes first, the other way.
    static let turnOver = 24.0
    /// From the flamingo's middle up to its head.
    static let tallSlide: CGFloat = 100
    /// Past the folder's edges all around.
    static let coverGrowth = 2.45
}

extension Stage {
    /// A rectangle on the stage in AppKit screen coordinates.
    static func appKitRect(_ rect: CGRect) -> NSRect {
        ScreenSpace.appKitRect(accessibilityRect(rect))
    }
}
#endif

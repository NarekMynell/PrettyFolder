#if DEBUG
import AppKit
import PrettyFolderKit
import SwiftUI

/// The README's picture and animations, shot frame by frame.
extension Studio {
    private struct Folder {
        let name: String
        let picture: String?
    }

    private static let cast = [
        Folder(name: "Debugging", picture: "rubber-duck.jpg"),
        Folder(name: "Snacks", picture: "donut.jpg"),
        Folder(name: "Monkey Business", picture: "cool-monkey.jpg"),
        Folder(name: "Moonshots", picture: "rocket.jpg"),
        Folder(name: "Spooky", picture: "ghost.jpg"),
    ]

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

    // MARK: - Hero

    /// A row of folders with pictures on them.
    func renderHero() async throws {
        let size = CGSize(width: 760, height: 236)
        let bitmap = Bitmap(size: size)
        bitmap.draw(Scenery.wallpaper(size: size), in: CGRect(origin: .zero, size: size))
        let frames = row(count: Self.cast.count, side: 112, top: 48, spacing: 142, width: size.width)
        for (folder, frame) in zip(Self.cast, frames) {
            let icon = icon(try folder.picture.map(picture), side: frame.width)
            Scenery.drawItem(on: bitmap, icon: icon, frame: frame, name: folder.name)
        }
        try write(bitmap.image, to: "hero.png")
    }

    // MARK: - Drag and drop

    /// A picture dragged from the Desktop onto a folder's Set as Icon badge.
    func renderDrop() async throws {
        let size = CGSize(width: 720, height: 420)
        let wallpaper = Scenery.wallpaper(size: size)
        let names = ["Snacks", "Monkey Business", "Debugging", "Moonshots"]
        let pictures: [String?] = ["donut.jpg", "cool-monkey.jpg", nil, "rocket.jpg"]
        let frames = row(count: 4, side: 96, top: 88, spacing: 140, width: size.width)
        var icons = try pictures.map { icon(try $0.map(picture), side: 96) }
        let target = 2
        let duckIcon = icon(try picture("rubber-duck.jpg"), side: 96)

        // The picture file, as Finder shows it on the Desktop.
        let duck = NSImage(contentsOf: pictureURL("rubber-duck.jpg"))!.cgImage(forProposedRect: nil, context: nil, hints: nil)!
        let fileFrame = CGRect(x: 172, y: 272, width: 96, height: 96)
        let thumbnail = Scenery.thumbnail(of: duck, fitting: 96)

        // The badge, in each of its looks, where the app puts it for this folder.
        // Grabbed by its bottom-right corner, so what's dragged rides up and to the left of
        // the pointer and the badge's title stays in sight.
        let pressPoint = CGPoint(x: fileFrame.minX + 86, y: fileFrame.minY + 74)
        let overFolder = CGPoint(x: frames[target].midX - 4, y: frames[target].midY + 8)
        let item = FinderItem(
            url: URL(fileURLWithPath: "/Debugging/"), layout: .icon,
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
        }
        let badgeInset = DropBadgeController.shadowMargin
        let onBadge = CGPoint(x: badgeFrame.minX + badgeInset + 18, y: badgeFrame.midY + 1)

        var path = PointerPath(start: CGPoint(x: 560, y: 380))
        path.move(to: pressPoint, from: 0.4, to: 1.2)
        path.move(to: overFolder, from: 1.45, to: 2.55, arc: -0.12)
        path.move(to: onBadge, from: 2.95, to: 3.3, arc: 0)
        path.move(to: CGPoint(x: 520, y: 330), from: 4.7, to: 5.5)

        let pressAt = 1.3, releaseAt = 3.45
        let badgeShownAt = 2.55 + 0.18, doneAt = 3.75, badgeHiddenAt = doneAt + 0.7
        let sequence = try frameSequence("drop")
        for index in 0..<frameCount(6.6) {
            let t = Double(index) / Stage.framesPerSecond
            let pointer = path.position(at: t)
            let dragging = t >= pressAt && t < releaseAt
            let overBadge = dragging && t >= badgeShownAt && badgeFrame.insetBy(dx: badgeInset, dy: badgeInset).contains(pointer)
            if t >= doneAt { icons[target] = duckIcon }

            let bitmap = Bitmap(size: size)
            bitmap.draw(wallpaper, in: CGRect(origin: .zero, size: size))
            for (position, frame) in frames.enumerated() {
                let targeted = dragging && position == target && frame.contains(pointer) && !overBadge
                Scenery.drawItem(on: bitmap, icon: icons[position], frame: frame, name: names[position], targeted: targeted)
            }
            Scenery.drawItem(on: bitmap, icon: thumbnail, frame: fileFrame, name: "rubber-duck.jpg", selected: t >= pressAt)

            // The badge comes up a moment after the picture reaches the folder.
            if t >= badgeShownAt && t < badgeHiddenAt + 0.1 {
                let state: DropBadgeModel.State = t >= doneAt ? .done : t >= releaseAt ? .working : overBadge ? .targeted : .ready
                let fadeIn = progress(t, badgeShownAt, badgeShownAt + 0.12)
                let fadeOut = 1 - progress(t, badgeHiddenAt, badgeHiddenAt + 0.1)
                bitmap.draw(badges[state]!, in: badgeFrame, alpha: CGFloat(fadeIn * fadeOut))
            }

            if dragging {
                // What is being dragged follows the pointer, a little see-through.
                let offset = CGPoint(x: fileFrame.minX - pressPoint.x, y: fileFrame.minY - pressPoint.y)
                let dragFrame = CGRect(x: pointer.x + offset.x, y: pointer.y + offset.y, width: fileFrame.width, height: fileFrame.height)
                bitmap.context.saveGState()
                bitmap.context.setAlpha(0.75)
                Scenery.drawItem(on: bitmap, icon: thumbnail, frame: dragFrame, name: "rubber-duck.jpg", selected: true)
                bitmap.context.restoreGState()
            }
            Scenery.drawCursor(overBadge ? .dragCopy : .arrow, at: pointer, on: bitmap)
            try sequence.add(bitmap.image)
        }
    }

    // MARK: - The buttons on a folder

    /// Pointing at folders: their buttons come up; one picture is removed, then the
    /// window opens for another folder.
    func renderHover() async throws {
        let size = CGSize(width: 720, height: 420)
        let wallpaper = Scenery.wallpaper(size: size)
        let folders = [Self.cast[0], Self.cast[1], Self.cast[2], Self.cast[4]]
        let frames = row(count: 4, side: 96, top: 120, spacing: 140, width: size.width)
        var icons = try folders.map { icon(try $0.picture.map(picture), side: 96) }
        let plainIcon = icon(nil, side: 96)
        let ghost = 3, monkey = 2

        // The buttons, as the app lays them out on each of the two folders.
        func bar(on position: Int, highlight: HoverButtonsController.Action?, pressed: Bool) -> (CGImage, CGRect, HoverBarView.Layout) {
            let iconOnScreen = Stage.appKitRect(frames[position])
            let layout = HoverBarView.Layout(icon: iconOnScreen, buttonCount: 3)
            let view = HoverBarView()
            view.configure(actions: [.choose, .remove, .settings], layout: layout)
            view.highlight(highlight, pressed: pressed)
            let image = sprite(of: view, size: layout.panelFrame.size)
            return (image, Stage.stageRect(fromAppKit: layout.panelFrame), layout)
        }
        func button(_ action: HoverButtonsController.Action, in layout: HoverBarView.Layout) -> CGPoint {
            let index = CGFloat([HoverButtonsController.Action.choose, .remove, .settings].firstIndex(of: action)!)
            let bar = Stage.stageRect(fromAppKit: layout.barFrame)
            return CGPoint(
                x: bar.minX + layout.padding + index * (layout.buttonSize + layout.spacing) + layout.buttonSize / 2,
                y: bar.minY + layout.padding + layout.buttonSize / 2
            )
        }
        let (ghostBar, ghostBarFrame, ghostLayout) = bar(on: ghost, highlight: nil, pressed: false)
        let (ghostTrash, _, _) = bar(on: ghost, highlight: .remove, pressed: false)
        let (ghostTrashPressed, _, _) = bar(on: ghost, highlight: .remove, pressed: true)
        let (monkeyBar, monkeyBarFrame, monkeyLayout) = bar(on: monkey, highlight: nil, pressed: false)
        let (monkeySettings, _, _) = bar(on: monkey, highlight: .settings, pressed: false)
        let (monkeySettingsPressed, _, _) = bar(on: monkey, highlight: .settings, pressed: true)
        let trash = button(.remove, in: ghostLayout)
        let settingsButton = button(.settings, in: monkeyLayout)

        // The window it opens.
        let folder = try await makeFolder("Monkey Business", picture: "cool-monkey.jpg")
        let controller = EditorWindowController(actions: actions)
        let window = controller.window!
        controller.model.show([folder])
        park(window)
        await settle(window, milliseconds: 700)
        let windowImage = snapshot(window)
        let windowSize = window.frame.size
        window.close()

        var path = PointerPath(start: CGPoint(x: 370, y: 390))
        path.move(to: CGPoint(x: frames[ghost].midX + 8, y: frames[ghost].midY + 14), from: 0.4, to: 1.2)
        path.move(to: trash, from: 1.75, to: 2.15, arc: 0.05)
        path.move(to: CGPoint(x: frames[monkey].midX - 6, y: frames[monkey].midY + 16), from: 3.0, to: 3.7)
        path.move(to: settingsButton, from: 4.2, to: 4.6, arc: 0.05)
        path.move(to: CGPoint(x: 360, y: 300), from: 5.6, to: 6.3)

        let ghostShown = 1.3, trashPress = 2.45, trashRelease = 2.6
        let monkeyShown = 3.8, settingsPress = 4.85, settingsRelease = 5.0
        let windowShown = 5.15
        let windowScale: CGFloat = 0.78
        let windowOrigin = CGPoint(x: (size.width - windowSize.width) / 2, y: (size.height - windowSize.height) / 2)
        let sequence = try frameSequence("hover")
        for index in 0..<frameCount(7.8) {
            let t = Double(index) / Stage.framesPerSecond
            let pointer = path.position(at: t)
            if t >= trashRelease + 0.12 { icons[ghost] = plainIcon }

            let bitmap = Bitmap(size: size)
            bitmap.draw(wallpaper, in: CGRect(origin: .zero, size: size))
            for (position, frame) in frames.enumerated() {
                Scenery.drawItem(on: bitmap, icon: icons[position], frame: frame, name: folders[position].name)
            }
            var cursor = NSCursor.arrow
            if t >= ghostShown && t < trashRelease {
                let onTrash = t >= 2.15
                let image = t >= trashPress ? ghostTrashPressed : onTrash ? ghostTrash : ghostBar
                bitmap.draw(image, in: ghostBarFrame, alpha: CGFloat(progress(t, ghostShown, ghostShown + 0.12)))
                if onTrash { cursor = .pointingHand }
            }
            if t >= monkeyShown && t < settingsRelease {
                let onSettings = t >= 4.6
                let image = t >= settingsPress ? monkeySettingsPressed : onSettings ? monkeySettings : monkeyBar
                bitmap.draw(image, in: monkeyBarFrame, alpha: CGFloat(progress(t, monkeyShown, monkeyShown + 0.12)))
                if onSettings { cursor = .pointingHand }
            }
            if t >= windowShown {
                let appear = ease(progress(t, windowShown, windowShown + 0.25))
                Scenery.drawWindow(
                    windowImage, at: windowOrigin, size: windowSize, on: bitmap,
                    alpha: CGFloat(appear), scale: windowScale * (0.94 + 0.06 * CGFloat(appear))
                )
            }
            Scenery.drawCursor(cursor, at: pointer, on: bitmap)
            try sequence.add(bitmap.image)
        }
    }

    // MARK: - The window

    /// Moving and resizing the picture in the window, with the folder on the Desktop
    /// following every change.
    func renderWindow() async throws {
        let size = CGSize(width: 780, height: 540)
        let wallpaper = Scenery.wallpaper(size: size)
        let folder = try await makeFolder("Moonshots", picture: "rocket.jpg")
        let rocket = try picture("rocket.jpg")
        let controller = EditorWindowController(actions: actions)
        let model = controller.model
        let window = controller.window!
        model.show([folder])
        park(window)
        await settle(window, milliseconds: 700)

        let windowSize = window.frame.size
        let windowOrigin = CGPoint(x: size.width - windowSize.width - 46, y: (size.height - windowSize.height) / 2 - 6)
        guard let controls = controls(of: window), controls.buttons.count == 3 else {
            throw MediaError("Couldn't find the window's controls")
        }
        let editor = controls.editor, scaling = controls.scaling

        // Choose, reset, remove.
        let reset = controls.buttons[1]
        let side = editor.width
        func onStage(_ point: CGPoint) -> CGPoint {
            CGPoint(x: windowOrigin.x + point.x, y: windowOrigin.y + point.y)
        }
        func inWindow(_ point: CGPoint) -> CGPoint {
            CGPoint(x: point.x - windowOrigin.x, y: point.y - windowOrigin.y)
        }
        func pictureRect(_ style: IconStyle) -> CGRect {
            IconGeometry.targetRect(for: style, canvas: side, flipped: true).offsetBy(dx: editor.minX, dy: editor.minY)
        }

        // The folder on the Desktop, big enough to see it change.
        let folderFrame = CGRect(x: 92, y: 168, width: 150, height: 150)
        var desktopStyle = model.style
        var previousIcon: CGImage?
        var currentIcon = icon(rocket, style: desktopStyle, side: folderFrame.width)
        var iconChangedAt = -10.0

        // Where the pointer goes: grab the picture and move it until it snaps; pull its
        // top-left corner over the folder's tab, where it takes the folder's shape; switch
        // to Fit; and back to the default look.
        let start = model.style
        let grab = onStage(CGPoint(x: pictureRect(start).midX, y: pictureRect(start).midY))
        let moveFree = CGPoint(x: grab.x - 52, y: grab.y - 10)
        let moveSnapped = CGPoint(x: grab.x + 2, y: grab.y - (start.y - FolderArtwork.shape.front.minY) * side - 2)
        let moved = IconStyle(rect: start.rect.offsetBy(dx: 0, dy: FolderArtwork.shape.front.minY - start.y), mode: start.mode)
        let corner = onStage(CGPoint(x: pictureRect(moved).minX, y: pictureRect(moved).minY))
        let stretched = onStage(CGPoint(x: editor.minX + 3, y: editor.minY + 3))
        let fit = onStage(CGPoint(x: scaling.maxX - scaling.width / 4, y: scaling.midY))
        let resetPoint = onStage(CGPoint(x: reset.midX, y: reset.midY))

        var path = PointerPath(start: CGPoint(x: 300, y: 470))
        path.move(to: grab, from: 0.4, to: 1.2)
        path.move(to: moveFree, from: 1.5, to: 2.2, arc: 0.08)
        path.move(to: moveSnapped, from: 2.3, to: 3.1, arc: -0.06)
        path.move(to: corner, from: 3.8, to: 4.4)
        path.move(to: stretched, from: 4.6, to: 5.7, arc: 0)
        path.move(to: fit, from: 6.3, to: 6.9)
        path.move(to: resetPoint, from: 7.6, to: 8.2)
        path.move(to: CGPoint(x: 300, y: 470), from: 9.0, to: 9.8)

        // The editor's drags, the way its gestures handle them: the same resizing and
        // snapping code, the same model. (A window off screen gets no mouse events.)
        enum Grip { case none, picture, corner }
        var grip = Grip.none
        var gripStart = (style: start, pointer: CGPoint.zero)
        let snapping = StyleEditor.snapping(side: side)
        let sequence = try frameSequence("window")
        for index in 0..<frameCount(10.6) {
            let t = Double(index) / Stage.framesPerSecond
            let pointer = path.position(at: t)
            let local = inWindow(pointer)

            switch grip {
            case .none where t >= 1.4 && t < 3.3, .none where t >= 4.5 && t < 5.9:
                grip = t < 4 ? .picture : .corner
                gripStart = (model.style, pointer)
                model.isAdjusting = true
            case .picture where t >= 3.3, .corner where t >= 5.9:
                grip = .none
                model.guides = []
                model.isAdjusting = false
                model.commit(from: gripStart.style)
            case .picture, .corner:
                let dx = (pointer.x - gripStart.pointer.x) / side
                let dy = (pointer.y - gripStart.pointer.y) / side
                let snapped = grip == .picture
                    ? snapping.move(gripStart.style.rect.offsetBy(dx: dx, dy: dy))
                    : snapping.resize(
                        ResizeHandle.topLeft.resize(gripStart.style.rect, dx: dx, dy: dy, keepRatio: false, fromCenter: false),
                        moving: ResizeHandle.topLeft.edges, symmetric: false
                    )
                model.style = IconStyle(rect: snapped.rect, mode: model.style.mode)
                model.guides = snapped.guides
            default:
                break
            }
            if index == frameCount(7.0) { model.setMode(.fit) }
            if index == frameCount(8.3) { model.reset() }
            await settle(window, milliseconds: 15)

            // The folder on the Desktop shows each change once it's written.
            if grip == .none, model.style != desktopStyle {
                desktopStyle = model.style
                previousIcon = currentIcon
                currentIcon = icon(rocket, style: desktopStyle, side: folderFrame.width)
                iconChangedAt = t + 0.15
            }

            let bitmap = Bitmap(size: size)
            bitmap.draw(wallpaper, in: CGRect(origin: .zero, size: size))
            let fade = progress(t, iconChangedAt, iconChangedAt + 0.2)
            if let previousIcon, fade < 1 {
                bitmap.draw(previousIcon, in: folderFrame)
                bitmap.draw(currentIcon, in: folderFrame, alpha: CGFloat(fade))
            } else {
                bitmap.draw(currentIcon, in: folderFrame)
            }
            Scenery.drawLabel("Moonshots", on: bitmap, below: folderFrame, selected: false)
            Scenery.drawWindow(snapshot(window), at: windowOrigin, size: windowSize, on: bitmap)

            let cursor: NSCursor
            switch grip {
            case .picture: cursor = .closedHand
            case .corner:
                if #available(macOS 15, *) {
                    cursor = .frameResize(position: .topLeft, directions: .all)
                } else {
                    cursor = .crosshair
                }
            case .none:
                let rect = pictureRect(model.style).insetBy(dx: 4, dy: 4)
                cursor = rect.contains(local) && model.canEdit ? .openHand : .arrow
            }
            Scenery.drawCursor(cursor, at: pointer, on: bitmap)
            try sequence.add(bitmap.image)
        }
        window.close()
    }
}

extension Stage {
    /// A rectangle on the stage in AppKit screen coordinates.
    static func appKitRect(_ rect: CGRect) -> NSRect {
        ScreenSpace.appKitRect(accessibilityRect(rect))
    }
}
#endif

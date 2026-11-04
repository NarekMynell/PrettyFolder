#if DEBUG
import AppKit
import FinderSync
import ObjectiveC
import PrettyFolderKit
import SwiftUI

/// Renders the README's pictures and animations from the app's own views and icons:
///
///     PrettyFolder --readme-media <output folder> --pictures <folder> [--only <scene>] [--scale 2] [--fps 25] [--pointer 1]
///
/// writes a folder of numbered PNG frames for each animation, and single PNGs, then quits.
/// `wallpaper.jpg` among the pictures, if there is one, is the desktop the scenes are on.
/// `make readme-media` builds a debug copy, runs this and turns the frames into GIFs.
///
/// Nothing on screen is touched: windows are drawn off screen, the pointer is drawn into
/// the frames, folders live in a temporary directory and settings in their own domain.
enum ReadmeMedia {
    static func runIfRequested() {
        let arguments = CommandLine.arguments
        guard let output = value(after: "--readme-media", in: arguments) else { return }
        let pictures = value(after: "--pictures", in: arguments) ?? output
        let only = value(after: "--only", in: arguments)
        if let scale = value(after: "--scale", in: arguments).flatMap(Double.init) { Stage.scale = CGFloat(scale) }
        if let rate = value(after: "--fps", in: arguments).flatMap(Double.init) { Stage.framesPerSecond = rate }
        if let pointer = value(after: "--pointer", in: arguments).flatMap(Double.init) { Stage.pointerScale = CGFloat(pointer) }
        Scenery.bareDesktop = arguments.contains("--no-desktop")

        MainActor.assumeIsolated {
            NSApplication.shared.setActivationPolicy(.accessory)
            StagedLook.install()
            Task {
                do {
                    let studio = try Studio(
                        output: URL(fileURLWithPath: output, isDirectory: true),
                        pictures: URL(fileURLWithPath: pictures, isDirectory: true)
                    )
                    defer { studio.cleanUp() }
                    try await studio.render(only: only)
                } catch {
                    FileHandle.standardError.write(Data("README media failed: \(error)\n".utf8))
                    exit(1)
                }
                exit(0)
            }
            NSApplication.shared.run()
        }
        exit(0)
    }

    private static func value(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }
}

/// Makes the app look the way it does in use, whatever the Mac rendering it says.
///
/// Windows drawn off screen belong to an app that isn't active, so they would look
/// inactive: grey traffic lights, grey default buttons. A debug build's Finder extension
/// isn't the one turned on, so the window would ask to turn it on. And AppKit would pull
/// a resized window back onto a screen. None of that is what a user sees.
private enum StagedLook {
    static func install() {
        let yes: @convention(block) (AnyObject) -> Bool = { _ in true }
        replace(NSApplication.self, "isActive", with: imp_implementationWithBlock(yes))
        for name in ["isKeyWindow", "isMainWindow", "_hasActiveAppearance", "_hasActiveAppearanceIgnoringKeyFocus",
                     "_hasKeyAppearance", "_hasMainAppearance", "_hasActiveControls"] {
            replace(NSWindow.self, name, with: imp_implementationWithBlock(yes))
        }
        let yesForButton: @convention(block) (AnyObject, Int) -> Bool = { _, _ in true }
        replace(NSWindow.self, "_hasActiveAppearanceForStandardWindowButton:", with: imp_implementationWithBlock(yesForButton))
        // Nor does it give that up when another app comes forward: that would end a pinch halfway.
        let stays: @convention(block) (AnyObject) -> Void = { _ in }
        for name in ["resignKeyWindow", "resignMainWindow"] {
            replace(NSWindow.self, name, with: imp_implementationWithBlock(stays))
        }
        let unconstrained: @convention(block) (AnyObject, NSRect, NSScreen?) -> NSRect = { _, rect, _ in rect }
        replace(NSWindow.self, "constrainFrameRect:toScreen:", with: imp_implementationWithBlock(unconstrained))
        if let method = class_getClassMethod(FIFinderSyncController.self, NSSelectorFromString("isExtensionEnabled")) {
            method_setImplementation(method, imp_implementationWithBlock(yes))
        }
        // The app believes it is active now; keep its snapping taps off the trackpad.
        let silent: @convention(block) (AnyObject, Int, UInt) -> Void = { _, _, _ in }
        replace(type(of: NSHapticFeedbackManager.defaultPerformer as AnyObject), "performFeedbackPattern:performanceTime:", with: imp_implementationWithBlock(silent))
    }

    private static func replace(_ type: AnyClass, _ name: String, with implementation: IMP) {
        guard let method = class_getInstanceMethod(type, NSSelectorFromString(name)) else { return }
        method_setImplementation(method, implementation)
    }
}

/// The set the scenes are shot on: a temporary folder with folders in it, the app's real
/// manager and actions working on them, and what it takes to turn views into frames.
@MainActor
final class Studio {
    let output: URL
    let pictures: URL
    let workspace: URL
    let settings: AppSettings
    let manager: FolderImageManager
    let actions: FolderActions
    let renderer = IconRenderer()
    private let defaultsDomain = "com.narekmynell.PrettyFolder.ReadmeMedia"
    private var spriteWindow: NSWindow?

    init(output: URL, pictures: URL) throws {
        self.output = output
        self.pictures = pictures
        workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("PrettyFolder-ReadmeMedia-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let defaults = UserDefaults(suiteName: defaultsDomain)!
        defaults.removePersistentDomain(forName: defaultsDomain)
        settings = AppSettings(defaults: defaults)
        let wallpaper = pictures.appendingPathComponent("wallpaper.jpg")
        Scenery.desktopPicture = NSImage(contentsOf: wallpaper)?.cgImage(forProposedRect: nil, context: nil, hints: nil)
        manager = FolderImageManager(directory: workspace.appendingPathComponent("Library", isDirectory: true), defaultStyle: settings.defaultStyle)
        actions = FolderActions(manager: manager, settings: settings)
    }

    func render(only: String?) async throws {
        let scenes: [(name: String, render: () async throws -> Void)] = [
            ("depth", renderDepth),
            ("drop", renderDrop),
            ("hover", renderHover),
            ("clear", renderClear),
            ("size", renderSize),
            ("zoom", renderZoom),
            ("turn", renderTurn),
            ("fit", renderFit),
            ("cover", renderCover),
        ]
        for scene in scenes where only == nil || only == scene.name {
            print("Rendering \(scene.name)…")
            try await scene.render()
        }
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: workspace)
        UserDefaults(suiteName: defaultsDomain)?.removePersistentDomain(forName: defaultsDomain)
    }

    // MARK: - Folders and pictures

    func pictureURL(_ name: String) -> URL {
        pictures.appendingPathComponent(name)
    }

    func picture(_ name: String) throws -> SourceImage {
        try ImageLoader.load(contentsOf: pictureURL(name))
    }

    /// A fresh folder in the workspace, with `picture` on it when given.
    func makeFolder(_ name: String, picture: String? = nil) async throws -> URL {
        let folder = workspace.appendingPathComponent("Folders", isDirectory: true).appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.removeItem(at: folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if let picture {
            let outcomes = await manager.apply(imageAt: pictureURL(picture), to: [folder])
            if let failure = outcomes.first(where: { !$0.succeeded })?.failure { throw MediaError(failure) }
        }
        return folder
    }

    /// The icon PrettyFolder makes: the folder with `picture` on it, or the plain folder.
    func icon(_ picture: SourceImage?, style: IconStyle = .standard, placement: PicturePlacement = .natural, side: CGFloat) -> CGImage {
        renderer.render(picture, style: style, placement: placement, pixelSize: Int((side * Stage.scale).rounded()))!
    }

    // MARK: - Windows and views

    /// Lets SwiftUI and AppKit catch up with whatever just changed.
    func settle(_ window: NSWindow? = nil, milliseconds: Int = 40) async {
        try? await Task.sleep(for: .milliseconds(milliseconds))
        window?.contentView?.layoutSubtreeIfNeeded()
        window?.displayIfNeeded()
    }

    /// Waits until the window shows what it was opened for: the folder's picture and look, which
    /// it reads off the main thread. A debug build takes its time over the folder's artwork.
    func settleUntilShown(_ model: EditorModel, in window: NSWindow) async throws {
        for _ in 0..<200 where !model.hasPicture {
            await settle(window, milliseconds: 50)
        }
        guard model.hasPicture else { throw MediaError("The window never showed the folder's picture") }
        await settle(window, milliseconds: 300)
    }

    /// Puts a window where no screen shows it, ready to be drawn. It becomes this app's key
    /// window, so its controls look the way they do while someone uses them; that doesn't
    /// bring the app forward or take the keyboard from anyone.
    func park(_ window: NSWindow) {
        window.animationBehavior = .none
        window.setFrameOrigin(NSPoint(x: -8000, y: -8000))
        window.orderFrontRegardless()
        if window.canBecomeKey { window.makeKey() }
    }

    /// The whole window, title bar included, with its rounded corners.
    func snapshot(_ window: NSWindow) -> CGImage {
        window.displayIfNeeded()
        let frameView = window.contentView!.superview!
        let rep = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds)!
        frameView.cacheDisplay(in: frameView.bounds, to: rep)
        let image = rep.cgImage!
        let size = frameView.bounds.size
        let bitmap = Bitmap(size: size, scale: CGFloat(image.width) / size.width)
        bitmap.context.addPath(
            RoundedRectangle(cornerRadius: Self.windowCornerRadius, style: .continuous).path(in: CGRect(origin: .zero, size: size)).cgPath
        )
        bitmap.context.clip()
        bitmap.draw(image, in: CGRect(origin: .zero, size: size))
        return bitmap.image
    }

    /// What macOS 26 rounds a window with a title bar and no toolbar by.
    static let windowCornerRadius: CGFloat = 16

    /// Draws a view on its own, transparent around it, at the stage's scale.
    func sprite(of view: NSView, size: CGSize) -> CGImage {
        let window = spriteWindow ?? {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 10, height: 10), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isOpaque = false
            window.backgroundColor = .clear
            park(window)
            spriteWindow = window
            return window
        }()
        window.setContentSize(size)
        window.contentView = view
        view.frame = CGRect(origin: .zero, size: size)
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        // At the stage's scale, whatever the screen's: a video zooms in on these.
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int((size.width * Stage.scale).rounded()), pixelsHigh: Int((size.height * Stage.scale).rounded()),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )!
        rep.size = size
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep.cgImage!
    }

    /// Where the window's controls are, in points from its top-left corner, found in its
    /// view hierarchy so the scenes can point at them without repeating its layout.
    struct WindowControls {
        /// The folder icon being edited, and where it is.
        var editorView: StyleEditorView
        var editor: CGRect
        /// The Fill / Fit switch.
        var scaling: CGRect
        /// The buttons below the folder, left to right: choose, reset, remove, Done.
        var buttons: [CGRect]
        /// The dial that turns the picture, and where it is.
        var dialView: TurnDialView
        var dial: CGRect
    }

    func controls(of window: NSWindow) -> WindowControls? {
        var views: [NSView] = []
        func collect(_ view: NSView) {
            views.append(view)
            view.subviews.forEach(collect)
        }
        collect(window.contentView!)
        func frame(_ view: NSView) -> CGRect {
            let frame = view.convert(view.bounds, to: nil)
            return CGRect(x: frame.minX, y: window.frame.height - frame.maxY, width: frame.width, height: frame.height)
        }
        guard let editor = views.compactMap({ $0 as? StyleEditorView }).first,
              let dial = views.compactMap({ $0 as? TurnDialView }).first,
              let scaling = views.compactMap({ $0 as? NSSegmentedControl })
                .first(where: { $0.segmentCount == 2 && $0.label(forSegment: 1) == "Fit" }).map(frame)
        else { return nil }
        let buttons = views.filter { "\(type(of: $0))".contains("FocusRing") }.map(frame)
            .filter { abs($0.midY - scaling.midY) < 8 }
            .sorted { $0.minX < $1.minX }
        let margin = StyleEditorView.margin
        return WindowControls(
            editorView: editor, editor: frame(editor).insetBy(dx: margin, dy: margin), scaling: scaling, buttons: buttons,
            dialView: dial, dial: frame(dial)
        )
    }

    // MARK: - Output

    func write(_ image: CGImage, to name: String) throws {
        try PNG.write(image, to: output.appendingPathComponent(name))
    }

    func frameSequence(_ name: String) throws -> FrameSequence {
        try FrameSequence(directory: output.appendingPathComponent(name, isDirectory: true))
    }
}

struct MediaError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

enum PNG {
    static func write(_ image: CGImage, to url: URL) throws {
        let rep = NSBitmapImageRep(cgImage: image)
        guard let data = rep.representation(using: .png, properties: [:]) else { throw MediaError("Couldn't encode \(url.lastPathComponent)") }
        try data.write(to: url)
    }
}

/// Numbered frames in a folder of their own, for ffmpeg to turn into a GIF.
final class FrameSequence {
    let directory: URL
    private(set) var count = 0

    init(directory: URL) throws {
        try? FileManager.default.removeItem(at: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.directory = directory
    }

    func add(_ image: CGImage) throws {
        count += 1
        try PNG.write(image, to: directory.appendingPathComponent(String(format: "frame-%04d.png", count)))
    }
}
#endif

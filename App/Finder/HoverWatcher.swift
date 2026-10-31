import AppKit
import PrettyFolderKit
import os

/// Shows the buttons on a folder while the pointer is over its icon, in Finder's icon
/// view and on the Desktop.
///
/// Finder is only asked what is under the pointer when the pointer slows down over one
/// of its windows; while it travels, or sits anywhere else, nothing happens at all. Once
/// a folder is found, moving around on its icon needs no more questions.
final class HoverWatcher {
    /// Faster than this (points per second) the pointer is travelling, not aiming.
    private static let aimingSpeed: CGFloat = 900
    private static let queryInterval: TimeInterval = 0.05
    /// Icons smaller than this are too small to carry the buttons.
    private static let smallestIcon: CGFloat = 32

    private let finder: FinderProcess
    private let accessibility: FinderAccessibility
    private let buttons: HoverButtonsController
    private let log = Logger(subsystem: "com.narekmynell.PrettyFolder", category: "Hover")

    private var monitors: [Any] = []
    private var lastMove: (point: NSPoint, time: TimeInterval)?
    /// The folder whose icon the pointer is over, and that icon's area on screen.
    private var hovered: (item: FinderItem, zone: NSRect)?
    private var queryInFlight = false
    private var pendingPoint: NSPoint?
    private var lastQueryTime: TimeInterval = 0
    private var settleTask: Task<Void, Never>?
    private var showTask: Task<Void, Never>?

    init(finder: FinderProcess, accessibility: FinderAccessibility, buttons: HoverButtonsController) {
        self.finder = finder
        self.accessibility = accessibility
        self.buttons = buttons
        buttons.onExit = { [weak self] in self?.pointerMoved() }
    }

    var isRunning: Bool { !monitors.isEmpty }

    func start() {
        guard monitors.isEmpty else { return }
        if let moved = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.pointerMoved() }
        }) {
            monitors.append(moved)
        }
        // Anything that can move icons around invalidates what we know.
        let resetting: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel, .leftMouseDragged]
        if let other = NSEvent.addGlobalMonitorForEvents(matching: resetting, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.reset() }
        }) {
            monitors.append(other)
        }
    }

    func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        reset()
    }

    private func reset() {
        hovered = nil
        pendingPoint = nil
        settleTask?.cancel()
        showTask?.cancel()
        buttons.hide()
    }

    private func pointerMoved() {
        let point = NSEvent.mouseLocation
        let now = ProcessInfo.processInfo.systemUptime
        defer { lastMove = (point, now) }

        // Still on the same folder, or on its buttons: nothing to ask.
        if buttons.contains(point) { return }
        if let hovered, hovered.zone.contains(point) { return }

        hovered = nil
        showTask?.cancel()
        buttons.hide()

        settleTask?.cancel()
        if let last = lastMove, now > last.time {
            let speed = hypot(point.x - last.point.x, point.y - last.point.y) / CGFloat(now - last.time)
            if speed > Self.aimingSpeed {
                // Wait until it stops; no mouse-moved events arrive while it rests.
                settleTask = Task { [weak self] in
                    try? await Task.sleep(for: .milliseconds(70))
                    guard !Task.isCancelled else { return }
                    self?.pendingPoint = NSEvent.mouseLocation
                    self?.queryIfPossible()
                }
                return
            }
        }
        pendingPoint = point
        queryIfPossible()
    }

    private func queryIfPossible() {
        guard !queryInFlight, let point = pendingPoint else { return }
        let wait = Self.queryInterval - (ProcessInfo.processInfo.systemUptime - lastQueryTime)
        if wait > 0 {
            settleTask?.cancel()
            settleTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(wait))
                guard !Task.isCancelled else { return }
                self?.queryIfPossible()
            }
            return
        }
        pendingPoint = nil
        guard NSEvent.pressedMouseButtons == 0, let pid = finder.pid, finder.ownsWindow(at: point) else { return }
        queryInFlight = true
        lastQueryTime = ProcessInfo.processInfo.systemUptime
        accessibility.item(at: ScreenSpace.accessibilityPoint(point), finderPID: pid) { [weak self] item in
            Task { @MainActor in self?.finishQuery(item) }
        }
    }

    private func finishQuery(_ item: FinderItem?) {
        queryInFlight = false
        log.debug("Under the pointer: \(item?.url.lastPathComponent ?? "nothing", privacy: .private), \(item.map { "\($0.layout)" } ?? "-", privacy: .public) layout, plain folder \(item?.isPlainFolder ?? false), \(item?.iconFrame.width ?? 0) pt")
        defer { queryIfPossible() }
        // List and column views are left alone: their icons are too small for buttons.
        guard let item, item.layout == .icon, item.isPlainFolder, item.iconFrame.width >= Self.smallestIcon else { return }
        let zone = ScreenSpace.appKitRect(item.iconFrame)
        guard NSEvent.pressedMouseButtons == 0, zone.contains(NSEvent.mouseLocation) else { return }
        if hovered?.item == item, buttons.isVisible { return }
        hovered = (item, zone)

        let url = item.url
        showTask?.cancel()
        showTask = Task { [weak self] in
            // Only a picture from PrettyFolder gets a remove button. A quick look, but still
            // a look at the disk, so not on the main thread.
            let canRemove = await Task.detached(priority: .userInitiated) {
                FolderImageManager.appearsToHavePicture(url)
            }.value
            guard !Task.isCancelled, let self, let hovered = self.hovered, hovered.item.url == url,
                  NSEvent.pressedMouseButtons == 0, hovered.zone.contains(NSEvent.mouseLocation)
            else { return }
            self.buttons.show(for: hovered.item, canRemove: canRemove)
        }
    }
}

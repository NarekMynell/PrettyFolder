import AppKit
import PrettyFolderKit
import os

/// Shows the buttons on a folder while the pointer is over its icon, in Finder's icon
/// view and on the Desktop.
///
/// Finder is only asked what is under the pointer when the pointer slows down over one
/// of its windows; while it travels, or sits anywhere else, nothing happens at all. Once
/// a folder is found, moving around on its icon needs no more questions, only a look now
/// and then to see that the folder is still there.
final class HoverWatcher {
    /// Faster than this (points per second) the pointer is travelling, not aiming.
    private static let aimingSpeed: CGFloat = 900
    private static let queryInterval: TimeInterval = 0.05
    /// How often to check, while the buttons are up, that their folder is still under them.
    private static let recheckInterval: TimeInterval = 0.4
    /// On icons smaller than this the buttons would cover most of the folder.
    private static let smallestIcon: CGFloat = 48

    private let finder: FinderProcess
    private let accessibility: FinderAccessibility
    private let buttons: HoverButtonsController
    private let manager: FolderImageManager
    private let log = Logger(subsystem: "com.narekmynell.PrettyFolder", category: "Hover")

    private var monitors: [Any] = []
    private var lastMove: (point: NSPoint, time: TimeInterval)?
    /// A folder's icon and its area on screen.
    private typealias Hovered = (item: FinderItem, zone: NSRect)

    /// The folder whose icon the pointer is over.
    private var hovered: Hovered?
    /// The folder the buttons were last shown for.
    private var shown: Hovered?
    private var queryInFlight = false
    private var pendingPoint: NSPoint?
    private var lastQueryTime: TimeInterval = 0
    /// Waits for the pointer to stop after travelling fast.
    private var settleTask: Task<Void, Never>?
    /// Waits out the gap between two questions to Finder.
    private var throttleTask: Task<Void, Never>?
    private var showTask: Task<Void, Never>?
    private var recheckTimer: Timer?
    private var recheckInFlight = false
    /// Goes up whenever what is known about the pointer is thrown away, so an answer to a
    /// question asked before is recognized as out of date.
    private var generation = 0
    // Only touched on the main thread; removing observers is thread-safe.
    nonisolated(unsafe) private var observers: [NSObjectProtocol] = []

    init(finder: FinderProcess, accessibility: FinderAccessibility, buttons: HoverButtonsController, manager: FolderImageManager) {
        self.finder = finder
        self.accessibility = accessibility
        self.buttons = buttons
        self.manager = manager
        buttons.onExit = { [weak self] in self?.pointerMoved() }
    }

    deinit {
        observers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
    }

    var isRunning: Bool { !monitors.isEmpty }

    func start() {
        guard monitors.isEmpty else { return }
        // Another app or another Space changes what is under the pointer without moving it.
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.activeSpaceDidChangeNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.reset() }
            })
        }
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
        observers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        observers.removeAll()
        reset()
    }

    private func reset() {
        generation += 1
        hovered = nil
        pendingPoint = nil
        settleTask?.cancel()
        throttleTask?.cancel()
        throttleTask = nil
        showTask?.cancel()
        stopRechecking()
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
        stopRechecking()
        buttons.hide()

        settleTask?.cancel()
        if let last = lastMove, now > last.time {
            let speed = hypot(point.x - last.point.x, point.y - last.point.y) / CGFloat(now - last.time)
            if speed > Self.aimingSpeed {
                // Wait until it stops; no mouse-moved events arrive while it rests. Where it
                // was before it sped off doesn't matter any more.
                pendingPoint = nil
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
        guard isRunning, !queryInFlight, let point = pendingPoint else { return }
        let wait = Self.queryInterval - (ProcessInfo.processInfo.systemUptime - lastQueryTime)
        if wait > 0 {
            // Asks about whatever point is newest when the time comes.
            guard throttleTask == nil else { return }
            throttleTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(wait))
                guard !Task.isCancelled else { return }
                self?.throttleTask = nil
                self?.queryIfPossible()
            }
            return
        }
        pendingPoint = nil
        guard NSEvent.pressedMouseButtons == 0, let pid = finder.pid, finder.ownsWindow(at: point) else { return }
        queryInFlight = true
        lastQueryTime = ProcessInfo.processInfo.systemUptime
        let generation = self.generation
        accessibility.item(at: ScreenSpace.accessibilityPoint(point), finderPID: pid) { [weak self] item in
            Task { @MainActor in self?.finishQuery(item, generation: generation) }
        }
    }

    private func finishQuery(_ item: FinderItem?, generation: Int) {
        queryInFlight = false
        log.debug("Under the pointer: \(item?.url.lastPathComponent ?? "nothing", privacy: .private), \(item.map { "\($0.layout)" } ?? "-", privacy: .public) layout, plain folder \(item?.isPlainFolder ?? false), \(item?.iconFrame.width ?? 0) pt")
        defer { queryIfPossible() }
        // Asked before a click, a scroll or another Space moved things, or before turning off.
        guard isRunning, generation == self.generation else { return }
        // List and column views are left alone: their icons are too small for buttons.
        guard let item, item.layout == .icon, item.isPlainFolder, item.iconFrame.width >= Self.smallestIcon else { return }
        let zone = ScreenSpace.appKitRect(item.iconFrame)
        guard NSEvent.pressedMouseButtons == 0, zone.contains(NSEvent.mouseLocation) else { return }
        if hovered?.item == item, buttons.isVisible { return }
        hovered = (item, zone)

        let url = item.url
        let manager = self.manager
        showTask?.cancel()
        showTask = Task { [weak self] in
            // Only a picture from PrettyFolder gets a remove button, not an icon somebody else
            // put on the folder since. The icon is compared on the manager's thread.
            let canRemove = await manager.showsOwnPicture(url)
            guard !Task.isCancelled, let self, generation == self.generation, let hovered = self.hovered, hovered.item.url == url,
                  NSEvent.pressedMouseButtons == 0, hovered.zone.contains(NSEvent.mouseLocation)
            else { return }
            self.buttons.show(for: hovered.item, canRemove: canRemove)
            self.shown = hovered
            self.startRechecking()
        }
    }

    // MARK: - Is the folder still there?

    /// Runs `action` only if the folder the buttons were shown for is still under them.
    /// Finder may have moved on in the meantime, by keyboard say, with the pointer still.
    func confirm(_ folder: URL, then action: @escaping () -> Void) {
        guard let shown, shown.item.url == folder else { return }
        Task {
            if await isStillThere(shown) { action() }
        }
    }

    /// Keyboard navigation, another view, a deleted folder: Finder can change what is under
    /// the pointer without the pointer moving. While the buttons are up, look now and then.
    private func startRechecking() {
        guard recheckTimer == nil else { return }
        recheckTimer = Timer.scheduledTimer(withTimeInterval: Self.recheckInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.recheck() }
        }
    }

    private func stopRechecking() {
        recheckTimer?.invalidate()
        recheckTimer = nil
    }

    private func recheck() {
        guard buttons.isVisible, let shown else {
            stopRechecking()
            return
        }
        guard !recheckInFlight else { return }
        recheckInFlight = true
        Task {
            let stillThere = await isStillThere(shown)
            recheckInFlight = false
            if !stillThere, self.shown?.item.url == shown.item.url {
                log.debug("The folder under the buttons changed; hiding them")
                reset()
            }
        }
    }

    /// Asks Finder whether the folder is still where it was, looking at a spot on its icon
    /// below the buttons.
    private func isStillThere(_ folder: Hovered) async -> Bool {
        let probe = NSPoint(x: folder.zone.midX, y: folder.zone.minY + folder.zone.height * 0.3)
        guard let pid = finder.pid, finder.ownsWindow(at: probe) else { return false }
        let accessibility = self.accessibility
        let item = await withCheckedContinuation { (continuation: CheckedContinuation<FinderItem?, Never>) in
            accessibility.item(at: ScreenSpace.accessibilityPoint(probe), finderPID: pid) { item in
                continuation.resume(returning: item)
            }
        }
        guard let item, item.url == folder.item.url else { return false }
        let frame = ScreenSpace.appKitRect(item.iconFrame)
        return abs(frame.minX - folder.zone.minX) < 2 && abs(frame.minY - folder.zone.minY) < 2
    }
}

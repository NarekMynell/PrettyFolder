import AppKit
import os

/// Shows the tab button when the pointer rests on a folder's tab in Finder.
///
/// Finder is only asked what is under the pointer when the pointer slows down over one
/// of its windows; while it travels, or sits anywhere else, nothing happens at all.
final class TabWatcher {
    /// Faster than this (points per second) the pointer is travelling, not aiming.
    private static let aimingSpeed: CGFloat = 900
    private static let queryInterval: TimeInterval = 0.05
    /// How long a looked-up icon frame is trusted (Finder can rearrange without any input).
    private static let cacheLifetime: TimeInterval = 1.0

    private let finder: FinderProcess
    private let accessibility: FinderAccessibility
    private let badge: TabBadgeController
    private let log = Logger(subsystem: "com.narekmynell.PrettyFolder", category: "Tab")

    private var monitors: [Any] = []
    private var lastMove: (point: NSPoint, time: TimeInterval)?
    private var cached: (item: FinderItem, frame: NSRect, time: TimeInterval)?
    private var queryInFlight = false
    private var pendingPoint: NSPoint?
    private var lastQueryTime: TimeInterval = 0
    private var settleTask: Task<Void, Never>?

    init(finder: FinderProcess, accessibility: FinderAccessibility, badge: TabBadgeController) {
        self.finder = finder
        self.accessibility = accessibility
        self.badge = badge
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
        cached = nil
        pendingPoint = nil
        settleTask?.cancel()
        badge.hide()
    }

    private func pointerMoved() {
        let point = NSEvent.mouseLocation
        let now = ProcessInfo.processInfo.systemUptime
        defer { lastMove = (point, now) }

        if badge.isVisible {
            if badge.contains(point) { return }
            badge.hide()
        }

        if let cached, now - cached.time < Self.cacheLifetime, cached.frame.contains(point) {
            // Still over the same folder icon: decide without asking Finder, unless the
            // pointer just entered the tab, which is worth a fresh look.
            if TabBadgeController.tabZone(for: cached.item).contains(point) {
                pendingPoint = point
                queryIfPossible()
            }
            return
        }
        cached = nil

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
        // Small icons have a tab too thin to aim at; list and column views are skipped.
        guard let item, item.layout == .icon, item.isPlainFolder, item.iconFrame.width >= 32 else {
            cached = nil
            return
        }
        let frame = ScreenSpace.appKitRect(item.iconFrame)
        cached = (item, frame, ProcessInfo.processInfo.systemUptime)
        let point = NSEvent.mouseLocation
        if NSEvent.pressedMouseButtons == 0, frame.contains(point), TabBadgeController.tabZone(for: item).contains(point) {
            badge.show(for: item)
        }
    }
}

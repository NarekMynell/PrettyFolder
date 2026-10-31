import AppKit

/// Watches drags anywhere on screen. While a picture is dragged over a folder in Finder,
/// it shows the "Set as Icon" badge next to that folder.
///
/// Only global event monitors are used, which observe events without touching them,
/// so dragging behaves exactly as it does without PrettyFolder.
final class DragWatcher {
    private enum Phase: Equatable {
        case idle
        /// The button is down; a drag starts when the drag pasteboard changes.
        case pressed(changeCount: Int)
        case dragging(hasPicture: Bool)
    }

    /// Accessibility queries are cheap but not free; this caps them at about 25 per second.
    private static let queryInterval: TimeInterval = 0.04

    private let finder: FinderProcess
    private let accessibility: FinderAccessibility
    private let badge: DropBadgeController
    private let dragPasteboard = NSPasteboard(name: .drag)

    private var monitor: Any?
    private var phase = Phase.idle
    private var hovered: FinderItem?
    private var queryInFlight = false
    private var pendingPoint: NSPoint?
    private var lastQueryTime: TimeInterval = 0
    private var retryTask: Task<Void, Never>?
    private var showTask: Task<Void, Never>?
    private var releaseCheckTimer: Timer?

    init(finder: FinderProcess, accessibility: FinderAccessibility, badge: DropBadgeController) {
        self.finder = finder
        self.accessibility = accessibility
        self.badge = badge
    }

    var isRunning: Bool { monitor != nil }

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        endDrag()
    }

    private func handle(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            phase = .pressed(changeCount: dragPasteboard.changeCount)
        case .leftMouseDragged:
            switch phase {
            case .pressed(let changeCount):
                // A selection rectangle or a window move never touches the drag pasteboard.
                guard dragPasteboard.changeCount != changeCount else { return }
                let hasPicture = DroppedPicture.isPresent(on: dragPasteboard)
                phase = .dragging(hasPicture: hasPicture)
                if hasPicture {
                    startReleaseCheck()
                    track(NSEvent.mouseLocation)
                }
            case .dragging(hasPicture: true):
                track(NSEvent.mouseLocation)
            default:
                break
            }
        case .leftMouseUp:
            endDrag()
        default:
            break
        }
    }

    // MARK: - Following the pointer

    private func track(_ point: NSPoint) {
        if badge.contains(point) {
            // On the badge: it is the drop target now, keep it.
            badge.cancelHide()
            showTask?.cancel()
            return
        }
        pendingPoint = point
        queryIfPossible()
    }

    private func queryIfPossible() {
        guard !queryInFlight, let point = pendingPoint else { return }
        let wait = Self.queryInterval - (ProcessInfo.processInfo.systemUptime - lastQueryTime)
        if wait > 0 {
            guard retryTask == nil else { return }
            retryTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(wait))
                self?.retryTask = nil
                self?.queryIfPossible()
            }
            return
        }
        pendingPoint = nil
        guard let pid = finder.pid, finder.ownsWindow(at: point) else {
            update(nil, pointer: point)
            return
        }
        queryInFlight = true
        lastQueryTime = ProcessInfo.processInfo.systemUptime
        accessibility.item(at: ScreenSpace.accessibilityPoint(point), finderPID: pid) { [weak self] item in
            Task { @MainActor in self?.finishQuery(item, pointer: point) }
        }
    }

    private func finishQuery(_ item: FinderItem?, pointer: NSPoint) {
        queryInFlight = false
        guard phase == .dragging(hasPicture: true) else { return }
        update(item?.isPlainFolder == true ? item : nil, pointer: pointer)
        queryIfPossible()
    }

    private func update(_ folder: FinderItem?, pointer: NSPoint) {
        guard let folder else {
            hovered = nil
            showTask?.cancel()
            if badge.isVisible, !badge.isBusy, !badge.contains(NSEvent.mouseLocation) {
                badge.scheduleHide(after: 0.15)
            }
            return
        }
        badge.cancelHide()
        if badge.isVisible, badge.folder == folder.url {
            // Same folder; Finder may have scrolled it, so follow along.
            badge.show(for: folder, pointer: pointer)
            return
        }
        guard hovered?.url != folder.url else { return }
        hovered = folder
        showTask?.cancel()
        // A short pause first, so sweeping across a grid of folders doesn't flash badges.
        let delay = badge.isVisible ? 0.08 : 0.18
        showTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self, self.phase == .dragging(hasPicture: true),
                  let hovered = self.hovered, hovered.url == folder.url
            else { return }
            if !self.badge.show(for: hovered, pointer: NSEvent.mouseLocation) {
                // The pointer sits where the badge would go; try again once it moves.
                self.hovered = nil
            }
        }
    }

    // MARK: - End of the drag

    private func endDrag() {
        phase = .idle
        hovered = nil
        pendingPoint = nil
        showTask?.cancel()
        retryTask?.cancel()
        retryTask = nil
        stopReleaseCheck()
        guard badge.isVisible, !badge.isBusy else { return }
        if badge.contains(NSEvent.mouseLocation) {
            // Released on the badge: the drop arrives separately, give it a moment.
            badge.scheduleHide(after: 0.6)
        } else {
            badge.hide()
        }
    }

    /// A drag can end without a mouse-up reaching the monitor (for example when another
    /// app grabs the mouse), so also check the button state now and then.
    private func startReleaseCheck() {
        stopReleaseCheck()
        releaseCheckTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                if NSEvent.pressedMouseButtons & 1 == 0 { self?.endDrag() }
            }
        }
    }

    private func stopReleaseCheck() {
        releaseCheckTimer?.invalidate()
        releaseCheckTimer = nil
    }
}

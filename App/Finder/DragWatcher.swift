import AppKit
import os

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
    private let log = Logger(subsystem: "com.narekmynell.PrettyFolder", category: "Drag")

    private var monitor: Any?
    private var spaceObserver: NSObjectProtocol?
    private var phase = Phase.idle
    private var hovered: FinderItem?
    private var queryInFlight = false
    private var pendingPoint: NSPoint?
    private var lastQueryTime: TimeInterval = 0
    /// Goes up whenever the folder found before is no longer the one, so an answer to a question
    /// asked before is recognized as out of date.
    private var generation = 0
    private var retryTask: Task<Void, Never>?
    private var showTask: Task<Void, Never>?
    private var releaseCheckTimer: Timer?

    init(finder: FinderProcess, accessibility: FinderAccessibility, badge: DropBadgeController) {
        self.finder = finder
        self.accessibility = accessibility
        self.badge = badge
    }

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
        }
        // The badge shows on every Space; the folder it belongs to doesn't.
        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.forgetFolder() }
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if let spaceObserver { NSWorkspace.shared.notificationCenter.removeObserver(spaceObserver) }
        spaceObserver = nil
        endDrag(releasedAt: nil)
    }

    /// What is under the pointer changed without it moving: the drag goes on, the folder
    /// found before is no longer the one.
    private func forgetFolder() {
        generation += 1
        hovered = nil
        pendingPoint = nil
        showTask?.cancel()
        retryTask?.cancel()
        retryTask = nil
        if badge.isVisible, !badge.isBusy { badge.hide(animated: false) }
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
                log.debug("Drag started, picture: \(hasPicture)")
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
            // Events seen by a global monitor carry screen coordinates.
            endDrag(releasedAt: event.locationInWindow)
        default:
            break
        }
    }

    // MARK: - Following the pointer

    private func track(_ point: NSPoint) {
        if badge.contains(point) {
            // On the badge: it is the drop target now, keep it as it is. Questions asked on the
            // way here are about where the pointer was, and so is the folder it was on the way to.
            badge.cancelHide()
            hovered = nil
            showTask?.cancel()
            pendingPoint = nil
            retryTask?.cancel()
            retryTask = nil
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
                guard !Task.isCancelled else { return }
                self?.retryTask = nil
                self?.queryIfPossible()
            }
            return
        }
        pendingPoint = nil
        guard let pid = finder.pid, finder.ownsWindow(at: point) else {
            log.debug("Not over a Finder window")
            update(nil, pointer: point)
            return
        }
        queryInFlight = true
        lastQueryTime = ProcessInfo.processInfo.systemUptime
        let generation = self.generation
        accessibility.item(at: ScreenSpace.accessibilityPoint(point), finderPID: pid) { [weak self] item, _ in
            Task { @MainActor in self?.finishQuery(item, pointer: point, generation: generation) }
        }
    }

    private func finishQuery(_ item: FinderItem?, pointer: NSPoint, generation: Int) {
        queryInFlight = false
        log.debug("Under the pointer: \(item?.url.lastPathComponent ?? "nothing", privacy: .private)")
        guard phase == .dragging(hasPicture: true), generation == self.generation else { return }
        // The pointer went on to the badge while Finder answered.
        guard !badge.contains(NSEvent.mouseLocation) else { return }
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
            badge.follow(folder, pointer: pointer)
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

    /// - Parameter point: where the button was released; that, not where the pointer is
    ///   by the time this runs, decides whether the drop went to the badge.
    private func endDrag(releasedAt point: NSPoint?) {
        phase = .idle
        hovered = nil
        pendingPoint = nil
        showTask?.cancel()
        retryTask?.cancel()
        retryTask = nil
        stopReleaseCheck()
        guard badge.isVisible, !badge.isBusy else { return }
        if let point, badge.contains(point) {
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
                if NSEvent.pressedMouseButtons & 1 == 0 { self?.endDrag(releasedAt: NSEvent.mouseLocation) }
            }
        }
    }

    private func stopReleaseCheck() {
        releaseCheckTimer?.invalidate()
        releaseCheckTimer = nil
    }
}

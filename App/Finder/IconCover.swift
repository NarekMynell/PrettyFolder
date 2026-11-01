import AppKit
import PrettyFolderKit
import os

/// Covers the moment Finder shows a plain folder while it loads a folder's new icon.
///
/// Finder doesn't notice when a custom icon is replaced, so PrettyFolder tells it (see
/// `FolderMetadata` in the kit), and Finder then drops the old icon, shows its plain folder
/// for up to a second and draws the new one. Just before Finder is told, a window with the new
/// icon goes exactly over each place Finder shows the folder, so all that is seen is the old
/// icon turning into the new one. The window goes once Finder has caught up, as soon as
/// anything could move the icon under it (a scroll, a key, a drag, a double-click, another
/// Space), or once a look at Finder finds the icon gone or moved: Finder is looked at now and
/// then, and right away after a click.
final class IconCover {
    /// Finder takes up to a second or two to notice the change and up to a second more to
    /// draw it; a cover that stays a little longer than needed shows the same icon as Finder.
    private static let lifetime: TimeInterval = 4
    private static let checkInterval: TimeInterval = 0.25
    /// Finder goes ahead without a cover rather than wait longer than this for a look.
    private static let lookLimit: TimeInterval = 0.3
    /// One look at Finder serves every folder written in a burst, like Redraw All.
    private static let reuseLimit: TimeInterval = 0.3
    private static let desktopLevel = Int(CGWindowLevelForKey(.desktopIconWindow))
    /// How far the pointer goes with a button down before Finder takes it for a drag.
    private static let dragDistance: CGFloat = 3
    /// When, after a click or an app coming forward, the covers are put right above their
    /// windows again: Finder may bring a window forward a moment after either, over the cover.
    private static let reorderDelays: [Duration] = [.milliseconds(15), .milliseconds(45), .milliseconds(100), .milliseconds(200)]

    private let finder: FinderProcess
    private let accessibility: FinderAccessibility
    private var covers: [CoverPanel] = []
    /// The last look at Finder's icons; `nil` icons when Finder didn't answer in time.
    private var lastLook: (time: TimeInterval, icons: [String: [ShownIcon]]?)?
    /// A look still on Finder's Accessibility queue, answered in time or not. There is only
    /// ever one: the buttons on folders and the drop badge use that queue too.
    private var isLooking = false
    /// Covers waiting for that look, with the generation they started in.
    private var lookWaiters: [(generation: Int, answer: OneAnswer<[String: [ShownIcon]]?>)] = []
    /// Goes up whenever all covers are taken away, so a look from before can't bring any back.
    private var generation = 0
    /// The newest icon asked for, by file: an older one that comes in later mustn't cover it.
    private var newest: [String: Int] = [:]
    /// Covers being placed right now, still looking at Finder.
    private var placing = 0
    // Only touched on the main thread; also undone in deinit, which nothing runs alongside.
    nonisolated(unsafe) private var timer: Timer?
    nonisolated(unsafe) private var monitors: [Any] = []
    nonisolated(unsafe) private var observers: [NSObjectProtocol] = []
    private var isChecking = false
    /// Asked for while a check was going on: what it found may be from before.
    private var checkIsDue = false
    /// Where a mouse button went down, to tell a click from a drag.
    private var pressedAt: NSPoint?
    /// Puts the covers back above their windows a few times after a click (`keepOnTop`).
    private var reordering: Task<Void, Never>?
    private let log = Logger(subsystem: "com.narekmynell.PrettyFolder", category: "Cover")

    init(finder: FinderProcess, accessibility: FinderAccessibility) {
        self.finder = finder
        self.accessibility = accessibility
    }

    deinit {
        timer?.invalidate()
        monitors.forEach(NSEvent.removeMonitor)
        observers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
    }

    /// Puts `icon` over every place Finder shows `folder`, and returns once it's there.
    func cover(_ folder: URL, with icon: RenderedIcon) async {
        guard AXIsProcessTrusted(), let pid = finder.pid else { return }
        // From here on a click or a scroll makes what Finder says out of date, and which icon
        // is newest must be remembered.
        placing += 1
        startWatching()
        defer {
            placing -= 1
            stopWatchingIfIdle()
        }
        guard let key = await Self.key(for: folder), icon.sequence >= newest[key] ?? icon.sequence else { return }
        newest[key] = icon.sequence
        // Covers still up from the last change get the new icon now, whatever the look below
        // finds: Finder is about to load this one.
        let expiry = ProcessInfo.processInfo.systemUptime + Self.lifetime
        for panel in covers where panel.key == key {
            panel.update(icon.image, until: expiry)
        }
        let generation = self.generation
        let icons = await look(pid: pid)
        let stillHasPicture = await Self.havePictures([folder]).first ?? false
        // Taken away, replaced or removed meanwhile.
        guard generation == self.generation, newest[key] == icon.sequence, stillHasPicture else { return }
        guard let shown = icons?[key] else {
            if icons == nil { log.debug("Finder didn't answer in time; no cover") }
            return
        }
        let windows = Self.windows(of: pid)
        for place in shown {
            guard let window = Self.window(showing: place, in: windows) else { continue }
            let panel: CoverPanel
            if let existing = covers.first(where: { $0.key == key && $0.place.frame.isClose(to: place.frame) }) {
                panel = existing
                // The same spot, possibly a new Accessibility element for it.
                panel.place = place
            } else {
                panel = CoverPanel(key: key, folder: folder, place: place)
                covers.append(panel)
            }
            panel.show(icon.image, above: window, until: ProcessInfo.processInfo.systemUptime + Self.lifetime)
        }
    }

    /// The folder's picture is gone, and so are its covers.
    func uncover(_ folder: URL) async {
        guard let key = await Self.key(for: folder) else { return }
        for panel in covers where panel.key == key { remove(panel) }
    }

    /// The key Finder's icons are found by. It asks the disk, which may be a slow network
    /// disk, so not on the main thread.
    private static func key(for folder: URL) async -> String? {
        await Task.detached(priority: .userInitiated) { ShownIcon.key(for: folder) }.value
    }

    // MARK: - Finder's windows and icons

    /// Finder's windows on screen, front to back, the Desktop included.
    private static func windows(of pid: pid_t) -> [FinderWindow] {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        return list.compactMap { info in
            guard (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
                  let number = (info[kCGWindowNumber as String] as? NSNumber)?.intValue,
                  let layer = (info[kCGWindowLayer as String] as? NSNumber)?.intValue,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds)
            else { return nil }
            return FinderWindow(number: number, layer: layer, frame: frame)
        }
    }

    /// The window Finder draws `place` in: the window of the same size, or for the Desktop,
    /// the desktop window of the display the icon is on. Nothing if that is unclear.
    private static func window(showing place: ShownIcon, in windows: [FinderWindow]) -> FinderWindow? {
        let candidates = place.isDesktop
            ? windows.filter { $0.layer == desktopLevel && $0.frame.contains(place.frame) }
            : windows.filter { $0.layer != desktopLevel && $0.frame.isClose(to: place.windowFrame) }
        return candidates.count == 1 ? candidates[0] : nil
    }

    /// Where Finder's icons are now; `nil` if Finder doesn't answer in time. Callers in the
    /// same moment share one look.
    private func look(pid: pid_t) async -> [String: [ShownIcon]]? {
        if let lastLook, ProcessInfo.processInfo.systemUptime - lastLook.time < Self.reuseLimit {
            return lastLook.icons
        }
        return await withCheckedContinuation { continuation in
            let answer = OneAnswer<[String: [ShownIcon]]?>(continuation)
            lookWaiters.append((generation, answer))
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.lookLimit) { answer.give(nil) }
            startLooking(pid: pid)
        }
    }

    private func startLooking(pid: pid_t) {
        guard !isLooking else { return }
        isLooking = true
        let generation = self.generation
        accessibility.shownIcons(finderPID: pid, within: Self.lookLimit) { [weak self] icons in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.finishLook(icons, generation: generation, pid: pid) }
            }
        }
    }

    private func finishLook(_ icons: [String: [ShownIcon]]?, generation: Int, pid: pid_t) {
        isLooking = false
        if generation == self.generation {
            lastLook = (ProcessInfo.processInfo.systemUptime, icons)
            let waiting = lookWaiters
            lookWaiters.removeAll()
            waiting.forEach { $0.answer.give(icons) }
            return
        }
        // The look began before the covers were taken away, so it may be out of date. Those
        // who asked since then get a new one.
        let outdated = lookWaiters.filter { $0.generation != self.generation || $0.answer.isAnswered }
        lookWaiters.removeAll { $0.generation != self.generation || $0.answer.isAnswered }
        outdated.forEach { $0.answer.give(nil) }
        if !lookWaiters.isEmpty { startLooking(pid: pid) }
    }

    /// Whether each folder still has a picture from PrettyFolder; read off the main thread,
    /// since a folder may be on a slow network disk.
    private static func havePictures(_ folders: [URL]) async -> [Bool] {
        await Task.detached(priority: .userInitiated) {
            folders.map(FolderImageManager.appearsToHavePicture)
        }.value
    }

    /// Where the covered icons are now; `nil` if Finder doesn't answer in time.
    private func currentFrames(of places: [ShownIcon]) async -> [CGRect?]? {
        await withCheckedContinuation { continuation in
            let answer = OneAnswer<[CGRect?]?>(continuation)
            accessibility.currentFrames(of: places) { answer.give($0) }
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.lookLimit) { answer.give(nil) }
        }
    }

    // MARK: - Taking covers away

    private func startWatching() {
        guard timer == nil else { return }
        // Also while a menu or an alert is open.
        let timer = Timer(timeInterval: Self.checkInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        let events: NSEvent.EventTypeMask = [
            .leftMouseDown, .rightMouseDown, .otherMouseDown, .leftMouseUp, .rightMouseUp, .otherMouseUp,
            .leftMouseDragged, .rightMouseDragged, .otherMouseDragged, .scrollWheel, .keyDown,
        ]
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: events, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
        }) {
            monitors.append(monitor)
        }
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.removeAll() }
        })
        // Finder coming forward reorders its windows; keep each cover right above its window.
        observers.append(center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.keepOnTop() }
        })
    }

    private func stopWatching() {
        timer?.invalidate()
        timer = nil
        pressedAt = nil
        reordering?.cancel()
        reordering = nil
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        observers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        observers.removeAll()
        // What Finder showed is no use once nothing is covered, and it holds on to its icons.
        lastLook = nil
        newest.removeAll()
    }

    /// What another app's input means for the covers. Scrolling, a key, a drag or a
    /// double-click (which may open the folder) can move icons at once: every cover goes. A
    /// click doesn't move them: Finder is likely still loading the new icon, and taking the
    /// covers away would show its plain folder, so they stay while Finder is looked at again.
    private func handle(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            // Events seen by a global monitor carry screen coordinates.
            pressedAt = event.locationInWindow
            guard event.clickCount < 2 else { return removeAll() }
            keepOnTop()
            check()
        case .leftMouseUp, .rightMouseUp, .otherMouseUp:
            pressedAt = nil
            keepOnTop()
            check()
        case .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            // A hand that shakes a little while clicking doesn't drag yet.
            guard let pressedAt else { return removeAll() }
            let point = event.locationInWindow
            if hypot(point.x - pressedAt.x, point.y - pressedAt.y) > Self.dragDistance { removeAll() }
        default:
            removeAll()
        }
    }

    /// Puts every cover right above its window now, and again a few times over the next moment.
    private func keepOnTop() {
        covers.forEach { $0.reorder() }
        reordering?.cancel()
        reordering = Task { [weak self] in
            var waited = Duration.zero
            for delay in Self.reorderDelays {
                try? await Task.sleep(for: delay - waited)
                waited = delay
                guard !Task.isCancelled, let self else { return }
                self.covers.forEach { $0.reorder() }
            }
        }
    }

    /// Stops watching once no cover is up and none is being placed.
    private func stopWatchingIfIdle() {
        if covers.isEmpty, placing == 0 { stopWatching() }
    }

    /// Takes every cover away at once: something may be moving the icons under them.
    private func removeAll() {
        generation += 1
        covers.forEach { $0.orderOut(nil) }
        covers.removeAll()
        stopWatching()
    }

    private func remove(_ panel: CoverPanel) {
        panel.orderOut(nil)
        covers.removeAll { $0 === panel }
        stopWatchingIfIdle()
    }

    private func check() {
        let now = ProcessInfo.processInfo.systemUptime
        for panel in covers where now >= panel.expiry { remove(panel) }
        guard !covers.isEmpty else { return }
        covers.forEach { $0.reorder() }

        // Still where Finder shows the folder, and still with a picture? A click that opened
        // another folder, keyboard navigation, a window moved by a shortcut, a folder sorted
        // elsewhere, a picture removed in Get Info.
        guard !isChecking else {
            checkIsDue = true
            return
        }
        isChecking = true
        let panels = covers
        let generation = self.generation
        Task {
            defer {
                isChecking = false
                if checkIsDue {
                    checkIsDue = false
                    check()
                }
            }
            let pictures = await Self.havePictures(panels.map(\.folder))
            for (panel, hasPicture) in zip(panels, pictures) where !hasPicture { remove(panel) }
            // No answer in time: Finder is busy, likely with this very icon. Look again later.
            guard let frames = await currentFrames(of: panels.map(\.place)), generation == self.generation else { return }
            var lost: [CoverPanel] = []
            for (panel, frame) in zip(panels, frames) where covers.contains(where: { $0 === panel }) {
                if let frame {
                    if !frame.isClose(to: panel.place.frame) {
                        remove(panel)
                        lastLook = nil
                    }
                } else {
                    lost.append(panel)
                }
            }
            guard !lost.isEmpty, let pid = finder.pid, let icons = await look(pid: pid), generation == self.generation else { return }
            // Finder may have made the icon anew; it's fine as long as it's in the same place.
            for panel in lost where covers.contains(where: { $0 === panel }) {
                if let again = icons[panel.key]?.first(where: { $0.frame.isClose(to: panel.place.frame) }) {
                    panel.place = again
                } else {
                    remove(panel)
                }
            }
        }
    }
}

/// A borderless window over one of Finder's icons, showing the icon Finder is about to load.
private final class CoverPanel: OverlayPanel {
    let key: String
    let folder: URL
    /// Where Finder shows the icon.
    var place: ShownIcon
    private(set) var expiry: TimeInterval = 0
    private var windowNumberBelow = 0
    private let imageView = NSImageView()

    init(key: String, folder: URL, place: ShownIcon) {
        self.key = key
        self.folder = folder
        self.place = place
        super.init()
        ignoresMouseEvents = true
        // Only where the Finder window is, and never in Mission Control.
        collectionBehavior = [.transient, .ignoresCycle, .fullScreenAuxiliary]
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.imageFrameStyle = .none
        imageView.animates = false
        contentView = imageView
        setFrame(ScreenSpace.appKitRect(place.frame), display: false)
    }

    func show(_ image: NSImage, above window: FinderWindow, until expiry: TimeInterval) {
        level = NSWindow.Level(rawValue: window.layer)
        windowNumberBelow = window.number
        update(image, until: expiry)
        reorder()
    }

    func update(_ image: NSImage, until expiry: TimeInterval) {
        // Only the size it is shown at: the icon has seven, up to 1024 pixels across.
        let size = frame.size
        let small = NSImage(size: size)
        let best = image.bestRepresentation(
            for: NSRect(origin: .zero, size: size), context: nil,
            hints: [.ctm: AffineTransform(scale: screen?.backingScaleFactor ?? 2)]
        )
        if let best { small.addRepresentation(best) }
        imageView.image = best == nil ? image : small
        self.expiry = expiry
    }

    /// Right above Finder's window: whatever covers that window covers this too.
    func reorder() {
        order(.above, relativeTo: windowNumberBelow)
    }
}

/// One of Finder's windows on screen, the Desktop included.
private struct FinderWindow {
    let number: Int
    let layer: Int
    let frame: CGRect
}

private extension CGRect {
    func isClose(to other: CGRect) -> Bool {
        abs(minX - other.minX) < 1 && abs(minY - other.minY) < 1 && abs(width - other.width) < 1 && abs(height - other.height) < 1
    }
}

/// Gives a continuation the first answer it gets, whichever side that comes from.
private nonisolated final class OneAnswer<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Never>?

    init(_ continuation: CheckedContinuation<Value, Never>) {
        self.continuation = continuation
    }

    var isAnswered: Bool {
        lock.lock()
        defer { lock.unlock() }
        return continuation == nil
    }

    func give(_ value: Value) {
        lock.lock()
        let waiting = continuation
        continuation = nil
        lock.unlock()
        waiting?.resume(returning: value)
    }
}

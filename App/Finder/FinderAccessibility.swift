import AppKit
import PrettyFolderIPC
import ApplicationServices
import os

/// A file or folder Finder shows somewhere on screen.
nonisolated struct FinderItem: Equatable, Sendable {
    enum Layout: Sendable {
        /// Icon view, the Desktop, the gallery strip: a big square icon.
        case icon
        /// List and column views: a small icon followed by the name.
        case row
    }

    /// A path-based file URL; folders end with a slash.
    let url: URL
    let layout: Layout
    /// Screen rectangles in Accessibility coordinates (origin top-left of the main display).
    let iconFrame: CGRect
    let nameFrame: CGRect?
    let rowFrame: CGRect?

    /// A folder whose icon may be changed: not a file, not an app or other package, not a disk.
    var isPlainFolder: Bool {
        FolderCommand.isPlainFolder(url)
    }
}

/// Asks Finder, through the Accessibility API, what is under a point on screen.
///
/// Every call is a round trip to Finder, so all of them run on one private serial queue
/// and never on the main thread. Calls time out quickly instead of hanging if Finder is busy.
nonisolated final class FinderAccessibility: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.narekmynell.PrettyFolder.finder-accessibility", qos: .userInteractive)
    private let systemWide: AXUIElement
    private let log = Logger(subsystem: "com.narekmynell.PrettyFolder", category: "Accessibility")

    init() {
        systemWide = AXUIElementCreateSystemWide()
        // Applies to every element when set on the system-wide one.
        AXUIElementSetMessagingTimeout(systemWide, 0.25)
    }

    /// What Finder shows at `point`, if anything. `answered` is `false` when Finder took too long
    /// to say, which says nothing about what is there.
    func item(at point: CGPoint, finderPID: pid_t, completion: @escaping @Sendable (_ item: FinderItem?, _ answered: Bool) -> Void) {
        queue.async { [self] in
            let (item, answered) = resolveItem(at: point, finderPID: finderPID)
            completion(item, answered)
        }
    }

    /// How far from an icon a hit on what it is wrapped in still counts as being on that icon.
    private static let iconReach: CGFloat = 12

    private func resolveItem(at point: CGPoint, finderPID: pid_t) -> (item: FinderItem?, answered: Bool) {
        var hit: AXUIElement?
        let status = AXUIElementCopyElementAtPosition(systemWide, Float(point.x), Float(point.y), &hit)
        guard status == .success, let hit else {
            log.debug("Hit test at \(point.x, privacy: .public),\(point.y, privacy: .public) failed: \(status.rawValue, privacy: .public)")
            return (nil, status != .cannotComplete)
        }
        var pid: pid_t = 0
        guard AXUIElementGetPid(hit, &pid) == .success, pid == finderPID else {
            log.debug("Hit belongs to pid \(pid, privacy: .public), not Finder (\(finderPID, privacy: .public))")
            return (nil, true)
        }

        // The hit can be the icon, the name, a table cell or the row; walk up a little.
        var node: AXUIElement? = hit
        for _ in 0..<4 {
            guard let current = node else { break }
            if let item = item(from: current) {
                // An empty spot on the Desktop is hit as the group of all its icons, which starts
                // with the first of them, wherever that is.
                let onIt = item.layout == .row || item.iconFrame.insetBy(dx: -Self.iconReach, dy: -Self.iconReach).contains(point)
                return (onIt ? item : nil, true)
            }
            node = parent(of: current)
        }
        log.debug("No item at the pointer (hit \(self.role(of: hit) ?? "?", privacy: .public))")
        return (nil, true)
    }

    private func item(from node: AXUIElement) -> FinderItem? {
        switch role(of: node) {
        case kAXImageRole:
            if let item = iconItem(node) { return item }
            // A list-view icon has no URL of its own; the name next to it does.
            return rowItem(in: parent(of: node))
        case kAXTextFieldRole:
            return fileURL(of: node) == nil ? nil : rowItem(in: parent(of: node))
        case kAXGroupRole:
            // Icon view wraps each item in a group holding one image.
            for child in children(of: node).prefix(4) where role(of: child) == kAXImageRole {
                if let item = iconItem(child) { return item }
            }
            // Column view rows are groups too: an image and a text field.
            return rowItem(in: node)
        case kAXCellRole:
            return rowItem(in: node)
        case kAXRowRole:
            // The name lives in the first cell; the pointer may be over another column.
            for cell in children(of: node).prefix(3) {
                if let item = rowItem(in: cell) { return item }
            }
            return nil
        default:
            return nil
        }
    }

    private func iconItem(_ image: AXUIElement) -> FinderItem? {
        guard let url = fileURL(of: image), let frame = frame(of: image), frame.width > 0 else { return nil }
        return FinderItem(url: url, layout: .icon, iconFrame: frame, nameFrame: nil, rowFrame: nil)
    }

    private func rowItem(in container: AXUIElement?) -> FinderItem? {
        guard let container else { return nil }
        let kids = children(of: container)
        guard let field = kids.first(where: { role(of: $0) == kAXTextFieldRole && fileURL(of: $0) != nil }),
              let url = fileURL(of: field),
              let nameFrame = frame(of: field)
        else { return nil }
        let iconFrame = kids.first { role(of: $0) == kAXImageRole }.flatMap(frame(of:)) ?? nameFrame
        return FinderItem(url: url, layout: .row, iconFrame: iconFrame, nameFrame: nameFrame, rowFrame: frame(of: container))
    }

    // MARK: - Icons on screen

    /// Every icon Finder shows on screen, in its windows on the current Space and on the
    /// Desktop, by file (`ShownIcon.key(for:)`). Only items in view are looked at, so this stays
    /// quick in big folders; `nil` if it takes longer than `limit`, counted from now.
    func shownIcons(finderPID: pid_t, within limit: TimeInterval, completion: @escaping @Sendable ([String: [ShownIcon]]?) -> Void) {
        let deadline = ProcessInfo.processInfo.systemUptime + limit
        queue.async { [self] in
            completion(resolveShownIcons(finderPID: finderPID, deadline: deadline))
        }
    }

    /// A look at Finder's icons under way.
    private struct IconSearch {
        let deadline: TimeInterval
        var found: [String: [ShownIcon]] = [:]

        var isOutOfTime: Bool { ProcessInfo.processInfo.systemUptime > deadline }
    }

    /// The window an icon is in: its frame, and whether it is the Desktop.
    private typealias Place = (frame: CGRect, isDesktop: Bool)

    private func resolveShownIcons(finderPID: pid_t, deadline: TimeInterval) -> [String: [ShownIcon]]? {
        var search = IconSearch(deadline: deadline)
        let app = AXUIElementCreateApplication(finderPID)
        let windows = (value(app, kAXWindowsAttribute) as? [AnyObject] ?? [])
            .compactMap { CFGetTypeID($0) == AXUIElementGetTypeID() ? ($0 as! AXUIElement) : nil }
        for window in windows {
            guard !search.isOutOfTime else { return nil }
            guard let windowFrame = frame(of: window) else { continue }
            // Finder's windows are windows; the Desktop is a scroll area over every display.
            let isDesktop = role(of: window) != kAXWindowRole
            // Content scrolls on under the toolbar, faded; icons there aren't drawn as they are.
            let toolbar = children(of: window).first { role(of: $0) == kAXToolbarRole }.flatMap(frame(of:))
            var area = windowFrame
            if let toolbar { area = CGRect(x: area.minX, y: toolbar.maxY, width: area.width, height: max(0, area.maxY - toolbar.maxY)) }
            collectIcons(in: window, depth: 0, area: area, place: (windowFrame, isDesktop), into: &search)
        }
        return search.isOutOfTime ? nil : search.found
    }

    private func collectIcons(in node: AXUIElement, depth: Int, area: CGRect, place: Place, into search: inout IconSearch) {
        guard depth < 16, !search.isOutOfTime else { return }
        var area = area
        switch role(of: node) {
        case kAXToolbarRole:
            return
        case kAXScrollAreaRole:
            if let frame = frame(of: node) { area = area.intersection(frame) }
        case kAXImageRole:
            // Icon view, the Desktop, the gallery: the icon itself has the URL.
            if let url = fileReference(of: node), let frame = frame(of: node) {
                add(node, at: frame, for: url, area: area, place: place, to: &search)
            }
            return
        default:
            break
        }
        let kids = visibleChildren(of: node)
        // List and column views: the name next to the icon has the URL.
        if let field = kids.first(where: { role(of: $0) == kAXTextFieldRole }), let url = fileReference(of: field),
           let image = kids.first(where: { role(of: $0) == kAXImageRole }), let frame = frame(of: image) {
            add(image, at: frame, for: url, area: area, place: place, to: &search)
            return
        }
        for kid in kids {
            collectIcons(in: kid, depth: depth + 1, area: area, place: place, into: &search)
        }
    }

    private func add(_ image: AXUIElement, at frame: CGRect, for url: URL, area: CGRect, place: Place, to search: inout IconSearch) {
        // Partly scrolled out of view or under the toolbar, it's drawn clipped or faded. A
        // preview that isn't square doesn't say where in it the icon is drawn.
        guard frame.width > 0, abs(frame.width - frame.height) < 1, area.insetBy(dx: -0.5, dy: -0.5).contains(frame),
              let key = ShownIcon.key(for: url)
        else { return }
        let icon = ShownIcon(frame: frame, windowFrame: place.frame, isDesktop: place.isDesktop, element: AXElement(image))
        search.found[key, default: []].append(icon)
    }

    /// Where each icon is now, as found by `shownIcons`; `nil` for one Finder no longer has.
    func currentFrames(of icons: [ShownIcon], completion: @escaping @Sendable ([CGRect?]) -> Void) {
        queue.async { [self] in
            completion(icons.map { frame(of: $0.element.node) })
        }
    }

    /// The children on screen where Finder says which those are (lists and tables), all of them elsewhere.
    private func visibleChildren(of node: AXUIElement) -> [AXUIElement] {
        for attribute in [kAXVisibleChildrenAttribute, kAXVisibleRowsAttribute, kAXChildrenAttribute] {
            if let list = value(node, attribute) as? [AnyObject] {
                return list.compactMap { CFGetTypeID($0) == AXUIElementGetTypeID() ? ($0 as! AXUIElement) : nil }
            }
        }
        return []
    }

    // MARK: - Attribute helpers

    private func value(_ node: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(node, attribute as CFString, &value) == .success else { return nil }
        return value
    }

    private func role(of node: AXUIElement) -> String? {
        value(node, kAXRoleAttribute) as? String
    }

    private func parent(of node: AXUIElement) -> AXUIElement? {
        guard let parent = value(node, kAXParentAttribute), CFGetTypeID(parent) == AXUIElementGetTypeID() else { return nil }
        return (parent as! AXUIElement)
    }

    private func children(of node: AXUIElement) -> [AXUIElement] {
        guard let list = value(node, kAXChildrenAttribute) as? [AnyObject] else { return [] }
        return list.compactMap { CFGetTypeID($0) == AXUIElementGetTypeID() ? ($0 as! AXUIElement) : nil }
    }

    private func frame(of node: AXUIElement) -> CGRect? {
        guard let position = value(node, kAXPositionAttribute), let size = value(node, kAXSizeAttribute),
              CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID()
        else { return nil }
        var origin = CGPoint.zero
        var extent = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &origin),
              AXValueGetValue(size as! AXValue, .cgSize, &extent)
        else { return nil }
        return CGRect(origin: origin, size: extent)
    }

    /// Finder publishes file reference URLs (`file:///.file/id=…`); this turns them into paths.
    private func fileURL(of node: AXUIElement) -> URL? {
        fileReference(of: node).flatMap { ($0 as NSURL).filePathURL }
    }

    private func fileReference(of node: AXUIElement) -> URL? {
        guard let raw = value(node, kAXURLAttribute), CFGetTypeID(raw) == CFURLGetTypeID() else { return nil }
        let url = (raw as! CFURL) as URL
        return url.isFileURL ? url : nil
    }
}

/// A place on screen where Finder shows a file's icon.
nonisolated struct ShownIcon: Sendable {
    /// The icon, in Accessibility coordinates.
    let frame: CGRect
    /// The Finder window it is in, or the Desktop.
    let windowFrame: CGRect
    /// On the Desktop, which is one element over all displays, drawn in a window on each.
    let isDesktop: Bool
    /// Finder's element for the icon, to ask later whether it moved.
    let element: AXElement

    /// Identifies a file however its URL is written: by volume and file number, the way
    /// Finder's file reference URLs do.
    static func key(for url: URL) -> String? {
        let reference = (url as NSURL).isFileReferenceURL() ? url : (url as NSURL).fileReferenceURL()
        guard let reference else { return nil }
        let text = reference.absoluteString
        return text.hasSuffix("/") ? String(text.dropLast()) : text
    }
}

/// Conversions between AppKit screen coordinates (origin bottom-left of the main display)
/// and Accessibility coordinates (origin top-left of the main display).
enum ScreenSpace {
    private static var mainDisplayHeight: CGFloat {
        NSScreen.screens.first?.frame.maxY ?? 0
    }

    static func accessibilityPoint(_ point: NSPoint) -> CGPoint {
        CGPoint(x: point.x, y: mainDisplayHeight - point.y)
    }

    static func appKitRect(_ rect: CGRect) -> NSRect {
        NSRect(x: rect.minX, y: mainDisplayHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    /// The visible frame of the screen that contains most of `rect`.
    static func visibleFrame(containing rect: NSRect) -> NSRect {
        let screen = NSScreen.screens.max { $0.frame.intersection(rect).area < $1.frame.intersection(rect).area }
        return screen?.visibleFrame ?? rect
    }
}

/// Keeps track of Finder's process and answers "is Finder's window under this point?"
/// cheaply, so the Accessibility API is only asked when it can be useful.
final class FinderProcess {
    private(set) var pid: pid_t?
    private var windowOwners: [Int: pid_t] = [:]
    // Only touched in init and deinit; removing observers is thread-safe.
    nonisolated(unsafe) private var observers: [NSObjectProtocol] = []

    init() {
        pid = Self.lookUpFinder()
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                guard app?.bundleIdentifier == "com.apple.finder" else { return }
                MainActor.assumeIsolated {
                    self?.pid = Self.lookUpFinder()
                    self?.windowOwners.removeAll()
                }
            })
        }
    }

    deinit {
        observers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
    }

    /// `true` when the topmost window at `point` (AppKit coordinates) belongs to Finder.
    func ownsWindow(at point: NSPoint) -> Bool {
        guard let pid else { return false }
        let number = NSWindow.windowNumber(at: point, belowWindowWithWindowNumber: 0)
        guard number > 0 else { return false }
        if let owner = windowOwners[number] { return owner == pid }
        let info = CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(number)) as? [[String: Any]]
        // Not found this time (the window is just appearing, say): ask again next time.
        guard let owner = (info?.first?[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value else { return false }
        // Window numbers are not reused quickly, but keep the cache small anyway.
        if windowOwners.count > 256 { windowOwners.removeAll() }
        windowOwners[number] = owner
        return owner == pid
    }

    private static func lookUpFinder() -> pid_t? {
        NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first?.processIdentifier
    }
}

private extension CGRect {
    var area: CGFloat { isNull ? 0 : width * height }
}

/// An Accessibility element. Asking one questions works from any thread.
nonisolated struct AXElement: @unchecked Sendable {
    let node: AXUIElement

    init(_ node: AXUIElement) {
        self.node = node
    }
}

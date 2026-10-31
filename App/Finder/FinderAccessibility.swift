import AppKit
import ApplicationServices
import UniformTypeIdentifiers
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
        guard url.hasDirectoryPath, url.path != "/" else { return false }
        let ext = url.pathExtension
        if !ext.isEmpty, let type = UTType(filenameExtension: ext, conformingTo: .directory), type.conforms(to: .package) {
            return false
        }
        return !url.path.hasPrefix("/Volumes/") || url.pathComponents.count > 3
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

    func item(at point: CGPoint, finderPID: pid_t, completion: @escaping @Sendable (FinderItem?) -> Void) {
        queue.async { [self] in
            completion(resolveItem(at: point, finderPID: finderPID))
        }
    }

    private func resolveItem(at point: CGPoint, finderPID: pid_t) -> FinderItem? {
        var hit: AXUIElement?
        let status = AXUIElementCopyElementAtPosition(systemWide, Float(point.x), Float(point.y), &hit)
        guard status == .success, let hit else {
            log.debug("Hit test at \(point.x, privacy: .public),\(point.y, privacy: .public) failed: \(status.rawValue, privacy: .public)")
            return nil
        }
        var pid: pid_t = 0
        guard AXUIElementGetPid(hit, &pid) == .success, pid == finderPID else {
            log.debug("Hit belongs to pid \(pid, privacy: .public), not Finder (\(finderPID, privacy: .public))")
            return nil
        }

        // The hit can be the icon, the name, a table cell or the row; walk up a little.
        var node: AXUIElement? = hit
        for _ in 0..<4 {
            guard let current = node else { break }
            if let item = item(from: current) { return item }
            node = parent(of: current)
        }
        log.debug("No item at the pointer (hit \(self.role(of: hit) ?? "?", privacy: .public))")
        return nil
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
        guard let raw = value(node, kAXURLAttribute), CFGetTypeID(raw) == CFURLGetTypeID() else { return nil }
        let url = (raw as! CFURL) as URL
        guard url.isFileURL else { return nil }
        return (url as NSURL).filePathURL
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
        let owner = (info?.first?[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value ?? -1
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

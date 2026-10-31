import AppKit
import Observation
import SwiftUI

/// The "Set as Icon" target that appears next to a folder while a picture is dragged over it.
///
/// It is a separate little window, so Finder's own drop target (the folder itself) keeps
/// working exactly as before: drop on the folder to copy the picture in, drop on the
/// badge to make it the folder's icon.
final class DropBadgeController {
    /// Applies the dropped picture; returns whether it worked.
    var onDrop: ((DroppedPicture, URL) async -> Bool)?

    private let model = DropBadgeModel()
    private let panel = OverlayPanel()
    private let targetView: DropTargetView
    private(set) var folder: URL?
    private var hideTask: Task<Void, Never>?

    /// `true` while a drop is being applied; the badge stays up until it is done.
    private(set) var isBusy = false

    init() {
        targetView = DropTargetView(model: model)
        panel.contentView = targetView
        targetView.isAccepting = { [weak self] in self?.folder != nil && self?.isBusy == false }
        targetView.onDrop = { [weak self] picture in self?.accept(picture) }
    }

    /// Shown and meant for a folder (not fading out after a hide).
    var isVisible: Bool { panel.isVisible && folder != nil }

    /// Whether `point` (AppKit screen coordinates) is over the badge.
    func contains(_ point: NSPoint) -> Bool {
        isVisible && panel.frame.insetBy(dx: Self.shadowMargin - 2, dy: Self.shadowMargin - 2).contains(point)
    }

    /// Shows the badge for `item`. Returns `false` when it would land under the pointer:
    /// popping up under the pointer would silently steal the drop from the folder.
    @discardableResult
    func show(for item: FinderItem, pointer: NSPoint) -> Bool {
        guard !isBusy else { return false }
        guard let frame = frame(for: item, avoiding: pointer) else { return false }
        cancelHide()
        folder = item.url
        if model.state != .ready { model.state = .ready }
        let size = fontSize(for: item)
        if model.fontSize != size { model.fontSize = size }
        if panel.frame != frame { panel.setFrame(frame, display: true) }
        if !panel.isVisible {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
        }
        // Also brings it back if it was in the middle of fading out.
        if panel.alphaValue < 1 {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.12
                panel.animator().alphaValue = 1
            }
        }
        return true
    }

    func hide(animated: Bool = true) {
        guard panel.isVisible, folder != nil, !isBusy else { return }
        cancelHide()
        model.state = .ready
        folder = nil
        guard animated else {
            panel.orderOut(nil)
            return
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.1
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                // Shown again while fading out? Then stay.
                guard let self, self.folder == nil else { return }
                self.panel.orderOut(nil)
            }
        })
    }

    /// Hides after a short grace period, so the pointer can travel from the folder to the badge.
    func scheduleHide(after delay: TimeInterval) {
        guard hideTask == nil else { return }
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            self.hideTask = nil
            self.hide()
        }
    }

    func cancelHide() {
        hideTask?.cancel()
        hideTask = nil
    }

    private func accept(_ picture: DroppedPicture) {
        guard let folder, let onDrop else { return }
        isBusy = true
        cancelHide()
        model.state = .working
        Task {
            let succeeded = await onDrop(picture, folder)
            model.state = succeeded ? .done : .failed
            try? await Task.sleep(for: .milliseconds(succeeded ? 700 : 1500))
            isBusy = false
            hide()
        }
    }

    // MARK: - Layout

    /// Room around the pill for its shadow.
    static let shadowMargin: CGFloat = 8

    private func fontSize(for item: FinderItem) -> CGFloat {
        switch item.layout {
        case .icon: min(max(item.iconFrame.height * 0.16, 11), 13)
        case .row: 11
        }
    }

    private func frame(for item: FinderItem, avoiding pointer: NSPoint) -> NSRect? {
        let font = fontSize(for: item)
        let height = item.layout == .icon ? min(max(item.iconFrame.height * 0.36, 24), 32) : 22
        let width = DropBadgeContent.width(fontSize: font, height: height)
        let icon = ScreenSpace.appKitRect(item.iconFrame)
        let margin = Self.shadowMargin
        let keepClear = { (pill: NSRect) in pill.insetBy(dx: -6, dy: -6).contains(pointer) }

        var pill: NSRect
        switch item.layout {
        case .icon:
            // Rides on the top edge of the icon, over the tab: clearly attached to this folder,
            // clear of its neighbours, and most of the folder stays a normal drop target.
            let overlap = min(max(icon.height * 0.25, 6), height * 0.75)
            pill = NSRect(x: icon.midX - width / 2, y: icon.maxY - overlap, width: width, height: height)
            if keepClear(pill) {
                pill.origin.y = icon.maxY + 4
            }
        case .row:
            // Just after the name, inside the folder's own row.
            let name = ScreenSpace.appKitRect(item.nameFrame ?? item.iconFrame)
            let row = ScreenSpace.appKitRect(item.rowFrame ?? item.nameFrame ?? item.iconFrame)
            pill = NSRect(x: name.maxX + 8, y: row.midY - height / 2, width: width, height: height)
            if keepClear(pill) {
                pill.origin.x = pointer.x + 18
            }
        }
        if keepClear(pill) { return nil }

        let screen = ScreenSpace.visibleFrame(containing: icon)
        pill.origin.x = min(max(pill.minX, screen.minX + 2), screen.maxX - pill.width - 2)
        pill.origin.y = min(max(pill.minY, screen.minY + 2), screen.maxY - pill.height - 2)
        if keepClear(pill) { return nil }
        return pill.insetBy(dx: -margin, dy: -margin)
    }
}

@Observable
final class DropBadgeModel {
    enum State { case ready, targeted, working, done, failed }
    var state: State = .ready
    var fontSize: CGFloat = 12
}

/// Hosts the SwiftUI pill and is the actual drag destination.
private final class DropTargetView: NSView {
    var onDrop: ((DroppedPicture) -> Void)?
    /// `false` while the badge is fading out or busy: drops then go nowhere, so refuse them.
    var isAccepting: () -> Bool = { false }
    private let model: DropBadgeModel
    private var lastOperation: NSDragOperation = []

    init(model: DropBadgeModel) {
        self.model = model
        super.init(frame: .zero)
        let host = NSHostingView(rootView: DropBadgeContent(model: model))
        host.translatesAutoresizingMaskIntoConstraints = false
        addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: leadingAnchor),
            host.trailingAnchor.constraint(equalTo: trailingAnchor),
            host.topAnchor.constraint(equalTo: topAnchor),
            host.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        let promiseTypes = NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }
        let dataTypes = ["public.jpeg", "public.heic", "com.compuserve.gif", "public.svg-image", "org.webmproject.webp", "com.microsoft.bmp"]
            .map { NSPasteboard.PasteboardType($0) }
        let basicTypes: [NSPasteboard.PasteboardType] = [.fileURL, .png, .tiff, .pdf]
        registerForDraggedTypes(basicTypes + dataTypes + promiseTypes)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    // The whole badge is one target; the SwiftUI views inside never handle events.
    override func hitTest(_ point: NSPoint) -> NSView? {
        frame.contains(point) ? self : nil
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard isAccepting(), model.state == .ready || model.state == .targeted,
              DroppedPicture.isPresent(on: sender.draggingPasteboard)
        else {
            lastOperation = []
            return []
        }
        model.state = .targeted
        lastOperation = .copy
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        lastOperation
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        if model.state == .targeted { model.state = .ready }
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        lastOperation == .copy && isAccepting()
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let picture = DroppedPicture.read(from: sender.draggingPasteboard) else { return false }
        onDrop?(picture)
        return true
    }
}

struct DropBadgeContent: View {
    let model: DropBadgeModel

    static let title = String(localized: "Set as Icon")

    /// Width of the pill for a given text size, so the window can be sized before showing.
    static func width(fontSize: CGFloat, height: CGFloat) -> CGFloat {
        let font = NSFont.systemFont(ofSize: fontSize, weight: .semibold)
        let text = (title as NSString).size(withAttributes: [.font: font]).width
        return ceil(text + fontSize * 1.3 + 5 + height * 0.9)
    }

    var body: some View {
        HStack(spacing: 5) {
            symbol
                .font(.system(size: model.fontSize, weight: .semibold))
                .frame(width: model.fontSize * 1.3)
            Text(label)
                .font(.system(size: model.fontSize, weight: .semibold))
                .lineLimit(1)
                .fixedSize()
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            Capsule()
                .fill(fill.gradient)
                .shadow(color: .black.opacity(0.35), radius: 4, y: 1.5)
        }
        .overlay {
            Capsule().strokeBorder(.white.opacity(model.state == .targeted ? 0.9 : 0.3), lineWidth: model.state == .targeted ? 2 : 1)
        }
        .scaleEffect(model.state == .targeted ? 1.08 : 1)
        .padding(DropBadgeController.shadowMargin)
        .animation(.spring(response: 0.22, dampingFraction: 0.7), value: model.state)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(Self.title))
    }

    @ViewBuilder
    private var symbol: some View {
        switch model.state {
        case .working:
            ProgressView().controlSize(.mini).tint(.white)
        case .done:
            Image(systemName: "checkmark")
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
        case .ready, .targeted:
            Image(systemName: "photo.badge.plus")
        }
    }

    private var label: String {
        switch model.state {
        case .done: String(localized: "Done")
        case .failed: String(localized: "Can't Use")
        default: Self.title
        }
    }

    private var fill: Color {
        switch model.state {
        case .failed: .red
        case .done: .green
        case .targeted: .accentColor
        default: Color.accentColor.opacity(0.88)
        }
    }
}

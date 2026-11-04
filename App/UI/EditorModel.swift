import AppKit
import Observation
import PrettyFolderKit

/// What the window shows and edits: the picture on one folder (or a few), or the default
/// look that new pictures get.
///
/// A folder's look is written to the folder as soon as a change is finished, so Finder
/// shows it right away; every change to a look can be undone, each on its own. The default
/// look can change many folders at once, so it is only saved on request, with a question
/// about those folders.
@Observable
final class EditorModel {
    enum Scope: Hashable {
        /// The folders the window was opened for.
        case folders
        /// The default look.
        case defaultLook
    }

    @ObservationIgnored let actions: FolderActions
    @ObservationIgnored weak var window: NSWindow?
    @ObservationIgnored weak var undoManager: UndoManager?
    /// Called after the folders' icons changed, so the window can show the new one.
    @ObservationIgnored var onFoldersChanged: (() -> Void)?

    /// The folders being edited; empty when the window only edits the default look. They are
    /// followed when they are renamed or moved while the window is open.
    private(set) var folders: [URL] = []
    /// What the editor works on. A change still going on is finished first, where it began.
    var scope: Scope = .defaultLook {
        willSet { if newValue != scope { finishPendingChange() } }
    }

    /// The folders among `folders` that have a picture from PrettyFolder.
    private(set) var managedFolders: [URL] = []
    /// Their picture (the first one's, when they differ).
    private(set) var folderPicture: SourceImage?
    /// The look the editor shows for them: the first one's.
    private(set) var folderStyle: IconStyle
    /// Where their picture sits in that look and how it is turned: the first one's.
    private(set) var folderPlacement = PicturePlacement.natural
    /// Whether all of them follow the default look.
    private(set) var followsDefault = true
    /// Whether all of their pictures sit in the middle of their rectangle, upright.
    private(set) var isPictureNatural = true
    /// Whether any of them has a custom icon at all, from PrettyFolder or not.
    private(set) var hasCustomIcon = false
    /// Their picture, if they have one, is still being read: when the window opens, say.
    private(set) var isLoadingPicture = false

    /// The default look as it is being edited; `saveDefault()` makes it the default.
    var defaultDraft: IconStyle
    /// A picture chosen just to preview the default look with.
    private(set) var previewPicture: SourceImage?

    /// The lines the picture is lined up with during a drag.
    var guides: [SnapGuide] = []
    /// `true` while the picture is being moved or resized in the editor.
    var isAdjusting = false
    /// `true` while a drag or a gesture in the editor goes on: changes from elsewhere in the
    /// window (Fill or Fit, a quarter turn, reset) wait for it to end.
    private(set) var isHolding = false
    var isAskingAboutExistingFolders = false
    private(set) var followerCount = 0
    /// Work on many folders at once, shown at the bottom of the window.
    let progress = BatchProgress()

    /// A folder's own look (`nil` when it follows the default look), and where its picture sits
    /// in it and how it is turned.
    private struct Look: Equatable {
        var style: IconStyle?
        var placement: PicturePlacement

        /// The default look, picture in the middle and upright: what a folder has to begin with.
        static let followingDefault = Look(style: nil, placement: .natural)
    }

    /// Which parts of the looks a change writes, so that it never writes over the other part
    /// with what the window last read: a new picture comes in the middle, say.
    private enum Parts {
        case style, placement, both
    }

    /// Each folder's look.
    @ObservationIgnored private var looks: [URL: Look] = [:]
    /// The folders as they were opened, to find them after a rename or a move.
    @ObservationIgnored private var bookmarks: [Data?] = []
    /// Goes up whenever the window is opened for other folders. What was done to the folders
    /// before is about the same folders as long as it stays, whatever they are called by then.
    @ObservationIgnored private var opening = 0
    /// Goes up whenever folders that followed the default look stay behind with the old one.
    @ObservationIgnored private var defaultsLeftBehind = 0
    @ObservationIgnored private var folderPictureURL: URL?
    @ObservationIgnored private var loadGeneration = 0
    @ObservationIgnored private var writeGeneration = 0
    @ObservationIgnored private var writing: Task<Void, Never>?
    /// A reload found a change in the editor going on, or newer writes, and left the looks
    /// alone; it is run again once they are done.
    @ObservationIgnored private var reloadIsDue = false
    /// The editor's change in progress (a drag, a pinch, a burst of arrow keys or of scrolling):
    /// what it was made in, and where it started from.
    @ObservationIgnored private var pendingChange: (scope: Scope, opening: Int, start: Layout)?

    /// The look and where the picture sits in it, as the editor shows them.
    private typealias Layout = (style: IconStyle, placement: PicturePlacement)
    /// Learns how saving the default look ended: saved, or not.
    @ObservationIgnored private var afterSavingDefault: ((Bool) -> Void)?

    init(actions: FolderActions) {
        self.actions = actions
        folderStyle = actions.settings.defaultStyle
        defaultDraft = actions.settings.defaultStyle
    }

    var settings: AppSettings { actions.settings }
    var hasFolders: Bool { !folders.isEmpty }
    var isEditingFolders: Bool { scope == .folders && hasFolders }
    var hasPicture: Bool { folderPicture != nil && !managedFolders.isEmpty }
    var isDefaultDirty: Bool { defaultDraft != settings.defaultStyle }

    var title: String {
        switch folders.count {
        case 0: String(localized: "Default Look")
        case 1: FileManager.default.displayName(atPath: folders[0].path)
        default: String(localized: "\(folders.count) Folders")
        }
    }

    /// The picture the editor shows. The default look is previewed with a picture chosen
    /// for that, the folders' own, or a made-up landscape.
    var picture: SourceImage? {
        let folders = hasPicture ? folderPicture : nil
        return isEditingFolders ? folders : previewPicture ?? folders ?? PreviewPicture.sample
    }

    /// The look the editor shows and changes.
    var style: IconStyle {
        get { isEditingFolders ? folderStyle : defaultDraft }
        set {
            if isEditingFolders { folderStyle = newValue } else { defaultDraft = newValue }
        }
    }

    /// Where the picture sits in the look and how it is turned. Only the folders' own picture
    /// moves and turns: the default look always has it in the middle, upright.
    var placement: PicturePlacement {
        get { isEditingFolders ? folderPlacement : .natural }
        set {
            if isEditingFolders { folderPlacement = newValue }
        }
    }

    var canEdit: Bool { isEditingFolders ? hasPicture : true }
    var placesPicture: Bool { isEditingFolders && hasPicture }
    var canReset: Bool {
        isEditingFolders ? hasPicture && !(followsDefault && isPictureNatural) : defaultDraft != IconStyle.standard
    }

    private var layout: Layout { (style, placement) }

    // MARK: - Showing folders

    func show(_ folders: [URL]) {
        finishPendingChange()
        if folders != self.folders {
            undoManager?.removeAllActions(withTarget: self)
            opening += 1
            self.folders = folders
            bookmarks = folders.map { try? $0.bookmarkData() }
            managedFolders = []
            looks = [:]
            folderPicture = nil
            folderPictureURL = nil
            hasCustomIcon = false
            followsDefault = true
            isPictureNatural = true
            folderStyle = settings.defaultStyle
            folderPlacement = .natural
        }
        scope = folders.isEmpty ? .defaultLook : .folders
        isLoadingPicture = !folders.isEmpty && folderPicture == nil
        reload()
    }

    /// The window closed: the pictures go, and come back with the next `reload`. So do the
    /// undo steps, since the pictures may change before the window opens again.
    func windowClosed() {
        finishPendingChange()
        undoManager?.removeAllActions(withTarget: self)
        guides = []
        isAdjusting = false
        folderPicture = nil
        folderPictureURL = nil
        previewPicture = nil
    }

    /// Before quitting or a new picture: finishes the change going on in the editor and waits for
    /// every write. Those would otherwise find no picture left, or land on the new one.
    func finishEditing() async {
        finishPendingChange()
        await writing?.value
    }

    /// Reloads the window if it shows any of `changed`.
    func reload(ifShowing changed: [URL]) {
        let paths = Set(changed.map(\.standardizedFileURL.path))
        if folders.contains(where: { paths.contains($0.standardizedFileURL.path) }) {
            reload()
        }
    }

    /// Reads the folders again: where they are, their picture, their look, whether they have
    /// an icon.
    func reload() {
        reloadIsDue = false
        loadGeneration += 1
        let generation = loadGeneration
        let writesSoFar = writeGeneration
        let bookmarks = self.bookmarks
        let opened = self.folders
        let manager = actions.manager
        let queuedWrites = writing
        Task {
            // Read the folders as they are once the writes already on their way are done.
            await queuedWrites?.value
            // Where they are now (renamed or moved since the window opened?) and whether any
            // has a custom icon. The disk is asked off the main thread.
            let (moved, anyCustomIcon) = await Task.detached(priority: .userInitiated) {
                let moved = Self.locations(of: bookmarks)
                let current = opened.enumerated().map { index, folder in index < moved.count ? moved[index] ?? folder : folder }
                return (moved, current.contains(where: FolderInspector.hasCustomIcon))
            }.value
            guard generation == loadGeneration else { return }
            for (index, location) in moved.enumerated() where index < folders.count {
                if let location, location.path != folders[index].path { follow(folders[index], to: location, at: index) }
            }
            let folders = self.folders
            var found: [(folder: URL, look: FolderLook)] = []
            for folder in folders {
                if let look = await manager.look(for: folder) { found.append((folder, look)) }
            }
            let pictureURL = found.first?.look.pictureURL
            let picture: SourceImage? = if pictureURL == folderPictureURL {
                folderPicture
            } else if let pictureURL {
                await Task.detached(priority: .userInitiated) { PreviewPicture.load(pictureURL) }.value
            } else {
                nil
            }
            // Something newer is on its way.
            guard generation == loadGeneration else { return }
            isLoadingPicture = false
            managedFolders = found.map(\.folder)
            hasCustomIcon = anyCustomIcon
            if pictureURL != folderPictureURL, folderPictureURL != nil {
                // Another picture, or none. What was being done to the old one, and undoing
                // what was done to it, would put that onto this one. Something may still be held
                // on to in the editor; it has the last word until then.
                pendingChange = nil
                reloadIsDue = isHolding
                undoManager?.removeAllActions(withTarget: self)
            }
            // A change in the editor, or one made since this started, is newer than what was read.
            if pendingChange == nil, writesSoFar == writeGeneration {
                looks = Dictionary(
                    found.map { ($0.folder, Look(style: $0.look.followsDefault ? nil : $0.look.style, placement: $0.look.placement)) },
                    uniquingKeysWith: { first, _ in first }
                )
                folderStyle = found.first?.look.style ?? settings.defaultStyle
                folderPlacement = found.first?.look.placement ?? .natural
                followsDefault = found.allSatisfy(\.look.followsDefault)
                isPictureNatural = found.allSatisfy { $0.look.placement == .natural }
            } else {
                reloadIsDue = true
            }
            if pictureURL != folderPictureURL {
                folderPicture = picture
                folderPictureURL = pictureURL
            }
            onFoldersChanged?()
        }
    }

    /// A folder was renamed or moved: it is the same one, with what is known about it.
    private func follow(_ folder: URL, to location: URL, at index: Int) {
        folders[index] = location
        if let look = looks.removeValue(forKey: folder) { looks[location] = look }
        managedFolders = managedFolders.map { $0 == folder ? location : $0 }
    }

    /// Where the folders are now, from their bookmarks; `nil` for one that can't be found.
    nonisolated private static func locations(of bookmarks: [Data?]) -> [URL?] {
        bookmarks.map { bookmark in
            guard let bookmark else { return nil }
            var stale = false
            return try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting], relativeTo: nil, bookmarkDataIsStale: &stale)
        }
    }

    // MARK: - Editing

    /// The editor started a change: a drag, a pinch, a burst of arrow keys or of scrolling.
    /// `holding` for a drag or a gesture, which holds on until it ends.
    func beginChange(holding: Bool = false) {
        guard pendingChange == nil else { return }
        pendingChange = (scope, opening, layout)
        isHolding = holding
    }

    /// The editor finished its change.
    func commit() {
        isHolding = false
        // It may be finished already, because the scope or the folders changed under it.
        if let pending = pendingChange {
            pendingChange = nil
            if pending.scope == scope, pending.opening == opening {
                record(from: pending.start, in: scope)
            }
        }
        if reloadIsDue { reload() }
    }

    /// Finishes a change that is still going on, in what it was made in, as an undo step of
    /// its own: whatever comes next (Fit, reset, undo) is a step of its own too.
    func finishPendingChange() {
        isHolding = false
        guard let pending = pendingChange else { return }
        pendingChange = nil
        if pending.opening == opening {
            record(from: pending.start, in: pending.scope)
        }
        if reloadIsDue { reload() }
    }

    /// Keeps a finished change: writes it to the folders, or keeps it in the draft, and
    /// lets it be undone. A moved or turned picture doesn't give the folders a look of their own.
    private func record(from previous: Layout, in scope: Scope) {
        switch scope {
        case .folders:
            let style = folderStyle, placement = folderPlacement
            let restyled = style != previous.style, placed = placement != previous.placement
            guard hasFolders, hasPicture, restyled || placed else { return }
            change(writing: restyled && placed ? .both : restyled ? .style : .placement) { look in
                if restyled { look.style = style }
                if placed { look.placement = placement }
            }
        case .defaultLook:
            guard defaultDraft != previous.style else { return }
            registerUndo(restoringDraft: previous.style)
        }
    }

    /// Turns the folders' picture a quarter turn, counterclockwise or `clockwise`. It stays
    /// where it is as far as its new size lets it.
    func rotatePicture(clockwise: Bool) {
        guard !isHolding else { return }
        finishPendingChange()
        guard placesPicture, let picture else { return }
        let previous = layout
        placement = StyleEditor.placement(placement, turnedBy: clockwise ? -90 : 90, imageSize: picture.size, style: style)
        record(from: previous, in: scope)
    }

    /// Fill or Fit. The picture stays put as far as the new mode lets it: against the same
    /// edges, or in the middle.
    func setMode(_ mode: FitMode) {
        guard !isHolding else { return }
        finishPendingChange()
        guard style.mode != mode else { return }
        let previous = layout
        style.mode = mode
        record(from: previous, in: scope)
    }

    /// Back to the default look for the folders, picture in the middle; back to the standard
    /// look for the default.
    func reset() {
        guard !isHolding else { return }
        finishPendingChange()
        if isEditingFolders {
            guard canReset else { return }
            change(writing: .both) { $0 = .followingDefault }
        } else {
            guard defaultDraft != IconStyle.standard else { return }
            let previous = defaultDraft
            defaultDraft = IconStyle.standard
            registerUndo(restoringDraft: previous)
        }
    }

    /// Makes the same change to every folder: what the editor shows becomes theirs. With
    /// several folders, they all get the look the editor shows for the first one.
    private func change(writing parts: Parts, _ edit: (inout Look) -> Void) {
        let before = looks
        var after: [URL: Look] = [:]
        for folder in managedFolders {
            var look = before[folder] ?? .followingDefault
            edit(&look)
            after[folder] = look
        }
        apply(after, writing: parts)
        registerUndo(restoring: before)
    }

    /// Shows each folder's look and writes the parts that changed. Writes happen one after
    /// another, in the order they were asked for; if any fails, the folders are read again.
    private func apply(_ newLooks: [URL: Look], writing parts: Parts) {
        looks = newLooks
        let first = managedFolders.first.flatMap { newLooks[$0] }
        folderStyle = first?.style ?? settings.defaultStyle
        folderPlacement = first?.placement ?? .natural
        followsDefault = newLooks.values.allSatisfy { $0.style == nil }
        isPictureNatural = newLooks.values.allSatisfy { $0.placement == .natural }
        writeGeneration += 1
        let manager = actions.manager
        let previous = writing
        let folders = self.folders, bookmarks = self.bookmarks
        writing = Task {
            await previous?.value
            // Where they are by now: one renamed since the window last looked still gets it.
            let locations = await Task.detached(priority: .userInitiated) { Self.locations(of: bookmarks) }.value
            var failures: [FolderOutcome] = []
            for (index, folder) in folders.enumerated() {
                guard let look = newLooks[folder] else { continue }
                let location = (index < locations.count ? locations[index] : nil) ?? folder
                do {
                    switch parts {
                    case .style: try await manager.setStyle(look.style, for: location)
                    case .placement: try await manager.setPlacement(look.placement, for: location)
                    case .both: try await manager.setStyle(look.style, placement: look.placement, for: location)
                    }
                } catch {
                    failures.append(FolderOutcome(folder: location, failure: error.localizedDescription))
                }
            }
            actions.report(failures)
            onFoldersChanged?()
            // Undoing a change that never got there would only fail again.
            if !failures.isEmpty { undoManager?.removeAllActions(withTarget: self) }
            // What the window shows isn't what is on the folders, or a reload waited for this.
            if !failures.isEmpty || reloadIsDue { reload() }
        }
    }

    /// Undo puts every folder back to its own look from before.
    private func registerUndo(restoring looks: [URL: Look]) {
        let opening = self.opening, folders = self.folders, defaultsLeftBehind = self.defaultsLeftBehind
        registerUndoStep(named: String(localized: "Change Look")) { model in
            guard model.opening == opening else { return }
            let current = model.looks
            var restored: [URL: Look] = [:]
            // Under the names they have now.
            for (folder, now) in zip(folders, model.folders) where model.managedFolders.contains(now) {
                guard var look = looks[folder] else { continue }
                // It followed the default look then, but was left with the old one since: going
                // back mustn't take it to the new one it was spared.
                if look.style == nil, model.defaultsLeftBehind != defaultsLeftBehind { look.style = current[now]?.style }
                restored[now] = look
            }
            model.scope = .folders
            model.apply(restored, writing: .both)
            model.registerUndo(restoring: current)
        }
    }

    private func registerUndo(restoringDraft draft: IconStyle) {
        registerUndoStep(named: String(localized: "Change Default Look")) { model in
            let current = model.defaultDraft
            model.scope = .defaultLook
            model.defaultDraft = draft
            model.registerUndo(restoringDraft: current)
        }
    }

    /// Every change is undone on its own, however soon after another it comes: the undo manager
    /// doesn't group by event here (see `EditorUndoManager`). What undoing registers goes among
    /// the redo steps by itself, and the other way round.
    private func registerUndoStep(named name: String, undo: @escaping @MainActor (EditorModel) -> Void) {
        guard let undoManager else { return }
        let isNewStep = !undoManager.isUndoing && !undoManager.isRedoing
        if isNewStep { undoManager.beginUndoGrouping() }
        undoManager.registerUndo(withTarget: self, handler: undo)
        undoManager.setActionName(name)
        if isNewStep { undoManager.endUndoGrouping() }
    }

    // MARK: - Pictures

    /// Chooses a picture for the folders, or one to preview the default look with.
    func choosePicture() {
        if isEditingFolders {
            actions.chooseImage(for: folders, attachedTo: window)
        } else {
            actions.choosePreviewPicture(attachedTo: window) { [weak self] picture in
                self?.previewPicture = picture
            }
        }
    }

    func removePicture() {
        guard isEditingFolders, hasCustomIcon else { return }
        actions.removeImage(from: folders)
    }

    /// A picture dropped on the editor: for the folders, or to preview the default look with.
    func drop(_ file: DroppedImageFile) {
        guard isEditingFolders else {
            Task {
                let url = file.url
                if let picture = await Task.detached(priority: .userInitiated, operation: { PreviewPicture.load(url) }).value {
                    previewPicture = picture
                }
                file.discard()
            }
            return
        }
        let folders = self.folders
        Task {
            await actions.apply(imageAt: file.url, to: folders)
            file.discard()
        }
    }

    // MARK: - Default look

    /// Saves the draft as the default look, first asking about the folders that already
    /// use it. `completion` learns whether it was saved.
    func saveDefault(completion: ((Bool) -> Void)? = nil) {
        finishPendingChange()
        afterSavingDefault = completion
        let manager = actions.manager
        Task {
            followerCount = await manager.folderCountFollowingDefault()
            if followerCount == 0 {
                commitDefault(updateExisting: false)
            } else {
                isAskingAboutExistingFolders = true
            }
        }
    }

    /// Makes the draft the default look. `updateExisting` redraws the folders that follow
    /// the default; otherwise they keep the look they have and only new pictures change.
    func commitDefault(updateExisting: Bool) {
        let style = defaultDraft
        settings.defaultStyle = style
        if updateExisting { progress.start(total: followerCount) } else { defaultsLeftBehind += 1 }
        let reporter = progress.reporter
        let manager = actions.manager
        let completion = afterSavingDefault
        afterSavingDefault = nil
        Task {
            let outcomes = await manager.setDefaultStyle(style, updateExisting: updateExisting, progress: reporter)
            progress.isRunning = false
            actions.report(outcomes)
            reload()
            completion?(true)
        }
    }

    /// The question about existing folders was dismissed: nothing is saved.
    func cancelSavingDefault() {
        let completion = afterSavingDefault
        afterSavingDefault = nil
        completion?(false)
    }

    /// The draft is thrown away, and so are its undo steps.
    func revertDefault() {
        defaultDraft = settings.defaultStyle
        undoManager?.removeAllActions(withTarget: self)
    }

    // MARK: - Every folder

    /// Draws every picture again, for example after a macOS update changed how folders look.
    func redrawAll() {
        guard !progress.isRunning else { return }
        let manager = actions.manager
        Task {
            let count = await manager.managedFolderCount()
            guard count > 0, !progress.isRunning else { return }
            progress.start(total: count)
            let outcomes = await manager.redrawAll(progress: progress.reporter)
            progress.isRunning = false
            actions.report(outcomes)
            reload()
        }
    }

    /// Puts every folder that got a picture from PrettyFolder back to the standard icon,
    /// after asking.
    func removeAll() {
        guard !progress.isRunning, let window else { return }
        let manager = actions.manager
        Task {
            await manager.prune()
            let count = await manager.managedFolderCount()
            guard count > 0 else { return }
            let alert = NSAlert()
            alert.messageText = count == 1
                ? String(localized: "Remove the picture from the folder that has one?")
                : String(localized: "Remove the pictures from all \(count) folders?")
            alert.informativeText = String(localized: "The folders go back to the standard icon. The pictures themselves are not touched.")
            alert.addButton(withTitle: count == 1 ? String(localized: "Remove the Picture") : String(localized: "Remove \(count) Pictures"))
            alert.addButton(withTitle: String(localized: "Cancel"))
            alert.buttons.first?.hasDestructiveAction = true
            alert.beginSheetModal(for: window) { [weak self] response in
                guard response == .alertFirstButtonReturn, let self, !self.progress.isRunning else { return }
                self.progress.start(total: count)
                let reporter = self.progress.reporter
                Task {
                    let outcomes = await manager.removeAll(progress: reporter)
                    self.progress.isRunning = false
                    self.actions.report(outcomes)
                    self.reload()
                }
            }
        }
    }
}

/// The window's undo manager. Every change is a step of its own, so it doesn't group by event:
/// everything registered with it has to be in a group of its own (`EditorModel.registerUndoStep`).
/// Undo and redo finish a change still going on first, whichever way they are asked for, and
/// wait while the pointer or the fingers hold on to something.
final class EditorUndoManager: UndoManager {
    /// Finishes a burst of keys or of scrolling, which then is the step to undo.
    var finishChange: () -> Void = {}
    var isHolding: () -> Bool = { false }

    override init() {
        super.init()
        groupsByEvent = false
    }

    override var canUndo: Bool { !isHolding() && super.canUndo }
    override var canRedo: Bool { !isHolding() && super.canRedo }

    override func undo() {
        guard !isHolding() else { return }
        finishChange()
        super.undo()
    }

    override func redo() {
        guard !isHolding() else { return }
        finishChange()
        super.redo()
    }
}

/// Progress of a long run over many folders; a class so background work can report into it.
@Observable
final class BatchProgress {
    var done = 0
    var total = 0
    var isRunning = false

    func start(total: Int) {
        done = 0
        self.total = max(total, 1)
        isRunning = true
    }

    /// A callback the manager can call from any thread.
    var reporter: @Sendable (Int, Int) -> Void {
        { [weak self] done, total in
            Task { @MainActor in
                self?.done = done
                self?.total = max(total, 1)
            }
        }
    }
}

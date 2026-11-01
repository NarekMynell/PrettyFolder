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
    /// Where their picture sits in that look: the first one's.
    private(set) var folderAlignment = PictureAlignment.centered
    /// Whether all of them follow the default look.
    private(set) var followsDefault = true
    /// Whether all of their pictures sit in the middle of their rectangle.
    private(set) var isPictureCentered = true
    /// Whether any of them has a custom icon at all, from PrettyFolder or not.
    private(set) var hasCustomIcon = false

    /// The default look as it is being edited; `saveDefault()` makes it the default.
    var defaultDraft: IconStyle
    /// A picture chosen just to preview the default look with.
    private(set) var previewPicture: SourceImage?

    /// The lines the picture is lined up with during a drag.
    var guides: [SnapGuide] = []
    /// `true` while the picture is being moved or resized in the editor.
    var isAdjusting = false
    var isAskingAboutExistingFolders = false
    private(set) var followerCount = 0
    /// Work on many folders at once, shown at the bottom of the window.
    let progress = BatchProgress()

    /// A folder's own look (`nil` when it follows the default look) and where its picture sits in it.
    private struct Look: Equatable {
        var style: IconStyle?
        var alignment: PictureAlignment

        /// The default look, picture in the middle: what a folder has to begin with.
        static let followingDefault = Look(style: nil, alignment: .centered)
    }

    /// Which parts of the looks a change writes, so that it never writes over the other part
    /// with what the window last read: a new picture comes in the middle, say.
    private enum Parts {
        case style, alignment, both
    }

    /// Each folder's look.
    @ObservationIgnored private var looks: [URL: Look] = [:]
    /// The folders as they were opened, to find them after a rename or a move.
    @ObservationIgnored private var bookmarks: [Data?] = []
    @ObservationIgnored private var folderPictureURL: URL?
    @ObservationIgnored private var loadGeneration = 0
    @ObservationIgnored private var writeGeneration = 0
    @ObservationIgnored private var writing: Task<Void, Never>?
    /// A reload found a change in the editor going on, or newer writes, and left the looks
    /// alone; it is run again once they are done.
    @ObservationIgnored private var reloadIsDue = false
    /// The editor's change in progress (a drag, a pinch, a burst of arrow keys): what it
    /// was made in, and where it started from.
    @ObservationIgnored private var pendingChange: (scope: Scope, folders: [URL], start: Placement)?

    /// The look and where the picture sits in it, as the editor shows them.
    private typealias Placement = (style: IconStyle, alignment: PictureAlignment)
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

    /// Where the picture sits in the look. Only the folders' own picture moves: the default
    /// look always has it in the middle.
    var alignment: PictureAlignment {
        get { isEditingFolders ? folderAlignment : .centered }
        set {
            if isEditingFolders { folderAlignment = newValue }
        }
    }

    var canEdit: Bool { isEditingFolders ? hasPicture : true }
    var movesPicture: Bool { isEditingFolders && hasPicture }
    var canReset: Bool {
        isEditingFolders ? hasPicture && !(followsDefault && isPictureCentered) : defaultDraft != IconStyle.standard
    }

    private var placement: Placement { (style, alignment) }

    // MARK: - Showing folders

    func show(_ folders: [URL]) {
        finishPendingChange()
        if folders != self.folders {
            undoManager?.removeAllActions(withTarget: self)
            self.folders = folders
            bookmarks = folders.map { try? $0.bookmarkData() }
            managedFolders = []
            looks = [:]
            folderPicture = nil
            folderPictureURL = nil
            hasCustomIcon = false
            followsDefault = true
            isPictureCentered = true
            folderStyle = settings.defaultStyle
            folderAlignment = .centered
        }
        scope = folders.isEmpty ? .defaultLook : .folders
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

    /// Before quitting: finishes the change going on in the editor and waits for every write.
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
                if let location, location.path != folders[index].path { folders[index] = location }
            }
            let folders = self.folders
            var found: [(folder: URL, look: FolderLook)] = []
            for folder in folders {
                if let look = await manager.look(for: folder) { found.append((folder, look)) }
            }
            let pictureURL = found.first?.look.pictureURL
            let picture: SourceImage? = if let pictureURL, pictureURL != folderPictureURL {
                await Task.detached(priority: .userInitiated) { PreviewPicture.load(pictureURL) }.value
            } else {
                folderPicture
            }
            // Something newer is on its way.
            guard generation == loadGeneration else { return }
            managedFolders = found.map(\.folder)
            hasCustomIcon = anyCustomIcon
            if pictureURL != folderPictureURL, folderPictureURL != nil {
                // Another picture, or none. What was being done to the old one, and undoing
                // what was done to it, would put that onto this one.
                pendingChange = nil
                undoManager?.removeAllActions(withTarget: self)
            }
            // A change in the editor, or one made since this started, is newer than what was read.
            if pendingChange == nil, writesSoFar == writeGeneration {
                looks = Dictionary(
                    found.map { ($0.folder, Look(style: $0.look.followsDefault ? nil : $0.look.style, alignment: $0.look.alignment)) },
                    uniquingKeysWith: { first, _ in first }
                )
                folderStyle = found.first?.look.style ?? settings.defaultStyle
                folderAlignment = found.first?.look.alignment ?? .centered
                followsDefault = found.allSatisfy(\.look.followsDefault)
                isPictureCentered = found.allSatisfy { $0.look.alignment == .centered }
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

    /// Where the folders are now, from their bookmarks; `nil` for one that can't be found.
    nonisolated private static func locations(of bookmarks: [Data?]) -> [URL?] {
        bookmarks.map { bookmark in
            guard let bookmark else { return nil }
            var stale = false
            return try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting], relativeTo: nil, bookmarkDataIsStale: &stale)
        }
    }

    // MARK: - Editing

    /// The editor started a change: a drag, a pinch, a burst of arrow keys.
    func beginChange() {
        guard pendingChange == nil else { return }
        pendingChange = (scope, folders, placement)
    }

    /// The editor finished its change.
    func commit() {
        // Already finished, because the scope or the folders changed under it.
        guard let pending = pendingChange else { return }
        pendingChange = nil
        if pending.scope == scope, pending.folders == folders {
            record(from: pending.start, in: scope)
        }
        if reloadIsDue { reload() }
    }

    /// Finishes a change that is still going on, in what it was made in, as an undo step of
    /// its own: whatever comes next in the same moment (Fit, reset) is undone separately.
    private func finishPendingChange() {
        guard let pending = pendingChange else { return }
        pendingChange = nil
        if pending.folders == folders {
            record(from: pending.start, in: pending.scope)
            if let undoManager, undoManager.groupingLevel > 0, !undoManager.isUndoing, !undoManager.isRedoing {
                undoManager.endUndoGrouping()
                undoManager.beginUndoGrouping()
            }
        }
        if reloadIsDue { reload() }
    }

    /// Keeps a finished change: writes it to the folders, or keeps it in the draft, and
    /// lets it be undone. A moved picture doesn't give the folders a look of their own.
    private func record(from previous: Placement, in scope: Scope) {
        switch scope {
        case .folders:
            let style = folderStyle, alignment = folderAlignment
            let restyled = style != previous.style, moved = alignment != previous.alignment
            guard hasFolders, hasPicture, restyled || moved else { return }
            change(writing: restyled && moved ? .both : restyled ? .style : .alignment) { look in
                if restyled { look.style = style }
                if moved { look.alignment = alignment }
            }
        case .defaultLook:
            guard defaultDraft != previous.style else { return }
            registerUndo(restoringDraft: previous.style)
        }
    }

    func setMode(_ mode: FitMode) {
        finishPendingChange()
        let previous = placement
        style.mode = mode
        record(from: previous, in: scope)
    }

    /// Back to the default look for the folders, picture in the middle; back to the standard
    /// look for the default.
    func reset() {
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
        folderAlignment = first?.alignment ?? .centered
        followsDefault = newLooks.values.allSatisfy { $0.style == nil }
        isPictureCentered = newLooks.values.allSatisfy { $0.alignment == .centered }
        writeGeneration += 1
        let manager = actions.manager
        let previous = writing
        writing = Task {
            await previous?.value
            var failures: [FolderOutcome] = []
            for (folder, look) in newLooks {
                do {
                    switch parts {
                    case .style: try await manager.setStyle(look.style, for: folder)
                    case .alignment: try await manager.setAlignment(look.alignment, for: folder)
                    case .both: try await manager.setStyle(look.style, alignment: look.alignment, for: folder)
                    }
                } catch {
                    failures.append(FolderOutcome(folder: folder, failure: error.localizedDescription))
                }
            }
            actions.report(failures)
            onFoldersChanged?()
            // What the window shows isn't what is on the folders, or a reload waited for this.
            if !failures.isEmpty || reloadIsDue { reload() }
        }
    }

    /// Undo puts every folder back to its own look from before.
    private func registerUndo(restoring looks: [URL: Look]) {
        guard let undoManager else { return }
        let folders = self.folders
        undoManager.registerUndo(withTarget: self) { model in
            guard model.folders == folders else { return }
            model.dropPendingChange()
            let current = model.looks
            model.scope = .folders
            model.apply(looks.filter { model.managedFolders.contains($0.key) }, writing: .both)
            model.registerUndo(restoring: current)
        }
        undoManager.setActionName(String(localized: "Change Look"))
    }

    private func registerUndo(restoringDraft draft: IconStyle) {
        guard let undoManager else { return }
        undoManager.registerUndo(withTarget: self) { model in
            model.dropPendingChange()
            let current = model.defaultDraft
            model.scope = .defaultLook
            model.defaultDraft = draft
            model.registerUndo(restoringDraft: current)
        }
        undoManager.setActionName(String(localized: "Change Default Look"))
    }

    /// Undo goes back past anything the editor still had going; recording it now would put it
    /// among the redo steps. (The editor finishes its arrow keys before it undoes.)
    private func dropPendingChange() {
        pendingChange = nil
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
        progress.start(total: updateExisting ? followerCount : 0)
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

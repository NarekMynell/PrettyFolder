import AppKit
import Observation
import PrettyFolderKit

/// What the window shows and edits: the picture on one folder (or a few), or the default
/// look that new pictures get.
///
/// A folder's look is written to the folder as soon as a change is finished, so Finder
/// shows it right away; every change can be undone. The default look can change many
/// folders at once, so it is only saved on request, with a question about those folders.
@Observable
final class EditorModel {
    enum Scope: Hashable {
        /// The folders the window was opened for.
        case folders
        /// The default look.
        case standard
    }

    @ObservationIgnored let actions: FolderActions
    @ObservationIgnored weak var window: NSWindow?
    @ObservationIgnored weak var undoManager: UndoManager?
    /// Called after the folders' icons changed, so the window can show the new one.
    @ObservationIgnored var onFoldersChanged: (() -> Void)?

    /// The folders being edited; empty when the window only edits the default look.
    private(set) var folders: [URL] = []
    var scope: Scope = .standard

    /// The folders among `folders` that have a picture from PrettyFolder.
    private(set) var managedFolders: [URL] = []
    /// Their picture (the first one's, when they differ).
    private(set) var folderPicture: SourceImage?
    /// Their look: their own, or the default look they follow.
    private(set) var folderStyle: IconStyle
    private(set) var followsDefault = true
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
    let progress = BatchProgress()

    @ObservationIgnored private var folderPictureURL: URL?
    @ObservationIgnored private var loadGeneration = 0
    @ObservationIgnored private var writing: Task<Void, Never>?

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

    var canEdit: Bool { isEditingFolders ? hasPicture : true }
    var canReset: Bool { isEditingFolders ? hasPicture && !followsDefault : defaultDraft != .standard }

    // MARK: - Showing folders

    func show(_ folders: [URL]) {
        if folders != self.folders {
            undoManager?.removeAllActions(withTarget: self)
            self.folders = folders
            managedFolders = []
            folderPicture = nil
            folderPictureURL = nil
            hasCustomIcon = false
            followsDefault = true
            folderStyle = settings.defaultStyle
        }
        scope = folders.isEmpty ? .standard : .folders
        reload()
    }

    /// Reloads the window if it shows any of `changed`.
    func reload(ifShowing changed: [URL]) {
        let paths = Set(changed.map(\.standardizedFileURL.path))
        if folders.contains(where: { paths.contains($0.standardizedFileURL.path) }) {
            reload()
        }
    }

    /// Reads the folders again: their picture, their look, whether they have an icon.
    func reload() {
        loadGeneration += 1
        let generation = loadGeneration
        let folders = self.folders
        let manager = actions.manager
        Task {
            var managed: [URL] = []
            var first: FolderLook?
            for folder in folders {
                guard let look = await manager.look(for: folder) else { continue }
                managed.append(folder)
                if first == nil { first = look }
            }
            // Something newer is on its way.
            guard generation == loadGeneration else { return }
            managedFolders = managed
            hasCustomIcon = folders.contains(where: FolderInspector.hasCustomIcon)
            if let first {
                // Mid-drag, the editor's look is the newest; it is written when the drag ends.
                if !isAdjusting {
                    folderStyle = first.style
                    followsDefault = first.followsDefault
                }
                if first.pictureURL != folderPictureURL {
                    folderPicture = PreviewPicture.load(first.pictureURL)
                    folderPictureURL = first.pictureURL
                }
            } else {
                folderPicture = nil
                folderPictureURL = nil
                folderStyle = settings.defaultStyle
                followsDefault = true
            }
            onFoldersChanged?()
        }
    }

    // MARK: - Editing

    /// A change in the editor is finished; `previous` is the look from before it.
    func commit(from previous: IconStyle) {
        guard style != previous else { return }
        if isEditingFolders {
            let before: IconStyle? = followsDefault ? nil : previous
            write(style)
            registerUndo(restoringFolderStyle: before)
        } else {
            registerUndo(restoringDraft: previous)
        }
    }

    func setMode(_ mode: FitMode) {
        let previous = style
        style.mode = mode
        commit(from: previous)
    }

    /// Back to the default look for the folders, back to the standard look for the default.
    func reset() {
        if isEditingFolders {
            guard hasPicture, !followsDefault else { return }
            let previous = folderStyle
            write(nil)
            registerUndo(restoringFolderStyle: previous)
        } else {
            let previous = defaultDraft
            defaultDraft = .standard
            registerUndo(restoringDraft: previous)
        }
    }

    /// Gives the folders `style`, or makes them follow the default look again with `nil`.
    /// Writes happen one after another, in the order they were asked for.
    private func write(_ style: IconStyle?) {
        folderStyle = style ?? settings.defaultStyle
        followsDefault = style == nil
        let folders = managedFolders
        let manager = actions.manager
        let previous = writing
        writing = Task {
            await previous?.value
            var failures: [FolderOutcome] = []
            for folder in folders {
                do {
                    try await manager.setStyle(style, for: folder)
                } catch {
                    failures.append(FolderOutcome(folder: folder, failure: error.localizedDescription))
                }
            }
            actions.report(failures)
            onFoldersChanged?()
        }
    }

    private func registerUndo(restoringFolderStyle style: IconStyle?) {
        guard let undoManager else { return }
        let folders = self.folders
        undoManager.registerUndo(withTarget: self) { model in
            guard model.folders == folders, model.hasPicture else { return }
            let current: IconStyle? = model.followsDefault ? nil : model.folderStyle
            model.scope = .folders
            model.write(style)
            model.registerUndo(restoringFolderStyle: current)
        }
        undoManager.setActionName(String(localized: "Change Look"))
    }

    private func registerUndo(restoringDraft draft: IconStyle) {
        guard let undoManager else { return }
        undoManager.registerUndo(withTarget: self) { model in
            let current = model.defaultDraft
            model.scope = .standard
            model.defaultDraft = draft
            model.registerUndo(restoringDraft: current)
        }
        undoManager.setActionName(String(localized: "Change Default Look"))
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
            if let picture = PreviewPicture.load(file.url) { previewPicture = picture }
            file.discard()
            return
        }
        let folders = self.folders
        Task {
            await actions.apply(imageAt: file.url, to: folders)
            file.discard()
        }
    }

    // MARK: - Default look

    func saveDefault() {
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
        Task {
            let outcomes = await manager.setDefaultStyle(style, updateExisting: updateExisting, progress: reporter)
            progress.isRunning = false
            actions.report(outcomes)
            reload()
        }
    }

    func revertDefault() {
        defaultDraft = settings.defaultStyle
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

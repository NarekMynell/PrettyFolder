import AppKit
import CoreTransferable
import Observation
import PrettyFolderKit
import SwiftUI
import UniformTypeIdentifiers

/// PrettyFolder's one window: the picture on a folder, where it sits and how it is
/// scaled, the default look, and the few settings there are (behind the gear).
final class EditorWindowController: NSWindowController, NSWindowDelegate {
    let model: EditorModel

    init(actions: FolderActions) {
        model = EditorModel(actions: actions)
        let hosting = NSHostingController(rootView: EditorView(model: model))
        hosting.sizingOptions = [.preferredContentSize]
        let window = NSWindow(contentViewController: hosting)
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.collectionBehavior.insert(.fullScreenNone)

        super.init(window: window)
        window.delegate = self
        // Where it was left last time, or the middle of the screen the first time.
        if !window.setFrameUsingName("Editor") {
            window.center()
        }
        window.setFrameAutosaveName("Editor")
        model.window = window
        model.onFoldersChanged = { [weak self] in self?.updateTitle() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Shows the window for `folders`; with none, as it was, or for the default look.
    func show(folders: [URL]) {
        if !folders.isEmpty || window?.isVisible != true {
            model.show(folders)
        }
        updateTitle()
        AppActivation.bringToFront(window)
    }

    private func updateTitle() {
        guard let window else { return }
        window.title = model.title
        // Setting it again also picks up the folder's new icon.
        window.representedURL = nil
        window.representedURL = model.folders.count == 1 ? model.folders[0] : nil
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard model.isDefaultDirty else { return true }
        confirmUnsavedDefault { [weak sender] proceed in
            if proceed { sender?.close() }
        }
        return false
    }

    /// Asks what to do with a default look that hasn't been saved: save it, discard it, or
    /// stay. `completion` learns whether to go ahead (closing, quitting).
    func confirmUnsavedDefault(completion: @escaping (Bool) -> Void) {
        guard let window, model.isDefaultDirty else {
            completion(true)
            return
        }
        AppActivation.bringToFront(window)
        let alert = NSAlert()
        alert.messageText = String(localized: "Keep the new default look?")
        alert.informativeText = String(localized: "It hasn't been saved yet.")
        alert.addButton(withTitle: String(localized: "Save"))
        alert.addButton(withTitle: String(localized: "Discard"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return completion(true) }
            switch response {
            case .alertFirstButtonReturn:
                model.scope = .standard
                model.saveDefault(completion: completion)
            case .alertSecondButtonReturn:
                model.revertDefault()
                completion(true)
            default:
                completion(false)
            }
        }
    }

    func windowWillClose(_ notification: Notification) {
        model.guides = []
        model.isAdjusting = false
    }
}

private struct EditorView: View {
    @Bindable var model: EditorModel
    @Environment(\.undoManager) private var undoManager
    @State private var isDropTargeted = false

    private let editorSide: CGFloat = 300

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                if model.hasFolders {
                    Picker("Edit", selection: $model.scope) {
                        Text(model.folders.count == 1 ? "This Folder" : "These Folders").tag(EditorModel.Scope.folders)
                        Text("Default").tag(EditorModel.Scope.standard)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
                HStack {
                    Spacer()
                    PreferencesButton(model: model)
                }
            }
            .frame(height: 28)
            .padding(.horizontal, 14)
            .padding(.top, 2)

            stage
                .padding(.horizontal, 22)
                .padding(.top, 10)

            tools
                .padding(.horizontal, 22)
                .padding(.vertical, 16)

            if model.progress.isRunning {
                ProgressView(value: Double(model.progress.done), total: Double(model.progress.total))
                    .padding(.horizontal, 22)
                    .padding(.bottom, 14)
            }

            SetupBar()
        }
        .frame(width: 384)
        .onAppear { model.undoManager = undoManager }
        .onChange(of: undoManager) { model.undoManager = undoManager }
        .confirmationDialog("Update existing folders too?", isPresented: $model.isAskingAboutExistingFolders) {
            Button(model.followerCount == 1 ? LocalizedStringKey("Update It Too") : "Update All \(model.followerCount) Folders") {
                model.commitDefault(updateExisting: true)
            }
            Button("Only New Pictures") { model.commitDefault(updateExisting: false) }
            Button("Cancel", role: .cancel) { model.cancelSavingDefault() }
        } message: {
            Text(model.followerCount == 1
                 ? LocalizedStringKey("One folder uses the default look. It can switch to the new look now, or keep its current look while only new pictures get the new one.")
                 : "\(model.followerCount) folders use the default look. They can switch to the new look now, or keep their current look while only new pictures get the new one.")
        }
    }

    // MARK: - The folder

    private var stage: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color.primary.opacity(0.045))
            StyleEditor(
                style: $model.style,
                guides: $model.guides,
                isAdjusting: $model.isAdjusting,
                picture: model.picture,
                isEnabled: model.canEdit,
                side: editorSide,
                onBegin: { model.beginChange() },
                onCommit: { model.commit(from: $0) },
                onReset: { model.reset() }
            )
            if model.isEditingFolders && !model.hasPicture {
                addButton
            }
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(Color.accentColor, lineWidth: 2.5)
            }
        }
        .frame(height: editorSide + 36)
        .dropDestination(for: DroppedImageFile.self) { files, _ in
            guard let file = files.first else { return false }
            files.dropFirst().forEach { $0.discard() }
            model.drop(file)
            return true
        } isTargeted: { isDropTargeted = $0 }
    }

    /// A folder without a picture: a big button where the picture will go.
    private var addButton: some View {
        let target = IconGeometry.targetRect(for: model.style, canvas: editorSide, flipped: true)
        return Button { model.choosePicture() } label: {
            Image(systemName: "photo.badge.plus")
                .font(.system(size: 30, weight: .medium))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.18), radius: 3, y: 1)
                .frame(width: target.width, height: target.height)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .offset(x: target.midX - editorSide / 2, y: target.midY - editorSide / 2)
        .help("Choose a Picture…")
        .accessibilityLabel(Text("Choose a Picture"))
    }

    // MARK: - Tools

    private var tools: some View {
        HStack(spacing: 10) {
            ToolButton(
                symbol: "photo.badge.plus",
                help: model.isEditingFolders ? "Choose a Picture…" : "Preview with Another Picture…"
            ) { model.choosePicture() }

            Spacer(minLength: 8)
            Picker("Scaling", selection: Binding(get: { model.style.mode }, set: { model.setMode($0) })) {
                Text("Fill").tag(FitMode.fill)
                Text("Fit").tag(FitMode.fit)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .disabled(!model.canEdit)
            .help(model.style.mode == .fill
                  ? "Fill: the picture covers the whole rectangle; what doesn't fit is cropped."
                  : "Fit: the whole picture shows and grows until it touches the rectangle's sides.")
            Spacer(minLength: 8)

            ToolButton(
                symbol: "arrow.counterclockwise",
                help: model.isEditingFolders ? "Use the Default Look" : "Back to the Standard Look"
            ) { model.reset() }
                .disabled(!model.canReset)

            if model.isEditingFolders {
                ToolButton(symbol: "trash", help: "Remove the Picture") { model.removePicture() }
                    .disabled(!model.hasCustomIcon)
            } else {
                Button("Save") { model.saveDefault() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(!model.isDefaultDirty || model.progress.isRunning)
                    .help("Make this the default look")
            }
        }
    }
}

private struct ToolButton: View {
    let symbol: String
    let help: LocalizedStringKey
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 18, height: 18)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.circle)
        .controlSize(.large)
        .help(help)
        .accessibilityLabel(Text(help))
    }
}

/// Shown only while something is missing: the Finder menu or the Accessibility permission.
private struct SetupBar: View {
    @State private var finderExtension = FinderExtensionStatus.shared
    @State private var permission = AccessibilityPermission.shared

    var body: some View {
        Group {
            if !finderExtension.isEnabled || !permission.isGranted {
                VStack(spacing: 0) {
                    Divider()
                    HStack(spacing: 8) {
                        if !finderExtension.isEnabled {
                            Button { finderExtension.enable() } label: {
                                Label("Turn On Finder Menu", systemImage: "contextualmenu.and.cursorarrow")
                            }
                            .help("Adds Folder Picture… to the menu you get by right-clicking a folder.")
                        }
                        if !permission.isGranted {
                            Button { permission.request() } label: {
                                Label("Allow Accessibility", systemImage: "hand.point.up.left")
                            }
                            .help("Lets PrettyFolder see which folder is under the pointer, for Set as Icon and the buttons on folders. Nothing else is read.")
                        }
                    }
                    .controlSize(.small)
                    .padding(.vertical, 12)
                }
            }
        }
        .onAppear {
            finderExtension.refresh()
            permission.refresh()
        }
    }
}

/// A picture dropped on the window, copied to a folder of its own: whatever was dragged
/// (a file from Finder, a photo from Photos, an image from Safari) is only lent for the
/// moment of the drop.
struct DroppedImageFile: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .image) { try DroppedImageFile(copying: $0.file) }
        FileRepresentation(importedContentType: .pdf) { try DroppedImageFile(copying: $0.file) }
    }

    private init(copying file: URL) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PrettyFolder-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        url = directory.appendingPathComponent(file.lastPathComponent)
        try FileManager.default.copyItem(at: file, to: url)
    }

    /// Deletes the copy once it has been used.
    func discard() {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }
}

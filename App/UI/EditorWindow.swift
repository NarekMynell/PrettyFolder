import AppKit
import CoreTransferable
import Observation
import PrettyFolderKit
import SwiftUI
import UniformTypeIdentifiers

/// PrettyFolder's one window: the picture on a folder, where it sits and how it is
/// scaled, the default look, and the few settings there are (behind the gear).
final class EditorWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation {
    let model: EditorModel
    /// The newest icon shown in the title bar; an older one that comes in later is ignored.
    private var titleIconSequence = Int.min

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
        let represented = model.folders.count == 1 ? model.folders[0] : nil
        // The icon comes from the folder: set again, it shows a removed picture is gone. A
        // new picture comes through `showIcon` instead.
        if window.representedURL != represented || !model.hasCustomIcon {
            window.representedURL = nil
            window.representedURL = represented
        }
    }

    /// The folder's new icon, in the title bar. Asked for by its file, macOS would show a
    /// plain folder for a moment while it loads the new one.
    func showIcon(_ icon: RenderedIcon, for folder: URL) {
        guard icon.sequence > titleIconSequence, let window, let represented = window.representedURL,
              represented.standardizedFileURL.path == folder.standardizedFileURL.path,
              let button = window.standardWindowButton(.documentIconButton),
              let small = icon.image.copy() as? NSImage
        else { return }
        titleIconSequence = icon.sequence
        small.size = button.image?.size ?? NSSize(width: 16, height: 16)
        button.image = small
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
                model.scope = .defaultLook
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
        model.windowClosed()
    }

    // ⌘L and ⌘R turn the picture wherever the keyboard's focus is in the window; the editor
    // takes them first when it has it.
    @objc func rotateLeft(_ sender: Any?) {
        model.rotatePicture(clockwise: false)
    }

    @objc func rotateRight(_ sender: Any?) {
        model.rotatePicture(clockwise: true)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(rotateLeft(_:)), #selector(rotateRight(_:)):
            return model.placesPicture && !model.isHolding
        default:
            return true
        }
    }

    /// Back from Finder: the folders may have been renamed, or their pictures changed there.
    func windowDidBecomeKey(_ notification: Notification) {
        if model.hasFolders { model.reload() }
    }
}

private struct EditorView: View {
    @Bindable var model: EditorModel
    @Environment(\.undoManager) private var undoManager
    @State private var isDropTargeted = false
    @State private var turnLink = TurnLink()

    private let editorSide = StyleEditor.side

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                if model.hasFolders {
                    Picker("Edit", selection: $model.scope) {
                        Text(model.folders.count == 1 ? "This Folder" : "These Folders").tag(EditorModel.Scope.folders)
                        Text("Default").tag(EditorModel.Scope.defaultLook)
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

            turnBar
                .padding(.horizontal, 22)
                .padding(.top, 10)

            tools
                .padding(.horizontal, 22)
                .padding(.top, 12)
                .padding(.bottom, 16)

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
                placement: $model.placement,
                guides: $model.guides,
                isAdjusting: $model.isAdjusting,
                picture: model.picture,
                isEnabled: model.canEdit,
                placesPicture: model.placesPicture,
                side: editorSide,
                onBegin: { model.beginChange(holding: $0) },
                onCommit: { model.commit() },
                turnLink: turnLink
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

    /// A folder without a picture: a big button where the picture will go, on the folder.
    private var addButton: some View {
        let canvas = CGRect(x: 0, y: 0, width: editorSide, height: editorSide)
        let target = IconGeometry.targetRect(for: model.style, canvas: editorSide, flipped: true).intersection(canvas)
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

    // MARK: - Turning

    /// The dial that turns the picture to any angle, between quarter turns either way. Only a
    /// folder's own picture turns: the default look keeps it upright.
    private var turnBar: some View {
        let canTurn = model.placesPicture && !model.isHolding
        return HStack(spacing: 6) {
            QuarterTurnButton(symbol: "rotate.left", help: "Rotate Left 90° (⌘L)", label: "Rotate Left") {
                model.rotatePicture(clockwise: false)
            }
            .disabled(!canTurn)
            TurnDial(degrees: model.placement.rotation, isEnabled: model.placesPicture, link: turnLink)
                .frame(height: TurnDialView.height)
            QuarterTurnButton(symbol: "rotate.right", help: "Rotate Right 90° (⌘R)", label: "Rotate Right") {
                model.rotatePicture(clockwise: true)
            }
            .disabled(!canTurn)
        }
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
            }

            // Folders change as you go, so there is nothing to save for them: Done only
            // closes. A new default look waits for Save until it is saved or discarded.
            if !model.isEditingFolders && model.isDefaultDirty {
                Button("Save") { model.saveDefault() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.progress.isRunning)
                    .help("Make this the default look")
            } else {
                Button("Done") { model.window?.performClose(nil) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
            }
        }
    }
}

/// A quarter turn, beside the dial: lighter than the tools, as part of it.
private struct QuarterTurnButton: View {
    let symbol: String
    let help: LocalizedStringKey
    let label: LocalizedStringKey
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .regular))
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .opacity(isEnabled ? 1 : 0.4)
        .help(help)
        .accessibilityLabel(Text(label))
    }
}

private struct ToolButton: View {
    let symbol: String
    let help: LocalizedStringKey
    /// What VoiceOver says; the help, unless that tells more than the button's name.
    var label: LocalizedStringKey?
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
        .accessibilityLabel(Text(label ?? help))
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
        do {
            try FileManager.default.copyItem(at: file, to: url)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    /// Deletes the copy once it has been used.
    func discard() {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }
}

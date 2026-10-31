import AppKit
import Observation
import PrettyFolderKit
import SwiftUI

/// The per-folder look editor: where this folder's picture sits and how it is scaled.
final class FolderLookWindowController: SwiftUIWindowController {
    init(look: FolderLook, actions: FolderActions) {
        let model = FolderLookModel(look: look, defaultStyle: actions.settings.defaultStyle)
        let name = FileManager.default.displayName(atPath: look.folder.path)
        var closeWindow: () -> Void = {}
        let view = FolderLookView(model: model, actions: actions, close: { closeWindow() })
        super.init(title: String(localized: "“\(name)” Picture"), rootView: view)
        closeWindow = { [weak self] in self?.close() }
    }
}

@Observable
final class FolderLookModel {
    let folder: URL
    let picture: NSImage?
    var style: IconStyle
    var followsDefault: Bool
    var isSaving = false

    init(look: FolderLook, defaultStyle: IconStyle) {
        folder = look.folder
        picture = PreviewPicture.load(look.pictureURL)
        style = look.style
        followsDefault = look.followsDefault
    }
}

private struct FolderLookView: View {
    @Bindable var model: FolderLookModel
    let actions: FolderActions
    let close: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 28) {
            StyleEditor(
                style: model.followsDefault ? .constant(actions.settings.defaultStyle) : $model.style,
                picture: model.picture,
                isEnabled: !model.followsDefault
            )
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(FileManager.default.displayName(atPath: model.folder.path))
                        .font(.title3.weight(.semibold))
                    Text(model.folder.path)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(model.folder.path)
                }
                Toggle("Use the default look", isOn: Binding(
                    get: { model.followsDefault },
                    set: { follow in
                        if !follow, model.followsDefault {
                            // Start editing from what the folder looks like now.
                            model.style = actions.settings.defaultStyle
                        }
                        model.followsDefault = follow
                    }
                ))
                FitModePicker(mode: model.followsDefault ? .constant(actions.settings.defaultStyle.mode) : $model.style.mode)
                    .disabled(model.followsDefault)
                HStack {
                    Button("Change Picture…") {
                        actions.chooseImage(for: [model.folder])
                        close()
                    }
                    Button("Remove Picture", role: .destructive) {
                        actions.removeImage(from: [model.folder])
                    }
                }
                Spacer(minLength: 12)
                HStack {
                    Button("Cancel", role: .cancel, action: close)
                        .keyboardShortcut(.cancelAction)
                    Spacer()
                    Button("Apply", action: apply)
                        .keyboardShortcut(.defaultAction)
                        .disabled(model.isSaving)
                }
            }
            .frame(width: 280, alignment: .leading)
        }
        .padding(24)
    }

    private func apply() {
        model.isSaving = true
        let style = model.followsDefault ? nil : model.style
        Task {
            do {
                try await actions.manager.setStyle(style, for: model.folder)
                close()
            } catch {
                actions.report([FolderOutcome(folder: model.folder, failure: error.localizedDescription)])
            }
            model.isSaving = false
        }
    }
}

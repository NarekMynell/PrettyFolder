import AppKit
import Observation
import PrettyFolderKit
import SwiftUI
import UniformTypeIdentifiers

final class SettingsWindowController: SwiftUIWindowController {
    init(actions: FolderActions) {
        super.init(title: String(localized: "PrettyFolder Settings"), rootView: SettingsView(actions: actions), autosaveName: "Settings")
    }
}

private struct SettingsView: View {
    let actions: FolderActions

    var body: some View {
        TabView {
            DefaultLookTab(actions: actions)
                .tabItem { Label("Default Look", systemImage: "photo.on.rectangle") }
            GeneralTab(settings: actions.settings)
                .tabItem { Label("General", systemImage: "gearshape") }
            FoldersTab(actions: actions)
                .tabItem { Label("Folders", systemImage: "folder") }
            AboutTab()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 660)
        .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Default look

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

private struct DefaultLookTab: View {
    let actions: FolderActions

    @State private var draft: IconStyle
    @State private var preview: NSImage = PreviewPicture.sample
    @State private var followers = 0
    @State private var askingScope = false
    @State private var progress = BatchProgress()

    init(actions: FolderActions) {
        self.actions = actions
        _draft = State(initialValue: actions.settings.defaultStyle)
    }

    private var isDirty: Bool { draft != actions.settings.defaultStyle }

    var body: some View {
        HStack(alignment: .top, spacing: 28) {
            VStack(spacing: 10) {
                StyleEditor(style: $draft, picture: preview)
                Button("Preview with Another Picture…", action: choosePreview)
                    .buttonStyle(.link)
            }
            VStack(alignment: .leading, spacing: 14) {
                Text("Default Look")
                    .font(.title3.weight(.semibold))
                Text("Where the picture sits on the folder and how it is scaled. New pictures use this look, and so do folders that don't have a look of their own.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                FitModePicker(mode: $draft.mode)
                Button("Back to Standard") { draft = .standard }
                    .disabled(draft == .standard)
                Spacer(minLength: 12)
                if progress.isRunning {
                    ProgressView(value: Double(progress.done), total: Double(progress.total)) {
                        Text("Updating folders…")
                    }
                }
                HStack {
                    Button("Revert") { draft = actions.settings.defaultStyle }
                        .disabled(!isDirty || progress.isRunning)
                    Spacer()
                    Button("Save", action: save)
                        .keyboardShortcut(.defaultAction)
                        .disabled(!isDirty || progress.isRunning)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(24)
        .confirmationDialog("Update existing folders too?", isPresented: $askingScope) {
            Button("Update All \(followers) Folders") { commit(updateExisting: true) }
            Button("Only New Pictures") { commit(updateExisting: false) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(followers) folders use the default look. They can switch to the new look now, or keep the current one while only new pictures get the new look.")
        }
    }

    private func save() {
        Task {
            followers = await actions.manager.folderCountFollowingDefault()
            if followers == 0 {
                commit(updateExisting: false)
            } else {
                askingScope = true
            }
        }
    }

    private func commit(updateExisting: Bool) {
        let style = draft
        actions.settings.defaultStyle = style
        progress.start(total: updateExisting ? followers : 0)
        let reporter = progress.reporter
        Task {
            let outcomes = await actions.manager.setDefaultStyle(style, updateExisting: updateExisting, progress: reporter)
            progress.isRunning = false
            actions.report(outcomes)
        }
    }

    private func choosePreview() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = ImageLoader.acceptedTypes
        panel.prompt = String(localized: "Preview")
        panel.message = String(localized: "This picture is only used for the preview here.")
        guard panel.runModal() == .OK, let url = panel.url, let image = PreviewPicture.load(url) else { return }
        preview = image
    }
}

// MARK: - General

private struct GeneralTab: View {
    @Bindable var settings: AppSettings
    @State private var permission = AccessibilityPermission.shared
    @State private var finderExtension = FinderExtensionStatus.shared
    @State private var loginItem = LoginItem.shared

    var body: some View {
        Form {
            Section("Finder") {
                LabeledContent("Right-click menu") {
                    StatusButton(isOn: finderExtension.isEnabled, onTitle: "On", offTitle: "Turn On…", action: { finderExtension.enable() })
                }
                LabeledContent("Accessibility") {
                    StatusButton(isOn: permission.isGranted, onTitle: "Allowed", offTitle: "Allow…", action: { permission.request() })
                }
                Toggle("Show “Set as Icon” while dragging a picture over a folder", isOn: $settings.showsDropTarget)
                    .disabled(!permission.isGranted)
                Toggle("Click a folder's tab to choose a picture", isOn: $settings.opensPickerFromTab)
                    .disabled(!permission.isGranted)
                if !permission.isGranted {
                    Text("These two need Accessibility access so PrettyFolder can see which folder is under the pointer. It reads nothing else.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            Section("App") {
                Toggle("Open at login", isOn: Binding(get: { loginItem.isEnabled }, set: { loginItem.setEnabled($0) }))
                Toggle("Show in menu bar", isOn: $settings.showsMenuBarIcon)
                if !settings.showsMenuBarIcon {
                    Text("Open PrettyFolder again from Applications or Spotlight to get back here.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            permission.refresh()
            finderExtension.refresh()
            loginItem.refresh()
        }
    }
}

/// "On ✓" when something is set up, a button to set it up otherwise.
struct StatusButton: View {
    let isOn: Bool
    let onTitle: LocalizedStringKey
    let offTitle: LocalizedStringKey
    let action: () -> Void

    var body: some View {
        if isOn {
            Label(onTitle, systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        } else {
            Button(offTitle, action: action)
        }
    }
}

// MARK: - Folders

private struct FoldersTab: View {
    let actions: FolderActions
    @State private var count = 0
    @State private var confirmingRemoval = false
    @State private var progress = BatchProgress()

    var body: some View {
        Form {
            Section {
                LabeledContent("Folders with a picture", value: "\(count)")
            }
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Button("Redraw All Folder Pictures", action: redraw)
                        .disabled(count == 0 || progress.isRunning)
                    Text("After a macOS update changes how folders look, this redraws every picture on the new folder.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Button("Remove All Folder Pictures…", role: .destructive) { confirmingRemoval = true }
                        .disabled(count == 0 || progress.isRunning)
                    Text("Puts every folder that got a picture from PrettyFolder back to the standard icon. Do this before deleting the app if you want the standard icons back.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                if progress.isRunning {
                    ProgressView(value: Double(progress.done), total: Double(progress.total))
                }
            }
        }
        .formStyle(.grouped)
        .task { await refresh() }
        .confirmationDialog("Remove all folder pictures?", isPresented: $confirmingRemoval) {
            Button("Remove \(count) Pictures", role: .destructive, action: removeAll)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The folders go back to the standard icon. The pictures themselves are not touched.")
        }
    }

    private func refresh() async {
        await actions.manager.prune()
        count = await actions.manager.managedFolderCount()
    }

    private func redraw() {
        progress.start(total: count)
        let reporter = progress.reporter
        Task {
            let outcomes = await actions.manager.redrawAll(progress: reporter)
            progress.isRunning = false
            actions.report(outcomes)
            await refresh()
        }
    }

    private func removeAll() {
        progress.start(total: count)
        let reporter = progress.reporter
        Task {
            let outcomes = await actions.manager.removeAll(progress: reporter)
            progress.isRunning = false
            actions.report(outcomes)
            await refresh()
        }
    }
}

// MARK: - About

private struct AboutTab: View {
    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }

    var body: some View {
        VStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
            Text("PrettyFolder")
                .font(.title2.weight(.semibold))
            Text("Version \(version)")
                .foregroundStyle(.secondary)
            Text("Put any picture on a folder icon.")
            Link("github.com/NarekMynell/PrettyFolder", destination: URL(string: "https://github.com/NarekMynell/PrettyFolder")!)
            Text("© 2026 Narek · MIT License")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(32)
    }
}

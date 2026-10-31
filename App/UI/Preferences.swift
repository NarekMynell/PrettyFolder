import AppKit
import PrettyFolderKit
import SwiftUI

/// The gear in the window's top corner, with the few settings PrettyFolder has.
struct PreferencesButton: View {
    let actions: FolderActions
    @State private var isShown = false

    var body: some View {
        Button { isShown.toggle() } label: {
            Image(systemName: "gearshape")
                .font(.system(size: 13, weight: .medium))
                .frame(width: 26, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help("Settings")
        .accessibilityLabel(Text("Settings"))
        .popover(isPresented: $isShown, arrowEdge: .bottom) {
            PreferencesView(settings: actions.settings, actions: actions)
        }
    }
}

private struct PreferencesView: View {
    @Bindable var settings: AppSettings
    let actions: FolderActions

    @State private var loginItem = LoginItem.shared
    @State private var finderExtension = FinderExtensionStatus.shared
    @State private var permission = AccessibilityPermission.shared
    @State private var progress = BatchProgress()
    @State private var pictureCount = 0

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    Toggle("Open at Login", isOn: Binding(get: { loginItem.isEnabled }, set: { loginItem.setEnabled($0) }))
                    Toggle("Show in Menu Bar", isOn: $settings.showsMenuBarIcon)
                        .help("Without it, open PrettyFolder from Applications or Spotlight to get here.")
                }
                Section {
                    Toggle("Set as Icon While Dragging", isOn: $settings.showsDropTarget)
                        .help("Drag a picture over a folder and drop it on Set as Icon.")
                    Toggle("Buttons on Folders", isOn: $settings.showsHoverButtons)
                        .help("Point at a folder to choose its picture, remove it or open this window.")
                }
                .disabled(!permission.isGranted)
                Section {
                    LabeledContent("Finder Menu") {
                        SetupState(isOn: finderExtension.isEnabled, offTitle: "Turn On") { finderExtension.enable() }
                    }
                    LabeledContent("Accessibility") {
                        SetupState(isOn: permission.isGranted, offTitle: "Allow") { permission.request() }
                    }
                }
                Section {
                    Button("Redraw All Pictures", action: redraw)
                        .disabled(pictureCount == 0 || progress.isRunning)
                        .help("After a macOS update changes how folders look, this puts every picture on the new folder.")
                    Button("Remove All Pictures…", role: .destructive, action: removeAll)
                        .disabled(pictureCount == 0 || progress.isRunning)
                        .help("Puts every folder that got a picture from PrettyFolder back to the standard icon.")
                    if progress.isRunning {
                        ProgressView(value: Double(progress.done), total: Double(progress.total))
                    }
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)

            HStack {
                Link("PrettyFolder \(Self.version)", destination: URL(string: "https://github.com/NarekMynell/PrettyFolder")!)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
            .font(.callout)
            .controlSize(.small)
            .padding(.horizontal, 20)
            .padding(.bottom, 14)
        }
        .frame(width: 320)
        .fixedSize(horizontal: false, vertical: true)
        .task {
            loginItem.refresh()
            finderExtension.refresh()
            permission.refresh()
            await countPictures()
        }
    }

    private static var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
    }

    private func countPictures() async {
        await actions.manager.prune()
        pictureCount = await actions.manager.managedFolderCount()
    }

    private func redraw() {
        progress.start(total: pictureCount)
        let reporter = progress.reporter
        let manager = actions.manager
        Task {
            let outcomes = await manager.redrawAll(progress: reporter)
            progress.isRunning = false
            actions.picturesChanged(outcomes.map(\.folder))
            actions.report(outcomes)
            await countPictures()
        }
    }

    private func removeAll() {
        guard actions.confirmRemovingAll(count: pictureCount) else { return }
        progress.start(total: pictureCount)
        let reporter = progress.reporter
        let manager = actions.manager
        Task {
            let outcomes = await manager.removeAll(progress: reporter)
            progress.isRunning = false
            actions.picturesChanged(outcomes.map(\.folder))
            actions.report(outcomes)
            await countPictures()
        }
    }
}

/// A checkmark when something is set up, a button to set it up otherwise.
private struct SetupState: View {
    let isOn: Bool
    let offTitle: LocalizedStringKey
    let action: () -> Void

    var body: some View {
        if isOn {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .accessibilityLabel(Text("On"))
        } else {
            Button(offTitle, action: action)
        }
    }
}

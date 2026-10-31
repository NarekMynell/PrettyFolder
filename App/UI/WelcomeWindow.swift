import AppKit
import SwiftUI

/// First-run window: two switches to flip in System Settings and a short how-to.
final class WelcomeWindowController: SwiftUIWindowController {
    init(actions: FolderActions) {
        var closeWindow: () -> Void = {}
        super.init(title: String(localized: "Welcome to PrettyFolder"), rootView: WelcomeView(close: { closeWindow() }))
        closeWindow = { [weak self] in self?.close() }
    }
}

private struct WelcomeView: View {
    let close: () -> Void

    @State private var finderExtension = FinderExtensionStatus.shared
    @State private var permission = AccessibilityPermission.shared
    @State private var loginItem = LoginItem.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 64, height: 64)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Welcome to PrettyFolder")
                        .font(.title2.weight(.semibold))
                    Text("Put any picture on a folder icon, in a second.")
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 14) {
                SetupStep(
                    number: 1,
                    title: "Turn on the Finder menu",
                    detail: "Adds “Choose Folder Picture…” and friends to the right-click menu of folders.",
                    isDone: finderExtension.isEnabled,
                    buttonTitle: "Turn On…",
                    action: { finderExtension.enable() }
                )
                SetupStep(
                    number: 2,
                    title: "Allow Accessibility",
                    detail: "Lets PrettyFolder see which folder is under the pointer, for the drop target and the tab button. Nothing else is read.",
                    isDone: permission.isGranted,
                    buttonTitle: "Allow…",
                    action: { permission.request() }
                )
                Toggle("Open PrettyFolder at login", isOn: Binding(get: { loginItem.isEnabled }, set: { loginItem.setEnabled($0) }))
                    .padding(.leading, 34)
            }

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                Text("Three ways to use it")
                    .font(.headline)
                HowTo(symbol: "hand.draw", text: "Drag a picture over a folder and drop it on “Set as Icon”. Dropping on the folder itself still copies the picture in, as always.")
                HowTo(symbol: "cursorarrow.click", text: "Click a folder's tab, the top-left corner of its icon, and pick a picture. Option-click removes it.")
                HowTo(symbol: "contextualmenu.and.cursorarrow", text: "Right-click a folder: choose, remove or adjust its picture, or change the default look.")
            }

            HStack {
                Spacer()
                Button("Done", action: close)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 520)
        .onAppear {
            finderExtension.refresh()
            permission.refresh()
            loginItem.refresh()
        }
    }
}

private struct SetupStep: View {
    let number: Int
    let title: LocalizedStringKey
    let detail: LocalizedStringKey
    let isDone: Bool
    let buttonTitle: LocalizedStringKey
    let action: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle().fill(isDone ? Color.green : Color.accentColor)
                if isDone {
                    Image(systemName: "checkmark").font(.caption.weight(.bold))
                } else {
                    Text("\(number)").font(.callout.weight(.semibold))
                }
            }
            .foregroundStyle(.white)
            .frame(width: 22, height: 22)

            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.body.weight(.medium))
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if !isDone {
                Button(buttonTitle, action: action)
            }
        }
    }
}

private struct HowTo: View {
    let symbol: String
    let text: LocalizedStringKey

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(Color.accentColor)
                .frame(width: 22)
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

import AppKit
import PrettyFolderKit

/// The open panel for choosing a folder picture.
final class PicturePicker {
    enum Result {
        case picture(URL)
        case remove
        case cancelled
    }

    private var panel: NSOpenPanel?

    var isOpen: Bool { panel != nil }

    /// Shows the picker. Only one is open at a time; asking again brings it to the front.
    func pick(for folders: [URL], startingIn directory: URL?, offerRemove: Bool, completion: @escaping (Result) -> Void) {
        if let panel {
            AppActivation.bringToFront(panel)
            return
        }

        let panel = NSOpenPanel()
        panel.allowedContentTypes = ImageLoader.acceptedTypes
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.resolvesAliases = true
        panel.prompt = String(localized: "Use Picture")
        panel.title = String(localized: "Choose a Picture")
        panel.message = folders.count == 1
            ? String(localized: "Choose a picture for “\(FileManager.default.displayName(atPath: folders[0].path))”.")
            : String(localized: "Choose a picture for \(folders.count) folders.")
        panel.directoryURL = directory.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
            ?? FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first

        // "Remove Current Picture" closes the panel and reports `.remove`.
        let removal = RemovalRequest()
        if offerRemove {
            let button = NSButton(title: String(localized: "Remove Current Picture"), target: removal, action: #selector(RemovalRequest.request(_:)))
            button.bezelStyle = .push
            removal.panel = panel
            let accessory = NSStackView(views: [button])
            accessory.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
            panel.accessoryView = accessory
            panel.isAccessoryViewDisclosed = true
        }

        self.panel = panel
        panel.begin { [weak self] response in
            MainActor.assumeIsolated {
                self?.panel = nil
                if removal.isRequested {
                    completion(.remove)
                } else if response == .OK, let url = panel.url {
                    completion(.picture(url))
                } else {
                    completion(.cancelled)
                }
            }
        }
        AppActivation.bringToFront(panel)
    }
}

private final class RemovalRequest: NSObject {
    weak var panel: NSOpenPanel?
    private(set) var isRequested = false

    @objc func request(_ sender: Any?) {
        isRequested = true
        panel?.cancel(sender)
    }
}

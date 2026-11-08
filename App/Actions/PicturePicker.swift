import AppKit
import PrettyFolderKit

/// The open panel for choosing a picture.
final class PicturePicker {
    private var panel: NSOpenPanel?
    /// Asked for, and finding out where to open.
    private var isOpening = false

    /// Shows the picker, as a sheet on `window` when there is one. Only one picker is open
    /// at a time; asking again brings it to the front. `completion` gets `nil` on Cancel.
    func pick(message: String, prompt: String, startingIn directory: URL?, attachedTo window: NSWindow?, completion: @escaping (URL?) -> Void) {
        if let panel {
            AppActivation.bringToFront(panel.sheetParent ?? panel)
            return
        }
        guard !isOpening else { return }
        isOpening = true
        Task {
            let start = await Self.reachable(directory)
            // Setting up a panel can wait a while for macOS.
            outsideMenus { [self] in
                isOpening = false
                open(message: message, prompt: prompt, in: start, attachedTo: window, completion: completion)
            }
        }
    }

    /// `directory` if it is still there. Asked off the main thread and not waited for long: it may
    /// be on a disk that is gone, or a network disk that has stopped answering.
    private static func reachable(_ directory: URL?) async -> URL? {
        guard let directory else { return nil }
        return await onOwnThread(within: 1, otherwise: nil) {
            FileManager.default.fileExists(atPath: directory.path) ? directory : nil
        }
    }

    private func open(message: String, prompt: String, in directory: URL?, attachedTo window: NSWindow?, completion: @escaping (URL?) -> Void) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = ImageLoader.acceptedTypes
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.resolvesAliases = true
        panel.prompt = prompt
        panel.title = String(localized: "Choose a Picture")
        panel.message = message
        panel.directoryURL = directory ?? FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first

        self.panel = panel
        let finish = { [weak self] (response: NSApplication.ModalResponse) in
            self?.panel = nil
            completion(response == .OK ? panel.url : nil)
        }
        if let window, window.isVisible {
            AppActivation.bringToFront(window)
            panel.beginSheetModal(for: window) { response in
                MainActor.assumeIsolated { finish(response) }
            }
        } else {
            panel.begin { response in
                MainActor.assumeIsolated { finish(response) }
            }
            AppActivation.bringToFront(panel)
        }
    }
}

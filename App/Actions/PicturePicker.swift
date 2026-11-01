import AppKit
import PrettyFolderKit

/// The open panel for choosing a picture.
final class PicturePicker {
    private var panel: NSOpenPanel?

    /// Shows the picker, as a sheet on `window` when there is one. Only one picker is open
    /// at a time; asking again brings it to the front. `completion` gets `nil` on Cancel.
    func pick(message: String, prompt: String, startingIn directory: URL?, attachedTo window: NSWindow?, completion: @escaping (URL?) -> Void) {
        if let panel {
            AppActivation.bringToFront(panel.sheetParent ?? panel)
            return
        }

        let panel = NSOpenPanel()
        panel.allowedContentTypes = ImageLoader.acceptedTypes
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.resolvesAliases = true
        panel.prompt = prompt
        panel.title = String(localized: "Choose a Picture")
        panel.message = message
        panel.directoryURL = directory.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
            ?? FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first

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

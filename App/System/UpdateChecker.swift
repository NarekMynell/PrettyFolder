import AppKit
import Observation
import PrettyFolderKit
import os

/// Once a day asks GitHub which version of PrettyFolder is the newest, so that the menu bar icon,
/// its menu and the settings can say when there's a newer one. PrettyFolder doesn't update itself:
/// the user downloads the new version from the release page, the same way as the first time.
@Observable
final class UpdateChecker {
    static let shared = UpdateChecker()

    /// This copy's version.
    static let current = AppVersion(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")

    /// A version newer than this copy, while checking is on.
    var newer: AppVersion? {
        guard settings.checksForUpdates, let latest, let current = Self.current, current < latest else { return nil }
        return latest
    }

    /// The newest version GitHub has named, kept between launches so the news doesn't wait for
    /// the next question.
    private(set) var latest: AppVersion? {
        didSet { defaults.set(latest?.description, forKey: Key.latest) }
    }

    private enum Key {
        static let latest = "LatestKnownVersion"
        static let lastChecked = "LastUpdateCheck"
    }

    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var check: Task<Void, Never>?
    @ObservationIgnored private var schedule: Task<Void, Never>?
    @ObservationIgnored private lazy var session = UpdateCheck.makeSession()
    @ObservationIgnored private let log = Logger(subsystem: "com.narekmynell.PrettyFolder", category: "Update")

    private init(settings: AppSettings = .shared, defaults: UserDefaults = .standard) {
        self.settings = settings
        self.defaults = defaults
        latest = defaults.string(forKey: Key.latest).flatMap(AppVersion.init)
    }

    /// When GitHub last answered.
    private var lastChecked: Date? {
        get { defaults.object(forKey: Key.lastChecked) as? Date }
        set { defaults.set(newValue, forKey: Key.lastChecked) }
    }

    /// Asks if a day has gone by since the last answer, a little after launch and then every
    /// hour, so a Mac that sleeps at night or goes without a network still asks about once a day.
    func start() {
        guard schedule == nil else { return }
        schedule = Task { [weak self] in
            // Launch has enough to do.
            try? await Task.sleep(for: .seconds(30))
            while !Task.isCancelled {
                self?.checkIfDue()
                try? await Task.sleep(for: .seconds(60 * 60))
            }
        }
    }

    /// Asks GitHub now, unless checking is off, a question is out already or the last answer is
    /// less than a day old. The wait is on the network, never on the main thread.
    func checkIfDue() {
        guard settings.checksForUpdates, check == nil, UpdateCheck.isDue(lastChecked: lastChecked) else { return }
        let appVersion = Self.current?.description ?? "0"
        let session = session
        check = Task { [weak self] in
            do {
                let version = try await UpdateCheck.latestVersion(appVersion: appVersion, session: session)
                self?.log.info("The newest release is \(version.description, privacy: .public)")
                self?.lastChecked = Date()
                if self?.latest != version { self?.latest = version }
            } catch {
                // Asked again within the hour.
                self?.log.notice("Couldn't ask about updates: \(String(describing: error), privacy: .public)")
            }
            self?.check = nil
        }
    }

    /// The release page, in the browser.
    func openReleasePage() {
        NSWorkspace.shared.open(UpdateCheck.releasePage, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
    }
}

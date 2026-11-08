import Foundation

/// A release's version number, such as 1.3.7. A tag's leading "v" is dropped; "1.3" and
/// "1.3.0" are the same version. Anything else, a "-beta" for one, isn't a version here.
public struct AppVersion: Comparable, Hashable, Sendable, CustomStringConvertible {
    /// Without trailing zeros, so that equal versions have equal parts.
    private let parts: [Int]

    public init?(_ text: String) {
        var text = Substring(text.trimmingCharacters(in: .whitespacesAndNewlines))
        if text.first == "v" || text.first == "V" { text = text.dropFirst() }
        let pieces = text.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...4).contains(pieces.count) else { return nil }
        var parts: [Int] = []
        for piece in pieces {
            guard (1...6).contains(piece.count), piece.allSatisfy({ ("0"..."9").contains($0) }), let number = Int(piece) else { return nil }
            parts.append(number)
        }
        while parts.count > 1, parts.last == 0 { parts.removeLast() }
        self.parts = parts
    }

    public var description: String {
        (parts + Array(repeating: 0, count: max(0, 3 - parts.count))).map(String.init).joined(separator: ".")
    }

    public static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        for index in 0..<max(lhs.parts.count, rhs.parts.count) {
            let left = index < lhs.parts.count ? lhs.parts[index] : 0
            let right = index < rhs.parts.count ? rhs.parts[index] : 0
            if left != right { return left < right }
        }
        return false
    }
}

/// Asks GitHub which release of PrettyFolder is the newest. Only that is asked, with nothing
/// about the Mac or its folders, and nothing is downloaded: getting the update is up to the user.
public enum UpdateCheck {
    public static let latestReleaseAddress = URL(string: "https://api.github.com/repos/NarekMynell/PrettyFolder/releases/latest")!
    /// Where the user gets it. Not the address in GitHub's answer, so that an answer can't send
    /// anyone elsewhere.
    public static let releasePage = URL(string: "https://github.com/NarekMynell/PrettyFolder/releases/latest")!
    /// How often to ask.
    public static let interval: TimeInterval = 24 * 60 * 60

    public enum Failure: Error, Equatable {
        /// GitHub answered with something other than 200: no release yet, or too many questions
        /// from this network for a while.
        case refused(status: Int)
        /// The answer isn't a release with a version number.
        case unreadable
    }

    /// Whether it's time to ask again. A clock set back since the last time counts as time.
    public static func isDue(lastChecked: Date?, now: Date = Date()) -> Bool {
        guard let lastChecked else { return true }
        let elapsed = now.timeIntervalSince(lastChecked)
        return elapsed >= interval || elapsed < 0
    }

    /// The newest release's version in GitHub's answer for the latest release.
    public static func version(fromLatestRelease data: Data) -> AppVersion? {
        struct Release: Decodable {
            let tag_name: String
            let draft: Bool?
            let prerelease: Bool?
        }
        guard let release = try? JSONDecoder().decode(Release.self, from: data),
              release.draft != true, release.prerelease != true else { return nil }
        return AppVersion(release.tag_name)
    }

    /// A session that keeps nothing (no cookies, no cache) and gives up soon when the network
    /// doesn't answer.
    public static func makeSession(protocolClasses: [AnyClass]? = nil) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 40
        configuration.waitsForConnectivity = false
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        if let protocolClasses { configuration.protocolClasses = protocolClasses + (configuration.protocolClasses ?? []) }
        return URLSession(configuration: configuration)
    }

    /// The newest release's version. Waits on the network away from the caller's thread and
    /// stops when the task is cancelled.
    public static func latestVersion(appVersion: String, session: URLSession) async throws -> AppVersion {
        var request = URLRequest(url: latestReleaseAddress)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        // GitHub turns away questions without one.
        request.setValue("PrettyFolder/\(appVersion)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw Failure.refused(status: status) }
        guard let version = version(fromLatestRelease: data) else { throw Failure.unreadable }
        return version
    }
}

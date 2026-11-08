import Foundation
import Testing
import os
@testable import PrettyFolderKit

@Suite(.serialized) struct UpdateCheckTests {
    // MARK: Versions

    @Test func readsTagsAsVersions() throws {
        #expect(AppVersion("v1.3.7")?.description == "1.3.7")
        #expect(AppVersion("1.3.7")?.description == "1.3.7")
        #expect(AppVersion(" V2.0 \n")?.description == "2.0.0")
        #expect(AppVersion("1.3") == AppVersion("1.3.0"))
        #expect(Set([AppVersion("1.3")!, AppVersion("1.3.0")!]).count == 1)
        for notAVersion in ["", "v", "1..3", "1.3.", ".1", "1.3.7-beta", "1.3.7b", "1.-3", "one", "1.2.3.4.5", "1.1234567", "١.٢"] {
            #expect(AppVersion(notAVersion) == nil, "\(notAVersion)")
        }
    }

    @Test func comparesVersionsByNumberNotByText() throws {
        let order = ["0.9", "1.0", "1.0.1", "1.2", "1.3.6", "1.3.7", "1.3.10", "1.10", "2"].map { AppVersion($0)! }
        #expect(order == order.sorted())
        for (lower, higher) in zip(order, order.dropFirst()) {
            #expect(lower < higher)
            #expect(!(higher < lower))
        }
        #expect(!(AppVersion("1.3")! < AppVersion("1.3.0")!))
    }

    // MARK: When to ask

    @Test func asksOnceADay() {
        let now = Date()
        #expect(UpdateCheck.isDue(lastChecked: nil, now: now))
        #expect(!UpdateCheck.isDue(lastChecked: now.addingTimeInterval(-60), now: now))
        #expect(!UpdateCheck.isDue(lastChecked: now.addingTimeInterval(-UpdateCheck.interval + 60), now: now))
        #expect(UpdateCheck.isDue(lastChecked: now.addingTimeInterval(-UpdateCheck.interval), now: now))
        // The clock was set back: asking again beats never asking for a year.
        #expect(UpdateCheck.isDue(lastChecked: now.addingTimeInterval(365 * 24 * 3600), now: now))
    }

    // MARK: GitHub's answer

    @Test func readsTheVersionInGitHubsAnswer() throws {
        #expect(UpdateCheck.version(fromLatestRelease: Self.release(tag: "v1.3.7")) == AppVersion("1.3.7"))
        #expect(UpdateCheck.version(fromLatestRelease: Self.release(tag: "v1.4.0-beta")) == nil)
        #expect(UpdateCheck.version(fromLatestRelease: Self.release(tag: "v1.4", prerelease: true)) == nil)
        #expect(UpdateCheck.version(fromLatestRelease: Self.release(tag: "v1.4", draft: true)) == nil)
        #expect(UpdateCheck.version(fromLatestRelease: Data(#"{"message":"Not Found"}"#.utf8)) == nil)
        #expect(UpdateCheck.version(fromLatestRelease: Data("<html>".utf8)) == nil)
        #expect(UpdateCheck.version(fromLatestRelease: Data()) == nil)
    }

    @Test func asksGitHubForTheLatestReleaseOnly() async throws {
        Stub.answer(status: 200, body: Self.release(tag: "v1.4.2"))
        let version = try await UpdateCheck.latestVersion(appVersion: "1.3.7", session: UpdateCheck.makeSession(protocolClasses: [Stub.self]))
        #expect(version == AppVersion("1.4.2"))

        let request = try #require(Stub.requests.last)
        #expect(request.url == URL(string: "https://api.github.com/repos/NarekMynell/PrettyFolder/releases/latest"))
        #expect(request.httpMethod == "GET")
        #expect(request.value(forHTTPHeaderField: "User-Agent") == "PrettyFolder/1.3.7")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/vnd.github+json")
        #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
        #expect(request.httpBody == nil)
    }

    @Test func sayWhenGitHubDoesntAnswerWithARelease() async throws {
        let session = UpdateCheck.makeSession(protocolClasses: [Stub.self])
        for status in [403, 404, 429, 500] {
            Stub.answer(status: status, body: Data(#"{"message":"API rate limit exceeded"}"#.utf8))
            await #expect(throws: UpdateCheck.Failure.refused(status: status)) {
                try await UpdateCheck.latestVersion(appVersion: "1.3.7", session: session)
            }
        }
        Stub.answer(status: 200, body: Data("<html>a captive Wi-Fi page</html>".utf8))
        await #expect(throws: UpdateCheck.Failure.unreadable) {
            try await UpdateCheck.latestVersion(appVersion: "1.3.7", session: session)
        }
        Stub.fail(URLError(.notConnectedToInternet))
        await #expect(throws: URLError.self) {
            try await UpdateCheck.latestVersion(appVersion: "1.3.7", session: session)
        }
    }

    @Test func stopsWaitingWhenCancelled() async throws {
        Stub.hang()
        let task = Task {
            try await UpdateCheck.latestVersion(appVersion: "1.3.7", session: UpdateCheck.makeSession(protocolClasses: [Stub.self]))
        }
        try await Task.sleep(for: .milliseconds(200))
        let start = ContinuousClock.now
        task.cancel()
        await #expect(throws: (any Error).self) { try await task.value }
        #expect(ContinuousClock.now - start < .seconds(3))
    }

    // MARK: Helpers

    static func release(tag: String, draft: Bool = false, prerelease: Bool = false) -> Data {
        // The shape of GitHub's answer, cut down.
        Data("""
        {"url":"https://api.github.com/repos/NarekMynell/PrettyFolder/releases/1","html_url":"https://example.com/elsewhere",
         "tag_name":"\(tag)","name":"PrettyFolder","draft":\(draft),"prerelease":\(prerelease),
         "assets":[{"name":"PrettyFolder.zip","browser_download_url":"https://example.com/x.zip"}],"body":"Notes"}
        """.utf8)
    }

    /// Answers the session's requests the way the test says.
    final class Stub: URLProtocol, @unchecked Sendable {
        enum Behavior { case answer(Int, Data), fail(URLError), hang }
        private static let state = OSAllocatedUnfairLock(initialState: (behavior: Behavior.hang, requests: [URLRequest]()))

        static func answer(status: Int, body: Data) { state.withLock { $0.behavior = .answer(status, body) } }
        static func fail(_ error: URLError) { state.withLock { $0.behavior = .fail(error) } }
        static func hang() { state.withLock { $0.behavior = .hang } }
        static var requests: [URLRequest] { state.withLock { $0.requests } }

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            let behavior = Self.state.withLock { state in
                state.requests.append(request)
                return state.behavior
            }
            switch behavior {
            case .answer(let status, let body):
                let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: body)
                client?.urlProtocolDidFinishLoading(self)
            case .fail(let error):
                client?.urlProtocol(self, didFailWithError: error)
            case .hang:
                break
            }
        }

        override func stopLoading() {}
    }
}

import Foundation
import os

/// A question to a part of the system whose answer takes as long as that part does: a round trip
/// to a service, with no time limit. It is asked on a thread of its own, and the answer comes to
/// the main thread.
///
/// The main thread must never wait for one. A menu of the app's that is opening has the keyboard
/// of every app until it shows: on 2026-11-06 `FIFinderSyncController.isExtensionEnabled`, asked
/// while the menu bar menu opened, waited for an answer that never came, and nothing could be
/// typed anywhere for an hour.
///
/// One question is out at a time. One out for longer than `retryAfter` is asked again, in case that
/// part of the system is back, and keeps its thread until it comes back, which may be never. After
/// a few of those, the next waits twice as long each time, up to 10 minutes: a day of no answers
/// leaves a few dozen threads waiting, not thousands, and once the system answers again the app
/// hears it within minutes, not hours. An answer starts the waits over.
///
/// The questions asked are yes-or-no ones. (Made generic, Swift 6.3 crashes optimizing it.)
final class SystemQuestion {
    typealias Answer = Bool

    private let label: String
    private let ask: @Sendable () -> Answer
    private let answered: (Answer) -> Void
    private let retryAfter: TimeInterval
    private let log = Logger(subsystem: "com.narekmynell.PrettyFolder", category: "System")

    /// The question out: its number and when it was asked.
    private var out: (id: Int, time: TimeInterval)?
    private var asked = 0
    private var lastAnswered = 0
    /// Questions asked again while they were out, whose threads still wait.
    private var leftBehind = 0
    /// Times the question has been asked again since an answer last came.
    private var retries = 0
    /// The longest wait before asking again, and the most threads ever left waiting.
    private static let longestWait: TimeInterval = 600
    private static let mostLeftBehind = 64
    private var isAskedAgain = false
    /// Those waiting for the answer to the question out, and for the one after it.
    private var waiting: [(Answer) -> Void] = []
    private var waitingForNext: [(Answer) -> Void] = []

    /// `answered` gets every answer, before anyone waiting for it.
    init(
        _ label: String, retryAfter: TimeInterval = 30,
        ask: @escaping @Sendable () -> Answer, answered: @escaping (Answer) -> Void
    ) {
        self.label = label
        self.ask = ask
        self.answered = answered
        self.retryAfter = retryAfter
    }

    /// Asks, unless a question is out already; it is then asked again once that one is answered.
    /// `then` gets the answer to a question asked after this call.
    func refresh(then: ((Answer) -> Void)? = nil) {
        if let then { waitingForNext.append(then) }
        isAskedAgain = true
        askIfDue()
    }

    private func askIfDue() {
        guard isAskedAgain else { return }
        if let out {
            let outFor = Self.uptime() - out.time
            let wait = min(retryAfter * pow(2, Double(max(0, retries - 3))), Self.longestWait)
            guard outFor > wait, leftBehind < Self.mostLeftBehind else { return }
            leftBehind += 1
            retries += 1
            log.error("\(self.label, privacy: .public) hasn't been answered for \(Int(outFor), privacy: .public) s; asking again")
        }
        isAskedAgain = false
        asked += 1
        let id = asked
        out = (id, Self.uptime())
        // Those waiting for one left behind get this one's answer, which is newer.
        waiting += waitingForNext
        waitingForNext = []
        // A thread of its own, not one of a pool another wait could use up.
        let thread = Thread { [ask] in
            let answer = ask()
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.give(answer, to: id) }
            }
        }
        thread.name = "com.narekmynell.PrettyFolder.\(label)"
        thread.qualityOfService = .utility
        thread.start()
    }

    private func give(_ answer: Answer, to id: Int) {
        if out?.id == id {
            out = nil
        } else {
            leftBehind -= 1
        }
        // That part of the system answers again.
        retries = 0
        // One left behind may come back after a newer one: then it says nothing new.
        if id > lastAnswered {
            lastAnswered = id
            answered(answer)
        }
        if out == nil {
            let waiting = self.waiting
            self.waiting = []
            waiting.forEach { $0(answer) }
        }
        askIfDue()
    }

    private static func uptime() -> TimeInterval {
        TimeInterval(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
    }
}

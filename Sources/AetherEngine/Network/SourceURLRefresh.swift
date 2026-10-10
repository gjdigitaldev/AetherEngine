import Foundation

/// givo-20: a host's way to hand the engine a fresh address for the source it is playing.
///
/// A set-top-box portal mints a short-lived, one-viewer link per play. When the media front ends that
/// link's connection itself, it keeps counting it for a minute or more and refuses every reconnect on
/// the same link, while a freshly minted link of the same title is served at once. The host owns the
/// minting (the portal session, its identity, its cooldown), so the engine asks it, and continues the
/// SAME session at the same byte offset on the new address: the buffered segments, the producer and
/// any queued seek all carry on.
public struct SourceURLRefresher: Sendable, Equatable {
    let id = UUID()
    let refresh: @Sendable (URL) async -> URL?

    /// `refresh` receives the address the session loaded and returns a fresh one for the same bytes,
    /// or nil when it has none. Called off the main actor; it may take seconds (a cooldown, a mint).
    public init(_ refresh: @escaping @Sendable (URL) async -> URL?) {
        self.refresh = refresh
    }

    public static func == (lhs: SourceURLRefresher, rhs: SourceURLRefresher) -> Bool { lhs.id == rhs.id }
}

/// givo-20: the refreshers loads registered, keyed by the source they loaded, and the address each
/// source now reads from. One refresh at a time per source (a second reader waits for the first and
/// shares its answer), and at most `maxRefreshes` in any `window`: past that the source is treated as
/// refused, so a host's own ladder takes over instead of the engine minting forever.
final class SourceURLRefresh: @unchecked Sendable {
    static let shared = SourceURLRefresh()

    static let maxRefreshes = 3
    static let window: TimeInterval = 120

    enum Outcome: Equatable {
        case refreshed(URL)
        /// The rate guard tripped: report the refusal, stop asking.
        case exhausted
        /// No refresher, the host had no address, or it did not answer in time.
        case unavailable
    }

    private struct Entry {
        var refresher: SourceURLRefresher
        var current: URL?
        var stamps: [Date] = []
        var exhausted = false
        var inFlight = false
        var lastOutcome: Outcome?
    }

    private let condition = NSCondition()
    private var entries: [String: Entry] = [:]

    func register(_ refresher: SourceURLRefresher?, for source: URL) {
        condition.lock()
        if let refresher { entries[source.absoluteString] = Entry(refresher: refresher) }
        else { entries.removeValue(forKey: source.absoluteString) }
        condition.broadcast()
        condition.unlock()
    }

    /// The address `source` reads from now, nil when it was never refreshed.
    func current(for source: URL) -> URL? {
        condition.lock(); defer { condition.unlock() }
        return entries[source.absoluteString]?.current
    }

    /// True while a refresh may still be asked for `source`.
    func canRefresh(_ source: URL) -> Bool {
        condition.lock(); defer { condition.unlock() }
        guard let entry = entries[source.absoluteString] else { return false }
        return !entry.exhausted
    }

    /// Blocks the calling thread (a reader's) until the host answers, `timeout` passes or
    /// `shouldAbort` says the caller has gone.
    func refresh(source: URL, timeout: TimeInterval, shouldAbort: @escaping () -> Bool) -> Outcome {
        let key = source.absoluteString
        condition.lock()
        guard var entry = entries[key] else { condition.unlock(); return .unavailable }
        if entry.exhausted { condition.unlock(); return .exhausted }
        if entry.inFlight {
            // Another reader of this source is asking: share its answer.
            let deadline = Date().addingTimeInterval(timeout)
            while entries[key]?.inFlight == true, Date() < deadline, !shouldAbort() {
                _ = condition.wait(until: min(deadline, Date().addingTimeInterval(0.1)))
            }
            let shared = entries[key]?.lastOutcome ?? .unavailable
            condition.unlock()
            return shared
        }
        let now = Date()
        entry.stamps = entry.stamps.filter { now.timeIntervalSince($0) < Self.window }
        if entry.stamps.count >= Self.maxRefreshes {
            entry.exhausted = true
            entry.lastOutcome = .exhausted
            entries[key] = entry
            condition.unlock()
            EngineLog.emit("[SourceRefresh] \(Self.maxRefreshes) fresh addresses in \(Int(Self.window)) s; "
                           + "no more, the refusal stands (givo-20)", category: .demux)
            return .exhausted
        }
        entry.stamps.append(now)
        entry.inFlight = true
        entries[key] = entry
        let refresher = entry.refresher
        condition.unlock()

        let box = AnswerBox()
        _ = BlockingWork.detached { box.set(await refresher.refresh(source)) }
        let deadline = Date().addingTimeInterval(timeout)
        var answer: URL?? = nil
        while answer == nil, Date() < deadline, !shouldAbort() {
            answer = box.wait(slice: 0.1)
        }

        let outcome: Outcome
        if let fresh = answer ?? nil { outcome = .refreshed(fresh) } else { outcome = .unavailable }
        condition.lock()
        if var done = entries[key], done.refresher == refresher {
            done.inFlight = false
            done.lastOutcome = outcome
            if case .refreshed(let fresh) = outcome { done.current = fresh }
            entries[key] = done
        }
        condition.broadcast()
        condition.unlock()
        return outcome
    }

    /// The host's answer, handed from its task to the waiting reader. `@unchecked Sendable`: guarded
    /// by its own condition.
    private final class AnswerBox: @unchecked Sendable {
        private let condition = NSCondition()
        private var answered = false
        private var value: URL?

        func set(_ url: URL?) {
            condition.lock(); value = url; answered = true; condition.broadcast(); condition.unlock()
        }

        /// nil while unanswered; `.some(url-or-nil)` once answered.
        func wait(slice: TimeInterval) -> URL?? {
            condition.lock(); defer { condition.unlock() }
            if !answered { _ = condition.wait(until: Date().addingTimeInterval(slice)) }
            return answered ? .some(value) : nil
        }
    }
}

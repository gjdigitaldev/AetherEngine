import Foundation

/// Host-app TLS trust policy for the engine's outbound HTTP connections.
///
/// URLSession enforces system certificate trust, which the in-demuxer network
/// stacks this engine replaces never did. A media server fronted by a
/// self-signed or private-CA certificate therefore keeps working in a host
/// whose own API layer bypasses trust, while every engine fetch fails its
/// handshake before a byte is read and the open surfaces as bare invalid
/// data. The host answers per origin, and while no evaluator is set every
/// challenge keeps the system's default handling.
public enum EngineTLS {

    /// Decides whether to accept a server certificate that failed system
    /// trust evaluation, for the origin the challenge came from.
    ///
    /// nil, the default, keeps the system's default handling everywhere. The
    /// blunt answer is one line (`{ _ in true }`), and a host holding a LAN
    /// address behind a private certificate alongside a WAN address with a
    /// real one can answer for each rather than relaxing both. A host that
    /// wants to pin an SPKI hash reads the protection space and decides.
    ///
    /// Read per challenge, but a challenge is not raised for every connection:
    /// within one URL session, once a certificate was accepted
    /// (`.useCredential`), later connections to that origin, full handshakes
    /// included, are served even where this now answers false (a system-default
    /// answer, or a rejected protection space); only a cancelled challenge
    /// refuses them (measured in the TLS lab, givo-35). Withdrawing an accept therefore takes
    /// effect only in URL sessions that have not accepted that origin yet: the
    /// next load's, or the next `ServerTrustPolicy`'s, which runs in sessions of
    /// its own. Called off the main actor, from whichever queue the session
    /// raised the challenge on, so it has to be thread-safe. Lock-guarded like
    /// `EngineLog.handler`.
    ///
    /// TODO(R2570): after 4023, answer a system-default decision with an explicit
    /// `SecTrustEvaluateWithError` (cancel when it fails) so a withdrawn accept
    /// also refuses inside a session that accepted, with the lab test that shows
    /// it.
    public static var serverTrustEvaluator: (@Sendable (URLProtectionSpace) -> Bool)? {
        get { lock.lock(); defer { lock.unlock() }; return _evaluator }
        set { lock.lock(); _evaluator = newValue; lock.unlock() }
    }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var _evaluator: (@Sendable (URLProtectionSpace) -> Bool)?

    /// givo-14: what to do with a server certificate, decided by the host before anything else.
    public enum ServerTrustDecision: Sendable, Equatable {
        /// Trust it, whatever system evaluation would say.
        case accept
        /// Refuse it, even one system evaluation would accept (a pinned origin presenting another
        /// certificate). The connection fails as a certificate rejection, never as a plain cancel.
        case reject
        /// No opinion: `serverTrustEvaluator`, then the system's default handling.
        case systemDefault
    }

    /// givo-14: a three-way answer per challenge, asked before `serverTrustEvaluator`. A host pinning
    /// one origin's certificate needs `.reject`, which the Bool evaluator cannot say: `false` there is
    /// the system's default handling, and that accepts any certificate the system trusts. nil, the
    /// default, asks nothing. Same threading rules as `serverTrustEvaluator`.
    public static var serverTrustDecision: (@Sendable (URLProtectionSpace) -> ServerTrustDecision)? {
        get { lock.lock(); defer { lock.unlock() }; return _decision }
        set { lock.lock(); _decision = newValue; lock.unlock() }
    }
    nonisolated(unsafe) private static var _decision: (@Sendable (URLProtectionSpace) -> ServerTrustDecision)?

    /// givo-14: origins (host and port) whose certificate a `.reject` refused, and when. URLSession
    /// reports a cancelled challenge as a plain cancel (-999); the readers read it as a trust refusal by
    /// this record.
    nonisolated(unsafe) private static var refusedOrigins: [String: Date] = [:]
    static let refusalMemorySeconds: TimeInterval = 10

    static func originKey(host: String, port: Int) -> String { "\(host.lowercased()):\(port)" }

    static func noteRefused(host: String, port: Int) {
        lock.lock(); refusedOrigins[originKey(host: host, port: port)] = Date(); lock.unlock()
    }

    static func refusedRecently(_ url: URL?) -> Bool {
        guard let url, let host = url.host else { return false }
        let port = url.port ?? (url.scheme?.lowercased() == "https" ? 443 : 80)
        lock.lock(); defer { lock.unlock() }
        guard let at = refusedOrigins[originKey(host: host, port: port)] else { return false }
        return Date().timeIntervalSince(at) < refusalMemorySeconds
    }

    /// givo-10: every redirect an engine request is about to follow, as (the request's original
    /// URL, the next hop), before the hop is requested. A host that answers `serverTrustEvaluator`
    /// for one origin can then answer for the hosts that origin redirects to, and for no other.
    /// Called off the main actor from the session's delegate queue, so it has to be thread-safe;
    /// nil, the default, costs one locked read per redirect.
    public static var redirectObserver: (@Sendable (_ original: URL?, _ target: URL) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return _redirectObserver }
        set { lock.lock(); _redirectObserver = newValue; lock.unlock() }
    }
    nonisolated(unsafe) private static var _redirectObserver: (@Sendable (_ original: URL?, _ target: URL) -> Void)?

    /// Session-level delegate for the owned sessions that otherwise run
    /// without one (disc reader, HLS ingest readers, audio tap fetcher,
    /// carriage probe, subtitle proxy, live rendition fetch) and the fallback
    /// for tasks that missed a per-task delegate.
    static let sessionDelegate = SessionTrustDelegate()

    /// givo-31: the session-level delegate for a connection opened under `trust`, or the shared one
    /// (the process-wide hooks) for a connection opened under none.
    static func sessionDelegate(for trust: ServerTrustPolicy?) -> SessionTrustDelegate {
        trust?.sessionDelegate ?? sessionDelegate
    }

    /// givo-31: the redirect rule without the trust answer, for a session that must see system trust
    /// alone, reporting its hops to `trust` (or to `redirectObserver` when there is none).
    static func redirectDelegate(for trust: ServerTrustPolicy?) -> RedirectScrubbingDelegate {
        guard let trust else { return redirectDelegate }
        return RedirectScrubbingDelegate(trust: trust)
    }

    /// givo-31: a redirect an engine request is about to follow, told to the policy the request was
    /// made under, and to the process-wide `redirectObserver` only for a request made under none.
    static func noteRedirect(from original: URL?, to target: URL, trust: ServerTrustPolicy?) {
        if let trust {
            trust.noteRedirect(from: original, to: target)
        } else {
            redirectObserver?(original, target)
        }
    }

    /// The redirect rule without the trust answer, for a session that must see
    /// system trust alone (`HLSOriginRelay.systemTrustRefuses`).
    static let redirectDelegate = RedirectScrubbingDelegate()

    /// Single disposition shared by the session-level delegate and the
    /// per-task delegates in AVIOReader. Anything other than a server-trust
    /// challenge the host accepted is left to default handling, so client
    /// certificates and HTTP auth behave exactly as before.
    static func resolve(
        _ challenge: URLAuthenticationChallenge,
        completionHandler: (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        // givo-14: the host's three-way answer first.
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           let decide = serverTrustDecision,
           answer(decide(challenge.protectionSpace), to: challenge, completionHandler: completionHandler) {
            return
        }
        guard
            challenge.protectionSpace.authenticationMethod
                == NSURLAuthenticationMethodServerTrust,
            let evaluator = serverTrustEvaluator,
            evaluator(challenge.protectionSpace),
            let trust = challenge.protectionSpace.serverTrust
        else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }

    /// givo-31: the disposition for a connection opened under `trust`. A load's policy answers alone:
    /// `.systemDefault` is the system's own handling, never the process-wide hooks, which answer only
    /// for connections opened under no policy (nil `trust` takes that path unchanged).
    static func resolve(
        _ challenge: URLAuthenticationChallenge,
        trust: ServerTrustPolicy?,
        completionHandler: (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard let trust else {
            resolve(challenge, completionHandler: completionHandler)
            return
        }
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           answer(trust.decision(for: challenge.protectionSpace), to: challenge,
                  completionHandler: completionHandler) {
            return
        }
        completionHandler(.performDefaultHandling, nil)
    }

    /// givo-31: a task-level challenge, answered for the policy the task's session was opened under (its
    /// session delegate's), so a per-task delegate on a policy's session cannot answer for another one.
    static func resolve(
        _ challenge: URLAuthenticationChallenge,
        on session: URLSession,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        if let bound = session.delegate as? SessionTrustDelegate {
            bound.urlSession(session, didReceive: challenge, completionHandler: completionHandler)
        } else {
            resolve(challenge, completionHandler: completionHandler)
        }
    }

    /// givo-31: where a task on `session` reports a redirect hop: its session delegate's policy, the
    /// process-wide observer for a shared session, nowhere for a policy's session whose policy is gone.
    static func redirectRoute(of session: URLSession) -> (trust: ServerTrustPolicy?, reportsHop: Bool) {
        guard let scrubbing = session.delegate as? RedirectScrubbingDelegate else { return (nil, true) }
        let trust = scrubbing.trust
        return (trust, !scrubbing.isPolicyBound || trust != nil)
    }

    /// givo-14 · givo-31: answers a server-trust challenge with `.accept` / `.reject`; false (nothing
    /// answered) for `.systemDefault`, and for an accept with no trust object to vouch for.
    private static func answer(
        _ decision: ServerTrustDecision,
        to challenge: URLAuthenticationChallenge,
        completionHandler: (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) -> Bool {
        switch decision {
        case .accept:
            guard let trust = challenge.protectionSpace.serverTrust else { return false }
            completionHandler(.useCredential, URLCredential(trust: trust))
            return true
        case .reject:
            noteRefused(host: challenge.protectionSpace.host, port: challenge.protectionSpace.port)
            EngineLog.emit("[EngineTLS] the host refused this origin's certificate (givo-14)", category: .demux)
            completionHandler(.cancelAuthenticationChallenge, nil)
            return true
        case .systemDefault:
            return false
        }
    }

    /// Audit NET-108: URLSession's own redirect copies every custom header
    /// except `Authorization` to the new request (measured on CFNetwork 3896:
    /// `X-Emby-Token`, `Cookie`, `Range` and `Referer` all reached a cross-host
    /// target), so without this a 302 took the host's token wherever it
    /// pointed. A task delegate that implements its own redirect method
    /// (AVIOReader, SourcePrewarmFetcher) still answers for its task; one that
    /// does not (the relay's pump) falls back to this.
    class RedirectScrubbingDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        /// givo-31: the policy the session's connections were opened under, nil for the process-wide
        /// hooks. Weak: a policy owns the delegate its own sessions carry, and a policy no load holds
        /// any more answers nothing (the system's handling).
        private(set) weak var trust: ServerTrustPolicy?
        /// givo-31: whether this delegate answers for a policy at all (the weak reference reads nil
        /// both for "none" and for "released", which must not fall back to the process-wide hooks).
        let isPolicyBound: Bool

        override init() {
            isPolicyBound = false
            super.init()
        }

        init(trust: ServerTrustPolicy) {
            self.trust = trust
            isPolicyBound = true
            super.init()
        }

        /// A policy's own delegate, made inside the policy's init and bound to it there.
        fileprivate init(unboundPolicy: Void) {
            isPolicyBound = true
            super.init()
        }

        fileprivate func bind(_ trust: ServerTrustPolicy) { self.trust = trust }

        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping (URLRequest?) -> Void
        ) {
            let original = task.originalRequest
            // givo-31: a policy's own delegate reports to its policy; an unbound one used as a task's
            // delegate reports where the task's session does (its policy, or the process-wide observer).
            let route = isPolicyBound ? (trust: trust, reportsHop: trust != nil) : EngineTLS.redirectRoute(of: session)
            completionHandler(RedirectHeaderPolicy.redirectRequest(
                request,
                originalURL: original?.url,
                originalRange: original?.value(forHTTPHeaderField: "Range"),
                extraHeaders: [:],
                trust: route.trust,
                reportsHop: route.reportsHop))
        }
    }

    final class SessionTrustDelegate: RedirectScrubbingDelegate, @unchecked Sendable {
        func urlSession(
            _ session: URLSession,
            didReceive challenge: URLAuthenticationChallenge,
            completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?)
                -> Void
        ) {
            guard isPolicyBound else {
                EngineTLS.resolve(challenge, completionHandler: completionHandler)
                return
            }
            // givo-31: a released policy accepts nothing on anyone's behalf.
            guard let trust else {
                completionHandler(.performDefaultHandling, nil)
                return
            }
            EngineTLS.resolve(challenge, trust: trust, completionHandler: completionHandler)
        }
    }
}

/// givo-31: one load's own answer to server certificates.
///
/// `EngineTLS`'s hooks are process-wide, so a host that accepts one source's private certificate
/// accepts it for every session, warm and relay that reaches the same host, whichever source that
/// session plays. A policy belongs to one load (`LoadOptions.serverTrust`) or one warm
/// (`AetherEngine.prewarm(url:httpHeaders:byteBudget:serverTrust:)`), and every connection that
/// load opens asks it, and only it: the source reader and its reconnects and fresh addresses, the
/// held connection, the side readers, the HLS ingest, the origin relay, the subtitle proxy and the
/// sidecars. Connections opened under no policy keep the process-wide hooks.
///
/// Connections opened under a policy run in URL sessions of their own, so a connection whose
/// certificate one policy accepted is never pooled into a request made under another policy, or
/// under none. The sessions go when the policy does.
public final class ServerTrustPolicy: @unchecked Sendable, Equatable {

    private let decide: @Sendable (URLProtectionSpace) -> EngineTLS.ServerTrustDecision
    private let onRedirect: (@Sendable (_ original: URL?, _ target: URL) -> Void)?

    /// givo-33: a host's name for what this policy accepts. Two policies with the same non-nil
    /// `identity` answer alike, so bytes a warm fetched under one may be adopted by a load under the
    /// other; nil (the default) matches this policy object only. Never logged.
    public let identity: String?
    private let stampID = UUID()

    /// givo-33: what a warm records of the policy it was fetched under (no reference to the policy, so a
    /// stored warm does not keep its sessions alive).
    struct Stamp: Sendable, Equatable {
        let id: UUID
        let identity: String?
    }

    var stamp: Stamp { Stamp(id: stampID, identity: identity) }

    /// givo-33: whether bytes fetched under `stamp` (nil: under no policy) may be adopted by a load under
    /// `policy`. No policy matches only no policy; a policy matches itself or a policy of the same
    /// non-nil `identity`.
    static func answersAlike(_ stamp: Stamp?, _ policy: ServerTrustPolicy?) -> Bool {
        switch (stamp, policy) {
        case (nil, nil):
            return true
        case let (stamp?, policy?):
            return stamp.id == policy.stampID || (stamp.identity != nil && stamp.identity == policy.identity)
        default:
            return false
        }
    }

    /// The delegate every session opened under this policy carries.
    let sessionDelegate: EngineTLS.SessionTrustDelegate

    private let poolLock = NSLock()
    private var pool: [String: URLSession] = [:]

    /// - Parameters:
    ///   - decide: asked per server-trust challenge of a connection this policy's load opens:
    ///     `.accept` trusts the certificate, `.reject` refuses it even where system trust would accept
    ///     it (the open fails as a certificate rejection), `.systemDefault` is the system's handling.
    ///     The process-wide hooks are not asked. An answer is not re-asked for every connection: in a
    ///     URL session that already accepted an origin, a later `.systemDefault` for it is still
    ///     served (only `.reject` refuses there), so an accept the closure withdraws holds for this
    ///     policy's sessions until the policy goes; a new load's policy starts clean. TODO(R2570):
    ///     after 4023, `.systemDefault` gets an explicit trust evaluation. Called off the main actor,
    ///     so it has to be thread-safe.
    ///   - onRedirect: told (the request's original URL, the next hop) for every redirect a request
    ///     made under this policy is about to follow, before the hop is requested, so `decide` can
    ///     answer for the hosts this load's source redirects to and for no other load's. Same
    ///     threading rules.
    ///   - identity: givo-33: see `identity`.
    public init(decide: @escaping @Sendable (URLProtectionSpace) -> EngineTLS.ServerTrustDecision,
                onRedirect: (@Sendable (_ original: URL?, _ target: URL) -> Void)? = nil,
                identity: String? = nil) {
        self.decide = decide
        self.onRedirect = onRedirect
        self.identity = identity
        self.sessionDelegate = EngineTLS.SessionTrustDelegate(unboundPolicy: ())
        sessionDelegate.bind(self)
    }

    deinit {
        poolLock.lock()
        let sessions = Array(pool.values)
        pool.removeAll()
        poolLock.unlock()
        for session in sessions { session.finishTasksAndInvalidate() }
    }

    public static func == (lhs: ServerTrustPolicy, rhs: ServerTrustPolicy) -> Bool { lhs === rhs }

    func decision(for space: URLProtectionSpace) -> EngineTLS.ServerTrustDecision { decide(space) }

    func noteRedirect(from original: URL?, to target: URL) { onRedirect?(original, target) }

    /// This policy's own long-lived session for `key` (one per shared engine session it stands in for),
    /// made on first use from `configuration`.
    func pooledSession(_ key: String, configuration: () -> URLSessionConfiguration) -> URLSession {
        poolLock.lock()
        defer { poolLock.unlock() }
        if let session = pool[key] { return session }
        let session = URLSession(configuration: configuration(), delegate: sessionDelegate, delegateQueue: nil)
        pool[key] = session
        return session
    }
}

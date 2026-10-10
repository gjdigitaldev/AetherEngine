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
    /// Read per challenge, so replacing it applies from the next connection
    /// without rebuilding sessions. Called off the main actor, from whichever
    /// queue the session raised the challenge on, so it has to be
    /// thread-safe. Lock-guarded like `EngineLog.handler`.
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
           let decide = serverTrustDecision {
            switch decide(challenge.protectionSpace) {
            case .accept:
                if let trust = challenge.protectionSpace.serverTrust {
                    completionHandler(.useCredential, URLCredential(trust: trust))
                    return
                }
            case .reject:
                noteRefused(host: challenge.protectionSpace.host, port: challenge.protectionSpace.port)
                EngineLog.emit("[EngineTLS] the host refused this origin's certificate (givo-14)", category: .demux)
                completionHandler(.cancelAuthenticationChallenge, nil)
                return
            case .systemDefault:
                break
            }
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

    /// Audit NET-108: URLSession's own redirect copies every custom header
    /// except `Authorization` to the new request (measured on CFNetwork 3896:
    /// `X-Emby-Token`, `Cookie`, `Range` and `Referer` all reached a cross-host
    /// target), so without this a 302 took the host's token wherever it
    /// pointed. A task delegate that implements its own redirect method
    /// (AVIOReader, SourcePrewarmFetcher) still answers for its task; one that
    /// does not (the relay's pump) falls back to this.
    class RedirectScrubbingDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping (URLRequest?) -> Void
        ) {
            let original = task.originalRequest
            completionHandler(RedirectHeaderPolicy.redirectRequest(
                request,
                originalURL: original?.url,
                originalRange: original?.value(forHTTPHeaderField: "Range"),
                extraHeaders: [:]))
        }
    }

    final class SessionTrustDelegate: RedirectScrubbingDelegate, @unchecked Sendable {
        func urlSession(
            _ session: URLSession,
            didReceive challenge: URLAuthenticationChallenge,
            completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?)
                -> Void
        ) {
            EngineTLS.resolve(challenge, completionHandler: completionHandler)
        }
    }
}

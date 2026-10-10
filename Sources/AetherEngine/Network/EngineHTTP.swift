import Foundation

/// Host hooks on the engine's source HTTP traffic.
public enum EngineHTTP {

    /// givo-13: every response a source reader's request is answered with, any status, before the
    /// reader acts on it, as (the URL the request named, the response). A host whose origin carries
    /// facts in response headers (where a time-addressed request actually landed, how far a growing
    /// file has been written) reads them here; the engine has no use for them itself.
    ///
    /// Called off the main actor, from the transport's delegate queue, so it has to be thread-safe
    /// and quick. nil, the default, costs one locked read per response.
    public static var sourceResponseObserver: (@Sendable (_ requested: URL, _ response: HTTPURLResponse) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return _observer }
        set { lock.lock(); _observer = newValue; lock.unlock() }
    }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var _observer: (@Sendable (_ requested: URL, _ response: HTTPURLResponse) -> Void)?

    static func noteSourceResponse(requested: URL?, _ response: HTTPURLResponse) {
        guard let requested, let observer = sourceResponseObserver else { return }
        observer(requested, response)
    }
}

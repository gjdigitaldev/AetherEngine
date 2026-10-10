import Testing
import Foundation
@testable import AetherEngine

/// givo-13: a host reads facts its origin carries in response headers (a DVR server's landed seek time)
/// through `EngineHTTP.sourceResponseObserver`, on every transport a source reader opens with.
@Suite("Source response observer (givo-13)", .offCooperativePool, .serialized)
struct SourceResponseObserverTests {

    private final class Seen: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [(URL, Int)] = []
        func add(_ url: URL, _ status: Int) { lock.lock(); items.append((url, status)); lock.unlock() }
        func snapshot() -> [(URL, Int)] { lock.lock(); defer { lock.unlock() }; return items }
    }

    @Test("the reader's answered requests reach the observer with the URL they named",
          .timeLimit(.minutes(1)), arguments: [0, 1, 2])
    func observerSeesTheSourceResponse(transport: Int) async throws {
        let serverMaybe = ThrottledOriginServer(totalSize: 8 * 1024 * 1024)
        let server = try #require(serverMaybe)
        defer { server.stop() }
        let marker = "givo13-\(transport)-\(UUID().uuidString.prefix(8))"
        let url = URL(string: "http://127.0.0.1:\(server.port)/movie.ts?t=12&m=\(marker)")!
        let seen = Seen()
        EngineHTTP.sourceResponseObserver = { requested, response in
            guard requested.query?.contains(marker) == true else { return }
            seen.add(requested, response.statusCode)
        }
        defer { EngineHTTP.sourceResponseObserver = nil }

        let reader = AVIOReader(url: url, sequentialOnly: transport == 2, heldConnection: transport == 1)
        defer { reader.markClosed(); reader.close() }
        try reader.open()
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: 64 * 1024)
        defer { buf.deallocate() }
        #expect(reader.read(into: buf, size: 64 * 1024) > 0)

        let hits = seen.snapshot()
        #expect(!hits.isEmpty, "no response reached the observer")
        #expect(hits.allSatisfy { $0.0.query?.contains("t=12") == true }, "the URL keeps the query it named: \(hits)")
        #expect(hits.contains { $0.1 == 200 || $0.1 == 206 })
    }
}

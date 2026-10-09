import Testing
import Foundation
@testable import AetherEngine

/// givo-1: a connection-capped panel keeps counting a connection for about a second after it
/// closes, so the request a seek sends right after ending the previous one is refused for that
/// previous connection (509 on Apache fronts, 458/460 on Xtream-style panels). Field traces: a
/// 17.8 s back-seek and a 19 s seek, each one such refusal charged to the rate-limit ladder, the
/// origin budget and its pacer. Such a refusal gets one quick retry and charges none of them.
@Suite("Own-close refusal (givo-1)", .offCooperativePool)
struct OwnCloseRefusalTests {

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func next() -> Int {
            lock.lock(); defer { lock.unlock() }
            value += 1
            return value
        }
    }

    @Test("a slot refusal right after our own close takes one quick retry and charges nothing",
          .timeLimit(.minutes(2)), arguments: [509, 458, 460], [false, true])
    func refusalAfterOwnCloseRetriesOnce(status: Int, held: Bool) async throws {
        let target: Int64 = 48 * 1024 * 1024
        let hitsAtTarget = Counter()
        // Slow enough that the first connection is still delivering when the seek ends it.
        let serverMaybe = ThrottledOriginServer(
            totalSize: 96 * 1024 * 1024, chunkBytes: 64 * 1024, throttleUs: 20_000,
            respond: { _, offset, _ in
                guard offset == target else { return .serve206 }
                return hitsAtTarget.next() == 1 ? .status(status) : .serve206
            })
        let server = try #require(serverMaybe)
        defer { server.stop() }

        let url = URL(string: "http://127.0.0.1:\(server.port)/movie.bin")!
        let reader = AVIOReader(url: url, heldConnection: held)
        defer { reader.markClosed(); reader.close() }
        try reader.open()

        let slice = 64 * 1024
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: slice)
        defer { buf.deallocate() }
        #expect(reader.read(into: buf, size: Int32(slice)) > 0)
        #expect(reader.hasLiveConnectionForTesting, "the seek has to end a connection that is still serving")

        #expect(reader.seek(offset: target, whence: SEEK_SET) == target)
        let began = Date()
        let n = reader.read(into: buf, size: Int32(slice))
        let elapsed = Date().timeIntervalSince(began)

        #expect(n > 0, "the retry must deliver")
        #expect(server.requestLog.filter { $0.start == target }.count == 2,
                "one refusal, one retry: \(server.requestLog)")
        #expect(reader.rateLimitStreakForTesting == 0, "the refusal is ours, not the origin metering")
        #expect(OriginRequestBudget.shared.limit(for: url) == nil, "no concurrency budget may be learned from it")
        #expect(!OriginRequestBudget.shared.isPaced(url), "and no request-rate pacer armed")
        #expect(OriginRequestBudget.shared.refusedRecently(url, within: 60),
                "the revive arm still has to see that a refusal happened")
        #expect(elapsed < 6, "one second of retry, not the 2/4/8 s ladder (took \(elapsed)s)")
    }
}

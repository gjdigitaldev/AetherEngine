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

    @Test("a slot refusal right after a completed range is the same lingering slot",
          .timeLimit(.minutes(2)), arguments: [509, 460])
    func refusalAfterCompletedRangeRetriesOnce(status: Int) async throws {
        // F1 on a 1-connection provider: the request for the next 32 MiB range, sent as the last one
        // completed, was refused 509 three times and stalled playback.
        let firstRange: Int64 = 4 * 1024 * 1024
        let hitsAtBoundary = Counter()
        let serverMaybe = ThrottledOriginServer(
            totalSize: 32 * 1024 * 1024,
            respond: { _, offset, _ in
                guard offset == firstRange else { return .serve206 }
                return hitsAtBoundary.next() == 1 ? .status(status) : .serve206
            })
        let server = try #require(serverMaybe)
        defer { server.stop() }

        let url = URL(string: "http://127.0.0.1:\(server.port)/movie.bin")!
        let reader = AVIOReader(url: url, boundedInitialFetch: firstRange)
        defer { reader.markClosed(); reader.close() }
        try reader.open()

        let slice = 128 * 1024
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: slice)
        defer { buf.deallocate() }
        var got: Int64 = 0
        while got < firstRange + Int64(slice) {
            let n = reader.read(into: buf, size: Int32(slice))
            if n <= 0 { break }
            got += Int64(n)
        }

        #expect(got >= firstRange + Int64(slice), "reading must continue past the refused boundary")
        #expect(server.requestLog.filter { $0.start == firstRange }.count == 2,
                "one refusal, one retry: \(server.requestLog)")
        #expect(reader.rateLimitStreakForTesting == 0)
        #expect(OriginRequestBudget.shared.limit(for: url) == nil)
        #expect(!OriginRequestBudget.shared.isPaced(url))
    }
}

/// givo-6: `LoadOptions.heldSourceMaxBitsPerSecond` holds a held connection's pull to its pace, so a
/// whole-film race ahead does not burst an origin that meters bandwidth.
@Suite("Held connection pace (givo-6)", .offCooperativePool)
struct HeldConnectionPaceTests {

    @Test("a paced held connection pulls no faster than its pace", .timeLimit(.minutes(2)))
    func pacedHeldConnectionHoldsItsRate() async throws {
        let serverMaybe = ThrottledOriginServer(totalSize: 64 * 1024 * 1024, throttleUs: 0)
        let server = try #require(serverMaybe)
        defer { server.stop() }
        let url = URL(string: "http://127.0.0.1:\(server.port)/movie.bin")!
        OriginRequestBudget.shared.setHeldPace(bitsPerSecond: 16_000_000, for: url)   // 2 MB/s
        defer { OriginRequestBudget.shared.setHeldPace(bitsPerSecond: nil, for: url) }

        let reader = AVIOReader(url: url, heldConnection: true)
        defer { reader.markClosed(); reader.close() }
        try reader.open()

        let slice = 256 * 1024
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: slice)
        defer { buf.deallocate() }
        let began = Date()
        var got = 0
        while got < 8 * 1024 * 1024 {
            let n = reader.read(into: buf, size: Int32(slice))
            if n <= 0 { break }
            got += Int(n)
        }
        let elapsed = Date().timeIntervalSince(began)
        #expect(got >= 8 * 1024 * 1024)
        // 8 MB at 2 MB/s, less the first second of bucket and the open's head: well over 2 s.
        #expect(elapsed > 2.0, "8 MB at a 2 MB/s pace took \(elapsed)s")
    }
}

/// givo-11: a connection-capped panel that ENDED a connection itself (a mid-body close) keeps
/// counting it until its own socket timeout notices, measured past 11 s (a 1-connection panel's
/// front closed a held connection 161 MB in, and refused the replacement 509 at 0.3 s, 1.3 s and
/// 11 s). Those refusals are our own connection too: retries at 1, 2, 4 and 8 s, nothing charged.
@Suite("Faulted-connection refusal (givo-11)", .offCooperativePool)
struct FaultedConnectionRefusalTests {

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func next() -> Int {
            lock.lock(); defer { lock.unlock() }
            value += 1
            return value
        }
    }

    @Test("refusals after the origin ended our connection retry at 1, 2 and 4 s and charge nothing",
          .timeLimit(.minutes(2)), arguments: [false, true])
    func refusalsAfterAFaultRetryWithoutTheLadder(held: Bool) async throws {
        let dropAt: Int64 = 8 * 1024 * 1024
        let refusals = Counter()
        let serverMaybe = ThrottledOriginServer(
            totalSize: 96 * 1024 * 1024, chunkBytes: 64 * 1024, throttleUs: 0,
            respond: { _, offset, _ in
                if offset == 0 { return .serveThenDrop(afterBytes: dropAt) }
                // The frontier only (wherever the drop left it: a close with unread bytes can lose
                // some in flight); the open's tail prefetch asks near the end and must not spend them.
                if offset > 0, offset < dropAt * 2, refusals.next() <= 3 { return .status(509) }
                return .serve206
            })
        let server = try #require(serverMaybe)
        defer { server.stop() }

        let url = URL(string: "http://127.0.0.1:\(server.port)/movie.bin")!
        let reader = AVIOReader(url: url, heldConnection: held)
        defer { reader.markClosed(); reader.close() }
        try reader.open()

        let slice = 256 * 1024
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: slice)
        defer { buf.deallocate() }
        let began = Date()
        var got: Int64 = 0
        while got < dropAt + 4 * Int64(slice) {
            let n = reader.read(into: buf, size: Int32(slice))
            if n <= 0 { break }
            got += Int64(n)
        }
        let elapsed = Date().timeIntervalSince(began)

        #expect(got >= dropAt + 4 * Int64(slice), "reading must continue past the dropped connection")
        #expect(server.requestLog.filter { $0.start > 0 && $0.start < dropAt * 2 }.count >= 4,
                "three refusals, then served: \(server.requestLog)")
        #expect(reader.rateLimitStreakForTesting == 0, "the refusals are our faulted connection, not metering")
        #expect(OriginRequestBudget.shared.limit(for: url) == nil, "no concurrency budget may be learned from them")
        #expect(!OriginRequestBudget.shared.isPaced(url), "and no request-rate pacer armed")
        // Upper bound only: other suites scale the reconnect backoff process-wide while this runs.
        #expect(elapsed < 12, "1 + 2 + 4 s of retries, not the ladder (took \(elapsed)s)")
    }
}

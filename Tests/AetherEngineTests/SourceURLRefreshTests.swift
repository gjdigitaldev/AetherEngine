import Testing
import Foundation
@testable import AetherEngine

/// givo-20: a set-top-box portal's media front ended a held connection 9.4 MB into a title and
/// refused every reconnect on that link for over a minute, while a freshly minted link was served at
/// once. After the lineage's first retry is refused, the reader asks the host for a fresh address and
/// reads on at the same offset; at most three times in two minutes.
@Suite("Fresh source address from the host (givo-20)", .offCooperativePool, .serialized)
struct SourceURLRefreshTests {

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func next() -> Int { lock.lock(); defer { lock.unlock() }; value += 1; return value }
        var count: Int { lock.lock(); defer { lock.unlock() }; return value }
    }

    @Test("a refused reconnect after the origin closed our connection reads on from a fresh address",
          .timeLimit(.minutes(2)), arguments: [false, true])
    func refusedReconnectReadsOnFromAFreshAddress(held: Bool) async throws {
        let dropAt: Int64 = 8 * 1024 * 1024
        let serverMaybe = ThrottledOriginServer(
            totalSize: 96 * 1024 * 1024, chunkBytes: 64 * 1024, throttleUs: 0,
            respond: { _, offset, path in
                if path.hasPrefix("/old") {
                    if offset == 0 { return .serveThenDrop(afterBytes: dropAt) }
                    if offset < dropAt * 2 { return .status(509) }   // the old link is counted for good
                }
                return .serve206
            })
        let server = try #require(serverMaybe)
        defer { server.stop() }
        let url = URL(string: "http://127.0.0.1:\(server.port)/old/movie.ts")!
        let fresh = URL(string: "http://127.0.0.1:\(server.port)/new/movie.ts")!
        let asked = Counter()
        SourceURLRefresh.shared.register(SourceURLRefresher { _ in _ = asked.next(); return fresh }, for: url)
        defer { SourceURLRefresh.shared.register(nil, for: url) }

        let reader = AVIOReader(url: url, heldConnection: held)
        defer { reader.markClosed(); reader.close() }
        try reader.open()
        let slice = 256 * 1024
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: slice)
        defer { buf.deallocate() }
        var got: Int64 = 0
        while got < dropAt + 4 * Int64(slice) {
            let n = reader.read(into: buf, size: Int32(slice))
            if n <= 0 { break }
            got += Int64(n)
        }

        #expect(got >= dropAt + 4 * Int64(slice), "reading must go on past the closed connection")
        #expect(asked.count == 1, "one fresh address, asked once: \(asked.count)")
        let log = server.requestLog
        #expect(log.filter { $0.path.hasPrefix("/old") && $0.start > 0 && $0.start < dropAt * 2 }.count == 2,
                "the refusal and its one quick retry on the old link, then the fresh one: \(log)")
        #expect(log.contains { $0.path.hasPrefix("/new") && $0.start > 0 }, "the read went on at the frontier on the fresh link")
        #expect(!OriginRequestBudget.shared.isPaced(url), "no pacer armed for our own counted connection")
    }

    @Test("three fresh addresses in two minutes, then the refusal stands and the read fails",
          .timeLimit(.minutes(2)))
    func refreshesAreBoundedThenTheReadFails() async throws {
        let dropAt: Int64 = 8 * 1024 * 1024
        let serverMaybe = ThrottledOriginServer(
            totalSize: 96 * 1024 * 1024, chunkBytes: 64 * 1024, throttleUs: 0,
            respond: { _, offset, path in
                if path.hasPrefix("/old"), offset == 0 { return .serveThenDrop(afterBytes: dropAt) }
                if offset > 0, offset < dropAt * 2 { return .status(509) }   // every link refused
                return .serve206
            })
        let server = try #require(serverMaybe)
        defer { server.stop() }
        let url = URL(string: "http://127.0.0.1:\(server.port)/old/movie.ts")!
        let asked = Counter()
        let port = server.port
        SourceURLRefresh.shared.register(SourceURLRefresher { _ in
            URL(string: "http://127.0.0.1:\(port)/fresh-\(asked.next())/movie.ts")
        }, for: url)
        defer { SourceURLRefresh.shared.register(nil, for: url) }

        let reader = AVIOReader(url: url, heldConnection: true)
        defer { reader.markClosed(); reader.close() }
        try reader.open()
        let slice = 256 * 1024
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: slice)
        defer { buf.deallocate() }
        var got: Int64 = 0
        var last: Int32 = 1
        let began = Date()
        while last > 0, got < dropAt * 4 {
            last = reader.read(into: buf, size: Int32(slice))
            if last > 0 { got += Int64(last) }
        }

        #expect(last <= 0, "the read fails once the fresh addresses are spent")
        #expect(got < dropAt * 2, "nothing past the drop was served")
        #expect(asked.count == SourceURLRefresh.maxRefreshes, "\(asked.count) refreshes")
        #expect(Date().timeIntervalSince(began) < 40, "bounded, not the minutes-long ladder")
    }

    @Test("a reader waits out the origin's release time after our own close before it dials again",
          .timeLimit(.minutes(1)))
    func ownCloseReleaseIsWaitedOut() async throws {
        let serverMaybe = ThrottledOriginServer(totalSize: 64 * 1024 * 1024, chunkBytes: 64 * 1024, throttleUs: 20_000)
        let server = try #require(serverMaybe)
        defer { server.stop() }
        let url = URL(string: "http://127.0.0.1:\(server.port)/release/movie.ts")!
        OriginRequestBudget.shared.setOwnCloseRelease(seconds: 0.8, for: url)
        defer { OriginRequestBudget.shared.setOwnCloseRelease(seconds: nil, for: url) }

        let reader = AVIOReader(url: url, heldConnection: true)
        defer { reader.markClosed(); reader.close() }
        try reader.open()
        let slice = 64 * 1024
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: slice)
        defer { buf.deallocate() }
        #expect(reader.read(into: buf, size: Int32(slice)) > 0)

        let target: Int64 = 40 * 1024 * 1024
        #expect(reader.seek(offset: target, whence: SEEK_SET) == target)
        let began = Date()
        #expect(reader.read(into: buf, size: Int32(slice)) > 0)
        #expect(Date().timeIntervalSince(began) >= 0.7, "the dial after our own close waited the release time")
    }

    /// givo-21: after our OWN close (a seek), a front that refuses the dial and its quick retry gets
    /// replaced by a fresh address at once, and nothing is charged: in the field a pacer armed by the
    /// old link's refusals made the fresh link wait 5.9 s for a slot.
    @Test("a seek's dial refused twice after our own close reads on from a fresh address, uncharged",
          .timeLimit(.minutes(2)))
    func ownCloseRefusalsGoStraightToAFreshAddress() async throws {
        let target: Int64 = 48 * 1024 * 1024
        let serverMaybe = ThrottledOriginServer(
            totalSize: 96 * 1024 * 1024, chunkBytes: 64 * 1024, throttleUs: 20_000,
            respond: { _, offset, path in
                if path.hasPrefix("/old"), offset == target { return .status(509) }   // the old link, counted
                return .serve206
            })
        let server = try #require(serverMaybe)
        defer { server.stop() }
        let url = URL(string: "http://127.0.0.1:\(server.port)/old/movie.ts")!
        let fresh = URL(string: "http://127.0.0.1:\(server.port)/new/movie.ts")!
        let asked = Counter()
        SourceURLRefresh.shared.register(SourceURLRefresher { _ in _ = asked.next(); return fresh }, for: url)
        defer { SourceURLRefresh.shared.register(nil, for: url) }

        let reader = AVIOReader(url: url, heldConnection: true)
        defer { reader.markClosed(); reader.close() }
        try reader.open()
        let slice = 64 * 1024
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: slice)
        defer { buf.deallocate() }
        #expect(reader.read(into: buf, size: Int32(slice)) > 0)

        #expect(reader.seek(offset: target, whence: SEEK_SET) == target)
        let began = Date()
        #expect(reader.read(into: buf, size: Int32(slice)) > 0, "the seek's read must be served")
        let elapsed = Date().timeIntervalSince(began)

        #expect(asked.count == 1, "one fresh address: \(asked.count)")
        let oldAtTarget = server.requestLog.filter { $0.path.hasPrefix("/old") && $0.start == target }.count
        #expect(oldAtTarget == 2, "the refusal and its one quick retry, then the fresh link: \(server.requestLog)")
        #expect(server.requestLog.contains { $0.path.hasPrefix("/new") && $0.start == target })
        #expect(!OriginRequestBudget.shared.isPaced(url), "nothing in this lineage arms the pacer")
        #expect(OriginRequestBudget.shared.limit(for: url) == nil, "nor teaches the origin a limit")
        #expect(elapsed < 6, "one quick retry and a refresh, not the ladder (took \(elapsed)s)")
    }

    @Test("an open whose first dial never answers dials a fresh address at the 5 s mark, and never the dead one again (givo-29)",
          .timeLimit(.minutes(2)))
    func deadFirstDialOpensOnAFreshAddress() async throws {
        let serverMaybe = ThrottledOriginServer(
            totalSize: 16 * 1024 * 1024, chunkBytes: 64 * 1024, throttleUs: 0,
            respond: { _, _, path in path.hasPrefix("/old") ? .neverAnswer : .serve206 })
        let server = try #require(serverMaybe)
        defer { server.stop() }
        let url = URL(string: "http://127.0.0.1:\(server.port)/old/movie.ts")!
        let fresh = URL(string: "http://127.0.0.1:\(server.port)/new/movie.ts")!
        let asked = Counter()
        SourceURLRefresh.shared.register(SourceURLRefresher { _ in _ = asked.next(); return fresh }, for: url)
        defer { SourceURLRefresh.shared.register(nil, for: url) }

        let reader = AVIOReader(url: url, heldConnection: true)
        defer { reader.markClosed(); reader.close() }
        let started = Date()
        try reader.open()
        let elapsed = Date().timeIntervalSince(started)
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: 65536)
        defer { buf.deallocate() }
        #expect(reader.read(into: buf, size: 65536) > 0)
        #expect(elapsed >= AVIOReader.deadDialMarkSeconds - 0.2 && elapsed < AVIOReader.deadDialMarkSeconds + 5,
                "opened at the mark plus a dial: \(elapsed)")
        #expect(asked.count == 1)
        #expect(server.requestLog.filter { $0.path.hasPrefix("/old") && $0.start == 0 }.count == 1,
                "the dead link is dialed once: \(server.requestLog)")
    }

    @Test("an open whose first dial answers never asks for a fresh address (givo-29)", .timeLimit(.minutes(1)))
    func answeredFirstDialIsUntouched() async throws {
        let serverMaybe = ThrottledOriginServer(
            totalSize: 16 * 1024 * 1024, chunkBytes: 64 * 1024, throttleUs: 0, respond: { _, _, _ in .serve206 })
        let server = try #require(serverMaybe)
        defer { server.stop() }
        let url = URL(string: "http://127.0.0.1:\(server.port)/old/movie.ts")!
        let asked = Counter()
        SourceURLRefresh.shared.register(SourceURLRefresher { _ in _ = asked.next(); return url }, for: url)
        defer { SourceURLRefresh.shared.register(nil, for: url) }
        let reader = AVIOReader(url: url, heldConnection: true)
        defer { reader.markClosed(); reader.close() }
        try reader.open()
        #expect(asked.count == 0)
    }

    @Test("a refresh is not offered once three are in the window (givo-29)")
    func canRefreshNowHonoursTheWindow() {
        let url = URL(string: "http://127.0.0.1:1/budget/movie.ts")!
        SourceURLRefresh.shared.register(SourceURLRefresher { _ in url }, for: url)
        defer { SourceURLRefresh.shared.register(nil, for: url) }
        #expect(SourceURLRefresh.shared.canRefreshNow(url))
        for _ in 0..<SourceURLRefresh.maxRefreshes {
            _ = SourceURLRefresh.shared.refresh(source: url, timeout: 2, shouldAbort: { false })
        }
        #expect(!SourceURLRefresh.shared.canRefreshNow(url))
        #expect(!SourceURLRefresh.shared.canRefreshNow(URL(string: "http://127.0.0.1:1/unregistered.ts")!))
    }
}

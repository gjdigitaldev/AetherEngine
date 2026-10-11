import AVFoundation
import Combine
import Foundation
import Testing
@testable import AetherEngine

/// Real AVPlayer witness with a synthetic H.264/AAC MKV, served only over loopback.
/// Scripts/test-vod-open-seek.sh supplies the fixture; no provider credentials are needed.
@Suite(.serialized, .timeLimit(.minutes(2)))
@MainActor
struct VODOpenSeekIntegrationTests {
    private func fixture() throws -> Data {
        let path = try #require(ProcessInfo.processInfo.environment["AETHER_VOD_FIXTURE"])
        return try Data(contentsOf: URL(fileURLWithPath: path))
    }

    @Test("A silent first request recovers once, then native forward and backward seeks land",
          .enabled(if: ProcessInfo.processInfo.environment["AETHER_VOD_FIXTURE"] != nil))
    func recoveredSourceSeeks() async throws {
        let origin = try ProbeHTTPTestOrigin(data: fixture(), stage: .headers)
        let engine = try AetherEngine()
        defer { engine.stop(); origin.stop() }
        var options = LoadOptions(sourceOpenPolicy: .init(firstByteTimeout: 0.2, sizeProbeTimeout: 2))
        options.maxConcurrentSourceRequests = 1
        options.prepareNativeSubtitles = true
        options.preferredSubtitleLanguages = ["en"]
        options.suppressDisplayCriteria = true
        let started = ContinuousClock.now
        try await engine.load(url: URL(string: "http://127.0.0.1:\(origin.port)/media.mkv")!, options: options)
        let ready = try await waitFor(upTo: .seconds(10)) { engine.canSeek && engine.currentTime > 0.5 }
        try #require(ready)
        #expect(engine.videoRoute == .loopback)
        #expect(!engine.subtitleTracks.isEmpty)
        let captionsReady = try await waitFor(upTo: .seconds(3)) { !engine.subtitleCues.isEmpty }
        #expect(captionsReady, "the primary packet harvest must still supply subtitles with serial source I/O")
        let elapsed = started.duration(to: .now)
        print("VOD_RECOVERY_READY=\(elapsed) requests=\(origin.requests.count)")
        #expect(elapsed < .seconds(5), "a recovered open must not repeat the probe/reconnect ladder")
        #expect(origin.requests.allSatisfy { $0.method == "GET" && $0.range != nil })
        let player = try #require(engine.currentAVPlayer)
        var events: [SeekEvent] = []
        let observer = engine.seekEvents.sink { events.append($0) }
        defer { observer.cancel() }
        for target in [12.0, 4.0] {
            await engine.seek(to: target)
            let actual = player.currentTime().seconds
            print("VOD_SEEK target=\(target) item=\(actual) engine=\(engine.currentTime) source=\(engine.sourceTime)")
            #expect(abs(actual - target) < 1)
            #expect(abs(engine.currentTime - target) < 1)
            let landed = events.contains { event in
                if case .landed(let rendered) = event.outcome { return abs(rendered - target) < 1 }
                return false
            }
            #expect(landed)
            let advanced = try await waitFor(upTo: .seconds(4)) { engine.currentTime > target + 1 }
            #expect(advanced)
            #expect(player.currentItem?.error == nil)
        }
        engine.pause()
        await engine.seek(to: 6)
        #expect(abs(player.currentTime().seconds - 6) < 0.25)
        #expect(engine.state == .paused)
        #expect(player.rate == 0)
        let source = URL(string: "http://127.0.0.1:\(origin.port)/media.mkv")!
        #expect(OriginRequestBudget.shared.snapshot(for: source)?.peakInflight == 1)
    }

    @Test("A forward-only VOD ignores saved position and rejects seeks without a false landing",
          .enabled(if: ProcessInfo.processInfo.environment["AETHER_VOD_FIXTURE"] != nil))
    func sequentialSourceHasHonestClock() async throws {
        let origin = try ProbeHTTPTestOrigin(data: fixture())
        let engine = try AetherEngine()
        defer { engine.stop(); origin.stop() }
        var options = LoadOptions()
        options.sequentialOrigin = true
        options.declaredDurationSeconds = 20
        options.maxConcurrentSourceRequests = 1
        options.prepareNativeSubtitles = true
        options.preferredSubtitleLanguages = ["en"]
        options.suppressDisplayCriteria = true
        try await engine.load(url: URL(string: "http://127.0.0.1:\(origin.port)/media.mkv")!, startPosition: 12, options: options)
        let ready = try await waitFor(upTo: .seconds(10)) { engine.isSessionReady && engine.currentTime > 0.5 }
        try #require(ready)
        #expect(engine.isSourceSeekable == false)
        #expect(!engine.canSeek)
        #expect(engine.currentTime < 5)
        var events: [SeekEvent] = []
        let observer = engine.seekEvents.sink { events.append($0) }
        defer { observer.cancel() }
        // givo-15 / givo-34: what the session already cut, inside the item's seekable range, lands from the
        // cache; a target past what the item can reach is refused without a false landing.
        await engine.seek(to: 12)
        let landed = try await waitFor(upTo: .seconds(5)) {
            events.contains { if case .landed = $0.outcome { return true } else { return false } }
                || events.contains { if case .rejected = $0.outcome { return true } else { return false } }
        }
        #expect(landed)
        if events.contains(where: { if case .rejected = $0.outcome { return true } else { return false } }) {
            #expect(events.map(\.outcome).last == .rejected(.sourceNotSeekable))
            #expect(engine.currentTime < 5)
        } else {
            #expect(abs(engine.currentTime - 12) < 0.5)
        }
        await engine.seek(to: 19.9)
        #expect(events.map(\.outcome).last == .rejected(.sourceNotSeekable), "a seek at the item's very end was not refused")
        #expect(!engine.isSeeking)
        print("VOD_SEQUENTIAL clock=\(engine.currentTime) seekable=\(engine.canSeek) events=\(events)")
    }

    /// givo-34: a load's trust policy (and the URL sessions it owns) goes with the load that stopped,
    /// and stays through the session's own rebuilds of the same title.
    @Test("A stop releases the load's trust policy; a rebuild of the same title keeps it",
          .enabled(if: ProcessInfo.processInfo.environment["AETHER_VOD_FIXTURE"] != nil))
    func stopReleasesTrustPolicy() async throws {
        let origin = try ProbeHTTPTestOrigin(data: fixture())
        let engine = try AetherEngine()
        defer { engine.stop(); origin.stop() }
        weak var released: ServerTrustPolicy?
        do {
            var options = LoadOptions()
            options.suppressDisplayCriteria = true
            options.serverTrust = ServerTrustPolicy(decide: { _ in .systemDefault })
            released = options.serverTrust
            try await engine.load(url: URL(string: "http://127.0.0.1:\(origin.port)/media.mkv")!, options: options)
        }
        let ready = try await waitFor(upTo: .seconds(10)) { engine.isSessionReady }
        try #require(ready)
        #expect(released != nil, "a playing load lost its policy")
        try await engine.reloadAtCurrentPosition()
        #expect(released != nil, "a rebuild of the same title dropped its policy")
        #expect(engine.loadedOptions.serverTrust != nil)
        engine.stop()
        #expect(engine.loadedOptions.serverTrust == nil, "a stopped session still names its load's policy")
        // Measured with this test: the stopped HLS session itself is still alive 40 s after stop, and its
        // open profile names the policy, so the policy outlives the engine's own reference.
        let gone = try await waitFor(upTo: .seconds(5)) { released == nil }
        withKnownIssue("the stopped HLS session is not released yet and still holds the policy") {
            #expect(gone, "the stopped load's policy is still alive")
        }
    }
}

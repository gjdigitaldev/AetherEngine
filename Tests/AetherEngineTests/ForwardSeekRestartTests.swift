import Testing
import Foundation
@testable import AetherEngine

/// givo-24: a forward seek within `forwardWaitWindow` of the march front restarts at the asked segment
/// when the measured march would only start it more than ~2 s later than a restart would. Lab (10 s
/// keyframe intervals, 10 MB segments at 1.3 MB/s): the march cut every segment in between first.
struct ForwardSeekRestartTests {

    private static let second: UInt64 = 1_000_000_000

    @Test("a producer's first segment is not a pace sample; a marched segment is")
    func meterSamplesOnlyMarchedSegments() {
        let meter = MarchPaceMeter()
        meter.readStarted(10, counts: false, now: 0)
        meter.segmentCut(10, now: 12 * Self.second)
        meter.segmentQueued(11)
        #expect(meter.reading(now: 12 * Self.second) == nil)
        meter.readStarted(11, counts: true, now: 12 * Self.second)
        meter.segmentCut(11, now: 20 * Self.second)
        meter.segmentQueued(12)
        meter.readStarted(12, counts: true, now: 20 * Self.second)
        meter.segmentCut(12, now: 30 * Self.second)
        meter.segmentQueued(13)
        let parked = meter.reading(now: 31 * Self.second)
        #expect(parked == .init(inProgressIndex: 13, inProgressElapsedSeconds: 0, secondsPerSegment: 9))
        meter.readStarted(13, counts: true, now: 32 * Self.second)
        #expect(meter.reading(now: 35 * Self.second)?.inProgressElapsedSeconds == 3)
    }

    @Test("a slow march that would start the asked segment 14 s from now loses to a restart")
    func slowMarchRestarts() {
        let pace = MarchPaceMeter.Reading(inProgressIndex: 10, inProgressElapsedSeconds: 2, secondsPerSegment: 8)
        #expect(VideoSegmentProvider.marchLeadBeforeRestartWins(index: 12, pace: pace) == 14)
    }

    @Test("the segment in progress is the march itself and never restarts")
    func sequentialFetchWaits() {
        let pace = MarchPaceMeter.Reading(inProgressIndex: 10, inProgressElapsedSeconds: 0, secondsPerSegment: 8)
        #expect(VideoSegmentProvider.marchLeadBeforeRestartWins(index: 10, pace: pace) == nil)
    }

    @Test("a fast march keeps the wait")
    func fastMarchWaits() {
        let pace = MarchPaceMeter.Reading(inProgressIndex: 10, inProgressElapsedSeconds: 0, secondsPerSegment: 0.3)
        #expect(VideoSegmentProvider.marchLeadBeforeRestartWins(index: 15, pace: pace) == nil)
    }

    @Test("the next segment restarts only when what is left of the one in progress outlasts the dial")
    func nextSegmentNeedsAFarCut() {
        let late = MarchPaceMeter.Reading(inProgressIndex: 10, inProgressElapsedSeconds: 6.5, secondsPerSegment: 8)
        #expect(VideoSegmentProvider.marchLeadBeforeRestartWins(index: 11, pace: late) == nil)
        let early = MarchPaceMeter.Reading(inProgressIndex: 10, inProgressElapsedSeconds: 3, secondsPerSegment: 8)
        #expect(VideoSegmentProvider.marchLeadBeforeRestartWins(index: 11, pace: early) == 5)
    }

    @Test("the reader keeps its live connection for a forward jump only as far as the link delivers in 2 s")
    func forwardKeepFollowsTheMeasuredRate() {
        #expect(AVIOReader.forwardKeepLimit(bytesPerSecond: nil, isLive: false) == 8 * 1024 * 1024)
        #expect(AVIOReader.forwardKeepLimit(bytesPerSecond: 25_000_000, isLive: false) == 8 * 1024 * 1024)
        #expect(AVIOReader.forwardKeepLimit(bytesPerSecond: 1_300_000, isLive: false) == 2_600_000)
        #expect(AVIOReader.forwardKeepLimit(bytesPerSecond: 50_000, isLive: false) == 512 * 1024)
        #expect(AVIOReader.forwardKeepLimit(bytesPerSecond: 1_300_000, isLive: true) == 8 * 1024 * 1024)
    }

    @Test("a rate needs a megabyte and half a second behind it")
    func deliveryRateNeedsEvidence() {
        let start = DispatchTime(uptimeNanoseconds: 1_000_000_000)
        let later = DispatchTime(uptimeNanoseconds: 3_000_000_000)
        #expect(AVIOReader.deliveryRate(bytes: 2_600_000, since: start, now: later) == 1_300_000)
        #expect(AVIOReader.deliveryRate(bytes: 500_000, since: start, now: later) == nil)
        #expect(AVIOReader.deliveryRate(bytes: 2_600_000, since: nil, now: later) == nil)
        #expect(AVIOReader.deliveryRate(bytes: 2_600_000, since: start,
                                         now: DispatchTime(uptimeNanoseconds: 1_200_000_000)) == nil)
    }
}

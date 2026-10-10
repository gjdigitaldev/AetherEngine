import Testing
import Foundation
@testable import AetherEngine

/// givo-26: a loopback VOD seek whose look-back is not cached goes in two legs. Lab (aetherctl,
/// 1.3 MB/s, 10 s segments): an exact seek asked for the segment ~15 s before the target first and
/// moved the picture after 29 s; a first leg bounded to the target's own segment asked for that one.
struct TolerantSeekLegTests {

    @Test("the first leg may reach back to the start of the target's segment, and never less than 0.5 s")
    func toleranceReachesTheSegmentStart() {
        #expect(abs(AetherEngine.tolerantSeekTolerance(itemSeconds: 153.02, segmentStart: 150) - 3.02) < 1e-9)
        #expect(AetherEngine.tolerantSeekTolerance(itemSeconds: 150.0, segmentStart: 150) == 0.5)
    }

    @Test("the first leg landed on the keyframe inside its window, not on a frame before it or past the target")
    func firstLegWindow() {
        #expect(NativeAVPlayerHost.tolerantLegLanded(finished: true, actual: 150.0, target: 153.02, toleranceBefore: 3.02))
        #expect(NativeAVPlayerHost.tolerantLegLanded(finished: true, actual: 153.02, target: 153.02, toleranceBefore: 3.02))
        #expect(!NativeAVPlayerHost.tolerantLegLanded(finished: true, actual: 140.0, target: 153.02, toleranceBefore: 3.02))
        #expect(!NativeAVPlayerHost.tolerantLegLanded(finished: true, actual: 155.0, target: 153.02, toleranceBefore: 3.02))
        #expect(!NativeAVPlayerHost.tolerantLegLanded(finished: false, actual: 150.0, target: 153.02, toleranceBefore: 3.02))
    }

    @Test("the look-back the exact seek is kept for spans the 15 s AVPlayer reached back in the lab")
    func lookbackCoversTheMeasuredReach() {
        #expect(HLSVideoEngine.exactSeekLookbackSeconds >= 15)
    }

    @Test("givo-28: a slow link lands on the keyframe when the stretch to the target would hold over 1.5 s")
    func keyframeLandingOnSlowLinks() {
        // Apple TV field, 4K at ~1.3 MB/s: 4.99 s past the keyframe took 5.0 s to load.
        #expect(AetherEngine.keyframeLandingHold(gapSeconds: 4.99, wallSecondsPerMediaSecond: 1.0,
                                                 targetSegmentResident: false) == 4.99)
        // iPhone field, 1080p: 0.71 s past the keyframe loaded in 0.6 s; the exact seek stays.
        #expect(AetherEngine.keyframeLandingHold(gapSeconds: 0.71, wallSecondsPerMediaSecond: 0.85,
                                                 targetSegmentResident: false) == nil)
        #expect(AetherEngine.keyframeLandingHold(gapSeconds: 4.99, wallSecondsPerMediaSecond: 0.1,
                                                 targetSegmentResident: false) == nil)
        #expect(AetherEngine.keyframeLandingHold(gapSeconds: 4.99, wallSecondsPerMediaSecond: 1.0,
                                                 targetSegmentResident: true) == nil)
        #expect(AetherEngine.keyframeLandingHold(gapSeconds: 4.99, wallSecondsPerMediaSecond: nil,
                                                 targetSegmentResident: false) == nil)
    }

    @Test("givo-28: the march's wall seconds per media second come from cuts the plan measured")
    func meterMediaRate() {
        let meter = MarchPaceMeter()
        meter.readStarted(0, counts: false, now: 0)
        meter.segmentCut(0, mediaSeconds: 10, now: 12_000_000_000)
        #expect(meter.wallSecondsPerMediaSecond() == 1.2)
        meter.segmentQueued(1)
        meter.readStarted(1, counts: true, now: 0)
        meter.segmentCut(1, mediaSeconds: 10, now: 8_000_000_000)
        meter.segmentQueued(2)
        meter.readStarted(2, counts: true, now: 8_000_000_000)
        meter.segmentCut(2, mediaSeconds: nil, now: 20_000_000_000)
        #expect(meter.wallSecondsPerMediaSecond() == 0.8)
    }

    @Test("givo-28: the option is a tuning field a running session may be corrected on")
    func optionIsCorrectable() {
        var options = LoadOptions()
        options.seekLandsOnKeyframeWhenSlow = true
        #expect(SessionOptionCorrection.knownFields.contains("seekLandsOnKeyframeWhenSlow"))
        #expect(SessionOptionCorrection.refusedFields(from: LoadOptions(), to: options).isEmpty)
    }
}

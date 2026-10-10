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
}

import Testing
import AetherLibavutil
@testable import AetherEngine

/// givo-3: `LoadOptions.firstSegmentTargetSeconds` splits a keyframe-aligned plan's first segment so
/// AVPlayer can start on one GOP. Measured on a loopback origin at twice the media rate, 2 s GOPs:
/// playback began 1.7 s after load against 3.0 s with the 4 s first segment (progressive delivery
/// off), 0.75 s against 1.1 s on a fast origin. Every later boundary must stay the default plan's.
struct PlanFirstSegmentSplitTests {

    private let tb = AVRational(num: 1, den: 1000)

    private func plan(keyframes: [Int64], duration: Double) -> [HLSVideoEngine.Segment] {
        HLSVideoEngine.buildKeyframeSegmentPlan(keyframes: keyframes, videoTimeBase: tb,
                                                sourceDurationSeconds: duration)
    }

    @Test("the first segment is cut at the first keyframe at or after the target; the rest is unchanged")
    func splitsAtFirstKeyframePastTarget() {
        let keyframes: [Int64] = stride(from: 0, through: 20_000, by: 2_000).map { Int64($0) }
        let base = plan(keyframes: keyframes, duration: 22)
        let out = HLSVideoEngine.splitFirstSegment(base, keyframes: keyframes, videoTimeBase: tb, targetSeconds: 1)
        #expect(out.count == base.count + 1)
        #expect(out[0].startPts == 0 && out[0].endPts == 2_000)
        #expect(out[1].startPts == 2_000 && out[1].endPts == base[0].endPts)
        #expect(abs(out[0].durationSeconds + out[1].durationSeconds - base[0].durationSeconds) < 1e-9)
        #expect(Array(out.dropFirst(2)).map(\.startPts) == Array(base.dropFirst()).map(\.startPts),
                "every later boundary must be the default plan's")
    }

    @Test("no split when the GOP leaves no keyframe inside the default first segment")
    func longGOPIsUnchanged() {
        let keyframes: [Int64] = [0, 5_000, 10_000, 15_000]
        let base = plan(keyframes: keyframes, duration: 20)
        let out = HLSVideoEngine.splitFirstSegment(base, keyframes: keyframes, videoTimeBase: tb, targetSeconds: 2)
        #expect(out.map(\.startPts) == base.map(\.startPts))
    }

    @Test("targets outside one second up to the cut target are ignored")
    func outOfRangeTargetsAreIgnored() {
        let keyframes: [Int64] = stride(from: 0, through: 20_000, by: 500).map { Int64($0) }
        let base = plan(keyframes: keyframes, duration: 21)
        for target in [0.5, HLSVideoEngine.targetSegmentDuration, 10] {
            let out = HLSVideoEngine.splitFirstSegment(base, keyframes: keyframes, videoTimeBase: tb,
                                                       targetSeconds: target)
            #expect(out.map(\.startPts) == base.map(\.startPts), "target \(target)")
        }
    }

    @Test("a remainder shorter than the minimum segment is not split off")
    func shortRemainderIsNotSplit() {
        // The default first segment ends at 4.0; a keyframe at 3.5 would leave 0.5 s behind it.
        let keyframes: [Int64] = [0, 3_500, 4_000, 8_000, 12_000]
        let base = plan(keyframes: keyframes, duration: 14)
        let out = HLSVideoEngine.splitFirstSegment(base, keyframes: keyframes, videoTimeBase: tb, targetSeconds: 3)
        #expect(out.map(\.startPts) == base.map(\.startPts))
    }
}

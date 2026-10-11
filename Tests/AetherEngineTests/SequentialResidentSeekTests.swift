import Testing
@testable import AetherEngine

/// givo-15: a sequential origin keeps every segment it cut, so a seek inside what the session already
/// read is served from the cache; anything past it (or in a gap) is still refused.
struct SequentialResidentSeekTests {

    @Test("a target inside a produced span, with half a second ahead of it, is resident")
    func insideAProducedSpan() {
        let resident: [ClosedRange<Double>] = [0...40, 60...80]
        #expect(AetherEngine.sequentialSeekIsResident(target: 12, resident: resident))
        #expect(AetherEngine.sequentialSeekIsResident(target: 0, resident: resident))
        #expect(AetherEngine.sequentialSeekIsResident(target: 79.5, resident: resident))
    }

    @Test("past the read frontier, in a gap, at the very edge or not finite: refused as before")
    func outsideIsRefused() {
        let resident: [ClosedRange<Double>] = [0...40, 60...80]
        #expect(!AetherEngine.sequentialSeekIsResident(target: 39.8, resident: resident))
        #expect(!AetherEngine.sequentialSeekIsResident(target: 50, resident: resident))
        #expect(!AetherEngine.sequentialSeekIsResident(target: 120, resident: resident))
        #expect(!AetherEngine.sequentialSeekIsResident(target: .nan, resident: resident))
        #expect(!AetherEngine.sequentialSeekIsResident(target: 5, resident: []))
    }

    /// givo-34: AVPlayer reads the growing playlist as a live one and seeks only inside the seekable
    /// range of its last reload; a cached target past it never landed (a fresh mount on a fast origin
    /// had 199 s cached and an item that could seek to 2 s).
    @Test("cached is not enough: the target has to be inside the item's seekable range")
    func itemReach() {
        #expect(AetherEngine.sequentialSeekIsWithinItemReach(target: 2, reach: 0...8.3))
        #expect(AetherEngine.sequentialSeekIsWithinItemReach(target: 0, reach: 0...8.3))
        #expect(!AetherEngine.sequentialSeekIsWithinItemReach(target: 199, reach: 0...8.3))
        #expect(!AetherEngine.sequentialSeekIsWithinItemReach(target: 8.1, reach: 0...8.3))
        #expect(!AetherEngine.sequentialSeekIsWithinItemReach(target: 1, reach: 0...0))
        #expect(!AetherEngine.sequentialSeekIsWithinItemReach(target: .nan, reach: 0...8.3))
    }
}

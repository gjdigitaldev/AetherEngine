import Testing
import Foundation
@testable import AetherEngine

/// givo-22: `progressiveSegmentDeliveryAfterSeek` makes only a seek's landing segment progressive. The
/// field: a Trex seek's landing segment (one ~10 s keyframe interval, 9.6 MB at ~1.3 MB/s) reached
/// AVPlayer after ~10 s; served as it is cut, AVPlayer starts at the first fragment. Opens and steady
/// play keep `progressiveSegmentDelivery` (D107).
struct LandingSegmentProgressiveTests {

    @Test("the option is a tuning field a running session may be corrected on")
    func optionIsCorrectable() {
        var options = LoadOptions()
        options.progressiveSegmentDeliveryAfterSeek = true
        #expect(SessionOptionCorrection.knownFields.contains("progressiveSegmentDeliveryAfterSeek"))
        #expect(SessionOptionCorrection.refusedFields(from: LoadOptions(), to: options).isEmpty)
    }

    @Test("givo-27: the landing and the segment after it are progressive; the march past them is whole again")
    func landingAndNextAreProgressive() {
        #expect(HLSSegmentProducer.isLandingSegment(15, landing: 15))
        #expect(HLSSegmentProducer.isLandingSegment(16, landing: 15))
        #expect(!HLSSegmentProducer.isLandingSegment(17, landing: 15))
        #expect(!HLSSegmentProducer.isLandingSegment(14, landing: 15))
    }
}

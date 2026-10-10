import Foundation

/// givo-24: the VOD march's own pace, measured where the pump cuts its segments.
///
/// A forward seek to a segment the march has not reached used to wait for the march whenever the
/// target sat within `forwardWaitWindow` segments of its front. On a link that delivers a title at
/// about its own bitrate (a portal's media front: ~10 s of 4K per ~8 s), that is the march cutting
/// every segment in between, one whole keyframe interval at a time, before it even starts the one
/// asked for. A restart starts it after a dial. This meter is what tells the two apart.
///
/// One per VOD session, shared by every producer the session builds: the link a march reads
/// through outlives a restart, so the pace measured before a seek is the pace that decides it.
/// A sample is the wall time from the moment the pump starts reading a segment (after any
/// backpressure park) to its cut. The first segment after a restart is not a sample: it also
/// carries the dial and the demuxer seek.
final class MarchPaceMeter: @unchecked Sendable {
    struct Reading: Equatable {
        /// The segment the pump is reading, or will read once its park releases.
        let inProgressIndex: Int
        /// How long the pump has been reading that segment; 0 while it is parked before it.
        let inProgressElapsedSeconds: Double
        /// Median wall time per cut segment over the recent samples.
        let secondsPerSegment: Double
    }

    static let sampleCapacity = 4
    /// One sample is enough: a seek right after the start (skipping an intro) has only one, and a
    /// sample is a real segment read at the link's pace.
    static let minimumSamples = 1

    private let lock = NSLock()
    private var samples: [Double] = []
    /// givo-28: wall seconds per media second of the same cuts, where the plan knew the cut's length.
    private var mediaRates: [Double] = []
    /// givo-28: the same figure from a producer's first segment, which also carries the dial and the
    /// seek, so it reads the link as slower than it is; used only until a marched cut is measured (a
    /// seek right after the open has nothing else).
    private var provisionalMediaRate: Double?
    private var inProgressIndex = Int.min
    private var readStartedAt: UInt64?
    private var currentCounts = false

    /// The pump moved on to `index` and may park before it reads any of it.
    func segmentQueued(_ index: Int) {
        lock.lock(); defer { lock.unlock() }
        inProgressIndex = index
        readStartedAt = nil
        currentCounts = false
    }

    /// The pump started reading `index`. `counts` is false for a producer's first segment.
    func readStarted(_ index: Int, counts: Bool, now: UInt64 = DispatchTime.now().uptimeNanoseconds) {
        lock.lock(); defer { lock.unlock() }
        inProgressIndex = index
        readStartedAt = now
        currentCounts = counts
    }

    /// The pump cut `index`, `mediaSeconds` of plan long when the plan knows it.
    func segmentCut(_ index: Int, mediaSeconds: Double? = nil, now: UInt64 = DispatchTime.now().uptimeNanoseconds) {
        lock.lock(); defer { lock.unlock() }
        guard index == inProgressIndex, let started = readStartedAt, now > started else { return }
        let wall = Double(now - started) / 1_000_000_000
        guard currentCounts else {
            if let mediaSeconds, mediaSeconds.isFinite, mediaSeconds >= 0.5 { provisionalMediaRate = wall / mediaSeconds }
            return
        }
        samples.append(wall)
        if samples.count > Self.sampleCapacity { samples.removeFirst(samples.count - Self.sampleCapacity) }
        if let mediaSeconds, mediaSeconds.isFinite, mediaSeconds >= 0.5 {
            mediaRates.append(wall / mediaSeconds)
            if mediaRates.count > Self.sampleCapacity { mediaRates.removeFirst(mediaRates.count - Self.sampleCapacity) }
        }
        currentCounts = false
    }

    /// givo-28: the march's wall seconds per media second (median of the recent cuts), nil before one.
    func wallSecondsPerMediaSecond() -> Double? {
        lock.lock(); defer { lock.unlock() }
        return Self.median(mediaRates) ?? provisionalMediaRate
    }

    private static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count % 2 == 0 ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
    }

    func reading(now: UInt64 = DispatchTime.now().uptimeNanoseconds) -> Reading? {
        lock.lock(); defer { lock.unlock() }
        guard samples.count >= Self.minimumSamples, inProgressIndex != .min else { return nil }
        let sorted = samples.sorted()
        let mid = sorted.count / 2
        let median = sorted.count % 2 == 0 ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
        let elapsed = readStartedAt.map { now > $0 ? Double(now - $0) / 1_000_000_000 : 0 } ?? 0
        return Reading(inProgressIndex: inProgressIndex, inProgressElapsedSeconds: elapsed,
                       secondsPerSegment: median)
    }
}

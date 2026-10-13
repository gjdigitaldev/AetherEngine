import Foundation
import AVFoundation
import CoreMedia
import Testing
import AetherLibavcodec
import AetherLibavutil
@testable import AetherEngine

private final class CountingProcessor: AudioSampleProcessing, @unchecked Sendable {
    var prepareCount = 0
    var preparedSampleRate: Double = 0
    var preparedChannels = 0
    var preparedInterleaved = false
    var preparedLayoutTag: UInt32 = 0
    var processCount = 0
    var lastFrameCount = 0
    var lastBufferCount = 0
    var lastBufferChannels: UInt32 = 0
    var lastByteSize: UInt32 = 0
    var totalFrames = 0
    var firstSampleSeen: Float?
    var resetCount = 0   // GiVo R2596-r2
    /// GiVo R2596-r2: runs inside `prepare`, to prove what the caller holds while it does.
    var duringPrepare: (() -> Void)?

    func prepare(sampleRate: Double, channelCount: Int, isInterleaved: Bool, layoutTag: UInt32) {
        prepareCount += 1
        duringPrepare?()
        preparedSampleRate = sampleRate
        preparedChannels = channelCount
        preparedInterleaved = isInterleaved
        preparedLayoutTag = layoutTag
    }

    func reset() { resetCount += 1 }   // GiVo R2596-r2

    func process(_ bufferList: UnsafeMutableAudioBufferListPointer, frameCount: Int) {
        processCount += 1
        lastFrameCount = frameCount
        lastBufferCount = bufferList.count
        lastBufferChannels = bufferList.first?.mNumberChannels ?? 0
        lastByteSize = bufferList.first?.mDataByteSize ?? 0
        totalFrames += frameCount
        if firstSampleSeen == nil, let data = bufferList.first?.mData {
            firstSampleSeen = data.load(as: Float.self)
        }
        // In place: halve every sample so the test can read the effect back out of the buffer.
        for buffer in bufferList {
            guard let data = buffer.mData else { continue }
            let samples = data.bindMemory(to: Float.self, capacity: Int(buffer.mDataByteSize) / 4)
            for i in 0..<(Int(buffer.mDataByteSize) / 4) { samples[i] *= 0.5 }
        }
    }
}

/// GiVo R2596: the software route's audio stage runs in place inside `AudioOutput.enqueue`, prepared once per
/// format, over the decoder's interleaved Float32 samples.
@Suite("AudioOutput sample processing stage (GiVo R2596)")
struct AudioSampleProcessingTests {

    /// Interleaved Float32 stereo, every sample 1.0, stamped with the stereo layout tag the decoder writes.
    private func makeStereoBuffer(pts: Double, frames: Int, sampleRate: Int32 = 48000) -> CMSampleBuffer? {
        let channels = 2
        var asbd = AudioStreamBasicDescription(
            mSampleRate: Float64(sampleRate),
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(channels * 4), mFramesPerPacket: 1, mBytesPerFrame: UInt32(channels * 4),
            mChannelsPerFrame: UInt32(channels), mBitsPerChannel: 32, mReserved: 0)
        var layout = AudioChannelLayout(mChannelLayoutTag: kAudioChannelLayoutTag_Stereo,
                                        mChannelBitmap: [], mNumberChannelDescriptions: 0,
                                        mChannelDescriptions: AudioChannelDescription())
        var format: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault,
                                             asbd: &asbd,
                                             layoutSize: MemoryLayout<AudioChannelLayout>.size, layout: &layout,
                                             magicCookieSize: 0, magicCookie: nil,
                                             extensions: nil,
                                             formatDescriptionOut: &format) == noErr,
              let format else { return nil }
        let byteCount = frames * channels * 4
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault,
                                                 memoryBlock: nil,
                                                 blockLength: byteCount,
                                                 blockAllocator: kCFAllocatorDefault,
                                                 customBlockSource: nil,
                                                 offsetToData: 0,
                                                 dataLength: byteCount,
                                                 flags: kCMBlockBufferAssureMemoryNowFlag,
                                                 blockBufferOut: &block) == noErr,
              let block else { return nil }
        let ones = [Float](repeating: 1.0, count: frames * channels)
        guard ones.withUnsafeBytes({ bytes in
            CMBlockBufferReplaceDataBytes(with: bytes.baseAddress!, blockBuffer: block,
                                          offsetIntoDestination: 0, dataLength: byteCount)
        }) == kCMBlockBufferNoErr else { return nil }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: sampleRate),
                                        presentationTimeStamp: CMTime(seconds: pts, preferredTimescale: sampleRate),
                                        decodeTimeStamp: .invalid)
        var out: CMSampleBuffer?
        guard CMSampleBufferCreate(allocator: kCFAllocatorDefault,
                                   dataBuffer: block, dataReady: true,
                                   makeDataReadyCallback: nil, refcon: nil,
                                   formatDescription: format,
                                   sampleCount: CMItemCount(frames),
                                   sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                                   sampleSizeEntryCount: 0, sampleSizeArray: nil,
                                   sampleBufferOut: &out) == noErr else { return nil }
        return out
    }

    private func firstSample(of buffer: CMSampleBuffer) -> Float? {
        guard let block = CMSampleBufferGetDataBuffer(buffer) else { return nil }
        var value: Float = 0
        guard CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: 4, destination: &value)
                == kCMBlockBufferNoErr else { return nil }
        return value
    }

    @Test("prepare runs once per format; process sees every buffer's frames and channels, in place")
    func stageIsPreparedOnceAndProcessesInPlace() throws {
        let processor = CountingProcessor()
        let output = AudioOutput(processor: processor)
        let first = try #require(makeStereoBuffer(pts: 10, frames: 1024))
        let second = try #require(makeStereoBuffer(pts: 10 + 1024.0 / 48000, frames: 512))

        #expect(output.enqueue(sampleBuffer: first, ifEpoch: output.epoch))
        #expect(output.enqueue(sampleBuffer: second, ifEpoch: output.epoch))

        #expect(processor.prepareCount == 1)
        #expect(processor.preparedSampleRate == 48000)
        #expect(processor.preparedChannels == 2)
        #expect(processor.preparedInterleaved)
        #expect(processor.preparedLayoutTag == kAudioChannelLayoutTag_Stereo)
        #expect(processor.processCount == 2)
        #expect(processor.lastFrameCount == 512)
        #expect(processor.lastBufferCount == 1)
        #expect(processor.lastBufferChannels == 2)
        #expect(processor.lastByteSize == 512 * 2 * 4)
        #expect(firstSample(of: first) == 0.5)
        #expect(firstSample(of: second) == 0.5)
    }

    @Test("a buffer refused by the flush epoch never reaches the stage")
    func refusedBufferIsNotProcessed() throws {
        let processor = CountingProcessor()
        let output = AudioOutput(processor: processor)
        let buffer = try #require(makeStereoBuffer(pts: 10, frames: 1024))
        let stale = output.epoch
        output.flush()

        #expect(output.enqueue(sampleBuffer: buffer, ifEpoch: stale) == false)
        #expect(processor.prepareCount == 0)
        #expect(processor.processCount == 0)
        #expect(firstSample(of: buffer) == 1.0)
    }

    @Test("GiVo R2596-r2: a flush resets the stage (what it holds belongs to the flushed audio)")
    func flushResetsTheStage() throws {
        let processor = CountingProcessor()
        let output = AudioOutput(processor: processor)
        let buffer = try #require(makeStereoBuffer(pts: 10, frames: 1024))
        #expect(output.enqueue(sampleBuffer: buffer, ifEpoch: output.epoch))
        #expect(processor.resetCount == 0)
        output.flush()
        #expect(processor.resetCount == 1)
    }

    @Test("GiVo R2596-r2: prepare runs outside the output's lock (another thread takes it meanwhile)")
    func prepareRunsOutsideTheLock() throws {
        let processor = CountingProcessor()
        let output = AudioOutput(processor: processor)
        let lockWasFree = LockedFlag()
        processor.duringPrepare = {
            // `epoch` takes the output's lock. Held by the enqueue that is preparing, this read would wait out
            // the timeout instead of signalling.
            let done = DispatchSemaphore(value: 0)
            DispatchQueue.global().async {
                _ = output.epoch
                done.signal()
            }
            lockWasFree.set(done.wait(timeout: .now() + 2) == .success)
        }
        let buffer = try #require(makeStereoBuffer(pts: 10, frames: 1024))
        #expect(output.enqueue(sampleBuffer: buffer, ifEpoch: output.epoch))
        #expect(processor.prepareCount == 1)
        #expect(processor.processCount == 1)
        #expect(lockWasFree.value)
    }
}

/// GiVo R2596-r2: a one-shot flag the prepare probe sets from inside the stage.
private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = false
    func set(_ v: Bool) { lock.withLock { _value = v } }
    var value: Bool { lock.withLock { _value } }
}

/// GiVo R2596: the loopback route's audio stage runs inside `AudioBridge`, between the resampler and the encoder,
/// in the layout the resampler produces: interleaved for the FLAC encoder's integer intermediate (seen through a
/// Float32 view), planar Float32 for the E-AC-3 encoder.
@Suite("AudioBridge sample processing stage (GiVo R2596)")
struct AudioBridgeSampleProcessingTests {

    private func makePCMCodecpar(channels: Int32) -> UnsafeMutablePointer<AVCodecParameters> {
        let par = avcodec_parameters_alloc()!
        par.pointee.codec_type = AVMEDIA_TYPE_AUDIO
        par.pointee.codec_id = AV_CODEC_ID_PCM_S16LE
        par.pointee.sample_rate = 48_000
        par.pointee.format = AV_SAMPLE_FMT_S16.rawValue
        par.pointee.bits_per_coded_sample = 16
        par.pointee.block_align = channels * 2
        av_channel_layout_default(&par.pointee.ch_layout, channels)
        return par
    }

    /// `frames` frames of interleaved S16, every sample 16384 (0.5 full scale).
    private func makePCMPacket(frames: Int, channels: Int, pts: Int64) -> UnsafeMutablePointer<AVPacket>? {
        let size = frames * channels * 2
        guard let pkt = trackedPacketAlloc(), av_new_packet(pkt, Int32(size)) >= 0 else { return nil }
        pkt.pointee.data.withMemoryRebound(to: Int16.self, capacity: frames * channels) { samples in
            for i in 0..<(frames * channels) { samples[i] = 16_384 }
        }
        pkt.pointee.pts = pts
        pkt.pointee.dts = pts
        pkt.pointee.duration = Int64(frames)
        return pkt
    }

    private func feed(_ bridge: AudioBridge, packets: Int, frames: Int, channels: Int) throws {
        for n in 0..<packets {
            guard let pkt = makePCMPacket(frames: frames, channels: channels, pts: Int64(n * frames)) else { return }
            var out = try bridge.feed(packet: pkt)
            var input: UnsafeMutablePointer<AVPacket>? = pkt
            trackedPacketFree(&input)
            for i in out.indices {
                var p: UnsafeMutablePointer<AVPacket>? = out[i]
                trackedPacketFree(&p)
            }
            out.removeAll()
        }
    }

    @Test("FLAC: prepared once as interleaved, every resampled frame staged, integers seen at their Float32 scale")
    func flacIntermediateIsStagedInterleaved() throws {
        let processor = CountingProcessor()
        var par: UnsafeMutablePointer<AVCodecParameters>? = makePCMCodecpar(channels: 2)
        defer { avcodec_parameters_free(&par) }
        let bridge = try AudioBridge(srcCodecpar: par!, srcTimeBase: AVRational(num: 1, den: 48_000),
                                     mode: .lossless, processor: processor)
        defer { bridge.close() }
        #expect(bridge.outputCodecID == AV_CODEC_ID_FLAC)

        try feed(bridge, packets: 4, frames: 1024, channels: 2)

        #expect(processor.prepareCount == 1)
        #expect(processor.preparedSampleRate == 48_000)
        #expect(processor.preparedChannels == 2)
        #expect(processor.preparedInterleaved)
        #expect(processor.preparedLayoutTag == kAudioChannelLayoutTag_Stereo)
        #expect(processor.totalFrames == 4 * 1024)
        #expect(processor.lastBufferCount == 1)
        #expect(processor.lastBufferChannels == 2)
        #expect(processor.firstSampleSeen == 0.5)
    }

    @Test("E-AC-3: prepared once as planar, one Float32 buffer per channel")
    func eac3IntermediateIsStagedPlanar() throws {
        let processor = CountingProcessor()
        var par: UnsafeMutablePointer<AVCodecParameters>? = makePCMCodecpar(channels: 6)
        defer { avcodec_parameters_free(&par) }
        let bridge = try AudioBridge(srcCodecpar: par!, srcTimeBase: AVRational(num: 1, den: 48_000),
                                     mode: .surroundCompat, processor: processor)
        defer { bridge.close() }
        #expect(bridge.outputCodecID == AV_CODEC_ID_EAC3)

        try feed(bridge, packets: 4, frames: 1536, channels: 6)

        #expect(processor.prepareCount == 1)
        #expect(processor.preparedChannels == 6)
        #expect(processor.preparedInterleaved == false)
        #expect(processor.preparedLayoutTag == kAudioChannelLayoutTag_MPEG_5_1_A)
        #expect(processor.totalFrames == 4 * 1536)
        #expect(processor.lastBufferCount == 6)
        #expect(processor.lastBufferChannels == 1)
        #expect(processor.firstSampleSeen == 0.5)
    }

    @Test("GiVo R2596-r2: a stage-forced bridge keeps a FLAC / ALAC 7.1 track whole; E-AC-3 / AAC / Opus fold to 5.1")
    func stageBridgeEncoderTable() {
        func pick(_ mode: AudioBridge.Mode, _ codec: AVCodecID, _ channels: Int32) -> AVCodecID {
            AudioBridge.stageBridgeEncoder(for: mode, sourceCodec: codec, sourceChannels: channels)
        }
        #expect(pick(.surroundCompat, AV_CODEC_ID_FLAC, 8) == AV_CODEC_ID_FLAC)
        #expect(pick(.surroundCompat, AV_CODEC_ID_ALAC, 7) == AV_CODEC_ID_FLAC)
        #expect(pick(.surroundCompat, AV_CODEC_ID_EAC3, 8) == AV_CODEC_ID_EAC3)
        #expect(pick(.surroundCompat, AV_CODEC_ID_AAC, 8) == AV_CODEC_ID_EAC3)
        #expect(pick(.surroundCompat, AV_CODEC_ID_OPUS, 8) == AV_CODEC_ID_EAC3)
        #expect(pick(.surroundCompat, AV_CODEC_ID_FLAC, 6) == AV_CODEC_ID_EAC3)
        #expect(pick(.surroundCompat, AV_CODEC_ID_FLAC, 2) == AV_CODEC_ID_FLAC)
        #expect(pick(.surroundCompat, AV_CODEC_ID_AAC, 2) == AV_CODEC_ID_FLAC)
        #expect(pick(.lossless, AV_CODEC_ID_EAC3, 8) == AV_CODEC_ID_FLAC)
        // The mode's own resolution is unchanged for a bridge the source needs anyway.
        #expect(AudioBridge.bridgeEncoder(for: .surroundCompat, sourceChannels: 8) == AV_CODEC_ID_EAC3)
    }

    @Test("no processor: the bridge is the plain transcode it was")
    func noProcessorIsAPlainTranscode() throws {
        var par: UnsafeMutablePointer<AVCodecParameters>? = makePCMCodecpar(channels: 2)
        defer { avcodec_parameters_free(&par) }
        let bridge = try AudioBridge(srcCodecpar: par!, srcTimeBase: AVRational(num: 1, den: 48_000), mode: .lossless)
        defer { bridge.close() }
        try feed(bridge, packets: 2, frames: 1024, channels: 2)
        #expect(bridge.outputCodecID == AV_CODEC_ID_FLAC)
    }
}

/// GiVo R2596: a title that plays with its original audio must not go silent because the audio stage forced it
/// through the bridge. A forced bridge that fails hands the session to the engine, which rebuilds it ONCE with
/// the stage off and latches that for the title.
@Suite("Forced-bridge fallback (GiVo R2596)")
struct ForcedAudioBridgeFallbackTests {

    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _reasons: [String] = []
        private var _surfaced: [PlaybackErrorKind] = []
        func reason(_ r: String) { lock.withLock { _reasons.append(r) } }
        func surfaced(_ k: PlaybackErrorKind) { lock.withLock { _surfaced.append(k) } }
        var reasons: [String] { lock.withLock { _reasons } }
        var surfaced: [PlaybackErrorKind] { lock.withLock { _surfaced } }
    }

    private func makeSession(forced: Bool, recorder: Recorder) -> HLSVideoEngine {
        let session = HLSVideoEngine(url: URL(fileURLWithPath: "/nonexistent/r2596-forced.mkv"), dvModeAvailable: false)
        session.audioBridgeForcedForStage = forced
        session.onForcedAudioBridgeFailure = { recorder.reason($0) }
        session.onVODSourceFailed = { _, _, kind in recorder.surfaced(kind) }
        return session
    }

    @Test("a forced bridge that decodes nothing reaches the engine once and surfaces nothing")
    func forcedBridgeFailureIsHandedBackOnce() {
        let recorder = Recorder()
        let session = makeSession(forced: true, recorder: recorder)

        session.handleBridgeDecodedNothing(streamIndex: 1, summary: "0 frames from 40 packets")
        session.surfaceVODSourceFailure(FFmpegErr.einval, "Audio could not be transcoded for playback",
                                        kind: .audioBridgeProducedNoOutput)

        #expect(recorder.reasons.count == 1)
        #expect(recorder.surfaced.isEmpty)
    }

    @Test("a bridge the source needs anyway still surfaces as before")
    func requiredBridgeFailureStillSurfaces() {
        let recorder = Recorder()
        let session = makeSession(forced: false, recorder: recorder)

        session.handleBridgeDecodedNothing(streamIndex: 1, summary: "0 frames from 40 packets")

        #expect(recorder.reasons.isEmpty)
        #expect(recorder.surfaced == [.audioBridgeProducedNoOutput])
    }

    @MainActor
    @Test("one rebuild with the stage off, no second attempt, and the stage stays off for the title")
    func engineRebuildsOnceAndLatches() throws {
        let engine = try AetherEngine()
        var options = LoadOptions()
        options.audioSampleProcessing = true
        engine.setLoadedOptionsForTesting(options)
        var rebuilds: [LoadOptions] = []
        engine.audioSampleProcessingDropRebuildForTesting = { change in
            var applied = engine.loadedOptions
            change(&applied)
            rebuilds.append(applied)
        }

        engine.dropAudioSampleProcessingForSession(reason: "the bridge decoded nothing")
        #expect(rebuilds.count == 1)
        #expect(rebuilds.first?.audioSampleProcessing == false)
        #expect(engine.audioSampleProcessingUnavailableForSession)

        // The rebuild lands on the corrected options; the rebuilt session's own forced bridge cannot exist,
        // and a late report from the old one starts nothing.
        engine.setLoadedOptionsForTesting(rebuilds[0])
        engine.dropAudioSampleProcessingForSession(reason: "a late report from the old session")
        #expect(rebuilds.count == 1)

        engine.setAudioSampleProcessingEnabled(true)
        #expect(engine.audioSampleProcessingEnabled == false)
    }

    @MainActor
    @Test("GiVo R2596-r2: the drop turns the stage off at once and tells the host once")
    func dropTellsTheHostOnce() throws {
        let engine = try AetherEngine()
        var options = LoadOptions()
        options.audioSampleProcessing = true
        engine.setLoadedOptionsForTesting(options)
        engine.audioSampleProcessingDropRebuildForTesting = { _ in }
        var reports: [(String, Bool)] = []
        engine.onAudioSampleProcessingDropped = { reason, refused in reports.append((reason, refused)) }

        engine.dropAudioSampleProcessingForSession(reason: "the bridge decoded nothing")
        #expect(engine.audioSampleProcessingEnabled == false)   // a superseding reload cannot cut with it on
        engine.dropAudioSampleProcessingForSession(reason: "again")
        #expect(reports.count == 1)
        #expect(reports.first?.0 == "the bridge decoded nothing")
        #expect(reports.first?.1 == false)
    }

    @Test("the session's own rebuilds keep the drop; a host load starts clean")
    func dropAcrossLoad() {
        #expect(AetherEngine.audioSampleProcessingDropAcrossLoad(true, sessionPreservingReload: true))
        #expect(AetherEngine.audioSampleProcessingDropAcrossLoad(true, sessionPreservingReload: false) == false)
        #expect(AetherEngine.audioSampleProcessingDropAcrossLoad(false, sessionPreservingReload: true) == false)
    }
}

/// GiVo R2596-r2: a change of the stage's own settings is baked into the loopback segments as they are cut, so it
/// re-cuts like a toggle; the re-anchor latch counts it; a load that started cutting before a change re-cuts once
/// it settles.
@Suite("Audio stage settings changes (GiVo R2596-r2)")
struct AudioStageParameterChangeTests {

    @Test("the route table")
    func routeTable() {
        func action(on: Bool = true, factory: Bool = true, dropped: Bool = false,
                    state: PlaybackState = .playing, route: VideoRoute, avPlayerAudio: Bool = false)
            -> AetherEngine.AudioStageParameterChange {
            AetherEngine.audioStageParameterChange(stageOn: on, factoryInstalled: factory, droppedForTitle: dropped,
                                                   state: state, route: route, audioAVPlayerActive: avPlayerAudio)
        }
        #expect(action(route: .loopback) == .recut)
        #expect(action(state: .paused, route: .loopback) == .recut)
        #expect(action(on: false, route: .loopback) == .noStage)
        #expect(action(dropped: true, route: .loopback) == .noStage)
        #expect(action(factory: false, route: .loopback) == .noStage)
        #expect(action(state: .loading, route: .loopback) == .loadInFlight)
        #expect(action(route: .software) == .nextBuffer)
        #expect(action(on: false, route: .software) == .nextBuffer)
        #expect(action(route: .audio) == .nextBuffer)
        #expect(action(route: .audio, avPlayerAudio: true) == .notEngineAudio)
        #expect(action(route: .remoteBypass) == .notEngineAudio)
        #expect(action(route: .none) == .notEngineAudio)
    }

    @Test("the re-anchor latch owes another pass for a settings change only while the stage is on")
    func latchCountsSettings() {
        func owes(delay: (Double, Double) = (0.1, 0.1), on: (Bool, Bool) = (true, true),
                  generation: (UInt64, UInt64) = (3, 3)) -> Bool {
            AetherEngine.audioReanchorOwesAnotherPass(deliveredDelay: delay.0, delay: delay.1,
                                                      deliveredProcessing: on.0, processing: on.1,
                                                      deliveredStageGeneration: generation.0,
                                                      stageGeneration: generation.1)
        }
        #expect(owes() == false)
        #expect(owes(generation: (3, 4)))
        #expect(owes(on: (false, false), generation: (3, 4)) == false)
        #expect(owes(on: (true, false)))
        #expect(owes(delay: (0.1, 0.2)))
    }

    @Test("a load whose cut started before a change re-cuts once it settles")
    func missedByLoadRule() {
        #expect(AetherEngine.audioStageMissedByLoad(routedOn: false, nowOn: true, routedGeneration: 1, nowGeneration: 1))
        #expect(AetherEngine.audioStageMissedByLoad(routedOn: true, nowOn: false, routedGeneration: 1, nowGeneration: 1))
        #expect(AetherEngine.audioStageMissedByLoad(routedOn: true, nowOn: true, routedGeneration: 1, nowGeneration: 2))
        #expect(AetherEngine.audioStageMissedByLoad(routedOn: false, nowOn: false, routedGeneration: 1, nowGeneration: 2) == false)
        #expect(AetherEngine.audioStageMissedByLoad(routedOn: true, nowOn: true, routedGeneration: 2, nowGeneration: 2) == false)
    }

    @MainActor
    @Test("on a loopback session a settings change re-cuts; during a load it waits for the settle, then re-cuts once")
    func engineRecutsForSettings() throws {
        let previousFactory = AudioSampleProcessingRegistry.factory
        AudioSampleProcessingRegistry.factory = { nil }
        defer { AudioSampleProcessingRegistry.factory = previousFactory }

        let engine = try AetherEngine()
        var options = LoadOptions()
        options.audioSampleProcessing = true
        engine.setLoadedOptionsForTesting(options)
        var recuts: [String] = []
        engine.audioStageRecutForTesting = { recuts.append($0) }

        engine.videoRoute = .loopback
        engine.state = .playing
        let generation = engine.audioSampleProcessingParameterGeneration
        #expect(engine.audioSampleProcessingParametersDidChange() == .recut)
        #expect(recuts == ["settings"])
        #expect(engine.audioSampleProcessingParameterGeneration == generation + 1)

        // A load in flight: the change is counted, not cut; the settle compares and re-cuts once.
        let session = HLSVideoEngine(url: URL(fileURLWithPath: "/nonexistent/r2596-r2.mkv"), dvModeAvailable: false)
        session.audioSampleProcessing = true
        engine.nativeVideoSession = session
        engine.state = .loading
        engine.audioSampleProcessingGenerationAtSessionStart = engine.audioSampleProcessingParameterGeneration
        #expect(engine.audioSampleProcessingParametersDidChange() == .loadInFlight)
        #expect(recuts.count == 1)
        engine.state = .playing
        #expect(recuts == ["settings", "missed by the load"])

        // A settle with nothing missed cuts nothing.
        engine.state = .loading
        engine.audioSampleProcessingGenerationAtSessionStart = engine.audioSampleProcessingParameterGeneration
        engine.state = .paused
        #expect(recuts.count == 2)
        engine.nativeVideoSession = nil
    }
}

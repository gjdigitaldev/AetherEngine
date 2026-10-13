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

    func prepare(sampleRate: Double, channelCount: Int, isInterleaved: Bool, layoutTag: UInt32) {
        prepareCount += 1
        preparedSampleRate = sampleRate
        preparedChannels = channelCount
        preparedInterleaved = isInterleaved
        preparedLayoutTag = layoutTag
    }

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

    @Test("the session's own rebuilds keep the drop; a host load starts clean")
    func dropAcrossLoad() {
        #expect(AetherEngine.audioSampleProcessingDropAcrossLoad(true, sessionPreservingReload: true))
        #expect(AetherEngine.audioSampleProcessingDropAcrossLoad(true, sessionPreservingReload: false) == false)
        #expect(AetherEngine.audioSampleProcessingDropAcrossLoad(false, sessionPreservingReload: true) == false)
    }
}

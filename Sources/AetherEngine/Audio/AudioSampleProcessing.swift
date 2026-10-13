import AudioToolbox
import CoreAudio   // UnsafeMutableAudioBufferListPointer: AudioToolbox alone does not surface it on iOS / tvOS
import Foundation

/// GiVo R2596 — a host-supplied real-time audio stage. `prepare` runs OFF the real-time thread whenever a
/// session's output format is (re)established and may be called again; `process` runs on the thread that
/// owns the samples (the renderer feed, or the bridge's producer): in place, no allocation, no blocking lock.
///
/// Where it runs:
/// - `.software` / decoded `.audio` (FFmpeg decode into `AVSampleBufferAudioRenderer`): every decoded buffer, in
///   place, inside `AudioOutput.enqueue`, whenever a factory is installed. The stage sees interleaved Float32.
/// - `.loopback` (HLS-fMP4 to AVPlayer): inside `AudioBridge`, between the resampler and the encoder, while
///   `LoadOptions.audioSampleProcessing` is on; that switch routes every source through the bridge. The stage
///   sees planar Float32 (E-AC-3 encoder) or interleaved Float32 (FLAC encoder). See `AudioBridge` for what the
///   re-encode costs while it is on.
/// - `.remoteBypass`: never. AVPlayer owns that media, and it ignores an `AVAudioMix` on HLS anyway (an HLS
///   asset vends no `AVAssetTrack` for one to bind to), so the engine never holds that audio.   // GiVo R2596-r2
public protocol AudioSampleProcessing: AnyObject {
    func prepare(sampleRate: Double, channelCount: Int, isInterleaved: Bool, layoutTag: UInt32)
    func process(_ bufferList: UnsafeMutableAudioBufferListPointer, frameCount: Int)
    /// GiVo R2596-r2 — the output dropped what it had queued (`AudioOutput.flush`, i.e. a seek): whatever the stage
    /// still holds belongs to that dropped audio. Never called from inside `process`.
    func reset()
}

/// GiVo R2596-r2 — a stage with nothing queued ignores it.
public extension AudioSampleProcessing {
    func reset() {}
}

public enum AudioSampleProcessingRegistry {
    /// One processor per audio output / native item; nil = no stage.
    nonisolated(unsafe) public static var factory: (@Sendable () -> AudioSampleProcessing?)?
}

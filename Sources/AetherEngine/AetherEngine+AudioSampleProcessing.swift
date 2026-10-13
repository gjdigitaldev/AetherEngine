import Foundation

/// GiVo R2596: the switch for the host's audio stage (`AudioSampleProcessingRegistry`), per route.
///
/// - `.loopback`: the stage needs PCM, and on this route the engine holds PCM only inside `AudioBridge`. On,
///   every source is decoded, staged and re-encoded in `audioBridgeMode` instead of stream-copied, so an E-AC-3
///   JOC (Atmos) source loses its object metadata and no source reaches the renderer as its original bitstream
///   for as long as it is on. A change is the session-preserving re-cut at the playhead the AE#464 audio delay
///   uses (a brief rebuffer), because the segments already cut carry the previous audio. Off, the stream copy is
///   untouched, so passthrough is intact whenever the feature is off.
/// - `.software` and a decoded `.audio` session: `AudioOutput` runs the stage on every buffer whenever a factory
///   is installed; the switch changes nothing there, the stage's own settings decide.
/// - `.remoteBypass` and an AVPlayer-owned audio-only item: AVPlayer owns the media and the engine never holds
///   its audio, so the stage cannot run. The value is kept for the next load.
extension AetherEngine {

    /// Whether the host's audio stage is asked for on this session's audio. See `setAudioSampleProcessingEnabled`.
    public var audioSampleProcessingEnabled: Bool { loadedOptions.audioSampleProcessing }

    /// True once a bridge the stage forced has failed on this title and the session was rebuilt on its original
    /// audio. While true the stage stays off for this session (`setAudioSampleProcessingEnabled(true)` logs and
    /// does nothing); the session's own rebuilds keep it, and the next host load starts clean.
    public var audioSampleProcessingUnavailableForSession: Bool { audioSampleProcessingDroppedForSession }

    /// What a load keeps of the drop: the session's own rebuilds keep it, which is what stops a second forced
    /// bridge on the same title; a host load is a new title and starts clean.
    nonisolated static func audioSampleProcessingDropAcrossLoad(_ current: Bool, sessionPreservingReload: Bool) -> Bool {
        sessionPreservingReload ? current : false
    }

    /// A bridge that existed only because the stage forced it failed (no decoder, header write, decoded nothing).
    /// The source stream-copies without the stage, so instead of going silent the session is rebuilt once at
    /// the playhead with the stage off, through the takeover rebuild (`reloadAtCurrentPosition(applying:)`), so
    /// a load still waiting on the session's startup follows it. The latch makes it once per title.
    func dropAudioSampleProcessingForSession(reason: String) {
        guard !audioSampleProcessingDroppedForSession else {
            EngineLog.emit("[AetherEngine] R2596: forced bridge failed again (\(reason)); processing is already "
                           + "dropped for this title, nothing more to do", category: .engine)
            return
        }
        audioSampleProcessingDroppedForSession = true
        EngineLog.emit("[AetherEngine] R2596: audio processing dropped for this title — forced bridge failed "
                       + "(\(reason)); playing the original audio", category: .engine)
        let change: @Sendable (inout LoadOptions) -> Void = { $0.audioSampleProcessing = false }
        #if DEBUG
        if let hook = audioSampleProcessingDropRebuildForTesting {
            hook(change)
            return
        }
        #endif
        let rebuild = startTakeoverRebuild(applying: change)
        Task { @MainActor in
            do {
                try await rebuild.value
                EngineLog.emit("[AetherEngine] R2596: rebuilt on the original audio, audio delivery = "
                               + "\(self.audioDelivery.rawValue)", category: .engine)
            } catch is CancellationError {
                EngineLog.emit("[AetherEngine] R2596: the rebuild on the original audio was superseded; "
                               + "nothing to do", category: .engine)
            } catch {
                EngineLog.emit("[AetherEngine] R2596: the rebuild on the original audio was refused (\(error)); "
                               + "the stage stays off for the next rebuild this session makes", category: .engine)
            }
        }
    }

    /// Turn the host's audio stage on or off for this session and every rebuild it makes on its own; the value
    /// lives in the options those rebuilds replay, like `setAudioDelay`'s. Passing the value in force does nothing.
    public func setAudioSampleProcessingEnabled(_ enabled: Bool) {
        guard enabled != loadedOptions.audioSampleProcessing else { return }
        if enabled, audioSampleProcessingDroppedForSession {
            EngineLog.emit("[AetherEngine] R2596: audio sample processing stays off for this title: a bridge it "
                           + "forced failed earlier in this session; the next load tries again", category: .engine)
            return
        }
        setLoadedAudioSampleProcessing(enabled)
        let label = "R2596: audio sample processing \(enabled ? "on" : "off")"

        guard AudioSampleProcessingRegistry.factory != nil else {
            EngineLog.emit("[AetherEngine] \(label), kept: no stage is installed, so no route changes",
                           category: .engine)
            return
        }
        guard state != .loading else {
            EngineLog.emit(
                "[AetherEngine] \(label) set while the session is being rebuilt; the load in flight reads it "
                + "from the options and delivers it",
                category: .engine
            )
            return
        }

        let route = videoRoute
        switch route {
        case .loopback:
            EngineLog.emit(
                "[AetherEngine] \(label) on the loopback path: the audio "
                + (enabled ? "moves into the bridge" : "returns to stream copy")
                + ", re-cut at the playhead",
                category: .engine
            )
            reanchorForAudioDelay(label: {
                "R2596: audio sample processing \(self.loadedOptions.audioSampleProcessing ? "on" : "off")"
            }) { _, _ in
                let state = self.loadedOptions.audioSampleProcessing ? "on" : "off"
                if let refusal = self.sessionReloadRefusal {
                    EngineLog.emit(
                        "[AetherEngine] R2596: audio sample processing \(state) stands, but this session cannot "
                        + "be rebuilt in place (\(refusal.rawValue)); it arrives at the next rebuild",
                        category: .engine
                    )
                    return
                }
                do {
                    try await self.reloadAtCurrentPosition()
                    EngineLog.emit("[AetherEngine] R2596: re-cut at the playhead with audio sample processing \(state)",
                                   category: .engine)
                } catch is CancellationError {
                    EngineLog.emit(
                        "[AetherEngine] R2596: the re-cut at the playhead was superseded by a newer load; the "
                        + "switch in force (\(self.loadedOptions.audioSampleProcessing ? "on" : "off")) is what "
                        + "that load builds with",
                        category: .engine
                    )
                } catch {
                    EngineLog.emit(
                        "[AetherEngine] R2596: the re-cut at the playhead failed (\(error)); audio sample "
                        + "processing \(state) stands and arrives at the next rebuild",
                        category: .engine
                    )
                }
            }

        case .software:
            EngineLog.emit(
                "[AetherEngine] \(label) on the software path: the renderer feed runs the stage on every buffer "
                + "regardless, nothing to rebuild",
                category: .engine
            )

        case .audio where !audioAVPlayerActive:
            EngineLog.emit(
                "[AetherEngine] \(label) on the decoded audio-only path: the renderer feed runs the stage on "
                + "every buffer regardless, nothing to rebuild",
                category: .engine
            )

        case .remoteBypass, .audio, .none:
            EngineLog.emit(
                "[AetherEngine] \(label), kept for the next load: this session's audio is not the engine's to "
                + "process (route=\(route.rawValue)\(route == .audio ? ", AVPlayer-owned" : ""))",
                category: .engine
            )
        }
    }
}

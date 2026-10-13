import Foundation

/// GiVo R2596: the switch for the host's audio stage (`AudioSampleProcessingRegistry`), per route.
///
/// - `.loopback`: the stage needs PCM, and on this route the engine holds PCM only inside `AudioBridge`. On,
///   every source is decoded, staged and re-encoded in `audioBridgeMode` instead of stream-copied, so an E-AC-3
///   JOC (Atmos) source loses its object metadata and no source reaches the renderer as its original bitstream
///   for as long as it is on. A change is the session-preserving re-cut at the playhead the AE#464 audio delay
///   uses (a brief rebuffer), because the segments already cut carry the previous audio. Off, the stream copy is
///   untouched, so passthrough is intact whenever the feature is off. GiVo R2596-r2: the stage's own settings are
///   cut into the segments the same way, so a change of them while the stage stays on is the same one re-cut
///   (`audioSampleProcessingParametersDidChange`).
/// - `.software` and a decoded `.audio` session: `AudioOutput` runs the stage on every buffer whenever a factory
///   is installed; the switch changes nothing there, the stage's own settings decide, and a change of them reaches
///   the next buffer the decoder hands over.
/// - `.remoteBypass` and an AVPlayer-owned audio-only item: AVPlayer owns the media and the engine never holds
///   its audio, so the stage cannot run. The value is kept for the next load.
extension AetherEngine {

    /// GiVo R2596-r2: what a change of the stage's own settings needs on the route in force.
    public enum AudioStageParameterChange: String, Sendable, Equatable {
        /// `.loopback` with the stage on: the segments already cut carry the old settings; re-cut at the playhead.
        case recut
        /// `.software` / decoded `.audio`: the stage reads its settings per buffer; nothing to rebuild.
        case nextBuffer
        /// A load is in flight: delivered when it settles (re-cut there if its cut missed the change).
        case loadInFlight
        /// The stage is not running on this session's loopback audio (off, not installed, or dropped for the title).
        case noStage
        /// `.remoteBypass`, AVPlayer-owned audio or no route: the engine never holds this audio.
        case notEngineAudio
    }

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

    /// GiVo R2596-r2: the route table for `audioSampleProcessingParametersDidChange`. Pure, so it is testable
    /// without a session.
    nonisolated static func audioStageParameterChange(stageOn: Bool, factoryInstalled: Bool, droppedForTitle: Bool,
                                                      state: PlaybackState, route: VideoRoute,
                                                      audioAVPlayerActive: Bool) -> AudioStageParameterChange {
        guard factoryInstalled else { return .noStage }
        if state == .loading { return .loadInFlight }
        switch route {
        case .loopback: return stageOn && !droppedForTitle ? .recut : .noStage
        case .software: return .nextBuffer
        case .audio: return audioAVPlayerActive ? .notEngineAudio : .nextBuffer
        case .remoteBypass, .none: return .notEngineAudio
        }
    }

    /// GiVo R2596-r2: a loopback session that started cutting with one stage value and runs under another. A load
    /// copies the switch onto its session before `start()` routes the audio, and that start runs for seconds while
    /// `state` is `.loading`; a switch or a settings change landing in that window used to be recorded and never
    /// cut (M8).
    nonisolated static func audioStageMissedByLoad(routedOn: Bool, nowOn: Bool,
                                                   routedGeneration: UInt64, nowGeneration: UInt64) -> Bool {
        routedOn != nowOn || (nowOn && routedGeneration != nowGeneration)
    }

    /// GiVo R2596-r2: the re-anchor latch's catch-up rule. Another pass is owed while any value the re-cut delivers
    /// moved after the last pass read it: the audio delay, the stage switch, or (with the stage on) its settings.
    nonisolated static func audioReanchorOwesAnotherPass(deliveredDelay: Double, delay: Double,
                                                         deliveredProcessing: Bool, processing: Bool,
                                                         deliveredStageGeneration: UInt64,
                                                         stageGeneration: UInt64) -> Bool {
        AudioDelayPolicy.isChange(from: deliveredDelay, to: delay)
            || deliveredProcessing != processing
            || (processing && deliveredStageGeneration != stageGeneration)
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
        // GiVo R2596-r2: written now as well as by the rebuild's correction, so a reload that supersedes that
        // rebuild (a seek, a track pick) cannot cut with the stage on and fail the same way a second time.
        setLoadedAudioSampleProcessing(false)
        EngineLog.emit("[AetherEngine] R2596: audio processing dropped for this title — forced bridge failed "
                       + "(\(reason)); playing the original audio", category: .engine)
        let change: @Sendable (inout LoadOptions) -> Void = { $0.audioSampleProcessing = false }
        #if DEBUG
        if let hook = audioSampleProcessingDropRebuildForTesting {
            hook(change)
            onAudioSampleProcessingDropped?(reason, false)
            return
        }
        #endif
        let rebuild = startTakeoverRebuild(applying: change)
        Task { @MainActor in
            do {
                try await rebuild.value
                EngineLog.emit("[AetherEngine] R2596: rebuilt on the original audio, audio delivery = "
                               + "\(self.audioDelivery.rawValue)", category: .engine)
                self.onAudioSampleProcessingDropped?(reason, false)   // GiVo R2596-r2
            } catch is CancellationError {
                EngineLog.emit("[AetherEngine] R2596: the rebuild on the original audio was superseded; "
                               + "nothing to do", category: .engine)
                // GiVo R2596-r2: a session-preserving reload keeps the latch and cuts with the stage off; a host
                // load clears it and is another title, which this drop must not be reported against.
                if self.audioSampleProcessingDroppedForSession { self.onAudioSampleProcessingDropped?(reason, false) }
            } catch {
                EngineLog.emit("[AetherEngine] R2596: the rebuild on the original audio was refused (\(error)); "
                               + "this session plays on without the audio the bridge was carrying, and the stage "
                               + "stays off for the next rebuild this session makes (R2596-r2: reported to the host)",
                               category: .engine)
                self.onAudioSampleProcessingDropped?(reason, true)   // GiVo R2596-r2 (M2): never silence without a word
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
                "[AetherEngine] \(label) set while the session is being rebuilt; the load in flight cuts with it, "
                + "or re-cuts once it settles if its cut started before this (R2596-r2)",
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
            recutForAudioStage(reason: "switch")

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

    /// GiVo R2596-r2: the host changed its stage's own settings (for GiVo: the Dialogue Boost level or Reduce Loud
    /// Sounds) while the stage stays on. On `.loopback` the stage runs when a segment is cut, and the producer cuts
    /// far ahead of the playhead, so the change is heard only after a re-cut: the same session-preserving re-cut at
    /// the playhead a toggle costs (a brief rebuffer), folded with any delay or switch change in flight. `.software`
    /// and decoded `.audio` read the settings per buffer and need nothing. Returns what it did.
    @discardableResult
    public func audioSampleProcessingParametersDidChange() -> AudioStageParameterChange {
        let action = Self.audioStageParameterChange(
            stageOn: loadedOptions.audioSampleProcessing,
            factoryInstalled: AudioSampleProcessingRegistry.factory != nil,
            droppedForTitle: audioSampleProcessingDroppedForSession,
            state: state, route: videoRoute, audioAVPlayerActive: audioAVPlayerActive)
        switch action {
        case .recut:
            audioSampleProcessingParameterGeneration &+= 1
            EngineLog.emit("[AetherEngine] R2596-r2: audio stage settings changed on the loopback path; the cut "
                           + "segments carry the old ones, re-cut at the playhead", category: .engine)
            recutForAudioStage(reason: "settings")
        case .loadInFlight:
            audioSampleProcessingParameterGeneration &+= 1
            EngineLog.emit("[AetherEngine] R2596-r2: audio stage settings changed while a load is in flight; "
                           + "re-cut once it settles if its cut started before this", category: .engine)
        case .nextBuffer:
            EngineLog.emit("[AetherEngine] R2596-r2: audio stage settings changed on the \(videoRoute.rawValue) "
                           + "path; the renderer feed reads them on its next buffer", category: .engine)
        case .noStage:
            EngineLog.emit("[AetherEngine] R2596-r2: audio stage settings changed; the stage is not running on "
                           + "this session's audio (switch off, dropped for the title, or none installed)",
                           category: .engine)
        case .notEngineAudio:
            EngineLog.emit("[AetherEngine] R2596-r2: audio stage settings changed; this session's audio is not "
                           + "the engine's (route=\(videoRoute.rawValue))", category: .engine)
        }
        return action
    }

    /// GiVo R2596-r2 (M8): called from `state`'s didSet. When a load settles, re-cut once if its loopback cut
    /// started under a stage switch or settings generation the host has since changed.
    func deliverAudioStageMissedByLoad(leaving oldState: PlaybackState) {
        guard oldState == .loading, state == .playing || state == .paused, videoRoute == .loopback,
              !audioDelayReanchorInFlight, AudioSampleProcessingRegistry.factory != nil,
              let session = nativeVideoSession else { return }
        let routedOn = session.audioSampleProcessing
        // A forced bridge that failed is the drop's takeover rebuild to undo, not this.
        if routedOn && audioSampleProcessingDroppedForSession { return }
        guard Self.audioStageMissedByLoad(routedOn: routedOn, nowOn: loadedOptions.audioSampleProcessing,
                                          routedGeneration: audioSampleProcessingGenerationAtSessionStart,
                                          nowGeneration: audioSampleProcessingParameterGeneration) else { return }
        EngineLog.emit("[AetherEngine] R2596-r2: an audio-stage change landed while this session was loading and "
                       + "missed its cut (cut with the stage \(routedOn ? "on" : "off"), now "
                       + "\(loadedOptions.audioSampleProcessing ? "on" : "off")); re-cut at the playhead",
                       category: .engine)
        recutForAudioStage(reason: "missed by the load")
    }

    /// GiVo R2596 / R2596-r2: the loopback re-cut that delivers the stage switch and the stage's settings, on the
    /// AE#464 re-anchor latch (one rebuild for a burst, a catch-up pass for a change inside it).
    func recutForAudioStage(reason: String) {
        #if DEBUG
        if let hook = audioStageRecutForTesting {
            hook(reason)
            return
        }
        #endif
        reanchorForAudioDelay(label: {
            "R2596: audio sample processing \(self.loadedOptions.audioSampleProcessing ? "on" : "off") (\(reason))"
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
    }
}

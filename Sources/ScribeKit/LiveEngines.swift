import AVFoundation
import FluidAudio
import Foundation

/// Builds the production engines: Nemotron Unified ASR 0.6B (CoreML fp16, streaming) per
/// track and LS-EEND diarization for the system track.
public enum LiveEngineFactory {
    /// HF repo of the recognizer, for notices and reports.
    public static let SPEECH_MODEL = "FluidInference/nemotron-labs-unified-asr-0.6b-coreml"
    public static let DIARIZATION_MODEL = "FluidInference/ls-eend-coreml"

    /// Languages the live recognizer accepts (ISO 639-1).
    public static let supportedLanguages: [String] = NemotronUnifiedLanguage.allCases
        .filter { $0 != .auto }.map(\.rawValue)

    static func nemotron(_ options: LiveOptions) async throws -> LiveEngines {
        let language: NemotronUnifiedLanguage
        if let code = options.language {
            guard let known = NemotronUnifiedLanguage(rawValue: code) else { throw LiveError.unsupportedLanguage(code) }
            language = known
        } else {
            language = .auto
        }
        var speech: [LiveTrack: any LiveSpeechEngine] = [:]
        for track in LiveTrack.allCases {
            speech[track] = try await NemotronSpeechEngine.load(language: language, latency: options.latency,
                                                                directory: options.modelDirectory)
        }
        let diarizer: (any LiveDiarizationEngine)? = options.diarizeSystem
            ? try await LSEENDDiarizationEngine.load(directory: options.modelDirectory) : nil
        let description = "nemotron-unified-asr-0.6b fp16 \(language.rawValue) \(options.latency.rawValue)ms"
            + (options.diarizeSystem ? " + ls-eend dihard3" : "")
        return LiveEngines(description: description, speech: speech, diarizer: diarizer)
    }
}

/// `StreamingUnifiedAsrManager` behind ``LiveSpeechEngine``.
final class NemotronSpeechEngine: LiveSpeechEngine, @unchecked Sendable {
    private let manager: StreamingUnifiedAsrManager
    private let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1,
                                       interleaved: false)!
    private let lookAhead: TimeInterval
    private let lock = NSLock()
    private var appended = 0

    private init(manager: StreamingUnifiedAsrManager, lookAhead: TimeInterval) {
        self.manager = manager
        self.lookAhead = lookAhead
    }

    static func load(language: NemotronUnifiedLanguage, latency: LiveLatency, directory: URL?) async throws
        -> NemotronSpeechEngine {
        let contexts = latency.contexts
        let config = UnifiedConfig(leftFrames: contexts.left, chunkFrames: contexts.chunk,
                                   rightFrames: contexts.right, family: .nemotronMultilingual(language))
        let manager = StreamingUnifiedAsrManager(config: config, encoderPrecision: .fp16)
        do {
            try await manager.loadModels(to: directory)
        } catch {
            throw LiveError.model("Nemotron Unified \(latency.rawValue)ms: \(error.localizedDescription)")
        }
        return NemotronSpeechEngine(manager: manager, lookAhead: Double(latency.rawValue) / 1000)
    }

    func append(_ samples: [Float]) async throws {
        guard !samples.isEmpty,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))
        else { return }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        try await manager.appendAudio(buffer)
        lock.withLock { appended += samples.count }
    }

    func process() async throws -> [LiveToken] {
        try await manager.processBufferedAudio()
        return Self.tokens(await manager.consumeTokenTimings())
    }

    func finish() async throws -> [LiveToken] {
        _ = try await manager.finish()
        return Self.tokens(await manager.consumeTokenTimings())
    }

    var decodedUntil: TimeInterval {
        get async { max(0, Double(lock.withLock { appended }) / 16_000 - lookAhead) }
    }

    static func tokens(_ timings: [TokenTiming]) -> [LiveToken] {
        timings.map {
            LiveToken(text: $0.token, start: $0.startTime, end: $0.endTime,
                      startsWord: $0.token.hasPrefix("▁") || $0.token.hasPrefix(" "))
        }
    }
}

/// `LSEENDDiarizer` (100 ms steps) behind ``LiveDiarizationEngine``. Slots are anonymous.
final class LSEENDDiarizationEngine: LiveDiarizationEngine, @unchecked Sendable {
    private let diarizer: LSEENDDiarizer
    private let lock = NSLock()

    private init(diarizer: LSEENDDiarizer) { self.diarizer = diarizer }

    static func load(directory: URL?) async throws -> LSEENDDiarizationEngine {
        let diarizer = LSEENDDiarizer()
        do {
            try await diarizer.initialize(variant: .dihard3, cacheDirectory: directory)
        } catch {
            throw LiveError.model("LS-EEND: \(error.localizedDescription)")
        }
        return LSEENDDiarizationEngine(diarizer: diarizer)
    }

    func append(_ samples: [Float]) async throws -> LiveDiarization {
        try lock.withLock {
            _ = try diarizer.process(samples: samples, sourceSampleRate: 16_000)
            return state()
        }
    }

    func finish() async throws -> LiveDiarization {
        try lock.withLock {
            _ = try diarizer.finalizeSession()
            return state()
        }
    }

    private func state() -> LiveDiarization {
        let timeline = diarizer.timeline
        var spans: [LiveSpeakerSpan] = []
        for (slot, speaker) in timeline.speakers {
            for segment in speaker.finalizedSegments {
                spans.append(LiveSpeakerSpan(slot: slot, start: Double(segment.startTime), end: Double(segment.endTime), isFinal: true))
            }
            for segment in speaker.tentativeSegments {
                spans.append(LiveSpeakerSpan(slot: slot, start: Double(segment.startTime), end: Double(segment.endTime), isFinal: false))
            }
        }
        let frontier = Double(timeline.numFinalizedFrames) * Double(timeline.config.frameDurationSeconds)
        return LiveDiarization(spans: spans, finalizedUntil: frontier)
    }
}

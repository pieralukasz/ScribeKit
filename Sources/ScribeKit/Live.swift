import Foundation

// MARK: - Public types

/// Which recorded track audio comes from. Both tracks share one timeline: second 0 is the
/// moment the recording started, for the microphone and the system audio alike.
public enum LiveTrack: String, Codable, Sendable, CaseIterable {
    /// The person recording. Words on this track belong to the local speaker; no diarization.
    case microphone
    /// Everything the Mac plays (the other side of a call). Split into anonymous speakers.
    case system
}

/// Whether a value may still change. `pending` values are working guesses that a later
/// revision corrects or confirms; `final` values do not change again.
public enum LiveState: String, Codable, Sendable {
    case pending
    case final
}

/// Look-ahead of the streaming recognizer: chunk plus right context. Shorter means text
/// arrives sooner but is less accurate. This is the model window only, not the full delay.
public enum LiveLatency: Int, Codable, Sendable, CaseIterable {
    case ms560 = 560
    case ms1120 = 1120
    case ms2080 = 2080

    /// Encoder frames (80 ms each) of the matching CoreML export: left, chunk, right.
    var contexts: (left: Int, chunk: Int, right: Int) {
        switch self {
        case .ms560: return (70, 2, 5)
        case .ms1120: return (70, 7, 7)
        case .ms2080: return (70, 13, 13)
        }
    }
}

/// Settings of a live transcription.
public struct LiveOptions: Sendable, Equatable {
    /// ISO 639-1 language for the recognizer prompt, or nil for automatic detection.
    public var language: String?
    public var latency: LiveLatency
    /// Split the system track into anonymous speakers (LS-EEND). Off: one "remote" speaker.
    public var diarizeSystem: Bool
    /// Opt-in: mark microphone words that repeat the system audio (speaker bleed without
    /// headphones) and leave them out of ``LiveSnapshot/transcript``. Off by default: the check
    /// is a text guess and also hides a real "tak" said by both sides at once.
    public var suppressBleed: Bool
    public var localSpeakerName: String
    /// Name of an anonymous remote speaker; `%d` becomes 1, 2, 3…
    public var remoteSpeakerTemplate: String
    /// Where models are downloaded; nil uses FluidAudio's default folder.
    public var modelDirectory: URL?

    public init(language: String? = "pl", latency: LiveLatency = .ms1120, diarizeSystem: Bool = true,
                suppressBleed: Bool = false, localSpeakerName: String = "Me",
                remoteSpeakerTemplate: String = "Speaker %d", modelDirectory: URL? = nil) {
        self.language = language
        self.latency = latency
        self.diarizeSystem = diarizeSystem
        self.suppressBleed = suppressBleed
        self.localSpeakerName = localSpeakerName
        self.remoteSpeakerTemplate = remoteSpeakerTemplate
        self.modelDirectory = modelDirectory
    }
}

/// One recognized word. `id` stays the same for the whole session while its text, times
/// or speaker are corrected; `revision` is the snapshot revision that last changed it.
public struct LiveWord: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public var track: LiveTrack
    public var text: String
    public var start: TimeInterval
    public var end: TimeInterval
    /// A transcript speaker id (see ``LiveSnapshot/speakers``); nil while unknown.
    public var speakerID: String?
    public var textState: LiveState
    public var speakerState: LiveState
    /// Microphone word that repeats the system audio; left out of ``LiveSnapshot/transcript``.
    public var isBleed: Bool
    public var revision: Int

    public init(id: String, track: LiveTrack, text: String, start: TimeInterval, end: TimeInterval,
                speakerID: String?, textState: LiveState, speakerState: LiveState, isBleed: Bool = false,
                revision: Int) {
        self.id = id
        self.track = track
        self.text = text
        self.start = start
        self.end = end
        self.speakerID = speakerID
        self.textState = textState
        self.speakerState = speakerState
        self.isBleed = isBleed
        self.revision = revision
    }
}

/// Audio that never reached the recognizer (dropped under load, or a capture gap). The
/// timeline stays aligned; this stretch is silence to the models.
public struct LiveGap: Codable, Hashable, Sendable {
    public var track: LiveTrack
    public var start: TimeInterval
    public var duration: TimeInterval
    public var reason: String

    public init(track: LiveTrack, start: TimeInterval, duration: TimeInterval, reason: String) {
        self.track = track
        self.start = start
        self.duration = duration
        self.reason = reason
    }
}

/// The live transcript at one revision.
public struct LiveSnapshot: Codable, Hashable, Sendable {
    public enum Phase: String, Codable, Sendable { case idle, running, finished, cancelled, failed }

    public var revision: Int
    public var phase: Phase
    /// Model and window, e.g. "nemotron-unified-asr-0.6b fp16 pl 1120ms + ls-eend".
    public var engine: String
    public var words: [LiveWord]
    /// Anonymous slots only (`Speaker 1`…), never matched to real people at this stage.
    public var speakers: [Speaker]
    public var gaps: [LiveGap]
    /// Seconds of audio received per track (`microphone`, `system`).
    public var received: [String: TimeInterval]
    public var error: String?

    public init(revision: Int, phase: Phase, engine: String, words: [LiveWord], speakers: [Speaker],
                gaps: [LiveGap], received: [String: TimeInterval], error: String?) {
        self.revision = revision
        self.phase = phase
        self.engine = engine
        self.words = words
        self.speakers = speakers
        self.gaps = gaps
        self.received = received
        self.error = error
    }

    /// Words changed after `revision`: what a client polling with its last seen revision needs.
    public func changes(since revision: Int) -> [LiveWord] {
        words.filter { $0.revision > revision }
    }

    /// The current state as an ordinary transcript (pending words included; words marked as
    /// bleed, only with ``LiveOptions/suppressBleed`` on, left out).
    public var transcript: Transcript {
        let kept = words.filter { !$0.isBleed }.sorted { ($0.start, $0.id) < ($1.start, $1.id) }
        let segments = SegmentBuilder.group(kept.map { (Word(text: $0.text, start: $0.start, end: $0.end), $0.speakerID) })
        let duration = received.values.max() ?? 0
        return Transcript(segments: segments, speakers: speakers, language: nil, duration: duration)
    }
}

// MARK: - Engine seams

/// A recognized sub-word piece, times in seconds on the track's timeline.
struct LiveToken: Sendable, Equatable {
    var text: String
    var start: TimeInterval
    var end: TimeInterval
    /// True when the piece begins a new word (SentencePiece `▁`).
    var startsWord: Bool
}

/// Streaming speech recognizer for one track.
protocol LiveSpeechEngine: AnyObject, Sendable {
    func append(_ samples: [Float]) async throws
    /// Decodes what the buffered audio allows and returns new tokens.
    func process() async throws -> [LiveToken]
    /// Flushes the remaining audio (padding the look-ahead) and returns the last tokens.
    func finish() async throws -> [LiveToken]
    /// Seconds of audio decoded so far; tokens before this point do not change any more.
    var decodedUntil: TimeInterval { get async }
}

/// A speaker activity span from the diarizer, in seconds.
struct LiveSpeakerSpan: Sendable, Equatable {
    var slot: Int
    var start: TimeInterval
    var end: TimeInterval
    var isFinal: Bool
}

/// The diarizer's current view: every span so far, and how far its decisions are final.
struct LiveDiarization: Sendable, Equatable {
    var spans: [LiveSpeakerSpan]
    var finalizedUntil: TimeInterval
}

protocol LiveDiarizationEngine: AnyObject, Sendable {
    func append(_ samples: [Float]) async throws -> LiveDiarization
    func finish() async throws -> LiveDiarization
}

/// Engines of one session. Production uses ``LiveEngineFactory/nemotron``.
struct LiveEngines: Sendable {
    var description: String
    var speech: [LiveTrack: any LiveSpeechEngine]
    var diarizer: (any LiveDiarizationEngine)?
}

public enum LiveError: LocalizedError, Sendable, Equatable {
    case notStarted
    case alreadyFinished
    case unsupportedLanguage(String)
    case model(String)

    public var errorDescription: String? {
        switch self {
        case .notStarted: return "Live transcription has not started."
        case .alreadyFinished: return "Live transcription has already finished."
        case .unsupportedLanguage(let code): return "The live model does not support language \"\(code)\"."
        case .model(let message): return "Live model error: \(message)"
        }
    }
}

// MARK: - Transcriber

/// Streams a two-track recording into a live, self-correcting transcript.
///
///     let live = LiveTranscriber(options: LiveOptions(language: "pl"))
///     try await live.start()                       // loads models (download on first use)
///     try await live.feed(samples, track: .system, at: 12.0)
///     let now = await live.snapshot()              // read any time, also from another task
///     let final = try await live.finish()          // flushes the last words
///
/// Audio must be 16 kHz mono Float. Text arrives once the model window passed it; the last
/// word of a batch stays `pending` until the next audio shows it is complete. System words
/// get a `pending` speaker from the diarizer's tentative output, corrected when it settles.
public actor LiveTranscriber {
    public static let SAMPLE_RATE: Double = 16_000
    /// Timing jitter between `at` and the samples already received that is not a gap.
    static let GAP_TOLERANCE: TimeInterval = 0.1
    /// A microphone word repeating a system word this close in time is treated as bleed.
    static let BLEED_WINDOW: TimeInterval = 0.8
    /// How many of the latest words the bleed check looks at (about a minute of two-sided talk).
    static let BLEED_SCAN_WORDS = 400
    static let LOCAL_ID = "local"
    static let REMOTE_ID = "remote"

    public let options: LiveOptions
    private let factory: @Sendable (LiveOptions) async throws -> LiveEngines
    private var engines: LiveEngines?

    private var phase: LiveSnapshot.Phase = .idle
    private var revision = 0
    private var words: [LiveWord] = []
    private var indexByID: [String: Int] = [:]
    private var nextWordNumber: [LiveTrack: Int] = [:]
    private var openWord: [LiveTrack: String] = [:]
    private var receivedSamples: [LiveTrack: Int] = [:]
    private var gaps: [LiveGap] = []
    private var diarization = LiveDiarization(spans: [], finalizedUntil: 0)
    private var slotSpeakers: [Int: Speaker] = [:]
    private var errorMessage: String?
    private var continuations: [UUID: AsyncStream<LiveSnapshot>.Continuation] = [:]

    public init(options: LiveOptions = LiveOptions()) {
        self.options = options
        self.factory = { try await LiveEngineFactory.nemotron($0) }
    }

    init(options: LiveOptions, engines: @escaping @Sendable (LiveOptions) async throws -> LiveEngines) {
        self.options = options
        self.factory = engines
    }

    /// Loads the models. Call once before feeding audio.
    public func start() async throws {
        guard engines == nil else { return }
        guard phase == .idle else { throw LiveError.alreadyFinished }
        do {
            let loaded = try await factory(options)
            // `cancel()` may run while the models load; it wins and the engines are dropped.
            guard phase == .idle else { return }
            engines = loaded
            phase = .running
            publish()
        } catch {
            if phase == .idle { fail(error) }
            throw error
        }
    }

    /// Adds audio of one track. `time` is where the first sample sits on the shared
    /// timeline; nil means right after the previous samples of that track. A jump forward
    /// is recorded as a gap and filled with silence, so later times stay correct.
    public func feed(_ samples: [Float], track: LiveTrack, at time: TimeInterval? = nil) async throws {
        guard let engines else { throw phase == .idle ? LiveError.notStarted : LiveError.alreadyFinished }
        guard phase == .running else { throw LiveError.alreadyFinished }
        var samples = samples
        let received = receivedSamples[track, default: 0]
        if let time {
            let expected = Int((time * Self.SAMPLE_RATE).rounded())
            let missing = expected - received
            if Double(missing) > Self.GAP_TOLERANCE * Self.SAMPLE_RATE {
                gaps.append(LiveGap(track: track, start: Double(received) / Self.SAMPLE_RATE,
                                    duration: Double(missing) / Self.SAMPLE_RATE, reason: "missing audio"))
                samples = [Float](repeating: 0, count: missing) + samples
            } else if Double(-missing) > Self.GAP_TOLERANCE * Self.SAMPLE_RATE {
                // Overlaps audio already received: drop the repeated part.
                samples = Array(samples.dropFirst(min(-missing, samples.count)))
            }
        }
        guard !samples.isEmpty else { return }
        receivedSamples[track] = received + samples.count
        do {
            guard let speech = engines.speech[track] else { return }
            try await speech.append(samples)
            let tokens = try await speech.process()
            let decoded = await speech.decodedUntil
            var changed = apply(tokens, track: track, closeBefore: decoded)
            if track == .system, let diarizer = engines.diarizer {
                diarization = try await diarizer.append(samples)
                changed = assignSpeakers() || changed
            }
            if changed { publish() }
        } catch {
            fail(error)
            throw error
        }
    }

    /// Records audio lost before it reached ``feed(_:track:at:)`` (for example dropped by a
    /// bounded capture buffer). Feeding with `at:` after the loss records it as well.
    public func reportGap(_ gap: LiveGap) {
        gaps.append(gap)
        bump()
        publish()
    }

    /// Flushes the remaining audio of every track and returns the final transcript.
    @discardableResult
    public func finish() async throws -> LiveSnapshot {
        guard let engines else { throw phase == .idle ? LiveError.notStarted : LiveError.alreadyFinished }
        guard phase == .running else { throw LiveError.alreadyFinished }
        do {
            for track in LiveTrack.allCases {
                guard let speech = engines.speech[track] else { continue }
                let tokens = try await speech.finish()
                _ = apply(tokens, track: track, closeBefore: .infinity)
            }
            if let diarizer = engines.diarizer {
                diarization = try await diarizer.finish()
                diarization.finalizedUntil = .infinity
            }
            _ = assignSpeakers()
            for index in words.indices where words[index].textState == .pending || words[index].speakerState == .pending {
                words[index].textState = .final
                words[index].speakerState = .final
                touch(index)
            }
            bump()
            phase = .finished
            self.engines = nil
            publish()
            finishStreams()
            return snapshot()
        } catch {
            fail(error)
            throw error
        }
    }

    /// Stops without flushing; the words so far stay readable. Safe to call any time.
    public func cancel() {
        guard phase == .running || phase == .idle else { return }
        engines = nil
        phase = .cancelled
        bump()
        publish()
        finishStreams()
    }

    public func snapshot() -> LiveSnapshot {
        var speakers: [Speaker] = []
        if words.contains(where: { $0.speakerID == Self.LOCAL_ID }) {
            speakers.append(Speaker(id: Self.LOCAL_ID, name: options.localSpeakerName, isLocal: true))
        }
        if words.contains(where: { $0.speakerID == Self.REMOTE_ID }) {
            speakers.append(Speaker(id: Self.REMOTE_ID, name: String(format: options.remoteSpeakerTemplate, 1)))
        }
        speakers += slotSpeakers.sorted { $0.key < $1.key }.map(\.value)
            .filter { speaker in words.contains { $0.speakerID == speaker.id } }
        return LiveSnapshot(
            revision: revision, phase: phase, engine: engines?.description ?? lastEngineDescription,
            words: words, speakers: speakers, gaps: gaps,
            received: Dictionary(uniqueKeysWithValues: receivedSamples.map { ($0.key.rawValue, Double($0.value) / Self.SAMPLE_RATE) }),
            error: errorMessage)
    }

    /// Snapshots as they change; ends when the session finishes or is cancelled.
    public func updates() -> AsyncStream<LiveSnapshot> {
        let id = UUID()
        let (stream, continuation) = AsyncStream.makeStream(of: LiveSnapshot.self, bufferingPolicy: .bufferingNewest(1))
        continuation.yield(snapshot())
        if phase == .running || phase == .idle {
            continuations[id] = continuation
            continuation.onTermination = { [weak self] _ in Task { await self?.removeContinuation(id) } }
        } else {
            continuation.finish()
        }
        return stream
    }

    // MARK: - Internals

    private var lastEngineDescription = ""

    private func removeContinuation(_ id: UUID) { continuations[id] = nil }

    private func publish() {
        if let engines { lastEngineDescription = engines.description }
        guard !continuations.isEmpty else { return }
        let current = snapshot()
        for continuation in continuations.values { continuation.yield(current) }
    }

    private func finishStreams() {
        for continuation in continuations.values { continuation.finish() }
        continuations = [:]
    }

    private func fail(_ error: Error) {
        errorMessage = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        engines = nil
        phase = .failed
        bump()
        publish()
        finishStreams()
    }

    private func bump() { revision += 1 }
    private func touch(_ index: Int) { words[index].revision = revision + 1 }

    /// Adds tokens to the track's words. The word left open at the end stays pending until
    /// a following token starts a new word or the decoder has moved past it.
    private func apply(_ tokens: [LiveToken], track: LiveTrack, closeBefore decoded: TimeInterval) -> Bool {
        var changed = false
        for token in tokens {
            let piece = token.text.replacingOccurrences(of: "▁", with: " ")
            let text = piece.trimmingCharacters(in: .whitespaces)
            if let openID = openWord[track], let index = indexByID[openID], !token.startsWord {
                guard !text.isEmpty else { continue }
                words[index].text += text
                words[index].end = max(words[index].end, token.end)
                touch(index)
                changed = true
                continue
            }
            guard !text.isEmpty else { continue }
            if let openID = openWord[track], let index = indexByID[openID] {
                words[index].textState = .final
                touch(index)
            }
            let number = nextWordNumber[track, default: 0]
            nextWordNumber[track] = number + 1
            let id = "\(track == .microphone ? "mic" : "sys")-\(number)"
            let speaker: String? = track == .microphone ? Self.LOCAL_ID : (options.diarizeSystem ? nil : Self.REMOTE_ID)
            words.append(LiveWord(id: id, track: track, text: text, start: token.start, end: token.end,
                                  speakerID: speaker, textState: .pending,
                                  speakerState: speaker == nil ? .pending : .final, isBleed: false,
                                  revision: revision + 1))
            indexByID[id] = words.count - 1
            openWord[track] = id
            changed = true
        }
        // The decoder emits a word's pieces from consecutive frames: once it decoded well
        // past the open word, no continuation can come.
        if let openID = openWord[track], let index = indexByID[openID], decoded >= words[index].end + 0.5 {
            words[index].textState = .final
            touch(index)
            openWord[track] = nil
            changed = true
        }
        if changed, options.suppressBleed { markBleed() }
        if changed { bump() }
        return changed
    }

    /// Gives system words the diarizer slot that overlaps them most. A word is settled once
    /// the diarizer's finalized frontier passed it.
    private func assignSpeakers() -> Bool {
        guard options.diarizeSystem else { return false }
        var changed = false
        for index in words.indices where words[index].track == .system && words[index].speakerState == .pending {
            let word = words[index]
            var best: (slot: Int, overlap: Double)?
            for span in diarization.spans {
                let overlap = min(word.end, span.end) - max(word.start, span.start)
                if overlap > 0, overlap > (best?.overlap ?? 0) { best = (span.slot, overlap) }
            }
            if best == nil {
                // No span covers the word (short pause inside speech): take the nearest one.
                let nearest = diarization.spans.min {
                    distance(word, $0) < distance(word, $1)
                }
                if let nearest, distance(word, nearest) <= 1.0 { best = (nearest.slot, 0) }
            }
            let id = best.map { speakerID(slot: $0.slot) }
            let settled = word.end <= diarization.finalizedUntil
            if id != word.speakerID || settled {
                words[index].speakerID = id
                words[index].speakerState = settled ? .final : .pending
                touch(index)
                changed = true
            }
        }
        if changed { bump() }
        return changed
    }

    private func distance(_ word: LiveWord, _ span: LiveSpeakerSpan) -> Double {
        max(0, max(span.start - word.end, word.start - span.end))
    }

    private func speakerID(slot: Int) -> String {
        let id = "slot-\(slot)"
        if slotSpeakers[slot] == nil {
            let name = String(format: options.remoteSpeakerTemplate, slotSpeakers.count + 1)
            slotSpeakers[slot] = Speaker(id: id, name: name)
        }
        return id
    }

    /// Without headphones the microphone also hears the call: a microphone word whose text
    /// repeats a system word at about the same time is marked as bleed (never deleted).
    private func markBleed() {
        // Only the recent tail can change: older words of both tracks are settled.
        let recent = words.indices.suffix(Self.BLEED_SCAN_WORDS)
        let system = recent.map { words[$0] }.filter { $0.track == .system }
        guard !system.isEmpty else { return }
        for index in recent where words[index].track == .microphone {
            let word = words[index]
            let key = Self.normalize(word.text)
            guard !key.isEmpty else { continue }
            let repeats = system.contains {
                abs($0.start - word.start) <= Self.BLEED_WINDOW && Self.normalize($0.text) == key
            }
            if repeats != word.isBleed {
                words[index].isBleed = repeats
                touch(index)
            }
        }
    }

    static func normalize(_ text: String) -> String {
        text.lowercased().filter { $0.isLetter || $0.isNumber }
    }
}

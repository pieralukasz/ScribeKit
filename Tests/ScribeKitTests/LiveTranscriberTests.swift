import XCTest
@testable import ScribeKit

/// Scripted recognizer: each `process()` returns the next batch; `finish()` the last one.
private final class FakeSpeech: LiveSpeechEngine, @unchecked Sendable {
    var batches: [[LiveToken]]
    var finalBatch: [LiveToken]
    var failOnProcess: Error?
    private(set) var samples = 0
    private(set) var finished = false

    init(_ batches: [[LiveToken]] = [], final finalBatch: [LiveToken] = []) {
        self.batches = batches
        self.finalBatch = finalBatch
    }

    func append(_ samples: [Float]) async throws { self.samples += samples.count }
    func process() async throws -> [LiveToken] {
        if let failOnProcess { throw failOnProcess }
        return batches.isEmpty ? [] : batches.removeFirst()
    }
    func finish() async throws -> [LiveToken] { finished = true; return finalBatch }
    var decodedUntil: TimeInterval { get async { 0 } }
}

private final class FakeDiarizer: LiveDiarizationEngine, @unchecked Sendable {
    var states: [LiveDiarization]
    var finalState: LiveDiarization
    init(_ states: [LiveDiarization], final finalState: LiveDiarization) {
        self.states = states
        self.finalState = finalState
    }
    func append(_ samples: [Float]) async throws -> LiveDiarization {
        states.count > 1 ? states.removeFirst() : states.first ?? finalState
    }
    func finish() async throws -> LiveDiarization { finalState }
}

private func token(_ text: String, _ start: TimeInterval, _ end: TimeInterval) -> LiveToken {
    LiveToken(text: text, start: start, end: end, startsWord: text.hasPrefix("▁"))
}

private let second = [Float](repeating: 0.1, count: 16_000)

final class LiveTranscriberTests: XCTestCase {
    private func transcriber(mic: FakeSpeech = FakeSpeech(), system: FakeSpeech = FakeSpeech(),
                             diarizer: FakeDiarizer? = nil, options: LiveOptions = LiveOptions()) -> LiveTranscriber {
        LiveTranscriber(options: options) { _ in
            LiveEngines(description: "fake", speech: [.microphone: mic, .system: system], diarizer: diarizer)
        }
    }

    func testLifecycleRejectsFeedingBeforeStartAndAfterFinish() async throws {
        let mic = FakeSpeech([[token("▁cześć", 0.2, 0.6)]])
        let live = transcriber(mic: mic)
        do { try await live.feed(second, track: .microphone); XCTFail("fed before start") } catch {
            XCTAssertEqual(error as? LiveError, .notStarted)
        }
        try await live.start()
        try await live.feed(second, track: .microphone, at: 0)
        let running = await live.snapshot()
        XCTAssertEqual(running.phase, .running)
        XCTAssertEqual(running.words.map(\.text), ["cześć"])
        XCTAssertEqual(running.words.first?.speakerID, "local")

        let final = try await live.finish()
        XCTAssertEqual(final.phase, .finished)
        XCTAssertTrue(mic.finished)
        do { try await live.feed(second, track: .microphone); XCTFail("fed after finish") } catch {
            XCTAssertEqual(error as? LiveError, .alreadyFinished)
        }
    }

    func testOpenWordIsCorrectedByItsContinuationAndFinishFlushesTheLastWords() async throws {
        let mic = FakeSpeech([[token("▁dzień", 0.1, 0.4), token("▁do", 0.5, 0.6)],
                              [token("bry", 0.6, 0.8), token("▁wszystkim", 0.9, 1.4)]],
                             final: [token("▁koniec", 1.6, 2.0)])
        let live = transcriber(mic: mic)
        try await live.start()

        try await live.feed(second, track: .microphone, at: 0)
        let first = await live.snapshot()
        XCTAssertEqual(first.words.map(\.text), ["dzień", "do"])
        XCTAssertEqual(first.words.map(\.textState), [.final, .pending])
        let openID = first.words[1].id

        try await live.feed(second, track: .microphone, at: 1)
        let second = await live.snapshot()
        XCTAssertEqual(second.words.map(\.text), ["dzień", "dobry", "wszystkim"])
        XCTAssertEqual(second.words[1].id, openID, "the corrected word keeps its id")
        XCTAssertEqual(second.words[1].textState, .final)
        XCTAssertEqual(second.words[1].end, 0.8, accuracy: 1e-9)
        XCTAssertEqual(second.changes(since: first.revision).map(\.text), ["dobry", "wszystkim"])
        XCTAssertGreaterThan(second.revision, first.revision)

        let final = try await live.finish()
        XCTAssertEqual(final.words.map(\.text), ["dzień", "dobry", "wszystkim", "koniec"])
        XCTAssertTrue(final.words.allSatisfy { $0.textState == .final && $0.speakerState == .final })
        XCTAssertEqual(final.transcript.text, "dzień dobry wszystkim koniec")
    }

    func testSystemSpeakerStaysPendingUntilTheDiarizerSettlesAndMayBeCorrected() async throws {
        let system = FakeSpeech([[token("▁tak", 0.2, 0.5)], [token("▁nie", 1.2, 1.5)]])
        let tentative = LiveDiarization(spans: [LiveSpeakerSpan(slot: 0, start: 0, end: 0.6, isFinal: false)],
                                        finalizedUntil: 0)
        let settled = LiveDiarization(spans: [LiveSpeakerSpan(slot: 3, start: 0, end: 0.6, isFinal: true),
                                              LiveSpeakerSpan(slot: 0, start: 1.1, end: 1.6, isFinal: false)],
                                      finalizedUntil: 1.0)
        let live = transcriber(system: system, diarizer: FakeDiarizer([tentative, settled], final: settled))
        try await live.start()

        try await live.feed(second, track: .system, at: 0)
        let first = await live.snapshot()
        XCTAssertEqual(first.words.first?.speakerID, "slot-0")
        XCTAssertEqual(first.words.first?.speakerState, .pending)

        try await live.feed(second, track: .system, at: 1)
        let corrected = await live.snapshot()
        XCTAssertEqual(corrected.words[0].speakerID, "slot-3", "settled diarization corrects the guess")
        XCTAssertEqual(corrected.words[0].speakerState, .final)
        XCTAssertEqual(corrected.words[1].speakerState, .pending)
        XCTAssertTrue(corrected.speakers.allSatisfy { $0.name.hasPrefix("Speaker ") && !$0.isLocal },
                      "slots stay anonymous")
    }

    func testJumpInTimeIsReportedAsGapAndPaddedSoTimesStayAligned() async throws {
        let mic = FakeSpeech()
        let live = transcriber(mic: mic)
        try await live.start()
        try await live.feed(second, track: .microphone, at: 0)
        try await live.feed(second, track: .microphone, at: 3)
        let snapshot = await live.snapshot()
        XCTAssertEqual(snapshot.gaps.count, 1)
        XCTAssertEqual(snapshot.gaps[0].start, 1, accuracy: 1e-6)
        XCTAssertEqual(snapshot.gaps[0].duration, 2, accuracy: 1e-6)
        XCTAssertEqual(mic.samples, 4 * 16_000, "silence fills the gap")
        XCTAssertEqual(snapshot.received["microphone"] ?? 0, 4, accuracy: 1e-6)
    }

    func testCancelKeepsWordsAndStopsTheSession() async throws {
        let live = transcriber(mic: FakeSpeech([[token("▁halo", 0, 0.3)]]))
        try await live.start()
        try await live.feed(second, track: .microphone, at: 0)
        await live.cancel()
        let snapshot = await live.snapshot()
        XCTAssertEqual(snapshot.phase, .cancelled)
        XCTAssertEqual(snapshot.words.map(\.text), ["halo"])
        do { _ = try await live.finish(); XCTFail("finished after cancel") } catch {
            XCTAssertEqual(error as? LiveError, .alreadyFinished)
        }
    }

    func testModelErrorsFailTheSessionWithAMessage() async throws {
        let broken = LiveTranscriber(options: LiveOptions()) { _ in throw LiveError.model("missing encoder") }
        do { try await broken.start(); XCTFail("started without a model") } catch {
            XCTAssertEqual(error as? LiveError, .model("missing encoder"))
        }
        let failed = await broken.snapshot()
        XCTAssertEqual(failed.phase, .failed)
        XCTAssertEqual(failed.error, "Live model error: missing encoder")

        let mic = FakeSpeech()
        mic.failOnProcess = LiveError.model("prediction failed")
        let live = transcriber(mic: mic)
        try await live.start()
        do { try await live.feed(second, track: .microphone, at: 0); XCTFail("model error swallowed") } catch {}
        let snapshot = await live.snapshot()
        XCTAssertEqual(snapshot.phase, .failed)
    }

    func testByDefaultAMicrophoneWordRepeatingTheSystemAudioStaysInTheTranscript() async throws {
        // Both people saying "tak" at once is real speech; the echo guess must not hide it unasked.
        let mic = FakeSpeech([[token("▁Tak", 1.0, 1.4)]])
        let system = FakeSpeech([[token("▁tak", 1.2, 1.6)]])
        let live = transcriber(mic: mic, system: system, options: LiveOptions(diarizeSystem: false))
        try await live.start()
        try await live.feed(second, track: .microphone, at: 0)
        try await live.feed(second, track: .system, at: 0)
        let snapshot = try await live.finish()
        XCTAssertEqual(snapshot.words.filter(\.isBleed).count, 0)
        XCTAssertEqual(snapshot.transcript.segments.map(\.speakerID), ["local", "remote"])
    }

    func testCancelWhileModelsLoadKeepsTheSessionCancelled() async throws {
        let live = LiveTranscriber(options: LiveOptions()) { _ in
            try await Task.sleep(for: .milliseconds(300))
            return LiveEngines(description: "fake", speech: [.microphone: FakeSpeech()], diarizer: nil)
        }
        let loading = Task { try await live.start() }
        try await Task.sleep(for: .milliseconds(50))
        await live.cancel()
        try? await loading.value
        let snapshot = await live.snapshot()
        XCTAssertEqual(snapshot.phase, .cancelled)
        do { try await live.feed(second, track: .microphone, at: 0); XCTFail("fed after cancel") } catch {
            XCTAssertEqual(error as? LiveError, .alreadyFinished)
        }
    }

    func testOptInBleedSuppressionMarksAndLeavesOutRepeatedMicrophoneWords() async throws {
        let mic = FakeSpeech([[token("▁Cześć", 1.0, 1.4), token("▁hej", 3.0, 3.3)]])
        let system = FakeSpeech([[token("▁cześć,", 1.2, 1.6)]])
        let live = transcriber(mic: mic, system: system, options: LiveOptions(diarizeSystem: false, suppressBleed: true))
        try await live.start()
        try await live.feed(second, track: .microphone, at: 0)
        try await live.feed(second, track: .system, at: 0)
        let snapshot = try await live.finish()
        XCTAssertEqual(snapshot.words.filter(\.isBleed).map(\.text), ["Cześć"])
        XCTAssertEqual(snapshot.transcript.segments.map(\.speakerID), ["remote", "local"])
        XCTAssertFalse(snapshot.transcript.text.contains("Cześć"))
    }

    func testUnsupportedLanguageIsRejectedBeforeLoadingModels() async throws {
        let live = LiveTranscriber(options: LiveOptions(language: "xx"))
        do { try await live.start(); XCTFail("accepted unknown language") } catch {
            XCTAssertEqual(error as? LiveError, .unsupportedLanguage("xx"))
        }
        XCTAssertTrue(LiveEngineFactory.supportedLanguages.contains("pl"))
    }
}

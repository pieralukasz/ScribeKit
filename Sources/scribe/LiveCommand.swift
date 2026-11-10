import AVFoundation
import Foundation
import ScribeKit

/// `scribe live`: replays recorded tracks through ``LiveTranscriber`` exactly as a live
/// recording would feed it, and measures what a client would see.
///
///     scribe live <microphone.wav|-> <system.wav|-> [--lang pl] [--latency 560|1120|2080]
///                 [--paced] [--chunk-ms 100] [--no-diarize] [--suppress-bleed] [--out transcript.json] [--metrics m.json]
///
/// Without `--paced` audio is fed as fast as the models take it (throughput, RTFx). With
/// `--paced` each chunk waits for its real time, so the measured delays are live delays.
@MainActor
enum LiveCommand {
    struct Metrics: Encodable {
        var engine: String
        var method: String
        var audioSeconds: Double
        var chunkMs: Int
        var modelLoadSeconds: Double
        var processingSeconds: Double
        var rtfx: Double
        var peakResidentMB: Double
        var words: Int
        var wordsPerTrack: [String: Int]
        var bleedWords: Int
        var speakers: Int
        var textCorrections: Int
        var speakerCorrections: Int
        var gaps: Int
        /// Seconds from the end of a word in the audio to its first appearance (paced only).
        var firstSeenDelay: Percentiles?
        var textFinalDelay: Percentiles?
        var speakerFinalDelay: Percentiles?
        var maxFeedSeconds: Double
    }

    struct Percentiles: Encodable {
        var p50: Double, p90: Double, max: Double, count: Int
        init?(_ values: [Double]) {
            guard !values.isEmpty else { return nil }
            let sorted = values.sorted()
            func at(_ q: Double) -> Double { sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * q))] }
            p50 = at(0.5); p90 = at(0.9); max = sorted.last!; count = values.count
        }
    }

    static func run(_ args: [String], option: (String) -> String?, flag: (String) -> Bool) async throws {
        let language = option("--lang") ?? "pl"
        let latency = option("--latency").flatMap(Int.init).flatMap(LiveLatency.init(rawValue:)) ?? .ms1120
        let chunkMs = option("--chunk-ms").flatMap(Int.init) ?? 100
        let outPath = option("--out")
        let metricsPath = option("--metrics")
        let paced = flag("--paced")
        let diarize = !flag("--no-diarize")
        let suppressBleed = flag("--suppress-bleed")
        guard args.count >= 3 else { throw LiveError.model("usage: scribe live <microphone.wav|-> <system.wav|-> …") }
        let tracks: [(LiveTrack, [Float])] = try [(LiveTrack.microphone, args[1]), (.system, args[2])]
            .filter { $0.1 != "-" }
            .map { ($0.0, try readMono16k(URL(fileURLWithPath: $0.1))) }

        let clock = ContinuousClock()
        let live = LiveTranscriber(options: LiveOptions(language: language, latency: latency, diarizeSystem: diarize, suppressBleed: suppressBleed))
        let loadStart = clock.now
        try await live.start()
        let loadSeconds = seconds(clock.now - loadStart)

        let chunk = Int(LiveTranscriber.SAMPLE_RATE) * chunkMs / 1000
        let total = tracks.map(\.1.count).max() ?? 0
        var firstSeen: [String: Double] = [:], textFinal: [String: Double] = [:], speakerFinal: [String: Double] = [:]
        var lastText: [String: String] = [:], lastSpeaker: [String: String?] = [:]
        var textCorrections = 0, speakerCorrections = 0, maxFeed = 0.0
        var seenRevision = 0
        let started = clock.now

        func observe(_ snapshot: LiveSnapshot) {
            let now = seconds(clock.now - started)
            for word in snapshot.changes(since: seenRevision) {
                if firstSeen[word.id] == nil { firstSeen[word.id] = now - word.end }
                else {
                    if lastText[word.id] != word.text { textCorrections += 1 }
                    if let previous = lastSpeaker[word.id], previous != nil, previous != word.speakerID { speakerCorrections += 1 }
                }
                lastText[word.id] = word.text
                lastSpeaker[word.id] = word.speakerID
                if word.textState == .final, textFinal[word.id] == nil { textFinal[word.id] = now - word.end }
                if word.speakerState == .final, speakerFinal[word.id] == nil { speakerFinal[word.id] = now - word.end }
            }
            seenRevision = snapshot.revision
        }

        var offset = 0
        while offset < total {
            if paced {
                let due = Double(offset + chunk) / LiveTranscriber.SAMPLE_RATE
                let wait = due - seconds(clock.now - started)
                if wait > 0 { try await Task.sleep(for: .milliseconds(Int(wait * 1000))) }
            }
            for (track, samples) in tracks where offset < samples.count {
                let slice = Array(samples[offset..<min(offset + chunk, samples.count)])
                let feedStart = clock.now
                try await live.feed(slice, track: track, at: Double(offset) / LiveTranscriber.SAMPLE_RATE)
                maxFeed = max(maxFeed, seconds(clock.now - feedStart))
            }
            observe(await live.snapshot())
            offset += chunk
        }
        let final = try await live.finish()
        observe(final)
        let processing = seconds(clock.now - started)
        let audio = Double(total) / LiveTranscriber.SAMPLE_RATE

        let metrics = Metrics(
            engine: final.engine, method: paced ? "paced replay (real-time feed)" : "unpaced replay (throughput)",
            audioSeconds: audio, chunkMs: chunkMs, modelLoadSeconds: loadSeconds, processingSeconds: processing,
            rtfx: audio / max(processing, 1e-9), peakResidentMB: peakResidentMB(),
            words: final.words.count,
            wordsPerTrack: Dictionary(grouping: final.words, by: { $0.track.rawValue }).mapValues(\.count),
            bleedWords: final.words.filter(\.isBleed).count, speakers: final.speakers.count,
            textCorrections: textCorrections, speakerCorrections: speakerCorrections, gaps: final.gaps.count,
            firstSeenDelay: paced ? Percentiles(Array(firstSeen.values)) : nil,
            textFinalDelay: paced ? Percentiles(Array(textFinal.values)) : nil,
            speakerFinalDelay: paced ? Percentiles(Array(speakerFinal.values)) : nil,
            maxFeedSeconds: maxFeed)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let metricsData = try encoder.encode(metrics)
        if let metricsPath { try metricsData.write(to: URL(fileURLWithPath: metricsPath)) }
        FileHandle.standardError.write(metricsData)
        FileHandle.standardError.write(Data("\n".utf8))
        if let outPath {
            try encoder.encode(final).write(to: URL(fileURLWithPath: outPath))
        } else {
            print(TranscriptRenderer.text(final.transcript))
        }
    }

    static func readMono16k(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
        guard let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))
        else { return [] }
        try file.read(into: input)
        if file.processingFormat.sampleRate == 16_000, file.processingFormat.channelCount == 1 {
            return Array(UnsafeBufferPointer(start: input.floatChannelData![0], count: Int(input.frameLength)))
        }
        guard let converter = AVAudioConverter(from: file.processingFormat, to: target),
              let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: AVAudioFrameCount(Double(file.length) * 16_000 / file.processingFormat.sampleRate) + 1024)
        else { return [] }
        var fed = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if fed { status.pointee = .endOfStream; return nil }
            fed = true
            status.pointee = .haveData
            return input
        }
        if let error { throw error }
        return Array(UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength)))
    }

    static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }

    static func peakResidentMB() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_maxrss) / 1_048_576 // bytes on macOS
    }
}

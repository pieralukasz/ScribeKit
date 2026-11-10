import Foundation
import ScribeKit

/// Command line front end for ScribeKit.
///
///     scribe prepare [--diarize]
///     scribe <audio> [--lang pl] [--no-diarize] [--speakers N] [--format md|txt|srt|vtt|json]
///     scribe conversation <microphone.wav> <system.wav> [--lang pl] [--me "Name"] [--format …]
///     scribe live <microphone.wav|-> <system.wav|-> [--lang pl] [--latency 1120] [--paced] [--out f.json]
@main
struct ScribeCLI {
    static func main() async {
        var args = Array(CommandLine.arguments.dropFirst())
        guard let first = args.first else { return usage() }

        func option(_ name: String) -> String? {
            guard let index = args.firstIndex(of: name), index + 1 < args.count else { return nil }
            let value = args[index + 1]
            args.removeSubrange(index...(index + 1))
            return value
        }
        func flag(_ name: String) -> Bool {
            guard let index = args.firstIndex(of: name) else { return false }
            args.remove(at: index)
            return true
        }

        let scribe = Scribe()
        let clock = ContinuousClock()
        let started = clock.now
        let progress: @Sendable (ModelProgress) -> Void = { update in
            let percent = update.fraction.map { " \(Int($0 * 100))%" } ?? ""
            fputs("\r\(update.model.rawValue):\(percent) \(update.detail)      ", stderr)
        }
        let stages: @Sendable (TranscriptionStage) -> Void = { stage in fputs("\n· \(stage)\n", stderr) }

        do {
            if first == "prepare" {
                try await scribe.prepare(diarization: flag("--diarize"), progress: progress)
                fputs("\nModels ready.\n", stderr)
                return
            }
            if first == "live" {
                try await LiveCommand.run(args, option: option, flag: flag)
                return
            }

            let language = option("--lang")
            let format = TranscriptFormat(rawValue: option("--format") ?? "md") ?? .markdown
            let speakers = option("--speakers").flatMap(Int.init)
            let me = option("--me") ?? "Me"
            let diarize = !flag("--no-diarize")
            let options = TranscriptionOptions(language: language, diarize: diarize,
                                               speakerCount: speakers, localSpeakerName: me)
            try await scribe.prepare(diarization: diarize, progress: progress)

            let transcript: Transcript
            if first == "conversation" {
                guard args.count >= 3 else { return usage() }
                transcript = try await scribe.transcribeConversation(
                    microphone: URL(fileURLWithPath: args[1]), system: URL(fileURLWithPath: args[2]),
                    options: options, progress: stages)
            } else {
                transcript = try await scribe.transcribe(URL(fileURLWithPath: first), options: options,
                                                         progress: stages)
            }
            print(try TranscriptRenderer.render(transcript, as: format))
            let elapsed = clock.now - started
            fputs("Done: \(transcript.wordCount) words, \(transcript.speakers.count) speakers, "
                  + "\(Int(transcript.duration))s of audio in \(elapsed.formatted(.units(allowed: [.seconds], fractionalPart: .show(length: 1)))).\n", stderr)
        } catch {
            fputs("\nerror: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    static func usage() {
        print("""
        usage: scribe prepare [--diarize]
               scribe <audio> [--lang pl] [--no-diarize] [--speakers N] [--format md|txt|srt|vtt|json]
               scribe conversation <microphone.wav> <system.wav> [--lang pl] [--me "Name"] [--format …]
               scribe live <microphone.wav|-> <system.wav|-> [--lang pl] [--latency 560|1120|2080] [--paced]
                           [--chunk-ms 100] [--no-diarize] [--out live.json] [--metrics metrics.json]
        """)
    }
}

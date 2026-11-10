# ScribeKit

Local speech-to-text with speakers for Swift. ScribeKit wraps [FluidAudio](https://github.com/FluidInference/FluidAudio)'s
Parakeet TDT v3 and offline diarization in a small API that returns a transcript with who said what, and renders it as
Markdown, plain text, SRT, WebVTT or JSON.

Everything runs on the Apple Neural Engine. No server, no API key, no Python.

- 25 European languages, automatic language detection
- Speaker diarization, or two-track "conversation" mode for calls (you on the microphone, everyone else on system audio)
- Echo removal: words the microphone picked up from the speakers are dropped
- Word timings, segments split on pauses and speaker turns
- Pure-Swift segment builder and renderers you can use with any ASR

Documentation: **[scribekit.lucaspiera.com](https://scribekit.lucaspiera.com)**

Used by [EchoPad](https://github.com/pieralukasz/echopad).

## Requirements

macOS 14 or iOS 17, Swift 6. Models (about 460 MB for speech, 20 MB for diarization) are downloaded from Hugging Face on
first use and cached in `~/Library/Application Support/FluidAudio`.

## Install

```swift
.package(url: "https://github.com/pieralukasz/ScribeKit.git", from: "0.1.0")
```

## Use

```swift
import ScribeKit

let scribe = Scribe.shared
try await scribe.prepare(diarization: true)          // optional: download and load ahead of time

// One file, speakers detected automatically
let transcript = try await scribe.transcribe(url, options: .init(language: "pl"))
for segment in transcript.segments {
    print(transcript.speaker(for: segment.speakerID)?.name ?? "", segment.text)
}

// A call recorded as two aligned tracks (see SystemAudioKit)
let call = try await scribe.transcribeConversation(
    microphone: micURL, system: systemURL,
    options: .init(localSpeakerName: "Łukasz"))

// Output
let markdown = TranscriptRenderer.markdown(call, options: .init(title: "Weekly sync"))
let subtitles = try TranscriptRenderer.render(call, as: .srt)
```

Plain text only:

```swift
let text = try await scribe.transcribeText(url)
```

## Live transcription

`LiveTranscriber` streams a two-track recording (microphone + system audio, 16 kHz mono, one
timeline) into a transcript that corrects itself. It runs
[Nemotron Unified ASR 0.6B](https://huggingface.co/FluidInference/nemotron-labs-unified-asr-0.6b-coreml)
(CoreML fp16, 25 European languages, Polish by default) with a 560, 1120 (default) or 2080 ms
look-ahead, and [LS-EEND](https://huggingface.co/FluidInference/ls-eend-coreml) to split the system
track into anonymous speakers (`Speaker 1`, `Speaker 2`…, never matched to real people). The batch
API above (Parakeet v3) is unchanged.

```swift
let live = LiveTranscriber(options: LiveOptions(language: "pl", latency: .ms1120))
try await live.start()                                 // downloads models on first use
try await live.feed(samples, track: .system, at: 12.0) // seconds on the recording's timeline
let now = await live.snapshot()                        // any time, e.g. for an agent
let new = now.changes(since: lastSeenRevision)         // words added or corrected
let final = try await live.finish()                    // flushes the last words
```

Every word has a stable `id` and the `revision` that last changed it. `textState` and
`speakerState` are `pending` until the model can no longer change them (the last word of a batch
may still get its continuation; a speaker settles once LS-EEND finalizes that stretch). Every
microphone word stays in `snapshot.transcript` by default. `LiveOptions(suppressBleed: true)`
(`scribe live --suppress-bleed`) opts into a text guess for speakers without headphones: a
microphone word repeating a system word within 0.8 s is marked `isBleed` and left out of
`snapshot.transcript`; it also hides a real "tak" said by both sides at once. A jump in `at` is recorded as a gap and
filled with silence, so times stay aligned. `cancel()` stops without flushing.

`scribe live <microphone.wav|-> <system.wav|-> [--latency 560|1120|2080] [--paced] [--suppress-bleed]` replays files
through the same path and prints delays, RTFx and memory (`--paced` feeds in real time).

## Command line

```bash
swift run -c release scribe prepare --diarize
swift run -c release scribe meeting.m4a --lang en --format md
swift run -c release scribe conversation mic.wav system.wav --me "Łukasz"
```

## License

MIT. The models are released by NVIDIA (Parakeet, CC-BY-4.0) and pyannote (diarization) and converted to Core ML by
FluidInference; check their licenses before shipping.

Model weights are not part of this package and are downloaded on first use under their own
licenses: Parakeet TDT 0.6B v3 (CC-BY-4.0, NVIDIA), Nemotron Labs Unified ASR 0.6B
(OpenMDW-1.1, NVIDIA; keep its license text and notices when redistributing), LS-EEND (MIT).
FluidAudio, which runs them, is Apache-2.0.

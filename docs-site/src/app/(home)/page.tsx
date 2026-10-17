import { AudioLines, Blocks, Cpu, FileText, Phone, Users } from "lucide-react";
import Link from "next/link";
import type { ReactNode } from "react";
import { HomeCode } from "@/components/home-code";
import { appName, asset, authorUrl, repoUrl } from "@/lib/shared";

const features = [
  {
    icon: Cpu,
    title: "Parakeet v3 on the Neural Engine",
    text: "NVIDIA’s TDT 0.6B v3 through FluidAudio’s Core ML port. 25 European languages, fully offline once the model is downloaded.",
  },
  {
    icon: Users,
    title: "Speakers, not just words",
    text: "Offline diarization labels who spoke when. Speakers are numbered in the order they first talk, ready to rename.",
  },
  {
    icon: Phone,
    title: "Call mode for two tracks",
    text: "Give it the microphone and the system audio. Everything on the mic is you; only the other side is diarized.",
  },
  {
    icon: AudioLines,
    title: "Echo removal",
    text: "Words your microphone picked up from the speakers are matched against the system track and dropped.",
  },
  {
    icon: FileText,
    title: "Markdown, SRT, WebVTT, JSON",
    text: "Front matter for note apps, subtitle cues split at clause boundaries, and a Codable transcript model.",
  },
  {
    icon: Blocks,
    title: "Bring your own recognizer",
    text: "The segment builder and renderers are plain Swift with no models, so they work with any speech recognizer.",
  },
];

const example = `import ScribeKit

let transcript = try await Scribe.shared.transcribe(
    meetingURL,
    options: .init(language: "en")
)

for segment in transcript.segments {
    let name = transcript.speaker(for: segment.speakerID)?.name ?? ""
    print("\\(name): \\(segment.text)")
}

let srt = try TranscriptRenderer.render(transcript, as: .srt)`;

const install = `dependencies: [
    .package(
        url: "https://github.com/pieralukasz/ScribeKit.git",
        from: "0.1.0"
    ),
]`;

export default function HomePage() {
  return (
    <main className="flex flex-col">
      <section className="border-b">
        <div className="mx-auto grid w-full max-w-6xl gap-12 px-6 pt-16 pb-16 lg:grid-cols-[minmax(0,5fr)_minmax(0,7fr)] lg:items-start lg:pt-20">
          <div className="min-w-0">
            <div className="mb-6 flex flex-wrap items-center gap-3">
              {/* biome-ignore lint/performance/noImgElement: static export serves plain files */}
              <img
                src={asset("/logo.svg")}
                alt=""
                width={40}
                height={40}
                className="rounded-lg"
              />
              <span className="rounded-md border bg-fd-card px-2 py-1 font-mono text-xs text-fd-muted-foreground max-sm:text-balance">
                Swift package · MIT · macOS 14 and iOS 17
              </span>
            </div>
            <h1 className="font-mono text-4xl font-bold tracking-tight sm:text-5xl">
              Transcripts with <span className="text-fd-primary">speakers</span>
              , <span className="whitespace-nowrap">on&#8209;device.</span>
            </h1>
            <p className="mt-5 text-lg text-fd-muted-foreground">
              ScribeKit turns audio files into transcripts that know who said
              what. NVIDIA Parakeet v3 and speaker diarization run on the Apple
              Neural Engine: no server, no API key, no Python.
            </p>
            <CallToAction className="mt-8" />
          </div>
          <div className="grid min-w-0 gap-6 [&>div]:min-w-0">
            <div>
              <CodeLabel>Package.swift</CodeLabel>
              <HomeCode lang="swift" code={install} />
              <p className="mt-3 text-sm text-fd-muted-foreground">
                Swift 6. The models (about 460 MB for speech, 20 MB for
                speakers) download from Hugging Face on first use and are cached
                on disk.
              </p>
            </div>
            <div>
              <CodeLabel>Transcribe a meeting</CodeLabel>
              <HomeCode lang="swift" code={example} />
            </div>
          </div>
        </div>
      </section>

      <Section
        eyebrow="What you get"
        title="Speech to text with the hard parts done"
      >
        <div className="grid gap-4 sm:grid-cols-2 lg:grid-cols-3">
          {features.map((feature) => (
            <div
              key={feature.title}
              className="rounded-lg border bg-fd-card p-6"
            >
              <feature.icon className="mb-4 size-5 text-fd-primary" />
              <h3 className="font-mono text-sm font-semibold">
                {feature.title}
              </h3>
              <p className="mt-1 text-sm text-fd-muted-foreground">
                {feature.text}
              </p>
            </div>
          ))}
        </div>
      </Section>

      <section className="mx-auto w-full max-w-6xl px-6 pb-24">
        <div className="rounded-lg border bg-fd-card px-8 py-12">
          <h2 className="font-mono text-2xl font-bold tracking-tight sm:text-3xl">
            A few lines to a transcript
          </h2>
          <p className="mt-3 max-w-xl text-fd-muted-foreground">
            Add the package, call transcribe, render the result. The guides
            cover call recordings, output formats and model handling.
          </p>
          <CallToAction className="mt-8" />
        </div>
      </section>

      <footer className="border-t py-10 text-center text-sm text-fd-muted-foreground">
        <p>
          {appName} is MIT licensed. Made by{" "}
          <a
            className="font-medium text-fd-foreground underline underline-offset-4"
            href={authorUrl}
          >
            Lucas Piera
          </a>
          .
        </p>
        <p className="mt-2">
          Built on{" "}
          <a
            className="underline"
            href="https://github.com/FluidInference/FluidAudio"
          >
            FluidAudio
          </a>
          , NVIDIA Parakeet and pyannote.
        </p>
      </footer>
    </main>
  );
}

function CallToAction({ className }: { className?: string }) {
  return (
    <div className={`flex flex-wrap gap-3 ${className ?? ""}`}>
      <Link
        href="/docs"
        className="rounded-md bg-fd-primary px-5 py-2.5 font-medium text-fd-primary-foreground transition hover:opacity-90"
      >
        Read the docs
      </Link>
      <a
        href={repoUrl}
        className="inline-flex items-center gap-2 rounded-md border bg-fd-card px-5 py-2.5 font-medium transition hover:bg-fd-accent"
      >
        <GitHubMark /> View on GitHub
      </a>
    </div>
  );
}

function CodeLabel({ children }: { children: ReactNode }) {
  return (
    <p className="mb-2 font-mono text-xs font-medium text-fd-muted-foreground">
      {children}
    </p>
  );
}

function Section({
  eyebrow,
  title,
  children,
}: {
  eyebrow: string;
  title: string;
  children: ReactNode;
}) {
  return (
    <section className="mx-auto w-full max-w-6xl px-6 py-16">
      <p className="font-mono text-xs font-medium uppercase tracking-wider text-fd-primary">
        {eyebrow}
      </p>
      <h2 className="mt-2 mb-8 font-mono text-2xl font-bold tracking-tight sm:text-3xl">
        {title}
      </h2>
      {children}
    </section>
  );
}

function GitHubMark() {
  return (
    <svg
      viewBox="0 0 16 16"
      className="size-4"
      fill="currentColor"
      aria-hidden="true"
    >
      <path d="M8 0C3.58 0 0 3.58 0 8c0 3.54 2.29 6.53 5.47 7.59.4.07.55-.17.55-.38 0-.19-.01-.82-.01-1.49-2.01.37-2.53-.49-2.69-.94-.09-.23-.48-.94-.82-1.13-.28-.15-.68-.52-.01-.53.63-.01 1.08.58 1.23.82.72 1.21 1.87.87 2.33.66.07-.52.28-.87.51-1.07-1.78-.2-3.64-.89-3.64-3.95 0-.87.31-1.59.82-2.15-.08-.2-.36-1.02.08-2.12 0 0 .67-.21 2.2.82.64-.18 1.32-.27 2-.27.68 0 1.36.09 2 .27 1.53-1.04 2.2-.82 2.2-.82.44 1.1.16 1.92.08 2.12.51.56.82 1.27.82 2.15 0 3.07-1.87 3.75-3.65 3.95.29.25.54.73.54 1.48 0 1.07-.01 1.93-.01 2.2 0 .21.15.46.55.38A8.013 8.013 0 0016 8c0-4.42-3.58-8-8-8z" />
    </svg>
  );
}

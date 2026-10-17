import { Analytics } from "@vercel/analytics/next";
import type { Metadata } from "next";
import { IBM_Plex_Sans, JetBrains_Mono } from "next/font/google";
import { Provider } from "@/components/provider";
import { appName, tagline } from "@/lib/shared";
import "./global.css";

const sans = IBM_Plex_Sans({
  subsets: ["latin", "latin-ext"],
  variable: "--font-plex-sans",
});

const mono = JetBrains_Mono({
  subsets: ["latin", "latin-ext"],
  variable: "--font-jetbrains-mono",
});

/** DOCS_SITE_URL wins; on Vercel the production domain is set automatically. */
function siteUrl() {
  if (process.env.DOCS_SITE_URL) return process.env.DOCS_SITE_URL;
  const vercelHost = process.env.VERCEL_PROJECT_PRODUCTION_URL;
  return vercelHost ? `https://${vercelHost}` : "http://localhost:3000";
}

export const metadata: Metadata = {
  metadataBase: new URL(siteUrl()),
  title: {
    default: `${appName}: ${tagline}`,
    template: `%s · ${appName}`,
  },
  description:
    "ScribeKit is a Swift package for on-device transcription with speakers: NVIDIA Parakeet v3 and speaker diarization on the Apple Neural Engine, with Markdown, SRT, WebVTT and JSON output. MIT licensed.",
};

export default function Layout({ children }: LayoutProps<"/">) {
  return (
    <html
      lang="en"
      className={`${sans.className} ${sans.variable} ${mono.variable}`}
      suppressHydrationWarning
    >
      <body className="flex flex-col min-h-screen">
        <Provider>{children}</Provider>
        <Analytics />
      </body>
    </html>
  );
}

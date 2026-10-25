import Image from 'next/image'
import { AppleLogo, ArrowRight, Check } from '@phosphor-icons/react/ssr'
import { Reveal } from '@/components/reveal'
import { DownloadButton } from '@/components/download-button'
import { DOWNLOAD_URL, GITHUB_URL } from '@/lib/site-metadata'
import { sitePath } from '@/lib/site-paths'

const PROOF = ['Free under the GPL v3', 'macOS 15 or later', 'Apple Silicon and Intel', 'No account']

export function Hero() {
  return (
    <section id="top" className="px-4 pt-24 pb-16 sm:pb-24">
      <div className="mx-auto mt-16 max-w-6xl">
        <Reveal immediate animateOnEnter>
          <h1 className="hero-heading max-w-[680px] pb-2 text-5xl font-semibold tracking-tight sm:text-6xl">
            Turn a cluttered folder <br className="hidden sm:block" />
            into a plan you approve
          </h1>
          <p className="mt-6 max-w-[680px] text-lg text-muted-foreground">
            Sorty is a free, open source Mac app. It reads a folder, proposes new
            folders and file names with the AI model you choose, and moves nothing
            until you say so. Every run can be undone from History.
          </p>

          <div className="mt-8 flex flex-wrap items-center gap-x-6 gap-y-4">
            <DownloadButton
              id="download"
              href={DOWNLOAD_URL}
              analyticsLocation="hero"
              className="gap-2 rounded-lg px-3 py-2 text-base font-semibold"
            >
              <AppleLogo weight="fill" className="size-4" aria-hidden />
              Download Sorty for Mac
            </DownloadButton>
            <a
              href={GITHUB_URL}
              target="_blank"
              rel="noreferrer"
              className="group inline-flex items-center gap-2 rounded-sm text-base font-medium text-muted-foreground transition-colors duration-300 ease-fluid hover:text-foreground focus-visible:outline-2 focus-visible:outline-offset-4 focus-visible:outline-ring"
              data-analytics-action="source_opened"
              data-analytics-component="text_link"
              data-analytics-location="hero"
              data-analytics-target="github"
            >
              Read the source on GitHub
              <ArrowRight className="size-4 transition-transform duration-300 ease-fluid group-hover:translate-x-1" aria-hidden />
            </a>
          </div>

          <ul className="mt-8 flex flex-wrap gap-x-6 gap-y-2 text-sm text-muted-foreground">
            {PROOF.map((item) => (
              <li key={item} className="flex items-center gap-2">
                <Check className="size-4 text-primary" aria-hidden />
                {item}
              </li>
            ))}
          </ul>
        </Reveal>

        <Reveal delay={150} className="mt-16">
          <figure className="glass-surface rounded-2xl border border-border bg-card p-2">
            <Image
              src={sitePath('/sorty-apply.webp?v=lossless-1')}
              alt="Sorty showing a proposed organization plan, with each file move listed for review before anything is applied."
              width={1102}
              height={754}
              preload
              className="w-full rounded-lg"
            />
          </figure>
        </Reveal>
      </div>
    </section>
  )
}

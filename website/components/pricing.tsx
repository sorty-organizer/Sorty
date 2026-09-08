import { Code2, Cpu, FolderOpen, Hammer, Heart, Infinity, UsersRound } from 'lucide-react'
import { Reveal } from '@/components/reveal'
import { GithubIcon } from '@/components/github-icon'
import { DownloadButton } from '@/components/download-button'

const GITHUB_URL = 'https://github.com/sorty-organizer/Sorty'
const SPONSOR_URL = 'https://github.com/sponsors/shirishpothi'
const DOWNLOAD_URL = `${GITHUB_URL}/releases/latest/download/Sorty.zip`

const INCLUDED = [
  {
    icon: Infinity,
    text: 'All features included',
  },
  {
    icon: FolderOpen,
    text: 'Unlimited folders and organization runs',
  },
  {
    icon: Cpu,
    text: 'Bring your own AI provider or run local',
  },
  {
    icon: Code2,
    text: 'Full source code under the GPL v3',
  },
  {
    icon: UsersRound,
    text: 'Community support on GitHub',
  },
]

export function Pricing() {
  return (
    <section
      id="pricing"
      className="section-seam page-section px-4 py-20 sm:py-28"
    >
      <div className="mx-auto max-w-3xl">
        <Reveal className="text-center">
          <p className="text-sm font-medium text-primary">Pricing &amp; availability</p>
          <h2 className="mt-3 text-balance text-3xl font-semibold tracking-tight sm:text-4xl">
            Free and open source
          </h2>
          <p className="mt-4 text-pretty text-muted-foreground">
            Sorty has no subscription or activation code. Cloud AI providers may
            charge for usage. Donations support development.
          </p>
        </Reveal>

        <Reveal delay={120} className="mt-12">
          <div className="relative overflow-hidden rounded-3xl border border-primary/30 bg-card/50 p-8 backdrop-blur-xl sm:p-10">
            <div
              aria-hidden
              className="pointer-events-none absolute -top-24 left-1/2 h-44 w-[28rem] -translate-x-1/2 rounded-[999px] bg-primary/15 blur-3xl"
            />
            <div className="flex flex-col items-start gap-1">
              <span className="rounded-full bg-primary/15 px-3 py-1 text-xs font-medium text-primary">
                GPL v3 · macOS 15+
              </span>
              <div className="mt-5 flex items-end gap-2">
                <span className="text-5xl font-semibold tracking-tight">$0</span>
                <span className="pb-1.5 text-muted-foreground">for the app</span>
              </div>
            </div>

            <ul className="mt-8 space-y-3">
              {INCLUDED.map(({ icon: Icon, text }) => (
                <li key={text} className="flex items-start gap-3 text-sm">
                  <span className="mt-0.5 flex size-5 shrink-0 items-center justify-center rounded-full bg-primary/15 text-primary">
                    <Icon className="size-3.5" />
                  </span>
                  <span className="text-muted-foreground">{text}</span>
                </li>
              ))}
            </ul>

            <div className="mt-9 flex flex-col gap-3 sm:flex-row">
              <DownloadButton
                href={DOWNLOAD_URL}
                analyticsLocation="pricing"
                className="w-full justify-center gap-2 px-6 py-3 text-sm font-medium"
              >
                <span
                  className="text-[17px] leading-none"
                  aria-hidden="true"
                >
                  
                </span>
                Download for Mac
              </DownloadButton>
              <a
                href={GITHUB_URL}
                target="_blank"
                rel="noreferrer"
                className="group flex w-full items-center justify-center gap-2 rounded-full border border-border bg-secondary/50 px-6 py-3 text-sm font-medium text-foreground backdrop-blur-md transition-colors hover:border-amber-300/50 hover:bg-amber-300/10 motion-reduce:transition-none"
                data-analytics-action="source_opened"
                data-analytics-component="cta"
                data-analytics-location="pricing"
                data-analytics-target="build_from_source"
              >
                <span className="relative size-4" aria-hidden="true">
                  <GithubIcon className="absolute inset-0 size-4 transition-all duration-200 group-hover:scale-75 group-hover:opacity-0 motion-reduce:transition-none" />
                  <Hammer className="absolute inset-0 size-4 scale-75 -rotate-12 text-amber-300 opacity-0 drop-shadow-[0_0_8px_rgba(252,211,77,0.75)] transition-all duration-200 group-hover:scale-110 group-hover:rotate-0 group-hover:opacity-100 motion-reduce:transition-none" />
                </span>
                Build from source
              </a>
              <a
                href={SPONSOR_URL}
                target="_blank"
                rel="noreferrer"
                className="btn-support flex w-full items-center justify-center gap-2 rounded-full px-6 py-3 text-sm font-medium"
                data-analytics-action="support_opened"
                data-analytics-component="cta"
                data-analytics-location="pricing"
                data-analytics-target="github_sponsors"
              >
                <Heart className="support-heart-icon size-4" />
                Donate
              </a>
            </div>

            <p className="mt-5 text-center text-xs text-muted-foreground">
              Apple Silicon &amp; Intel · Works with iCloud Drive, Dropbox, and
              external drives · Donations are optional
            </p>
          </div>
        </Reveal>
      </div>
    </section>
  )
}

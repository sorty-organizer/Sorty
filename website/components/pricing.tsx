import { AppleLogo, Check, Heart } from '@phosphor-icons/react/ssr'
import { Reveal } from '@/components/reveal'
import { DownloadButton } from '@/components/download-button'
import { DOWNLOAD_URL, GITHUB_URL, SPONSOR_URL } from '@/lib/site-metadata'

const INCLUDED = [
  'Every feature, with no paid tier',
  'Unlimited folders and organization runs',
  'Your own AI provider, or a local model',
  'Full source code under the GPL v3',
  'Community support on GitHub',
]

export function Pricing() {
  return (
    <section id="pricing" className="scroll-mt-24 px-4 py-24">
      <div className="mx-auto grid max-w-6xl items-start gap-12 md:grid-cols-12">
        <Reveal className="md:col-span-5">
          <p className="text-sm font-medium text-primary">Pricing</p>
          <h2 className="mt-4 text-4xl font-semibold tracking-tight">
            Free to download, free to keep
          </h2>
          <p className="mt-4 text-base text-muted-foreground">
            No subscription, no activation code, no account. Cloud AI providers
            bill you directly for their usage. Local models cost nothing to run.
          </p>
        </Reveal>

        <Reveal delay={120} className="md:col-span-7">
          <div className="glass-surface rounded-3xl bg-card p-8">
            <div className="flex items-baseline gap-2">
              <span className="text-6xl font-semibold tracking-tight">$0</span>
              <span className="text-base text-muted-foreground">for the app, forever</span>
            </div>

            <ul className="mt-8 grid gap-4 sm:grid-cols-2">
              {INCLUDED.map((text) => (
                <li key={text} className="flex items-start gap-2 text-base">
                  <Check className="mt-1 size-4 shrink-0 text-primary" aria-hidden />
                  {text}
                </li>
              ))}
            </ul>

            <div className="mt-8 flex flex-wrap items-center gap-x-6 gap-y-4">
              <DownloadButton
                href={DOWNLOAD_URL}
                analyticsLocation="pricing"
                className="gap-2 rounded-lg px-3 py-2 text-base font-semibold"
              >
                <AppleLogo weight="fill" className="size-4" aria-hidden />
                Download Sorty for Mac
              </DownloadButton>
              <a
                href={GITHUB_URL}
                target="_blank"
                rel="noreferrer"
                className="rounded-sm text-base font-medium text-muted-foreground transition-colors duration-300 ease-fluid hover:text-foreground focus-visible:outline-2 focus-visible:outline-offset-4 focus-visible:outline-ring"
                data-analytics-action="source_opened"
                data-analytics-component="text_link"
                data-analytics-location="pricing"
                data-analytics-target="build_from_source"
              >
                Build from source
              </a>
            </div>

            <p className="mt-8 rounded-2xl bg-secondary p-4 text-sm text-muted-foreground">
              <Heart weight="fill" className="mr-2 inline size-4 align-[-2px] text-primary" aria-hidden />
              Donations are optional and fund ongoing development. If Sorty saves
              you an afternoon,{' '}
              <a
                href={SPONSOR_URL}
                target="_blank"
                rel="noreferrer"
                className="font-medium text-foreground underline decoration-white/30 underline-offset-4 transition-colors duration-300 ease-fluid hover:decoration-white"
                data-analytics-action="support_opened"
                data-analytics-component="text_link"
                data-analytics-location="pricing"
                data-analytics-target="github_sponsors"
              >
                a donation on GitHub Sponsors
              </a>{' '}
              keeps it going.
            </p>
          </div>
        </Reveal>
      </div>
    </section>
  )
}

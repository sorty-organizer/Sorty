import { AppleLogo, ArrowRight } from '@phosphor-icons/react/ssr'
import { Reveal } from '@/components/reveal'
import { DownloadButton } from '@/components/download-button'
import { DOWNLOAD_URL, GITHUB_URL } from '@/lib/site-metadata'

/** Closing call to action. Mirrors the hero CTA so the page ends on one action. */
export function FinalCta() {
  return (
    <section className="px-4 py-24">
      <Reveal className="mx-auto flex max-w-6xl flex-col items-start gap-8 rounded-3xl bg-card p-8 sm:p-12 md:flex-row md:items-end md:justify-between">
        <div className="max-w-[680px]">
          <h2 className="text-4xl font-semibold tracking-tight">
            Point Sorty at your Downloads folder tonight
          </h2>
          <p className="mt-4 text-base text-muted-foreground">
            Free, no account, and every run can be undone from History.
          </p>
        </div>
        <div className="flex flex-wrap items-center gap-x-6 gap-y-4">
          <DownloadButton
            href={DOWNLOAD_URL}
            analyticsLocation="final_cta"
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
            data-analytics-location="final_cta"
            data-analytics-target="github"
          >
            Read the source on GitHub
            <ArrowRight className="size-4 transition-transform duration-300 ease-fluid group-hover:translate-x-1" aria-hidden />
          </a>
        </div>
      </Reveal>
    </section>
  )
}

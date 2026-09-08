import { Heart } from 'lucide-react'
import { SortyLogo } from '@/components/sorty-logo'
import { GithubIcon } from '@/components/github-icon'
import { DiaGradient } from '@/components/dia-gradient'
import { AnalyticsPreferencesButton } from '@/components/analytics-provider'
import { sitePath } from '@/lib/site-paths'

const GITHUB_URL = 'https://github.com/sorty-organizer/Sorty'
const SPONSOR_URL = 'https://github.com/sponsors/shirishpothi'

const COLUMNS = [
  {
    title: 'Product',
    links: [
      { label: 'Features', href: sitePath('/#features') },
      { label: 'Compare organizers', href: sitePath('/compare/') },
      { label: 'Privacy', href: sitePath('/privacy-policy/') },
      { label: 'Pricing', href: sitePath('/#pricing') },
    ],
  },
  {
    title: 'Resources',
    links: [
      { label: 'Ask your AI', href: sitePath('/#ask-ai') },
      { label: 'Changelog', href: sitePath('/changelog/') },
      { label: 'Press kit', href: sitePath('/press/') },
      { label: 'FAQ', href: sitePath('/#faq') },
    ],
  },
  {
    title: 'Project',
    links: [
      { label: 'Source code', href: GITHUB_URL },
      { label: 'Report an issue', href: `${GITHUB_URL}/issues` },
      { label: 'Donate', href: SPONSOR_URL },
    ],
  },
  {
    title: 'Legal',
    links: [
      { label: 'GPL v3 license', href: `${GITHUB_URL}/blob/main/LICENSE` },
      { label: 'Privacy policy', href: sitePath('/privacy-policy/') },
      { label: 'Terms', href: sitePath('/terms/') },
    ],
  },
]

export function SiteFooter() {
  return (
    <footer
      data-analytics-section="footer"
      className="relative isolate overflow-visible px-4 pt-14"
    >
      {/* Blue aurora rising from the floor. It intentionally extends above the
          footer so the glow blends into the previous section instead of ending
          at a visible rectangular edge. */}
      <div className="pointer-events-none absolute inset-x-[-10vw] top-[6vh] bottom-[-16vh] -z-10 [mask-image:linear-gradient(to_bottom,transparent_0%,black_34%,black_100%)]">
        <DiaGradient blur={15} peak={0.98} valley={0.55} strength={0.72} />
      </div>

      <div className="mx-auto grid max-w-6xl grid-cols-2 gap-x-8 gap-y-10 lg:grid-cols-5 lg:gap-10">
        <div className="col-span-2 lg:col-span-1">
          <SortyLogo />
          <p className="mt-4 max-w-xs text-sm leading-relaxed text-muted-foreground">
            AI folder organization for your Mac. Free and open source.
          </p>
          <div className="mt-5 flex items-center gap-2">
            <a
              href={GITHUB_URL}
              target="_blank"
              rel="noreferrer"
              className="flex size-9 items-center justify-center rounded-full border border-border text-muted-foreground transition-colors hover:text-foreground"
              aria-label="GitHub"
              data-analytics-action="source_opened"
              data-analytics-component="icon_link"
              data-analytics-location="footer"
              data-analytics-target="github"
            >
              <GithubIcon className="size-4" />
            </a>
            <a
              href={SPONSOR_URL}
              target="_blank"
              rel="noreferrer"
              className="btn-support flex size-9 items-center justify-center rounded-full"
              aria-label="Donate to support Sorty"
              data-analytics-action="support_opened"
              data-analytics-component="icon_link"
              data-analytics-location="footer"
              data-analytics-target="github_sponsors"
            >
              <Heart className="support-heart-icon size-4" />
            </a>
          </div>
        </div>

        {COLUMNS.map((col) => (
          <div key={col.title}>
            <h3 className="text-sm font-medium">{col.title}</h3>
            <ul className="mt-4 space-y-2.5">
              {col.links.map((link) => (
                <li key={link.label}>
                  <a
                    href={link.href}
                    className="text-sm text-muted-foreground transition-colors hover:text-foreground"
                    data-analytics-action="footer_link_opened"
                    data-analytics-component="text_link"
                    data-analytics-location="footer"
                    data-analytics-target={link.label}
                  >
                    {link.label}
                  </a>
                </li>
              ))}
            </ul>
          </div>
        ))}
      </div>

      <div className="mx-auto mt-12 flex max-w-5xl flex-col items-center justify-between gap-3 border-t border-border pt-6 text-xs text-muted-foreground sm:flex-row">
        <p>© {new Date().getFullYear()} Sorty. Released under the GPL v3.</p>
        <div className="flex items-center gap-3">
          <AnalyticsPreferencesButton className="underline-offset-4 transition-colors hover:text-foreground hover:underline" />
          <span aria-hidden>·</span>
          <p>Made for people with too many files.</p>
        </div>
      </div>

      {/* Oversized faded brand wordmark */}
      <div
        aria-hidden
        className="pointer-events-none relative mt-4 -mb-[18vw] select-none"
      >
        <span className="block bg-gradient-to-b from-sky-100/20 via-sky-200/10 to-sky-300/0 bg-clip-text text-center text-[30vw] font-semibold leading-[0.78] tracking-tight text-transparent [mask-image:linear-gradient(to_bottom,black_0%,black_54%,transparent_88%)]">
          Sorty
        </span>
      </div>
    </footer>
  )
}

import { SortyLogo } from '@/components/sorty-logo'
import { AnalyticsPreferencesButton } from '@/components/analytics-provider'
import { GITHUB_URL, SPONSOR_URL } from '@/lib/site-metadata'
import { sitePath } from '@/lib/site-paths'

const LINKS = [
  { label: 'Features', href: sitePath('/#features') },
  { label: 'Compare organizers', href: sitePath('/compare/') },
  { label: 'Changelog', href: sitePath('/changelog/') },
  { label: 'Ask your AI', href: sitePath('/#ask-ai') },
  { label: 'Press kit', href: sitePath('/press/') },
  { label: 'Source code', href: GITHUB_URL },
  { label: 'Report an issue', href: `${GITHUB_URL}/issues` },
  { label: 'Donate', href: SPONSOR_URL },
]

const LEGAL = [
  { label: 'Privacy policy', href: sitePath('/privacy-policy/') },
  { label: 'Terms', href: sitePath('/terms/') },
  { label: 'GPL v3 license', href: `${GITHUB_URL}/blob/main/LICENSE` },
]

const linkClass =
  'rounded-sm transition-colors duration-300 ease-fluid hover:text-foreground focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-ring'

export function SiteFooter() {
  return (
    <footer data-analytics-section="footer" className="overflow-hidden px-4 pt-16">
      <div className="mx-auto flex max-w-6xl flex-col gap-8 md:flex-row md:items-start md:justify-between">
        <div>
          <SortyLogo />
          <p className="mt-4 max-w-xs text-sm text-muted-foreground">
            AI folder organization for your Mac. Free and open source.
          </p>
        </div>
        <nav aria-label="Footer">
          <ul className="grid grid-cols-2 gap-x-12 gap-y-2 text-sm text-muted-foreground sm:grid-cols-4">
            {LINKS.map((link) => (
              <li key={link.label}>
                <a
                  href={link.href}
                  className={linkClass}
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
        </nav>
      </div>

      <div className="mx-auto mt-12 flex max-w-6xl flex-col gap-4 border-t border-border pt-6 text-xs text-muted-foreground sm:flex-row sm:items-center sm:justify-between">
        <p>© {new Date().getFullYear()} Sorty. Released under the GPL v3.</p>
        <ul className="flex flex-wrap items-center gap-4">
          {LEGAL.map((link) => (
            <li key={link.label}>
              <a
                href={link.href}
                className={linkClass}
                data-analytics-action="footer_link_opened"
                data-analytics-component="text_link"
                data-analytics-location="footer"
                data-analytics-target={link.label}
              >
                {link.label}
              </a>
            </li>
          ))}
          <li>
            <AnalyticsPreferencesButton className={linkClass} />
          </li>
        </ul>
      </div>

      {/* Oversized wordmark in a neighboring flat shade, cropped by the page edge. */}
      <p
        aria-hidden
        className="pointer-events-none mt-8 -mb-[8vw] select-none text-center text-[28vw] font-semibold leading-none tracking-tight text-[#181818]"
      >
        Sorty
      </p>
    </footer>
  )
}

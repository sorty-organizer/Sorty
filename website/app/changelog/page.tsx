import type { Metadata } from 'next'
import {
  ArrowUpRight,
  FolderGit2,
  ShieldCheck,
  Sparkles,
} from 'lucide-react'
import { DiaGradient } from '@/components/dia-gradient'
import { Reveal } from '@/components/reveal'
import { SiteFooter } from '@/components/site-footer'
import { SiteNav } from '@/components/site-nav'
import { PageStructuredData } from '@/components/page-structured-data'
import { OG_IMAGE_PATH, SITE_URL } from '@/lib/site-metadata'

export const metadata: Metadata = {
  title: 'Changelog',
  description:
    'See what changed in Sorty across the latest update and previous stable releases.',
  alternates: {
    canonical: '/changelog',
  },
  openGraph: {
    type: 'website',
    title: 'Sorty changelog — Latest releases and updates',
    description:
      'See what changed in Sorty across the latest update and previous stable releases.',
    url: `${SITE_URL}/changelog/`,
    images: [
      {
        url: OG_IMAGE_PATH,
        width: 1102,
        height: 754,
        alt: 'Sorty app interface.',
      },
    ],
  },
  twitter: {
    card: 'summary_large_image',
    title: 'Sorty changelog — Latest releases and updates',
    description:
      'See what changed in Sorty across the latest update and previous stable releases.',
    images: [OG_IMAGE_PATH],
  },
}

const RELEASES = [
  {
    version: 'Sorty 1.2.1',
    status: 'In preparation',
    date: 'September 23, 2026',
    title: 'Bug fixes and less work in the background',
    summary:
      'This maintenance update focuses on reliability and speed. Launch is faster, idle CPU work is sharply lower, and organization, Finder, permissions, and provider errors are more dependable.',
    highlights: [
      {
        icon: Sparkles,
        title: 'Faster launch',
        body: 'Median time to the first window fell from 2,262 ms to 1,127 ms in a same-machine Release A/B test.',
      },
      {
        icon: FolderGit2,
        title: 'Less idle work',
        body: 'Settled idle CPU fell from a 51.4% mean to 0% in a 60-second visible-window test.',
      },
      {
        icon: ShieldCheck,
        title: 'More reliable',
        body: 'Fixes cover organization, undo, Finder actions, permission recovery, provider errors, and stale status.',
      },
    ],
  },
]

const PREVIOUS_RELEASES = [
  {
    version: 'Sorty 1.2.0',
    date: 'July 11, 2026',
    sections: [
      {
        title: 'New',
        items: [
          'Cloud and external-storage organization, AI clarification before Improve, expanded generation stats, Finder diagnostics, sensitive-action protection, and privacy-safe paths.',
        ],
      },
      {
        title: 'Improved',
        items: [
          'Measured image-analysis progress, clearer live file movement, stronger OpenRouter and cloud reliability, refined storage controls, lower background rendering cost, and a smaller universal download.',
        ],
      },
      {
        title: 'Fixed',
        items: [
          'Fresh-download installation and launch, in-app updates from 1.1.2, Finder extension and volume actions, image-analysis feedback, cross-volume storage safety, and main-window recovery.',
        ],
      },
    ],
  },
  {
    version: 'Sorty 1.1.2',
    date: 'March 1, 2026',
    sections: [
      {
        title: 'Added',
        items: [
          'Preview learnings capture for accepted placements, manual moves, rejections, and rename feedback.',
          'Deeplink automation coverage for exclusions, scans, storage routes, and case-insensitive host matching.',
          'Settings search and focus-target tests across Help, Rules, and deeplink aliases.',
          'Dedicated Finder Integration and Xcode Project agent guides.',
          'Faster debug builds with update and linker deduplication skipping.',
          'A git information injection toggle for rapid development loops.',
          'More precise folder watcher snapshots after in-app file operations.',
          'Detection and filtering for internal file moves and Sorty-generated file system events.',
          'Hover effects, haptics, and glass background support in the About window.',
          'Smoother shimmer effects and progress indicators.',
        ],
      },
      {
        title: 'Changed',
        items: [
          'Streamlined the analysis view into a cleaner, distraction-free interface.',
          'Simplified the folder and file preview by removing legacy destination and validation overlays.',
          'Removed redundant vision batching and OCR language settings.',
          'Reworked the duplicate-files empty state with a clearer call to action.',
          'Improved onboarding spacing, scaling, and truncation.',
          'Refreshed Help and Support actions with compact controls, hover feedback, and haptics.',
          'Renamed the learnings impact metric from Rejected to Reverted.',
          'Simplified releases around one universal app artifact.',
          'Updated the copyright year to 2026.',
          'Improved CI validation coverage and history view defaults.',
          'Allowed all Sparkle update channels and refined the About window appearance.',
        ],
      },
      {
        title: 'Removed',
        items: [
          'Sorting Lab and AI Console.',
          'Manual rename steering and the rename summary.',
          'Quick Rename mode in favor of the unified organization flow.',
        ],
      },
      {
        title: 'Fixed',
        items: [
          'Learnings are now captured before preview plan mutations.',
          'Folder watcher snapshots now prevent missed automation events during organization.',
        ],
      },
    ],
  },
  {
    version: 'Sorty 1.1.1',
    date: 'February 13, 2026',
    sections: [
      {
        title: 'Added',
        items: [
          'A Delete All Data option for wiping usage history, watched folders, and local caches.',
        ],
      },
      {
        title: 'Changed',
        items: [
          'Reset All Settings now returns directly to onboarding.',
          'Custom AI provider endpoints now add a missing URL scheme automatically.',
        ],
      },
      {
        title: 'Fixed',
        items: [
          'A potential crash when changing AI configurations rapidly.',
          'Production code-signing entitlement issues.',
          'Completion checkmark rendering and missing menu bar mascot assets in release builds.',
        ],
      },
    ],
  },
  {
    version: 'Sorty 1.1.0',
    date: 'February 11, 2026',
    sections: [
      {
        title: 'Added',
        items: [
          'Reusable, AI-powered naming presets.',
          'Conflict handling for overwrite, skip, or keep-both decisions.',
          'A one-click installer for the Sorty command-line tool.',
          'Sparkle updates for installing new releases in the app.',
          'Privacy mode for obscuring paths and API keys while sharing your screen.',
        ],
      },
      {
        title: 'Changed',
        items: [
          'Introduced a new visual identity and glass design system.',
          'Redesigned onboarding with a simulated demo and guided walkthrough.',
          'Reorganized settings into focused AI, automation, and system sections.',
          'Added reasoning badges to explain suggested file moves.',
          'Improved semantic duplicate detection and directory scanning performance.',
        ],
      },
      {
        title: 'Fixed',
        items: [
          'Folder watcher memory leaks during long-running sessions.',
          'Communication delays between Finder and the main app.',
          'Missing background organization notifications.',
        ],
      },
    ],
  },
  {
    version: 'Sorty 1.0.6',
    date: 'February 1, 2026',
    sections: [
      {
        title: 'Added',
        items: [
          'In-app automatic updates with download and install progress plus a daily background check on launch.',
          'An Organize Finder Selection button that organizes only the files currently selected in Finder.',
          'A Diagnostics and Logs help section with step-by-step troubleshooting guides.',
        ],
      },
      {
        title: 'Changed',
        items: [
          'The update dialog now downloads and installs updates in place instead of opening a browser.',
          'Finder windows refresh and reveal newly created folders after organizing, when Automation permission is granted.',
          'Faster AI setup with shorter model-list timeouts and connection prewarming.',
        ],
      },
      {
        title: 'Fixed',
        items: [
          'The onboarding Automation permission step now detects granted or denied status instead of always showing unknown.',
        ],
      },
    ],
  },
  {
    version: 'Sorty 1.0.5',
    date: 'January 31, 2026',
    sections: [
      {
        title: 'Added',
        items: [
          'One-click CLI install from Help with installation status and version verification.',
          'Onboarding now requires Files and Folders access before continuing.',
        ],
      },
      {
        title: 'Changed',
        items: [
          'Long-analysis notice with Try Faster Model and Cancel actions.',
          'Folder insights now show the real macOS folder icon.',
          'Files and Folders access is requested through a folder picker and labeled Required, with Automation and Notifications marked Optional.',
          'Provider connection errors now name the specific response problem and suggest likely causes.',
        ],
      },
      {
        title: 'Fixed',
        items: [
          'Continuous learning no longer drops steering and file-move events while the Learnings view is locked.',
        ],
      },
    ],
  },
  {
    version: 'Sorty 1.0.4',
    date: 'January 29, 2026',
    sections: [
      {
        title: 'Added',
        items: [
          'A Software Update dialog with checking progress, release notes, and download for available updates.',
          'A Help downloads section for fetching the CLI tool and source archives from GitHub Releases.',
        ],
      },
      {
        title: 'Fixed',
        items: [
          'AI provider logos now load reliably in both Xcode and distributed builds.',
        ],
      },
    ],
  },
  {
    version: 'Sorty 1.0.3',
    date: 'January 29, 2026',
    sections: [
      {
        title: 'Fixed',
        items: [
          'Fixed a crash when clicking Get Started during onboarding in the downloaded app.',
        ],
      },
    ],
  },
  {
    version: 'Sorty 1.0.2',
    date: 'January 28, 2026',
    sections: [
      {
        title: 'Fixed',
        items: [
          'Made history persistence tests deterministic by isolating their settings storage.',
        ],
      },
    ],
  },
  {
    version: 'Sorty 1.0.1',
    date: 'January 28, 2026',
    sections: [
      {
        title: 'Fixed',
        items: [
          'System notifications now consistently display the Sorty app icon.',
        ],
      },
    ],
  },
  {
    version: 'Sorty 1.0.0',
    date: 'January 27, 2026',
    sections: [
      {
        title: 'Features',
        items: [
          'AI-powered organization with OpenAI, Anthropic, Groq, Ollama, GitHub Copilot, and Apple Foundation Models.',
          'A learnings profile that adapts suggestions to your organization preferences.',
          'Custom AI personas for different workflows.',
          'Image understanding through vision-capable AI providers.',
          'Finder integration for organizing folders from the context menu.',
          'Workspace health tools for clutter, duplicates, and cleanup suggestions.',
          'An interactive preview for reviewing every proposed move.',
          'Full undo through organization history.',
          'Watched folders for automatic background organization.',
          'Command-line tools and deeplinks for scripts and automations.',
          'Menu bar controls and keyboard navigation.',
        ],
      },
      {
        title: 'Requirements',
        items: [
          'macOS 15.0 or later.',
          'An API key for your preferred provider, or Apple Intelligence for on-device AI features.',
        ],
      },
    ],
  },
]

function versionAnchor(version: string) {
  const versionNumber = version.replace(/^Sorty\s+/i, '')
  const versionSlug = versionNumber
    .toLowerCase()
    .split(/[^a-z0-9]+/)
    .filter(Boolean)
    .join('-')

  return `version-${versionSlug}`
}

export default function ChangelogPage() {
  return (
    <main className="relative min-h-screen overflow-x-clip">
      <PageStructuredData
        name="Sorty changelog"
        description="Latest Sorty releases, improvements, and fixes."
        path="/changelog"
        dateModified="2026-07-11"
        breadcrumbs={[{ name: 'Sorty', path: '/' }, { name: 'Changelog', path: '/changelog' }]}
      />
      <SiteNav />

      <section className="relative isolate overflow-hidden px-4 pb-16 pt-32 sm:pb-24 sm:pt-40">
        <div className="pointer-events-none absolute inset-x-[-25vw] top-[-18vh] -z-10 h-[68vh] opacity-80 [mask-image:radial-gradient(ellipse_at_top,black_0%,black_42%,transparent_72%)]">
          <DiaGradient
            blur={18}
            peak={0.92}
            valley={0.5}
            strength={0.62}
          />
        </div>
        <div className="pointer-events-none absolute inset-0 -z-10 bg-[radial-gradient(circle_at_18%_24%,oklch(0.66_0.2_12_/_0.22),transparent_26%),radial-gradient(circle_at_82%_18%,oklch(0.68_0.16_250_/_0.18),transparent_30%),linear-gradient(180deg,transparent_0%,var(--background)_88%)]" />

        <div className="mx-auto max-w-5xl">
          <Reveal immediate animateOnEnter className="max-w-3xl">
            <p className="text-sm font-medium text-primary">Changelog</p>
            <h1 className="mt-4 text-balance text-5xl font-semibold tracking-tight sm:text-6xl lg:text-7xl">
              What changed in Sorty
            </h1>
            <p className="mt-6 max-w-2xl text-pretty text-lg leading-8 text-muted-foreground">
              Follow Sorty&apos;s latest changes and browse the history of stable
              releases for the Mac folder organizer.
            </p>
          </Reveal>
        </div>
      </section>

      <section className="px-4 pb-24">
        <div className="mx-auto max-w-5xl">
          <div className="relative space-y-8 before:absolute before:left-4 before:top-5 before:h-[calc(100%-2.5rem)] before:w-px before:bg-gradient-to-b before:from-primary/70 before:via-border before:to-transparent md:before:left-6">
            {RELEASES.map((release) => (
              <Reveal
                key={release.version}
                immediate
                animateOnEnter
                className="relative pl-12 md:pl-16"
              >
                <span
                  aria-hidden
                  className="absolute left-0 top-3 flex size-8 items-center justify-center rounded-full border border-primary/40 bg-background shadow-[0_0_30px_-8px_oklch(0.62_0.19_256_/_0.8)] md:size-12"
                >
                  <Sparkles className="size-4 text-primary md:size-5" />
                </span>

                <article
                  id={versionAnchor(release.version)}
                  className="release-feature-card scroll-mt-28 overflow-hidden rounded-3xl border border-border bg-card/40 shadow-2xl shadow-black/30 backdrop-blur-xl"
                >
                  <div className="grid gap-0 lg:grid-cols-[0.88fr_1.12fr]">
                    <div className="flex flex-col justify-between border-b border-border p-6 sm:p-8 lg:border-b-0 lg:border-r">
                      <div>
                        <div className="flex flex-wrap items-center gap-2">
                          <span className="rounded-full bg-primary/15 px-3 py-1 text-xs font-medium text-primary">
                            {release.status}
                          </span>
                          <span className="text-sm text-muted-foreground">
                            {release.date}
                          </span>
                        </div>
                        <h2 className="mt-5 text-3xl font-semibold tracking-tight sm:text-4xl">
                          {release.version}
                        </h2>
                        <p className="mt-3 text-xl font-medium text-foreground/90">
                          {release.title}
                        </p>
                        <p className="mt-4 text-sm leading-7 text-muted-foreground">
                          {release.summary}
                        </p>
                      </div>

                      <a
                        href="https://github.com/sorty-organizer/Sorty/releases"
                        target="_blank"
                        rel="noreferrer"
                        className="mt-8 inline-flex w-fit items-center gap-2 rounded-full border border-white/10 bg-background/65 px-4 py-2 text-sm font-medium text-foreground/85 transition-colors hover:border-primary/40 hover:text-foreground"
                        data-analytics-action="release_history_opened"
                        data-analytics-component="cta"
                        data-analytics-location="changelog"
                        data-analytics-target="github_releases"
                      >
                        GitHub releases
                        <ArrowUpRight className="size-4" />
                      </a>
                    </div>

                    <div className="relative p-3 sm:p-4">
                        <div className="release-metrics-card flex h-full flex-col justify-center rounded-[1.35rem] border border-white/10 p-5 sm:p-7">
                          <p className="text-xs font-semibold uppercase tracking-[0.2em] text-muted-foreground">
                            Measured against 1.2.0
                          </p>
                          <div className="mt-6 space-y-8" role="group" aria-label="Sorty 1.2.1 performance comparison">
                            <div>
                              <div className="flex items-baseline justify-between gap-3">
                                <h3 className="text-sm font-medium">Time to first window</h3>
                                <span className="text-sm font-semibold text-sky-300">50% faster</span>
                              </div>
                              <div className="mt-4 space-y-3 text-xs">
                                <div className="grid grid-cols-[4.5rem_1fr_4.5rem] items-center gap-3">
                                  <span className="text-muted-foreground">1.2.0</span>
                                  <span className="h-3 rounded-full bg-slate-500/30"><span className="block h-full w-full rounded-full bg-slate-400" /></span>
                                  <span className="text-right tabular-nums">2,262 ms</span>
                                </div>
                                <div className="grid grid-cols-[4.5rem_1fr_4.5rem] items-center gap-3">
                                  <span className="text-muted-foreground">1.2.1</span>
                                  <span className="h-3 rounded-full bg-sky-500/15"><span className="release-chart-fill block h-full w-1/2 origin-left rounded-full bg-sky-400" /></span>
                                  <span className="text-right font-semibold tabular-nums text-sky-300">1,127 ms</span>
                                </div>
                              </div>
                            </div>
                            <div>
                              <div className="flex items-baseline justify-between gap-3">
                                <h3 className="text-sm font-medium">Settled idle CPU</h3>
                                <span className="text-sm font-semibold text-emerald-300">Near zero</span>
                              </div>
                              <div className="mt-4 space-y-3 text-xs">
                                <div className="grid grid-cols-[4.5rem_1fr_4.5rem] items-center gap-3">
                                  <span className="text-muted-foreground">1.2.0</span>
                                  <span className="h-3 rounded-full bg-slate-500/30"><span className="block h-full w-full rounded-full bg-slate-400" /></span>
                                  <span className="text-right tabular-nums">51.4%</span>
                                </div>
                                <div className="grid grid-cols-[4.5rem_1fr_4.5rem] items-center gap-3">
                                  <span className="text-muted-foreground">1.2.1</span>
                                  <span className="h-3 rounded-full bg-emerald-500/15"><span className="release-chart-fill block h-full w-[2px] origin-left rounded-full bg-emerald-400" /></span>
                                  <span className="text-right font-semibold tabular-nums text-emerald-300">0.0%</span>
                                </div>
                              </div>
                            </div>
                          </div>
                          <a href="https://github.com/sorty-organizer/Sorty/blob/main/docs/performance.md#8-re-measurement-at-62ba6cbf-2026-09-23-v120-vs-latest-commit" className="mt-7 w-fit text-xs text-sky-300 underline-offset-4 hover:underline">How we measured</a>
                        </div>
                    </div>
                  </div>

                  <div className="grid gap-px border-t border-border bg-border md:grid-cols-3">
                    {release.highlights.map((highlight) => (
                      <div
                        key={highlight.title}
                        className="bg-card/70 p-6 sm:p-7"
                      >
                        <div className="flex items-center gap-3">
                          <span className="flex size-10 shrink-0 items-center justify-center rounded-2xl bg-primary/15 text-primary">
                            <highlight.icon className="size-5" />
                          </span>
                          <h3 className="text-base font-medium">
                            {highlight.title}
                          </h3>
                        </div>
                        <p className="mt-3 text-sm leading-6 text-muted-foreground">
                          {highlight.body}
                        </p>
                      </div>
                    ))}
                  </div>
                </article>
              </Reveal>
            ))}
          </div>

          <div className="mt-20 border-t border-border pt-14 sm:mt-24 sm:pt-16">
            <Reveal>
              <p className="text-sm font-medium text-primary">Release history</p>
              <h2 className="mt-3 text-3xl font-semibold tracking-tight sm:text-4xl">
                Previous stable releases
              </h2>
            </Reveal>

            <div className="mt-8 space-y-5">
              {PREVIOUS_RELEASES.map((release, index) => (
                <Reveal key={release.version} delay={Math.min(index * 45, 180)}>
                  <article
                    id={versionAnchor(release.version)}
                    className="scroll-mt-28 rounded-3xl border border-border bg-card/40 p-6 shadow-lg shadow-black/10 backdrop-blur-xl sm:p-8"
                  >
                    <header className="flex flex-col gap-1 border-b border-border pb-5 sm:flex-row sm:items-baseline sm:justify-between">
                      <h3 className="text-2xl font-semibold tracking-tight">
                        {release.version}
                      </h3>
                      <time className="text-sm text-muted-foreground">
                        {release.date}
                      </time>
                    </header>

                    {release.sections.length > 0 ? (
                      <div className="mt-6 grid gap-8 lg:grid-cols-2">
                        {release.sections.map((section) => (
                          <section key={section.title}>
                            <h4 className="text-sm font-semibold uppercase tracking-[0.16em] text-primary">
                              {section.title}
                            </h4>
                            <ul className="mt-3 space-y-2 text-sm leading-6 text-muted-foreground">
                              {section.items.map((item) => (
                                <li key={item} className="flex gap-3">
                                  <span
                                    aria-hidden
                                    className="mt-[0.65rem] size-1.5 shrink-0 rounded-full bg-primary/70"
                                  />
                                  <span>{item}</span>
                                </li>
                              ))}
                            </ul>
                          </section>
                        ))}
                      </div>
                    ) : (
                      <p className="mt-5 text-sm text-muted-foreground">
                        No detailed release notes were published for this maintenance update.
                      </p>
                    )}
                  </article>
                </Reveal>
              ))}
            </div>
          </div>
        </div>
      </section>

      <SiteFooter />
    </main>
  )
}

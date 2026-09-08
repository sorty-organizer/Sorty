import Image from 'next/image'
import { Cpu, Heart, Monitor, Star, UserX } from 'lucide-react'
import { Reveal } from '@/components/reveal'
import { GithubIcon } from '@/components/github-icon'
import { DownloadButton } from '@/components/download-button'
import { sitePath } from '@/lib/site-paths'

const GITHUB_URL = 'https://github.com/sorty-organizer/Sorty'
const SPONSOR_URL = 'https://github.com/sponsors/shirishpothi'
const DOWNLOAD_URL = `${GITHUB_URL}/releases/latest/download/Sorty.zip`

const TRUST_ITEMS = [
  { icon: Monitor, label: 'macOS 15+' },
  { icon: Cpu, label: 'Apple Silicon & Intel' },
  { icon: UserX, label: 'No account required' },
]

export function Hero() {
  return (
    <section
      id="top"
      className="page-section isolate relative overflow-hidden px-4 pt-28 pb-10 sm:pt-36"
    >
      <div
        aria-hidden
        className="pointer-events-none absolute inset-0 -z-30 bg-cover bg-center bg-no-repeat opacity-90"
        style={{
          backgroundImage: `url(${sitePath('/hero-local-background.webp')})`,
          maskImage:
            'linear-gradient(to bottom, black 0%, black 68%, transparent 100%)',
          WebkitMaskImage:
            'linear-gradient(to bottom, black 0%, black 68%, transparent 100%)',
        }}
      />
      {/* layered ambient gradient backdrop */}
      <div
        aria-hidden
        className="pointer-events-none absolute inset-0 -z-20"
        style={{
          background:
            'radial-gradient(900px 480px at 50% 8%, color-mix(in oklch, var(--brand) 28%, transparent), transparent 70%), radial-gradient(700px 420px at 80% 30%, color-mix(in oklch, var(--brand-bright) 18%, transparent), transparent 70%), radial-gradient(700px 420px at 18% 24%, color-mix(in oklch, var(--brand) 14%, transparent), transparent 72%)',
        }}
      />
      <div
        aria-hidden
        className="hero-glow pointer-events-none absolute left-1/2 top-24 -z-10 h-[420px] w-[680px] max-w-[90vw] rounded-full bg-primary/25 blur-[120px]"
      />

      <div className="mx-auto max-w-3xl text-center">
        <h1 className="mt-6 text-balance text-5xl font-semibold leading-[0.95] tracking-tight text-foreground sm:text-7xl">
          AI folder{' '}
          <span className="highlight-pill hero-keyword inline-block rounded-2xl px-3 py-1">
            organization
          </span>{' '}
          for your{' '}
          <span className="mac-heading-lockup">
            <Image
              src={sitePath('/macos-finder-40.webp')}
              alt=""
              width={96}
              height={96}
              className="mac-heading-icon"
              aria-hidden="true"
              preload
            />
          </span>{' '}
          Mac
        </h1>

        <p className="mx-auto mt-6 max-w-xl text-pretty text-base leading-relaxed text-muted-foreground sm:text-lg">
          Point{' '}
          <Image
            src={sitePath('/sorty-icon.webp')}
            alt=""
            width={18}
            height={18}
            className="hero-copy-sorty-icon"
            aria-hidden="true"
          />{' '}
          Sorty at a folder to get a plan for sorting and renaming its files.
          Review the changes before applying them. Use a local AI model or
          connect your preferred provider.
        </p>
        <div className="mt-9 flex flex-col items-center justify-center gap-3 sm:flex-row">
          <DownloadButton
            id="download"
            href={DOWNLOAD_URL}
            analyticsLocation="hero"
            className="w-full justify-center gap-2 px-6 py-3 text-sm font-medium sm:w-auto"
          >
            <span className="download-apple-mark" aria-hidden="true">
              
            </span>
            Download for Mac
          </DownloadButton>
          <a
            href={GITHUB_URL}
            target="_blank"
            rel="noreferrer"
            className="group flex w-full items-center justify-center gap-2 rounded-full border border-border bg-secondary/50 px-6 py-3 text-sm font-medium text-foreground backdrop-blur-md transition-colors hover:border-amber-300/50 hover:bg-amber-300/10 sm:w-auto"
            data-analytics-action="source_opened"
            data-analytics-component="cta"
            data-analytics-location="hero"
            data-analytics-target="github_star"
          >
            <span className="relative size-4" aria-hidden="true">
              <GithubIcon className="absolute inset-0 size-4 transition-all duration-200 group-hover:scale-75 group-hover:opacity-0" />
              <Star className="absolute inset-0 size-4 scale-75 fill-amber-300 text-amber-300 opacity-0 drop-shadow-[0_0_8px_rgba(252,211,77,0.75)] transition-all duration-200 group-hover:scale-110 group-hover:opacity-100" />
            </span>
            Star on GitHub
          </a>
          <a
            href={SPONSOR_URL}
            target="_blank"
            rel="noreferrer"
            className="btn-support flex w-full items-center justify-center gap-2 rounded-full px-6 py-3 text-sm font-medium sm:w-auto"
            data-analytics-action="support_opened"
            data-analytics-component="cta"
            data-analytics-location="hero"
            data-analytics-target="github_sponsors"
          >
            <Heart className="support-heart-icon size-4" />
            Donate
          </a>
        </div>

        <div className="mt-6 flex flex-wrap items-center justify-center gap-2">
          {TRUST_ITEMS.map(({ icon: Icon, label }) => (
            <span
              key={label}
              className="inline-flex items-center gap-1.5 rounded-full border border-border bg-secondary/45 px-3 py-1.5 text-xs text-muted-foreground backdrop-blur-md"
            >
              <Icon className="size-3.5 text-primary" />
              {label}
            </span>
          ))}
        </div>
      </div>

      {/* App screenshot */}
      <Reveal delay={120} className="mx-auto mt-12 max-w-5xl">
        <div
          className="hero-screenshot-card relative rounded-2xl border border-border bg-card/40 p-2 shadow-2xl shadow-black/50 backdrop-blur-xl sm:rounded-3xl sm:p-3"
        >
          <div
            aria-hidden
            className="pointer-events-none absolute inset-x-10 -top-px h-px bg-gradient-to-r from-transparent via-primary/60 to-transparent"
          />
          <picture>
            <source
              media="(max-width: 767px)"
              srcSet={sitePath('/sorty-app-768.webp')}
            />
            <Image
              src={sitePath('/sorty-app.webp')}
              alt="The Sorty app prompting the user to select a directory to organize."
              width={1102}
              height={754}
              className="w-full rounded-xl sm:rounded-2xl"
            />
          </picture>
        </div>
      </Reveal>
    </section>
  )
}

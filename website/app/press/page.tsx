import type { Metadata } from 'next'
import Image from 'next/image'
import Link from 'next/link'
import {
  ArrowDownToLine,
  ArrowUpRight,
  BadgeCheck,
  Images,
  MessageCircle,
  ShieldCheck,
} from 'lucide-react'
import { GithubIcon } from '@/components/github-icon'
import { PageStructuredData } from '@/components/page-structured-data'
import { Reveal } from '@/components/reveal'
import { SiteFooter } from '@/components/site-footer'
import { SiteNav } from '@/components/site-nav'
import { sitePath } from '@/lib/site-paths'
import {
  CURRENT_VERSION,
  GITHUB_URL,
  OG_IMAGE_PATH,
  SITE_URL,
} from '@/lib/site-metadata'

const PAGE_DESCRIPTION =
  'Download official Sorty app icons and product screenshots, and find key facts, descriptions, and press contact details.'

const RAW_ASSET_URL =
  'https://raw.githubusercontent.com/sorty-organizer/Sorty/main/Assets'
const MASCOT_ASSET_URL =
  'https://raw.githubusercontent.com/sorty-organizer/Sorty/main/Resources/Assets.xcassets/SortyMascot.imageset/SortyMascot.png'

const SCREENSHOTS = [
  {
    src: '/sorty-app.webp',
    width: 1102,
    height: 754,
    title: 'Organization workspace',
    description: 'Sorty preparing an AI-generated organization plan.',
  },
  {
    src: '/sorty-apply.webp',
    width: 1102,
    height: 754,
    title: 'Move preview',
    description: 'A reviewable plan showing proposed file moves before applying.',
  },
  {
    src: '/sorty-duplicates.webp',
    width: 1102,
    height: 754,
    title: 'Duplicate review',
    description: 'Sorty presenting duplicate files for a safe, informed decision.',
  },
  {
    src: '/sorty-health.webp',
    width: 1102,
    height: 754,
    title: 'Folder health',
    description: 'Folder health insights and organization recommendations.',
  },
  {
    src: '/sorty-settings.webp',
    width: 1102,
    height: 754,
    title: 'AI provider settings',
    description: 'Private local and cloud AI provider configuration.',
  },
  {
    src: '/sorty-1.2.0-changelog.png',
    width: 1123,
    height: 896,
    title: 'Sorty 1.2.0 artwork',
    description: 'Release artwork for the latest Sorty update.',
  },
]

const FACTS = [
  ['Product', 'Sorty'],
  ['Category', 'Productivity / file management'],
  ['Platform', 'macOS 15 or later'],
  ['Current version', CURRENT_VERSION],
  ['Price', 'Free'],
  ['License', 'GNU GPL v3'],
  ['Source', 'Open source'],
  ['Technology', 'Native Swift and SwiftUI'],
]

export const metadata: Metadata = {
  title: 'Press kit',
  description: PAGE_DESCRIPTION,
  alternates: {
    canonical: '/press',
  },
  openGraph: {
    type: 'website',
    title: 'Sorty press kit — Logos, screenshots, and facts',
    description: PAGE_DESCRIPTION,
    url: `${SITE_URL}/press/`,
    images: [
      {
        url: OG_IMAGE_PATH,
        width: 1102,
        height: 754,
        alt: 'The Sorty app showing an AI-generated organization plan.',
      },
    ],
  },
  twitter: {
    card: 'summary_large_image',
    title: 'Sorty press kit — Logos, screenshots, and facts',
    description: PAGE_DESCRIPTION,
    images: [OG_IMAGE_PATH],
  },
}

function DownloadLink({ href, label }: { href: string; label: string }) {
  return (
    <a
      href={href}
      download
      className="inline-flex items-center gap-2 rounded-full border border-border bg-background/40 px-4 py-2 text-sm font-medium transition-colors hover:border-foreground/20 hover:bg-card"
      data-analytics-action="press_asset_downloaded"
      data-analytics-component="download_link"
      data-analytics-location="press"
      data-analytics-target={label}
    >
      <ArrowDownToLine className="size-4" />
      {label}
    </a>
  )
}

export default function PressPage() {
  return (
    <main className="relative min-h-screen overflow-x-clip">
      <PageStructuredData
        name="Sorty press kit"
        description={PAGE_DESCRIPTION}
        path="/press"
        breadcrumbs={[
          { name: 'Sorty', path: '/' },
          { name: 'Press kit', path: '/press' },
        ]}
      />
      <SiteNav />

      <section className="relative px-4 pt-36 pb-16 sm:pt-44 sm:pb-24">
        <div
          aria-hidden
          className="pointer-events-none absolute inset-x-0 top-0 -z-10 h-[34rem]"
          style={{
            background:
              'radial-gradient(800px 420px at 50% 0%, color-mix(in oklch, var(--brand) 26%, transparent), transparent 72%)',
          }}
        />
        <Reveal immediate animateOnEnter className="mx-auto max-w-4xl text-center">
          <span className="inline-flex items-center gap-2 rounded-full border border-primary/25 bg-primary/10 px-3 py-1 text-xs font-medium text-primary">
            <BadgeCheck className="size-3.5" />
            Official press resources
          </span>
          <h1 className="mt-6 text-balance text-5xl font-semibold tracking-tight sm:text-6xl">
            Everything you need to tell the Sorty story.
          </h1>
          <p className="mx-auto mt-5 max-w-2xl text-pretty text-base leading-relaxed text-muted-foreground sm:text-lg">
            Approved app artwork, product screenshots, descriptions, and key
            facts for journalists, creators, and community partners.
          </p>
        </Reveal>
      </section>

      <section className="px-4 pb-24">
        <div className="mx-auto max-w-5xl space-y-24">
          <Reveal>
            <div className="grid overflow-hidden rounded-3xl border border-border bg-card/35 backdrop-blur-md lg:grid-cols-[0.85fr_1.15fr]">
              <div className="flex min-h-80 items-center justify-center border-b border-border p-10 lg:border-r lg:border-b-0">
                <Image
                  src={sitePath('/sorty-icon.webp')}
                  alt="Sorty app icon"
                  width={512}
                  height={512}
                  className="size-40 rounded-[2.2rem] object-cover shadow-2xl shadow-black/45 sm:size-48"
                  priority
                />
              </div>
              <div className="p-7 sm:p-10">
                <p className="text-xs font-medium uppercase tracking-[0.16em] text-primary">
                  App icon
                </p>
                <h2 className="mt-3 text-3xl font-semibold tracking-tight">
                  The official Sorty mark
                </h2>
                <p className="mt-4 max-w-xl leading-relaxed text-muted-foreground">
                  Use the release icon for editorial coverage. Keep it unaltered
                  apart from proportional resizing, and do not use it in a way
                  that suggests endorsement or an official partnership.
                </p>
                <div className="mt-7 flex flex-wrap gap-3">
                  <DownloadLink
                    href={`${RAW_ASSET_URL}/AppIcon/AppIcon-Release.png`}
                    label="PNG · 1024 px"
                  />
                  <DownloadLink
                    href={`${RAW_ASSET_URL}/AppIcon/AppIcon-Release.icns`}
                    label="ICNS · macOS"
                  />
                  <DownloadLink
                    href={MASCOT_ASSET_URL}
                    label="Mascot PNG · 1024 px"
                  />
                </div>
                <a
                  href={`${GITHUB_URL}/tree/main/Assets`}
                  target="_blank"
                  rel="noreferrer"
                  className="mt-5 inline-flex items-center gap-1.5 text-sm text-muted-foreground underline-offset-4 transition-colors hover:text-foreground hover:underline"
                >
                  Browse every source asset
                  <ArrowUpRight className="size-3.5" />
                </a>
              </div>
            </div>
          </Reveal>

          <section aria-labelledby="screenshots-heading">
            <Reveal className="flex flex-col gap-4 sm:flex-row sm:items-end sm:justify-between">
              <div>
                <span className="inline-flex items-center gap-2 text-sm font-medium text-primary">
                  <Images className="size-4" />
                  Product imagery
                </span>
                <h2 id="screenshots-heading" className="mt-3 text-3xl font-semibold tracking-tight sm:text-4xl">
                  Screenshots
                </h2>
                <p className="mt-3 max-w-2xl text-muted-foreground">
                  High-resolution product views and current release artwork.
                  Select any image to open the original, or use its download
                  link.
                </p>
              </div>
            </Reveal>

            <div className="mt-8 grid gap-6 md:grid-cols-2">
              {SCREENSHOTS.map((screenshot, index) => {
                const src = sitePath(screenshot.src)

                return (
                  <Reveal
                    key={screenshot.src}
                    delay={(index % 2) * 70}
                    className={index === 0 ? 'md:col-span-2' : undefined}
                  >
                    <article className="group overflow-hidden rounded-3xl border border-border bg-card/35">
                      <a
                        href={src}
                        target="_blank"
                        rel="noreferrer"
                        className="block overflow-hidden border-b border-border bg-black/20"
                        aria-label={`Open full-size ${screenshot.title} screenshot`}
                      >
                        <Image
                          src={src}
                          alt={screenshot.description}
                          width={screenshot.width}
                          height={screenshot.height}
                          className="h-auto w-full transition-transform duration-500 group-hover:scale-[1.015]"
                        />
                      </a>
                      <div className="flex items-start justify-between gap-4 p-5">
                        <div>
                          <h3 className="font-medium">{screenshot.title}</h3>
                          <p className="mt-1 text-sm leading-relaxed text-muted-foreground">
                            {screenshot.description}
                          </p>
                        </div>
                        <a
                          href={src}
                          download
                          className="flex size-9 shrink-0 items-center justify-center rounded-full border border-border text-muted-foreground transition-colors hover:text-foreground"
                          aria-label={`Download ${screenshot.title} screenshot`}
                          data-analytics-action="press_asset_downloaded"
                          data-analytics-component="icon_link"
                          data-analytics-location="press"
                          data-analytics-target={screenshot.title}
                        >
                          <ArrowDownToLine className="size-4" />
                        </a>
                      </div>
                    </article>
                  </Reveal>
                )
              })}
            </div>
          </section>

          <section className="grid gap-6 lg:grid-cols-2" aria-label="About Sorty">
            <Reveal>
              <div className="h-full rounded-3xl border border-border bg-card/35 p-7 sm:p-9">
                <p className="text-xs font-medium uppercase tracking-[0.16em] text-primary">
                  Boilerplate
                </p>
                <h2 className="mt-3 text-2xl font-semibold tracking-tight">
                  About Sorty
                </h2>
                <p className="mt-5 leading-7 text-muted-foreground">
                  Sorty is a free, open-source Mac app that uses AI to organize
                  folders. It understands file content and context, proposes a
                  clear organization plan, and lets people preview every move
                  before anything changes. Sorty supports private on-device AI
                  as well as popular cloud providers, and is designed around
                  user control, undo, and transparency.
                </p>
              </div>
            </Reveal>

            <Reveal delay={70}>
              <div className="h-full rounded-3xl border border-border bg-card/35 p-7 sm:p-9">
                <p className="text-xs font-medium uppercase tracking-[0.16em] text-primary">
                  At a glance
                </p>
                <h2 className="mt-3 text-2xl font-semibold tracking-tight">
                  Key facts
                </h2>
                <dl className="mt-5 divide-y divide-border">
                  {FACTS.map(([term, value]) => (
                    <div key={term} className="flex items-start justify-between gap-6 py-3 first:pt-0 last:pb-0">
                      <dt className="text-sm text-muted-foreground">{term}</dt>
                      <dd className="text-right text-sm font-medium">{value}</dd>
                    </div>
                  ))}
                </dl>
              </div>
            </Reveal>
          </section>

          <Reveal>
            <section className="relative overflow-hidden rounded-3xl border border-primary/25 bg-card/45 p-8 text-center sm:p-12" aria-labelledby="press-contact-heading">
              <div
                aria-hidden
                className="pointer-events-none absolute inset-0 -z-10"
                style={{
                  background:
                    'radial-gradient(560px 240px at 50% 0%, color-mix(in oklch, var(--brand) 20%, transparent), transparent 72%)',
                }}
              />
              <ShieldCheck className="mx-auto size-8 text-primary" />
              <h2 id="press-contact-heading" className="mt-4 text-3xl font-semibold tracking-tight">
                Need something else?
              </h2>
              <p className="mx-auto mt-3 max-w-xl text-pretty leading-relaxed text-muted-foreground">
                For interviews, additional formats, fact-checking, or other
                press requests, contact the developer directly.
              </p>
              <div className="mt-7 flex flex-wrap justify-center gap-3">
                <a
                  href="mailto:shirish.pothi.27@gmail.com"
                  className="group inline-flex items-center gap-2 rounded-full bg-foreground px-5 py-2.5 text-sm font-medium text-background shadow-sm transition-[transform,box-shadow,opacity] duration-200 ease-out hover:-translate-y-0.5 hover:scale-[1.02] hover:opacity-90 hover:shadow-lg active:translate-y-0 active:scale-[0.98]"
                >
                  <MessageCircle className="size-4 transition-transform duration-200 ease-out group-hover:scale-110" />
                  Contact the developer
                  <ArrowUpRight className="size-3.5 transition-transform duration-200 ease-out group-hover:translate-x-0.5 group-hover:-translate-y-0.5" />
                </a>
                <a
                  href={GITHUB_URL}
                  target="_blank"
                  rel="noreferrer"
                  className="group inline-flex items-center gap-2 rounded-full border border-border px-5 py-2.5 text-sm font-medium transition-[transform,background-color,border-color,box-shadow] duration-200 ease-out hover:-translate-y-0.5 hover:scale-[1.02] hover:border-foreground/25 hover:bg-card hover:shadow-lg active:translate-y-0 active:scale-[0.98]"
                >
                  <GithubIcon className="size-4 transition-transform duration-200 ease-out group-hover:scale-110" />
                  View source
                  <ArrowUpRight className="size-3.5 transition-transform duration-200 ease-out group-hover:translate-x-0.5 group-hover:-translate-y-0.5" />
                </a>
              </div>
              <p className="mt-6 text-xs text-muted-foreground">
                When publishing, please credit “Sorty” and link to{' '}
                <Link
                  href={sitePath('/')}
                  className="underline underline-offset-4 hover:text-foreground"
                >
                  the official website
                </Link>
                .
              </p>
            </section>
          </Reveal>
        </div>
      </section>

      <SiteFooter />
    </main>
  )
}

import type { ReactNode } from 'react'
import Link from 'next/link'
import { ShieldCheck } from 'lucide-react'
import { Reveal } from '@/components/reveal'
import { SiteNav } from '@/components/site-nav'
import { SiteFooter } from '@/components/site-footer'
import styles from './legal-page.module.css'

interface TocItem {
  id: string
  label: string
}

interface LegalPageProps {
  title: string
  updated: string
  /** Short "the short version" callout shown in the gradient banner. */
  summary?: ReactNode
  /** Anchor links rendered as an "On this page" index. */
  toc?: TocItem[]
  children: ReactNode
}

export function LegalPage({
  title,
  updated,
  summary,
  toc,
  children,
}: LegalPageProps) {
  return (
    <main className="relative min-h-screen overflow-x-clip">
      <SiteNav />
      <section className="relative px-4 pt-36 pb-12 sm:pt-44">
        <div
          aria-hidden
          className="pointer-events-none absolute inset-x-0 top-0 -z-10 h-80"
          style={{
            background:
              'radial-gradient(700px 320px at 50% 0%, color-mix(in oklch, var(--brand) 22%, transparent), transparent 70%)',
          }}
        />
        <div className="mx-auto max-w-3xl">
          <Reveal immediate animateOnEnter>
            <Link
              href="/"
              scroll={false}
              className={styles.backLink}
              data-analytics-action="legal_navigation_opened"
              data-analytics-component="back_link"
              data-analytics-location="legal_page"
              data-analytics-target="home"
            >
              <span className={styles.backLinkLabel}>← Back to Sorty</span>
            </Link>
            <h1 className="mt-6 text-balance text-4xl font-semibold tracking-tight sm:text-5xl">
              {title}
            </h1>
            <div className="mt-3 flex flex-col gap-4 sm:flex-row sm:items-center sm:justify-between">
              <p className="text-sm text-muted-foreground">
                Last updated {updated}
              </p>
            </div>
          </Reveal>

          {summary && (
            <Reveal immediate animateOnEnter delay={80}>
              <div className="relative mt-8 overflow-hidden rounded-3xl border border-primary/30 bg-card/50 p-6 backdrop-blur-xl sm:p-7">
                <div
                  aria-hidden
                  className="pointer-events-none absolute inset-0 -z-10"
                  style={{
                    background:
                      'radial-gradient(600px 220px at 50% 0%, color-mix(in oklch, var(--brand) 22%, transparent), transparent 70%)',
                  }}
                />
                <span className="inline-flex items-center gap-2 rounded-full bg-primary/15 px-3 py-1 text-xs font-medium text-primary">
                  <ShieldCheck className="size-3.5" />
                  The short version
                </span>
                <p className="mt-4 text-pretty text-base leading-relaxed text-foreground/90">
                  {summary}
                </p>
              </div>
            </Reveal>
          )}

          {toc && toc.length > 0 && (
            <Reveal immediate animateOnEnter delay={140}>
              <nav
                aria-label="On this page"
                className="mt-8 rounded-3xl border border-border bg-card/30 p-5 backdrop-blur-md"
              >
                <p className="text-xs font-medium uppercase tracking-wide text-muted-foreground">
                  On this page
                </p>
                <ol className="mt-3 grid gap-x-6 gap-y-1.5 sm:grid-cols-2">
                  {toc.map((item, i) => (
                    <li key={item.id}>
                      <a
                        href={`#${item.id}`}
                        className="flex gap-2 text-sm text-muted-foreground transition-colors hover:text-foreground"
                        data-analytics-action="legal_section_opened"
                        data-analytics-component="table_of_contents"
                        data-analytics-location="legal_page"
                        data-analytics-target={item.id}
                      >
                        <span className="text-primary/70 tabular-nums">
                          {i + 1}.
                        </span>
                        {item.label}
                      </a>
                    </li>
                  ))}
                </ol>
              </nav>
            </Reveal>
          )}

          <div className="legal-prose mt-12 space-y-10 text-sm leading-relaxed text-muted-foreground">
            {children}
          </div>
        </div>
      </section>
      <SiteFooter />
    </main>
  )
}

interface SectionProps {
  id?: string
  heading: string
  children: ReactNode
}

export function LegalSection({ id, heading, children }: SectionProps) {
  return (
    <div id={id} className="scroll-mt-28">
      <Reveal>
        <h2 className="text-lg font-medium text-foreground">{heading}</h2>
        <div className="mt-3 space-y-3">{children}</div>
      </Reveal>
    </div>
  )
}

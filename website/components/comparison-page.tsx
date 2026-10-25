import Image from 'next/image'
import Link from 'next/link'
import {
  ArrowRight,
  Check,
  CircleDotDashed,
  Download,
  ExternalLink,
  Minus,
  Scale,
  Sparkles,
} from 'lucide-react'
import {
  COMPARISON_PRODUCTS,
  COMPARISON_ROWS,
  type ComparisonCell,
  type ComparisonProductId,
} from '@/lib/comparison-data'
import { DOWNLOAD_URL, SITE_URL } from '@/lib/site-metadata'
import { sitePath } from '@/lib/site-paths'
import { Reveal } from '@/components/reveal'
import { SiteFooter } from '@/components/site-footer'
import { SiteNav } from '@/components/site-nav'

const RECOMMENDATIONS: {
  product: ComparisonProductId
  title: string
  body: string
}[] = [
  {
    product: 'sorty',
    title: 'Choose Sorty for review-first AI organization',
    body: 'Sorty is the strongest fit when you want folders proposed by meaning, a complete plan before anything moves, local or cloud AI choice, and open-source code.',
  },
  {
    product: 'hazel',
    title: 'Choose Hazel for deep deterministic automation',
    body: 'Hazel is a strong fit when you already know the exact conditions and actions you want, and those rules should run continuously.',
  },
  {
    product: 'folder-tidy',
    title: 'Choose Folder Tidy for focused rule-based cleanup',
    body: 'Folder Tidy suits on-demand tidying with built-in categories, custom predicates, a chosen destination, and historical undo.',
  },
  {
    product: 'sparkle',
    title: 'Choose Sparkle for automatic AI cleanup',
    body: 'Sparkle suits people who want always-on folder organization, deduplication, storage cleanup, and a reversible workflow after setup.',
  },
]

function StatusIcon({ cell }: { cell: ComparisonCell }) {
  if (cell.status === 'strong') {
    return (
      <span
        className="mt-0.5 flex size-5 shrink-0 items-center justify-center rounded-full bg-emerald-400/15 text-emerald-300"
        aria-label="Supported"
      >
        <Check className="size-3.5" aria-hidden="true" />
      </span>
    )
  }

  if (cell.status === 'partial') {
    return (
      <span
        className="mt-0.5 flex size-5 shrink-0 items-center justify-center rounded-full bg-amber-300/15 text-amber-200"
        aria-label="Partially supported or different workflow"
      >
        <CircleDotDashed className="size-3.5" aria-hidden="true" />
      </span>
    )
  }

  return (
    <span
      className="mt-0.5 flex size-5 shrink-0 items-center justify-center rounded-full bg-secondary text-muted-foreground"
      aria-label="Not offered or not documented"
    >
      <Minus className="size-3.5" aria-hidden="true" />
    </span>
  )
}

export function ComparisonPage() {
  const pageUrl = `${SITE_URL}/compare/`
  const structuredData = {
    '@context': 'https://schema.org',
    '@graph': [
      {
        '@type': 'WebPage',
        '@id': `${pageUrl}#webpage`,
        url: pageUrl,
        name: 'Sorty vs Hazel vs Folder Tidy vs Sparkle',
        description:
          'A sourced comparison of Mac file organizers across AI, rules, preview, automation, undo, privacy, and source availability.',
        isPartOf: { '@id': `${SITE_URL}/#website` },
        about: { '@id': `${SITE_URL}/#app` },
        inLanguage: 'en-US',
        dateModified: '2026-08-10',
      },
      {
        '@type': 'BreadcrumbList',
        '@id': `${pageUrl}#breadcrumb`,
        itemListElement: [
          { '@type': 'ListItem', position: 1, name: 'Sorty', item: `${SITE_URL}/` },
          { '@type': 'ListItem', position: 2, name: 'Compare Mac file organizers', item: pageUrl },
        ],
      },
      {
        '@type': 'ItemList',
        '@id': `${pageUrl}#products`,
        name: 'Mac file organizers compared',
        numberOfItems: COMPARISON_PRODUCTS.length,
        itemListElement: COMPARISON_PRODUCTS.map((product, index) => ({
          '@type': 'ListItem',
          position: index + 1,
          item: {
            '@type': 'SoftwareApplication',
            name: product.name,
            url: product.url,
            operatingSystem: 'macOS',
            applicationCategory: 'UtilitiesApplication',
            description: product.shortDescription,
          },
        })),
      },
    ],
  }

  return (
    <main className="relative min-h-screen overflow-x-clip">
      <script
        type="application/ld+json"
        dangerouslySetInnerHTML={{ __html: JSON.stringify(structuredData) }}
      />
      <SiteNav />

      <section className="page-section relative isolate px-4 pb-20 pt-32 sm:pt-44">
        <div
          aria-hidden="true"
          className="pointer-events-none absolute inset-x-0 top-0 -z-10 h-[38rem]"
          style={{
            background:
              'radial-gradient(850px 460px at 50% 0%, color-mix(in oklch, var(--brand) 24%, transparent), transparent 72%)',
          }}
        />
        <Reveal immediate animateOnEnter className="mx-auto max-w-5xl text-center">
          <span className="mx-auto flex size-12 items-center justify-center rounded-2xl border border-primary/30 bg-primary/10 text-primary shadow-xl shadow-black/30">
            <Scale className="size-6" />
          </span>
          <p className="mt-5 text-sm font-medium text-primary">Mac file organizer comparison</p>
          <h1 className="mx-auto mt-4 max-w-4xl text-balance text-4xl font-semibold leading-[1.04] tracking-tight sm:text-6xl">
            <span className="highlight-pill inline-flex items-center gap-2 rounded-2xl px-2.5 py-1 align-middle sm:gap-3">
              <Image
                src={sitePath('/favicon.png')}
                alt=""
                width={52}
                height={52}
                className="size-[0.82em] rounded-[0.22em] object-contain"
                aria-hidden="true"
              />
              <span>Sorty</span>
            </span>{' '}
            vs Hazel, Folder Tidy, and Sparkle
          </h1>
          <p className="mx-auto mt-6 max-w-3xl text-pretty text-lg leading-8 text-muted-foreground">
            See how four Mac organizers handle the decisions that matter: how they sort, what you
            can review, where AI runs, and how easily changes can be undone. Every comparison is
            grounded in the products’ official documentation.
          </p>

          <div className="mx-auto mt-9 flex flex-wrap items-center justify-center gap-3">
            {COMPARISON_PRODUCTS.map((product, index) => (
              <span
                key={product.id}
                className={`inline-flex items-center gap-2 rounded-2xl border px-3 py-2 text-sm ${
                  product.id === 'sorty'
                    ? 'border-primary/45 bg-primary/12 text-foreground'
                    : index % 2 === 0
                      ? 'border-white/15 bg-white/8 text-white'
                      : 'border-border bg-card/50 text-muted-foreground'
                }`}
              >
                <Image
                  src={sitePath(product.logo)}
                  alt=""
                  width={28}
                  height={28}
                  className="size-7 rounded-lg object-contain"
                  aria-hidden="true"
                />
                {product.name}
              </span>
            ))}
          </div>

          <div className="mx-auto mt-9 max-w-3xl rounded-3xl border border-primary/30 bg-primary/8 p-6 text-left backdrop-blur-xl">
            <div className="flex items-start gap-4">
              <span className="flex size-10 shrink-0 items-center justify-center rounded-2xl bg-primary/15 text-primary">
                <Sparkles className="size-5" />
              </span>
              <div>
                <h2 className="font-semibold">Why Sorty stands out</h2>
                <p className="mt-2 text-sm leading-6 text-muted-foreground">
                  Among these four apps, Sorty uniquely combines an AI-generated semantic plan,
                  review before apply, local and cloud model choice, and complete GPL-licensed
                  source code. Hazel is stronger for intricate fixed rules, Folder Tidy for a
                  focused rule-based tidy, and Sparkle for automatic cleanup and deduplication.
                </p>
              </div>
            </div>
          </div>
        </Reveal>
      </section>

      <section className="section-seam border-y border-border bg-card/20 px-4 py-20" aria-labelledby="comparison-table-heading">
        <Reveal className="mx-auto max-w-6xl">
          <div className="flex flex-col justify-between gap-4 sm:flex-row sm:items-end">
            <div>
              <p className="text-sm font-medium text-primary">Feature comparison</p>
              <h2 id="comparison-table-heading" className="mt-3 text-3xl font-semibold tracking-tight sm:text-4xl">
                The workflow differences that matter
              </h2>
            </div>
            <p className="max-w-sm text-sm leading-6 text-muted-foreground">
              Scroll sideways on smaller screens. Sorty is highlighted in blue.
            </p>
          </div>

          <div className="mt-9 overflow-x-auto rounded-3xl border border-border bg-background/65 shadow-2xl shadow-black/20">
            <table className="w-full min-w-[1120px] border-separate border-spacing-0 text-left">
              <caption className="sr-only">
                Sorty, Hazel, Folder Tidy, and Sparkle feature comparison
              </caption>
              <thead>
                <tr>
                  <th scope="col" className="sticky left-0 z-20 w-56 border-b border-border bg-background p-5 text-sm font-medium">
                    Capability
                  </th>
                  {COMPARISON_PRODUCTS.map((product) => (
                    <th
                      scope="col"
                      key={product.id}
                      className={`w-56 border-b border-border p-5 align-top ${
                        product.id === 'sorty' ? 'bg-primary/10' : 'bg-background'
                      }`}
                    >
                      <a
                        href={product.url}
                        target="_blank"
                        rel="noreferrer"
                        className="group inline-flex items-center gap-3 rounded-xl focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary"
                      >
                        <Image
                          src={sitePath(product.logo)}
                          alt={product.logoAlt}
                          width={38}
                          height={38}
                          className="size-10 rounded-xl object-contain"
                        />
                        <span>
                          <span className="flex items-center gap-1.5 font-semibold">
                            {product.name}
                            <ExternalLink className="size-3 text-muted-foreground opacity-0 transition-opacity group-hover:opacity-100" />
                          </span>
                          {product.id === 'sorty' && (
                            <span className="mt-1 block text-xs font-medium text-primary">Review-first AI</span>
                          )}
                        </span>
                      </a>
                    </th>
                  ))}
                </tr>
              </thead>
              <tbody>
                {COMPARISON_ROWS.map((row) => (
                  <tr key={row.feature} className="group/row">
                    <th
                      scope="row"
                      className="sticky left-0 z-10 border-b border-border bg-background p-5 align-top group-last/row:border-b-0"
                    >
                      <span className="font-medium">{row.feature}</span>
                      <span className="mt-2 block text-xs font-normal leading-5 text-muted-foreground">
                        {row.explanation}
                      </span>
                    </th>
                    {COMPARISON_PRODUCTS.map((product) => {
                      const cell = row.values[product.id]
                      return (
                        <td
                          key={product.id}
                          className={`border-b border-border p-5 align-top text-sm leading-6 group-last/row:border-b-0 ${
                            product.id === 'sorty' ? 'bg-primary/[0.065]' : ''
                          }`}
                        >
                          <div className="flex gap-2.5">
                            <StatusIcon cell={cell} />
                            <span className={product.id === 'sorty' ? 'text-foreground' : 'text-muted-foreground'}>
                              {cell.text}
                            </span>
                          </div>
                        </td>
                      )
                    })}
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </Reveal>
      </section>

      <section className="section-seam px-4 py-24" aria-labelledby="which-organizer-heading">
        <div className="mx-auto max-w-5xl">
          <Reveal className="text-center">
            <p className="text-sm font-medium text-primary">Decision guide</p>
            <h2 id="which-organizer-heading" className="mt-3 text-balance text-3xl font-semibold tracking-tight sm:text-4xl">
              Which Mac file organizer should you choose?
            </h2>
            <p className="mx-auto mt-4 max-w-2xl text-pretty text-muted-foreground">
              There is no honest universal winner. Choose the workflow that matches how much
              automation and review you want.
            </p>
          </Reveal>

          <div className="mt-10 grid gap-4 md:grid-cols-2">
            {RECOMMENDATIONS.map((recommendation, index) => {
              const product = COMPARISON_PRODUCTS.find((item) => item.id === recommendation.product)!
              return (
                <Reveal
                  key={recommendation.product}
                  delay={(index % 2) * 80}
                  className={`rounded-3xl border p-6 ${
                    recommendation.product === 'sorty'
                      ? 'border-primary/40 bg-primary/8'
                      : 'border-border bg-card/35'
                  }`}
                >
                  <div className="flex items-center gap-3">
                    <Image
                      src={sitePath(product.logo)}
                      alt=""
                      width={42}
                      height={42}
                      className="size-11 rounded-xl object-contain"
                      aria-hidden="true"
                    />
                    <h3 className="text-lg font-medium">{recommendation.title}</h3>
                  </div>
                  <p className="mt-4 text-sm leading-6 text-muted-foreground">
                    {recommendation.body}
                  </p>
                </Reveal>
              )
            })}
          </div>

        </div>
      </section>

      <section className="px-4 pb-24 text-center">
        <Reveal>
          <h2 className="text-balance text-3xl font-semibold tracking-tight">
            Try Sorty
          </h2>
          <p className="mx-auto mt-4 max-w-xl text-pretty text-muted-foreground">
            Sorty is free, open source, and available for Apple Silicon and Intel Macs running
            macOS 15 or later.
          </p>
          <div className="mt-7 flex flex-col justify-center gap-3 sm:flex-row">
            <a
              href={DOWNLOAD_URL}
              className="btn-download inline-flex items-center justify-center gap-2 rounded-full px-6 py-3 text-sm font-medium"
            >
              <Download className="size-4" />
              Download for Mac
            </a>
            <Link
              href="/#how-it-works"
              className="group inline-flex items-center justify-center gap-2 rounded-full border border-border bg-card/25 px-6 py-3 text-sm font-medium transition-[transform,background-color,border-color] duration-300 hover:-translate-y-0.5 hover:border-primary/45 hover:bg-secondary/70"
            >
              See the workflow
              <ArrowRight className="size-4 transition-transform duration-300 group-hover:translate-x-1" />
            </Link>
          </div>
        </Reveal>
      </section>

      <SiteFooter />
    </main>
  )
}

import { Reveal } from '@/components/reveal'
import { FAQS } from '@/components/faq-data'
import { GITHUB_URL } from '@/lib/site-metadata'

export function Faq() {
  return (
    <section id="faq" className="scroll-mt-24 px-4 py-24">
      <div className="mx-auto grid max-w-6xl gap-12 md:grid-cols-12">
        <Reveal className="md:col-span-4">
          <div className="md:sticky md:top-32">
            <p className="text-sm font-medium text-primary">FAQ</p>
            <h2 className="mt-4 text-4xl font-semibold tracking-tight">
              Questions people ask before they try it
            </h2>
            <p className="mt-4 text-base text-muted-foreground">
              Something missing?{' '}
              <a
                href={`${GITHUB_URL}/issues`}
                target="_blank"
                rel="noreferrer"
                className="font-medium text-foreground underline decoration-white/30 underline-offset-4 transition-colors duration-300 ease-fluid hover:decoration-white"
                data-analytics-action="source_opened"
                data-analytics-component="text_link"
                data-analytics-location="faq"
                data-analytics-target="github_issues"
              >
                Ask on GitHub
              </a>
              .
            </p>
          </div>
        </Reveal>

        <dl className="space-y-12 md:col-span-8">
          {FAQS.map((item, i) => (
            <Reveal key={item.id} delay={(i % 3) * 80}>
              <dt className="text-lg font-semibold">{item.q}</dt>
              <dd className="mt-2 max-w-2xl text-base text-muted-foreground">{item.a}</dd>
            </Reveal>
          ))}
        </dl>
      </div>
    </section>
  )
}

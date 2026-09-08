'use client'

import { useState } from 'react'
import { Heart, Plus } from 'lucide-react'
import { cn } from '@/lib/utils'
import { Reveal } from '@/components/reveal'
import { FAQS } from '@/components/faq-data'
import { trackWebInteraction } from '@/lib/analytics'

const SPONSOR_URL = 'https://github.com/sponsors/shirishpothi'

function FaqItem({ id, q, a }: { id: string; q: string; a: string }) {
  const [open, setOpen] = useState(false)
  const toggle = () => {
    const nextOpen = !open
    setOpen(nextOpen)
    trackWebInteraction({
      action: nextOpen ? 'faq_opened' : 'faq_closed',
      component: 'faq_item',
      location: 'faq',
      target: id,
      outcome: nextOpen ? 'opened' : 'closed',
    })
  }

  return (
    <div className="rounded-3xl border border-border bg-card/60 transition-colors hover:border-primary/30">
      <button
        type="button"
        onClick={toggle}
        className="flex w-full items-center justify-between gap-4 px-6 py-5 text-left"
        aria-expanded={open}
      >
        <span className="text-base font-medium">{q}</span>
        <Plus
          className={cn(
            'size-5 shrink-0 text-primary transition-transform duration-300',
            open && 'rotate-45',
          )}
        />
      </button>
      <div
        aria-hidden={!open}
        data-highlight-exclude={open ? undefined : ''}
        className={cn(
          'grid transition-[grid-template-rows,opacity] duration-300 ease-out motion-reduce:transition-none',
          open ? 'grid-rows-[1fr] opacity-100' : 'grid-rows-[0fr] opacity-0',
        )}
      >
        <div className="overflow-hidden">
          <p className="px-6 pb-5 text-sm leading-relaxed text-muted-foreground">
            {a}
          </p>
        </div>
      </div>
    </div>
  )
}

export function Faq() {
  return (
    <section
      id="faq"
      className="section-seam page-section px-4 py-20 sm:py-28"
    >
      <div className="mx-auto max-w-3xl">
        <Reveal className="text-center">
          <p className="text-sm font-medium text-primary">FAQ</p>
          <h2 className="mt-3 text-balance text-3xl font-semibold tracking-tight sm:text-4xl">
            Common questions
          </h2>
        </Reveal>

        <div className="mt-12 space-y-3">
          {FAQS.map((item, i) => (
            <Reveal key={item.q} delay={(i % 4) * 60}>
              <FaqItem {...item} />
            </Reveal>
          ))}
        </div>

        <Reveal delay={160} className="mt-10 text-center">
          <a
            href={SPONSOR_URL}
            target="_blank"
            rel="noreferrer"
            className="btn-support inline-flex items-center justify-center gap-2 rounded-full px-6 py-3 text-sm font-medium"
            data-analytics-action="support_opened"
            data-analytics-component="cta"
            data-analytics-location="faq"
            data-analytics-target="github_sponsors"
          >
            <Heart className="support-heart-icon size-4" />
            Donate
          </a>
        </Reveal>
      </div>
    </section>
  )
}

'use client'

import { useEffect, useRef } from 'react'

const LINES = ['Nothing moves until you approve the plan.', 'Anything that moves can move back.']

/**
 * Large tagline whose words light up in reading order as each one crosses a
 * trigger line 40% above the bottom of the viewport. One IntersectionObserver
 * watches every word, so there is no scroll listener.
 */
export function TaglineReveal() {
  const ref = useRef<HTMLHeadingElement>(null)

  useEffect(() => {
    const words = ref.current?.querySelectorAll<HTMLElement>('.tagline-word')
    if (!words?.length) return

    const observer = new IntersectionObserver(
      (entries) => {
        // A whole line crosses at once, so stagger the words lit together in
        // this batch to keep them activating one at a time in reading order.
        let order = 0
        for (const entry of entries) {
          const word = entry.target as HTMLElement
          // Words above the viewport stay lit; only words below the line dim.
          const lit = entry.isIntersecting || entry.boundingClientRect.top < 0
          if (lit === word.classList.contains('is-lit')) continue
          word.style.transitionDelay = lit ? `${order++ * 90}ms` : '0ms'
          word.classList.toggle('is-lit', lit)
        }
      },
      { rootMargin: '0px 0px -40% 0px' },
    )
    words.forEach((word) => observer.observe(word))
    return () => observer.disconnect()
  }, [])

  return (
    <section aria-label="Why Sorty is safe to try" className="px-4 py-24">
      <h2
        ref={ref}
        className="mx-auto max-w-[680px] text-4xl font-semibold tracking-tight sm:text-5xl"
      >
        {LINES.map((line) => (
          <span key={line} className="block">
            {line.split(' ').map((word, i) => (
              <span key={i} className="tagline-word">
                {word}{' '}
              </span>
            ))}
          </span>
        ))}
      </h2>
    </section>
  )
}

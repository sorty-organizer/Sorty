'use client'

import { useRef, useState } from 'react'
import { ArrowLeft, FolderSearch } from 'lucide-react'
import { useRouter } from 'next/navigation'
import { FileIconField } from '@/components/file-icon-field'
import { SortyLogo } from '@/components/sorty-logo'
import { cn } from '@/lib/utils'
import { trackWebInteraction } from '@/lib/analytics'
import { sitePath } from '@/lib/site-paths'

export default function NotFound() {
  const router = useRouter()
  const buttonRef = useRef<HTMLButtonElement>(null)
  const [collapsing, setCollapsing] = useState(false)
  const [target, setTarget] = useState<{ x: number; y: number } | null>(null)

  const returnHome = () => {
    if (collapsing) {
      return
    }

    trackWebInteraction({
      action: 'not_found_returned_home',
      component: 'return_button',
      location: 'not_found',
      target: 'home',
    })

    if (window.matchMedia('(prefers-reduced-motion: reduce)').matches) {
      router.push(sitePath('/'))
      return
    }

    const bounds = buttonRef.current?.getBoundingClientRect()
    setTarget(
      bounds
        ? {
            x: bounds.left + bounds.width / 2,
            y: bounds.top + bounds.height / 2,
          }
        : { x: window.innerWidth / 2, y: window.innerHeight / 2 },
    )
    setCollapsing(true)
    window.setTimeout(() => router.push(sitePath('/')), 560)
  }

  return (
    <main className="relative min-h-screen overflow-hidden bg-background text-foreground">
      <div className="absolute inset-0 bg-[radial-gradient(circle_at_50%_25%,oklch(0.62_0.19_256_/_0.22),transparent_32%),linear-gradient(180deg,oklch(0.16_0.004_260),oklch(0.08_0_0))]" />
      <FileIconField
        collapseTarget={target}
        collapsing={collapsing}
        obstacleSelector="[data-file-bounce]"
      />

      <section className="relative z-10 flex min-h-screen flex-col items-center justify-center px-6 py-16 text-center">
        <a
          href={sitePath('/')}
          className="absolute top-6 left-6"
          data-file-bounce
          data-analytics-action="not_found_returned_home"
          data-analytics-component="logo"
          data-analytics-location="not_found"
          data-analytics-target="home"
        >
          <SortyLogo />
        </a>

        <div
          className="mb-8 flex size-16 items-center justify-center rounded-2xl border border-white/12 bg-white/8 shadow-2xl shadow-black/40 backdrop-blur-xl"
          data-file-bounce
        >
          <FolderSearch className="size-8 text-sky-200" strokeWidth={1.7} />
        </div>

        <p
          className="mb-3 font-mono text-sm font-medium tracking-[0.24em] text-sky-200/80 uppercase"
          data-file-bounce
        >
          404
        </p>
        <h1
          className="max-w-2xl text-4xl font-semibold tracking-tight text-balance sm:text-6xl"
          data-file-bounce
        >
          This folder is empty
        </h1>
        <p
          className="mt-5 max-w-xl text-base leading-7 text-muted-foreground sm:text-lg"
          data-file-bounce
        >
          The page you were looking for moved, vanished, or never made it into
          the plan.
        </p>

        <button
          ref={buttonRef}
          type="button"
          onClick={returnHome}
          disabled={collapsing}
          data-file-bounce
          className={cn(
            'btn-download relative mt-9 inline-flex h-12 items-center justify-center gap-2 rounded-full px-6 text-sm font-semibold transition-transform duration-200 hover:scale-[1.02] focus-visible:ring-3 focus-visible:ring-sky-300/45 focus-visible:outline-none disabled:pointer-events-none disabled:opacity-95',
            collapsing && 'scale-105 shadow-sky-400/50',
          )}
        >
          {collapsing && (
            <>
              <span className="absolute inset-[-10px] animate-ping rounded-full border border-sky-200/50" />
              <span className="absolute inset-[-18px] rounded-full border border-sky-300/20" />
            </>
          )}
          <ArrowLeft
            className={cn(
              'relative size-4 transition-transform duration-200',
              collapsing && '-translate-x-1',
            )}
          />
          <span className="relative">
            {collapsing ? 'Returning...' : 'Return to website'}
          </span>
        </button>
      </section>
    </main>
  )
}

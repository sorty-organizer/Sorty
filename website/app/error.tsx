'use client'

import { useEffect } from 'react'
import { trackWebInteraction } from '@/lib/analytics'

export default function ErrorPage({
  error,
  reset,
}: {
  error: Error & { digest?: string }
  reset: () => void
}) {
  useEffect(() => {
    void import('@/lib/reliability').then(({ captureWebsiteException }) =>
      captureWebsiteException(error, {
        surface: 'route_error_boundary',
        handled: true,
        cause: 'render_failed',
      }),
    )
  }, [error])

  return (
    <main className="grid min-h-screen place-items-center px-6 text-center">
      <div className="max-w-md">
        <p className="text-sm font-medium text-primary">Something went wrong</p>
        <h1 className="mt-3 text-3xl font-semibold tracking-tight">
          Sorty&apos;s site couldn&apos;t finish loading.
        </h1>
        <p className="mt-4 text-sm leading-relaxed text-muted-foreground">
          You can try this page again. The report contains technical context
          only, without form text, query strings, or personal data.
        </p>
        <button
          type="button"
          onClick={() => {
            trackWebInteraction({
              action: 'error_retry_clicked',
              component: 'error_boundary',
              location: 'route_error',
              outcome: 'retrying',
            })
            reset()
          }}
          className="mt-6 rounded-full bg-primary px-6 py-3 text-sm font-medium text-primary-foreground"
        >
          Try again
        </button>
      </div>
    </main>
  )
}

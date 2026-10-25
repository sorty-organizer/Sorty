'use client'

import { Check, Copy, Download, Terminal, X } from 'lucide-react'
import type { AnchorHTMLAttributes, ReactNode } from 'react'
import { useCallback, useEffect, useId, useRef, useState } from 'react'
import { createPortal } from 'react-dom'
import { cn } from '@/lib/utils'
import {
  trackDownloadClicked,
  trackDownloadNoticeViewed,
  trackTerminalCommandCopied,
  trackWebInteraction,
} from '@/lib/analytics'

const XATTR_COMMAND = 'sudo xattr -cr /Applications/Sorty.app'

type CopyFeedback = 'idle' | 'copied' | 'failed'

type DownloadButtonProps = Omit<
  AnchorHTMLAttributes<HTMLAnchorElement>,
  'children' | 'className' | 'href' | 'rel' | 'target'
> & {
  href: string
  children: ReactNode
  className?: string
  analyticsLocation: string
}

export function DownloadButton({
  href,
  children,
  className,
  analyticsLocation,
  onClick,
  ...props
}: DownloadButtonProps) {
  const [showNotice, setShowNotice] = useState(false)
  const [copyFeedback, setCopyFeedback] = useState<CopyFeedback>('idle')
  const intentShellRef = useRef<HTMLSpanElement>(null)
  const copyFeedbackTimeout = useRef<number | null>(null)
  const modalPanelRef = useRef<HTMLDivElement>(null)
  const titleId = useId()
  const descriptionId = useId()

  const widthClassName = className
    ?.split(/\s+/)
    .filter((token) => /^(?:\w+:)*w-/.test(token))
    .join(' ')

  const dismissDownloadNotice = useCallback(
    (source: 'backdrop' | 'close_button' | 'done_button' | 'escape_key') => {
      setShowNotice(false)
      trackWebInteraction({
        action: 'download_notice_dismissed',
        component: 'download_notice',
        location: analyticsLocation,
        target: source,
        outcome: copyFeedback === 'copied' ? 'command_copied' : 'not_copied',
      })
    },
    [analyticsLocation, copyFeedback],
  )

  useEffect(() => {
    if (!showNotice) {
      return
    }

    const previousOverflow = document.documentElement.style.overflow
    const handleKeyDown = (event: KeyboardEvent) => {
      if (event.key === 'Escape') {
        dismissDownloadNotice('escape_key')
      }
    }

    document.documentElement.style.overflow = 'hidden'
    window.addEventListener('keydown', handleKeyDown)
    modalPanelRef.current?.focus({ preventScroll: true })

    return () => {
      document.documentElement.style.overflow = previousOverflow
      window.removeEventListener('keydown', handleKeyDown)
    }
  }, [dismissDownloadNotice, showNotice])

  useEffect(() => {
    return () => {
      if (copyFeedbackTimeout.current !== null) {
        window.clearTimeout(copyFeedbackTimeout.current)
      }
    }
  }, [])

  useEffect(() => {
    const shell = intentShellRef.current
    if (!shell || window.matchMedia('(prefers-reduced-motion: reduce)').matches) {
      return
    }

    let frame = 0
    let pointerX = 0
    let pointerY = 0

    const updateIntent = () => {
      frame = 0
      const rect = shell.getBoundingClientRect()
      const dx = Math.max(rect.left - pointerX, 0, pointerX - rect.right)
      const dy = Math.max(rect.top - pointerY, 0, pointerY - rect.bottom)
      const distance = Math.hypot(dx, dy)
      const intent = Math.max(0, 1 - distance / 180) ** 2

      shell.style.setProperty('--download-intent', intent.toFixed(3))
    }

    const scheduleIntent = (event: PointerEvent) => {
      pointerX = event.clientX
      pointerY = event.clientY

      if (!frame) {
        frame = window.requestAnimationFrame(updateIntent)
      }
    }

    const resetIntent = () => {
      if (frame) {
        window.cancelAnimationFrame(frame)
        frame = 0
      }

      shell.style.setProperty('--download-intent', '0')
    }

    window.addEventListener('pointermove', scheduleIntent, { passive: true })
    window.addEventListener('pointerleave', resetIntent)
    window.addEventListener('blur', resetIntent)

    return () => {
      if (frame) {
        window.cancelAnimationFrame(frame)
      }

      window.removeEventListener('pointermove', scheduleIntent)
      window.removeEventListener('pointerleave', resetIntent)
      window.removeEventListener('blur', resetIntent)
    }
  }, [])

  function showCopyFeedback(nextFeedback: CopyFeedback) {
    if (copyFeedbackTimeout.current !== null) {
      window.clearTimeout(copyFeedbackTimeout.current)
      copyFeedbackTimeout.current = null
    }

    setCopyFeedback(nextFeedback)

    copyFeedbackTimeout.current = window.setTimeout(
      () => {
        setCopyFeedback('idle')
        copyFeedbackTimeout.current = null
      },
      nextFeedback === 'failed' ? 2400 : 1700,
    )
  }

  async function writeClipboardText(text: string) {
    if (navigator.clipboard?.writeText && window.isSecureContext) {
      try {
        await navigator.clipboard.writeText(text)
        return
      } catch {
        // Fall through to the textarea path for browsers that expose the API
        // but reject it because of permissions or focus quirks.
      }
    }

    const textarea = document.createElement('textarea')
    textarea.value = text
    textarea.setAttribute('readonly', '')
    textarea.style.position = 'fixed'
    textarea.style.left = '-9999px'
    textarea.style.top = '0'
    document.body.appendChild(textarea)
    textarea.focus()
    textarea.select()
    textarea.setSelectionRange(0, textarea.value.length)
    const didCopy = document.execCommand('copy')
    textarea.remove()

    if (!didCopy) {
      throw new Error('Copy command failed')
    }
  }

  async function copyCommand() {
    showCopyFeedback('copied')

    try {
      await writeClipboardText(XATTR_COMMAND)
      trackTerminalCommandCopied(analyticsLocation, 'succeeded')
      trackWebInteraction({
        action: 'terminal_command_copied',
        component: 'download_notice',
        location: analyticsLocation,
        target: 'quarantine_command',
        outcome: 'succeeded',
      })
    } catch {
      showCopyFeedback('failed')
      trackTerminalCommandCopied(analyticsLocation, 'failed')
      trackWebInteraction({
        action: 'terminal_command_copied',
        component: 'download_notice',
        location: analyticsLocation,
        target: 'quarantine_command',
        outcome: 'failed',
      })
    }
  }

  function showDownloadNotice() {
    if (copyFeedbackTimeout.current !== null) {
      window.clearTimeout(copyFeedbackTimeout.current)
      copyFeedbackTimeout.current = null
    }

    setCopyFeedback('idle')
    setShowNotice(true)
    trackDownloadClicked(analyticsLocation)
    trackDownloadNoticeViewed(analyticsLocation)
    trackWebInteraction({
      action: 'download_started',
      component: 'download_button',
      location: analyticsLocation,
      target: 'sorty_zip',
    })
  }

  const copySucceeded = copyFeedback === 'copied'
  const copyFailed = copyFeedback === 'failed'

  const notice =
    showNotice &&
    typeof document !== 'undefined' &&
    createPortal(
      <div
        className="download-modal-backdrop fixed inset-0 z-[100] grid place-items-end bg-black/45 p-3 backdrop-blur-md sm:place-items-center sm:p-6"
        onMouseDown={(event) => {
          if (event.target === event.currentTarget) {
            dismissDownloadNotice('backdrop')
          }
        }}
      >
        <div
          ref={modalPanelRef}
          role="dialog"
          aria-modal="true"
          aria-labelledby={titleId}
          aria-describedby={descriptionId}
          tabIndex={-1}
          className="download-modal-panel relative max-h-[calc(100dvh-1.5rem)] w-full max-w-[480px] overflow-x-hidden overflow-y-auto rounded-[1.75rem] border border-white/15 bg-background/95 text-left shadow-2xl shadow-black/55 outline-none backdrop-blur-2xl sm:max-h-[calc(100dvh-3rem)]"
        >
          <div
            aria-hidden
            className="absolute inset-x-0 top-0 h-px bg-gradient-to-r from-transparent via-primary/70 to-transparent"
          />
          <div
            aria-hidden
            className="absolute -right-20 -top-24 size-56 rounded-full bg-primary/20 blur-3xl"
          />

          <div className="relative p-4 sm:p-5">
            <div className="grid grid-cols-[auto_minmax(0,1fr)_auto] items-start gap-3.5">
              <div className="flex size-11 shrink-0 items-center justify-center rounded-2xl bg-brand text-white shadow-lg shadow-brand/30">
                <Download className="size-5" />
              </div>

              <div className="min-w-0">
                <p
                  id={titleId}
                  className="text-base font-semibold text-foreground"
                >
                  Download started
                </p>
                <p
                  id={descriptionId}
                  className="mt-1 max-w-[36ch] text-sm leading-snug text-muted-foreground"
                >
                  Open Sorty.zip, move Sorty.app to Applications, then run this
                  Terminal command if macOS blocks the app.
                </p>
              </div>

              <button
                type="button"
                onClick={() => dismissDownloadNotice('close_button')}
                className="flex size-8 shrink-0 items-center justify-center rounded-full text-muted-foreground transition-colors hover:bg-secondary hover:text-foreground"
                aria-label="Dismiss download notice"
              >
                <X className="size-4" />
              </button>
            </div>

            <div className="mt-4 rounded-2xl border border-border bg-secondary/55 p-2 shadow-inner shadow-black/20">
              <div className="flex items-center gap-2 px-2 pb-2 pt-1 text-[11px] font-medium text-muted-foreground">
                <Terminal className="size-3.5" />
                Terminal
              </div>
              <div
                className={cn(
                  'copy-command-row grid gap-2 rounded-xl border border-white/10 bg-background/70 p-2 transition-colors duration-300 sm:grid-cols-[minmax(0,1fr)_auto] sm:items-center',
                  copySucceeded && 'is-copied border-brand/45',
                  copyFailed && 'border-destructive/55',
                )}
              >
                <code className="min-w-0 break-all px-1 text-xs leading-relaxed text-foreground">
                  {XATTR_COMMAND}
                </code>
                <button
                  type="button"
                  onClick={() => void copyCommand()}
                  className={cn(
                    'copy-command-button grid h-8 min-w-[72px] shrink-0 place-items-center rounded-lg px-2.5 text-xs font-medium',
                    copySucceeded && 'is-copied gap-1.5 bg-brand text-white',
                    copyFailed && 'is-failed gap-1.5 bg-destructive text-white',
                    copyFeedback === 'idle' &&
                      'gap-1.5 bg-foreground text-background',
                  )}
                  aria-label={
                    copySucceeded
                      ? 'Terminal command copied'
                      : copyFailed
                        ? 'Retry copying Terminal command'
                        : 'Copy Terminal command'
                  }
                >
                  <span className="copy-command-shine" aria-hidden />
                  <span
                    aria-hidden="true"
                    className={cn(
                      'copy-command-label col-start-1 row-start-1',
                      copyFeedback === 'idle' && 'is-visible',
                    )}
                  >
                    <Copy className="size-3.5" />
                    Copy
                  </span>
                  <span
                    aria-hidden="true"
                    className={cn(
                      'copy-command-label col-start-1 row-start-1',
                      copySucceeded && 'is-visible is-copied',
                    )}
                  >
                    <Check className="copy-command-check size-3.5" />
                    Copied
                  </span>
                  <span
                    aria-hidden="true"
                    className={cn(
                      'copy-command-label col-start-1 row-start-1',
                      copyFailed && 'is-visible',
                    )}
                  >
                    <X className="size-3.5" />
                    Retry
                  </span>
                </button>
                <span className="sr-only" aria-live="polite">
                  {copySucceeded
                    ? 'Terminal command copied'
                    : copyFailed
                      ? 'Could not copy Terminal command'
                      : ''}
                </span>
              </div>
            </div>

            <div className="mt-4 grid gap-2 sm:grid-cols-[1fr_auto] sm:items-center">
              <p className="text-xs leading-relaxed text-muted-foreground">
                Paste it into Terminal, press Return, enter your Mac password
                (typing stays hidden), then open Sorty from Applications. It
                only changes extended attributes on that Sorty.app copy.
              </p>
              <button
                type="button"
                onClick={() => dismissDownloadNotice('done_button')}
                className="modal-action-highlight relative justify-self-start overflow-hidden rounded-full border border-border bg-secondary/55 px-4 py-2 text-xs font-medium text-foreground transition-colors hover:bg-secondary sm:justify-self-end"
              >
                <span className="relative z-10">Done</span>
              </button>
            </div>
          </div>
        </div>
      </div>,
      document.body,
    )

  return (
    <>
      <span
        ref={intentShellRef}
        className={cn('download-intent-shell', widthClassName)}
      >
        <div className={cn('download-beam', widthClassName)}>
          <a
            href={href}
            onClick={(event) => {
              onClick?.(event)

              if (!event.defaultPrevented) {
                showDownloadNotice()
              }
            }}
            className={cn('btn-download flex items-center rounded-full', className)}
            data-webmcp-download
            {...props}
          >
            {children}
          </a>
        </div>
      </span>

      {notice}
    </>
  )
}

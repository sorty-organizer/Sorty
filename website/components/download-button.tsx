'use client'

import { Check, Copy, DownloadSimple, TerminalWindow, X } from '@phosphor-icons/react'
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
  const copyFeedbackTimeout = useRef<number | null>(null)
  const modalPanelRef = useRef<HTMLDivElement>(null)
  const titleId = useId()
  const descriptionId = useId()

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
        className="download-modal-backdrop fixed inset-0 z-[100] grid place-items-end bg-black/60 p-3 backdrop-blur-md sm:place-items-center sm:p-6"
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
          className="download-modal-panel relative max-h-[calc(100dvh-1.5rem)] w-full max-w-[480px] overflow-x-hidden overflow-y-auto rounded-3xl border border-white/10 bg-card text-left shadow-2xl shadow-black outline-none sm:max-h-[calc(100dvh-3rem)]"
        >
          <div className="relative p-4 sm:p-6">
            <div className="grid grid-cols-[auto_minmax(0,1fr)_auto] items-start gap-4">
              <div className="flex size-11 shrink-0 items-center justify-center rounded-2xl bg-brand text-white">
                <DownloadSimple className="size-5" />
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
                  className="mt-1 max-w-sm text-sm text-muted-foreground"
                >
                  Open Sorty.zip, move Sorty.app to Applications, then run this
                  Terminal command if macOS blocks the app.
                </p>
              </div>

              <button
                type="button"
                onClick={() => dismissDownloadNotice('close_button')}
                className="flex size-8 shrink-0 items-center justify-center rounded-full text-muted-foreground transition-colors duration-300 ease-fluid hover:bg-secondary hover:text-foreground"
                aria-label="Dismiss download notice"
              >
                <X className="size-4" />
              </button>
            </div>

            <div className="mt-4 rounded-2xl border border-border bg-secondary p-2">
              <div className="flex items-center gap-2 px-2 pb-2 pt-1 text-xs font-medium text-muted-foreground">
                <TerminalWindow className="size-4" />
                Terminal
              </div>
              <div
                className={cn(
                  'copy-command-row grid gap-2 rounded-lg border border-white/10 bg-background p-2 transition-colors duration-300 sm:grid-cols-[minmax(0,1fr)_auto] sm:items-center',
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
                    'copy-command-button grid h-8 min-w-20 shrink-0 place-items-center rounded-sm px-3 text-xs font-medium',
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
                    <Copy className="size-4" />
                    Copy
                  </span>
                  <span
                    aria-hidden="true"
                    className={cn(
                      'copy-command-label col-start-1 row-start-1',
                      copySucceeded && 'is-visible is-copied',
                    )}
                  >
                    <Check className="copy-command-check size-4" />
                    Copied
                  </span>
                  <span
                    aria-hidden="true"
                    className={cn(
                      'copy-command-label col-start-1 row-start-1',
                      copyFailed && 'is-visible',
                    )}
                  >
                    <X className="size-4" />
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
                className="justify-self-start rounded-lg bg-secondary px-3 py-2 text-sm font-semibold text-foreground transition-[background-color,transform] duration-300 ease-fluid hover:bg-accent active:scale-[0.98] focus-visible:outline-2 focus-visible:outline-ring sm:justify-self-end"
              >
                Done
              </button>
            </div>
          </div>
        </div>
      </div>,
      document.body,
    )

  return (
    <>
      <a
        href={href}
        onClick={(event) => {
          onClick?.(event)

          if (!event.defaultPrevented) {
            showDownloadNotice()
          }
        }}
        className={cn('btn-download inline-flex items-center', className)}
        data-webmcp-download
        {...props}
      >
        {children}
      </a>

      {notice}
    </>
  )
}

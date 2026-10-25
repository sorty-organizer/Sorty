'use client'

import { useEffect, useState } from 'react'
import Link from 'next/link'
import { usePathname } from 'next/navigation'
import { AppleLogo } from '@phosphor-icons/react'
import { cn } from '@/lib/utils'
import { SortyLogo } from '@/components/sorty-logo'
import { GithubIcon } from '@/components/github-icon'
import { DownloadButton } from '@/components/download-button'
import { DOWNLOAD_URL, GITHUB_URL } from '@/lib/site-metadata'

const LINKS = [
  { label: 'Features', href: '/#features', section: 'features' },
  { label: 'How it works', href: '/#how-it-works', section: 'how-it-works' },
  { label: 'Pricing', href: '/#pricing', section: 'pricing' },
  { label: 'FAQ', href: '/#faq', section: 'faq' },
  { label: 'Changelog', href: '/changelog/' },
]

const STAGGER = ['delay-100', 'delay-150', 'delay-200', 'delay-250', 'delay-300', 'delay-350']

/** Tracks which homepage section sits under the middle of the viewport. */
function useActiveSection(enabled: boolean) {
  const [active, setActive] = useState<string | null>(null)

  useEffect(() => {
    if (!enabled) return

    const observer = new IntersectionObserver(
      (entries) => {
        for (const entry of entries) {
          if (entry.isIntersecting) setActive(entry.target.id)
        }
      },
      { rootMargin: '-45% 0px -50% 0px' },
    )
    for (const link of LINKS) {
      const el = link.section && document.getElementById(link.section)
      if (el) observer.observe(el)
    }
    const top = document.getElementById('top')
    if (top) observer.observe(top)
    return () => observer.disconnect()
  }, [enabled])

  return enabled ? active : null
}

export function SiteNav() {
  const [open, setOpen] = useState(false)
  const pathname = usePathname()
  const onHome = pathname === '/' || pathname === ''
  const activeSection = useActiveSection(onHome)

  useEffect(() => {
    if (!open) return
    const previousOverflow = document.documentElement.style.overflow
    const onKey = (event: KeyboardEvent) => event.key === 'Escape' && setOpen(false)
    document.documentElement.style.overflow = 'hidden'
    window.addEventListener('keydown', onKey)
    return () => {
      document.documentElement.style.overflow = previousOverflow
      window.removeEventListener('keydown', onKey)
    }
  }, [open])

  const isActive = (link: (typeof LINKS)[number]) =>
    link.section
      ? onHome && activeSection === link.section
      : pathname.startsWith(link.href.replace(/\/$/, ''))

  return (
    <header className="fixed inset-x-0 top-0 z-50 flex justify-center px-4">
      <nav
        aria-label="Main"
        className="relative z-10 mx-auto mt-6 flex w-max max-w-full items-center gap-2 rounded-full border border-white/10 bg-black/60 p-2 pl-4 backdrop-blur-xl"
      >
        <Link
          href="/#top"
          className="mr-2 shrink-0 rounded-full focus-visible:outline-2 focus-visible:outline-offset-4 focus-visible:outline-ring"
          data-analytics-action="navigation_opened"
          data-analytics-component="logo"
          data-analytics-location="navigation"
          data-analytics-target="home"
        >
          <SortyLogo />
        </Link>

        <ul className="hidden items-center md:flex">
          {LINKS.map((link) => (
            <li key={link.href}>
              <Link
                href={link.href}
                scroll={link.section ? undefined : false}
                aria-current={isActive(link) ? 'page' : undefined}
                className={cn(
                  'block rounded-full px-3 py-2 text-sm font-medium transition-colors duration-300 ease-fluid focus-visible:outline-2 focus-visible:outline-ring',
                  isActive(link)
                    ? 'bg-white/10 text-foreground'
                    : 'text-muted-foreground hover:text-foreground',
                )}
                data-analytics-action="navigation_opened"
                data-analytics-component="text_link"
                data-analytics-location="navigation"
                data-analytics-target={link.label}
              >
                {link.label}
              </Link>
            </li>
          ))}
        </ul>

        <a
          href={GITHUB_URL}
          target="_blank"
          rel="noreferrer"
          aria-label="Sorty on GitHub"
          className="hidden size-9 items-center justify-center rounded-full text-muted-foreground transition-colors duration-300 ease-fluid hover:bg-white/10 hover:text-foreground focus-visible:outline-2 focus-visible:outline-ring sm:flex"
          data-analytics-action="source_opened"
          data-analytics-component="icon_link"
          data-analytics-location="navigation"
          data-analytics-target="github"
        >
          <GithubIcon className="size-4" />
        </a>
        <DownloadButton
          href={DOWNLOAD_URL}
          analyticsLocation="navigation"
          className="gap-2 rounded-full px-3 py-2 text-sm font-semibold"
        >
          <AppleLogo weight="fill" className="size-4" aria-hidden />
          Download
        </DownloadButton>

        <button
          type="button"
          onClick={() => setOpen((v) => !v)}
          className="relative flex size-9 items-center justify-center rounded-full text-foreground transition-colors duration-300 ease-fluid hover:bg-white/10 focus-visible:outline-2 focus-visible:outline-ring md:hidden"
          aria-label={open ? 'Close menu' : 'Open menu'}
          aria-expanded={open}
          aria-controls="mobile-menu"
          data-analytics-action="mobile_menu_toggled"
          data-analytics-component="menu_button"
          data-analytics-location="navigation"
          data-analytics-target={open ? 'closed' : 'opened'}
        >
          <span
            aria-hidden
            className={cn(
              'absolute h-0.5 w-4 rounded-full bg-current transition-transform duration-700 ease-fluid',
              open ? 'rotate-45' : '-translate-y-1',
            )}
          />
          <span
            aria-hidden
            className={cn(
              'absolute h-0.5 w-4 rounded-full bg-current transition-transform duration-700 ease-fluid',
              open ? '-rotate-45' : 'translate-y-1',
            )}
          />
        </button>
      </nav>

      <div
        id="mobile-menu"
        aria-hidden={!open}
        inert={!open}
        className={cn(
          'fixed inset-0 flex flex-col justify-center bg-black/80 px-8 backdrop-blur-3xl transition-opacity duration-700 ease-fluid md:hidden',
          open ? 'opacity-100' : 'pointer-events-none opacity-0',
        )}
      >
        <ul className="space-y-2">
          {LINKS.map((link, i) => (
            <li
              key={link.href}
              className={cn(
                'transition-all duration-700 ease-fluid',
                open ? `translate-y-0 opacity-100 ${STAGGER[i]}` : 'translate-y-12 opacity-0',
              )}
            >
              <Link
                href={link.href}
                scroll={link.section ? undefined : false}
                onClick={() => setOpen(false)}
                aria-current={isActive(link) ? 'page' : undefined}
                className={cn(
                  'block py-2 text-4xl font-semibold tracking-tight',
                  isActive(link) ? 'text-foreground' : 'text-muted-foreground',
                )}
                data-analytics-action="navigation_opened"
                data-analytics-component="mobile_text_link"
                data-analytics-location="mobile_navigation"
                data-analytics-target={link.label}
              >
                {link.label}
              </Link>
            </li>
          ))}
          <li
            className={cn(
              'pt-6 transition-all duration-700 ease-fluid',
              open ? `translate-y-0 opacity-100 ${STAGGER[5]}` : 'translate-y-12 opacity-0',
            )}
          >
            <a
              href={GITHUB_URL}
              target="_blank"
              rel="noreferrer"
              className="inline-flex items-center gap-2 text-base font-medium text-muted-foreground"
              data-analytics-action="source_opened"
              data-analytics-component="mobile_text_link"
              data-analytics-location="mobile_navigation"
              data-analytics-target="github"
            >
              <GithubIcon className="size-4" />
              View source on GitHub
            </a>
          </li>
        </ul>
      </div>
    </header>
  )
}

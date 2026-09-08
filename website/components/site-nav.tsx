'use client'

import { useEffect, useState } from 'react'
import Link from 'next/link'
import { Heart, Menu, X } from 'lucide-react'
import { cn } from '@/lib/utils'
import { SortyLogo } from '@/components/sorty-logo'
import { GithubIcon } from '@/components/github-icon'
import { DownloadButton } from '@/components/download-button'

const LINKS = [
  { label: 'Features', href: '/#features' },
  { label: 'Changelog', href: '/changelog/' },
  { label: 'Privacy', href: '/privacy-policy/' },
]

const GITHUB_URL = 'https://github.com/sorty-organizer/Sorty'
const SPONSOR_URL = 'https://github.com/sponsors/shirishpothi'
const DOWNLOAD_URL = `${GITHUB_URL}/releases/latest/download/Sorty.zip`

export function SiteNav() {
  const [scrolled, setScrolled] = useState(false)
  const [open, setOpen] = useState(false)

  useEffect(() => {
    const onScroll = () => setScrolled(window.scrollY > 16)
    onScroll()
    window.addEventListener('scroll', onScroll, { passive: true })
    return () => window.removeEventListener('scroll', onScroll)
  }, [])

  return (
    <header className="fixed inset-x-0 top-0 z-50 flex justify-center px-4 pt-4">
      <div className="relative w-full max-w-3xl">
      <nav
        className={cn(
          'flex w-full items-center justify-between gap-2 rounded-full border px-2 py-2 pl-4 transition-all duration-500',
          scrolled
            ? 'border-border bg-background/70 shadow-lg shadow-black/30 backdrop-blur-xl'
            : 'border-transparent bg-background/30 backdrop-blur-md',
        )}
      >
        <Link
          href="/#top"
          className="shrink-0"
          data-analytics-action="navigation_opened"
          data-analytics-component="logo"
          data-analytics-location="navigation"
          data-analytics-target="home"
        >
          <SortyLogo />
        </Link>

        <div className="hidden items-center gap-1 md:flex">
          {LINKS.map((link) => (
            <Link
              key={link.href}
              href={link.href}
              scroll={link.href.includes('#') ? undefined : false}
              className="rounded-full px-3 py-1.5 text-sm text-muted-foreground transition-colors hover:text-foreground"
              data-analytics-action="navigation_opened"
              data-analytics-component="text_link"
              data-analytics-location="navigation"
              data-analytics-target={link.label}
            >
              {link.label}
            </Link>
          ))}
        </div>

        <div className="flex items-center gap-2">
          <Link
            href={GITHUB_URL}
            target="_blank"
            rel="noreferrer"
            className="hidden items-center gap-1.5 rounded-full px-3 py-1.5 text-sm text-muted-foreground transition-colors hover:text-foreground sm:flex"
            data-analytics-action="source_opened"
            data-analytics-component="text_link"
            data-analytics-location="navigation"
            data-analytics-target="github"
          >
            <GithubIcon className="size-4" />
            GitHub
          </Link>
          <a
            href={SPONSOR_URL}
            target="_blank"
            rel="noreferrer"
            className="btn-support hidden items-center gap-1.5 rounded-full px-3 py-1.5 text-sm font-medium lg:flex"
            data-analytics-action="support_opened"
            data-analytics-component="text_link"
            data-analytics-location="navigation"
            data-analytics-target="github_sponsors"
          >
            <Heart className="support-heart-icon size-4" />
            Donate
          </a>
          <DownloadButton
            href={DOWNLOAD_URL}
            analyticsLocation="navigation"
            className="gap-1.5 px-4 py-2 text-sm font-medium"
          >
            <span
              className="text-[16px] leading-none"
              aria-hidden="true"
            >
              
            </span>
            <span>Download</span>
          </DownloadButton>
          <button
            type="button"
            onClick={() => setOpen((v) => !v)}
            className="relative flex size-9 items-center justify-center rounded-full text-muted-foreground transition-colors hover:text-foreground md:hidden"
            aria-label={open ? 'Close menu' : 'Open menu'}
            data-analytics-action="mobile_menu_toggled"
            data-analytics-component="menu_button"
            data-analytics-location="navigation"
            data-analytics-target={open ? 'closed' : 'opened'}
          >
            <Menu
              className={cn(
                'absolute size-5 transition-all duration-300',
                open ? 'rotate-90 scale-75 opacity-0' : 'rotate-0 scale-100 opacity-100',
              )}
            />
            <X
              className={cn(
                'absolute size-5 transition-all duration-300',
                open ? 'rotate-0 scale-100 opacity-100' : '-rotate-90 scale-75 opacity-0',
              )}
            />
          </button>
        </div>
      </nav>

      <div
        aria-hidden={!open}
        className={cn(
          'absolute inset-x-0 top-full mt-2 origin-top rounded-3xl border border-border bg-background/80 p-2 backdrop-blur-xl transition-all duration-300 ease-out md:hidden',
          open
            ? 'visible translate-y-0 scale-100 opacity-100'
            : 'invisible -translate-y-2 scale-[0.97] opacity-0',
        )}
      >
        {LINKS.map((link) => (
          <Link
            key={link.href}
            href={link.href}
            scroll={link.href.includes('#') ? undefined : false}
            onClick={() => setOpen(false)}
            className="block rounded-2xl px-4 py-3 text-sm text-muted-foreground transition-colors hover:bg-secondary hover:text-foreground"
            data-analytics-action="navigation_opened"
            data-analytics-component="mobile_text_link"
            data-analytics-location="mobile_navigation"
            data-analytics-target={link.label}
          >
            {link.label}
          </Link>
        ))}
        <a
          href={GITHUB_URL}
          target="_blank"
          rel="noreferrer"
          className="flex items-center gap-2 rounded-2xl px-4 py-3 text-sm text-muted-foreground transition-colors hover:bg-secondary hover:text-foreground"
          data-analytics-action="source_opened"
          data-analytics-component="mobile_text_link"
          data-analytics-location="mobile_navigation"
          data-analytics-target="github"
        >
          <GithubIcon className="size-4" />
          View source on GitHub
        </a>
        <a
          href={SPONSOR_URL}
          target="_blank"
          rel="noreferrer"
          className="btn-support mt-2 flex items-center justify-center gap-2 rounded-full px-4 py-3 text-sm font-medium"
          data-analytics-action="support_opened"
          data-analytics-component="mobile_text_link"
          data-analytics-location="mobile_navigation"
          data-analytics-target="github_sponsors"
        >
          <Heart className="support-heart-icon size-4" />
          Donate
        </a>
      </div>
      </div>
    </header>
  )
}

import type { Metadata, Viewport } from 'next'
import { Geist, Geist_Mono } from 'next/font/google'
import { sitePath } from '@/lib/site-paths'
import {
  GITHUB_URL,
  OG_IMAGE_PATH,
  SITE_DESCRIPTION,
  SITE_NAME,
  SITE_URL,
} from '@/lib/site-metadata'
import { SelectionHighlighter } from '@/components/selection-highlighter'
import { RouteScrollReset } from '@/components/route-scroll-reset'
import { RevealObserver } from '@/components/reveal-observer'
import { AnalyticsProvider } from '@/components/analytics-provider'
import { WebMCPTools } from '@/components/webmcp-tools'
import './globals.css'

const geistSans = Geist({ variable: '--font-geist-sans', subsets: ['latin'] })
const geistMono = Geist_Mono({
  variable: '--font-geist-mono',
  subsets: ['latin'],
})

export const metadata: Metadata = {
  metadataBase: new URL(SITE_URL),
  title: {
    default: `${SITE_NAME} — AI folder organization for your Mac`,
    template: `%s — ${SITE_NAME}`,
  },
  description: SITE_DESCRIPTION,
  applicationName: SITE_NAME,
  generator: 'Next.js',
  authors: [{ name: 'The Sorty open-source project' }],
  creator: 'The Sorty open-source project',
  publisher: 'The Sorty open-source project',
  category: 'productivity',
  keywords: [
    SITE_NAME,
    'AI folder organizer',
    'Mac file organization',
    'macOS file organizer',
    'organize Downloads folder',
    'AI file management Mac',
    'open source Mac app',
    'private file organizer',
    'local AI Mac',
    'Ollama file organizer',
    'GPL v3 macOS app',
  ],
  alternates: {
    canonical: '/',
  },
  robots: {
    index: true,
    follow: true,
    googleBot: {
      index: true,
      follow: true,
      'max-image-preview': 'large',
      'max-snippet': -1,
      'max-video-preview': -1,
    },
  },
  openGraph: {
    type: 'website',
    siteName: SITE_NAME,
    title: `${SITE_NAME} — AI folder organization for your Mac`,
    description: SITE_DESCRIPTION,
    url: `${SITE_URL}/`,
    locale: 'en_US',
    images: [
      {
        url: OG_IMAGE_PATH,
        width: 1102,
        height: 754,
        alt: 'The Sorty app showing an AI-generated organization plan for a Downloads folder.',
      },
    ],
  },
  twitter: {
    card: 'summary_large_image',
    title: `${SITE_NAME} — AI folder organization for your Mac`,
    description: SITE_DESCRIPTION,
    images: [OG_IMAGE_PATH],
  },
  other: {
    'github:repository_url': GITHUB_URL,
  },
  icons: {
    shortcut: sitePath('/favicon.png'),
    icon: {
      url: sitePath('/favicon.png'),
      sizes: '96x96',
      type: 'image/png',
    },
    apple: sitePath('/apple-icon.png'),
  },
}

export const viewport: Viewport = {
  colorScheme: 'dark',
  themeColor: '#0b0c10',
}

export default function RootLayout({
  children,
}: Readonly<{
  children: React.ReactNode
}>) {
  return (
    <html
      lang="en"
      className={`dark ${geistSans.variable} ${geistMono.variable} bg-background`}
    >
      <body className="font-sans antialiased">
        <AnalyticsProvider>
          <RouteScrollReset />
          <RevealObserver />
          <SelectionHighlighter />
          <WebMCPTools />
          {children}
        </AnalyticsProvider>
      </body>
    </html>
  )
}

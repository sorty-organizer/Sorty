'use client'

import type { CaptureResult, Properties } from 'posthog-js'

export const WEBSITE_ANALYTICS_PREFERENCE_KEY =
  'sorty.website.analytics.preference'
export const WEBSITE_INTERNAL_TELEMETRY_KEY = 'sorty.website.internalTelemetry'

export function isWebsiteInternalTelemetry(): boolean {
  return (
    typeof window !== 'undefined' &&
    window.localStorage.getItem(WEBSITE_INTERNAL_TELEMETRY_KEY) === 'true'
  )
}

export type WebsiteAnalyticsPreference = 'allowed' | 'denied'

type InteractionProperties = {
  action: string
  component: string
  location: string
  target?: string
  outcome?: string
}

type ConversionProperties = {
  location: string
  outcome?: string
}

const POSTHOG_EVENT_ALLOWLIST = new Set([
  '$pageleave',
  '$pageview',
  '$web_vitals',
  'web:download_clicked',
  'web:download_notice_viewed',
  'web:interaction',
  'web:not_found_viewed',
  'web:privacy_policy_clicked',
  'web:route_clicked',
  'web:scroll_depth_reached',
  'web:section_viewed',
  'web:sponsor_clicked',
  'web:terminal_command_copied',
])

const PAGE_NAMES: Record<string, string> = {
  '/': 'home',
  '/changelog': 'changelog',
  '/press': 'press',
  '/privacy-policy': 'privacy_policy',
  '/terms': 'terms',
}

const SECTION_NAMES = new Set([
  'top',
  'how-it-works',
  'features',
  'privacy',
  'pricing',
  'faq',
  'footer',
])

const WEBSITE_PROPERTY_ALLOWLIST = new Set([
  '$browser',
  '$browser_version',
  '$current_url',
  '$device_type',
  '$geoip_disable',
  '$lib',
  '$lib_version',
  '$os',
  '$os_version',
  '$pageview_id',
  '$prev_pageview_duration',
  '$prev_pageview_id',
  '$prev_pageview_pathname',
  '$process_person_profile',
  '$session_id',
  'action',
  'analytics_scope',
  'component',
  'depth_percent',
  'destination_page_path',
  'distinct_id',
  'location',
  'outcome',
  'page_name',
  'page_path',
  'platform_surface',
  'previous_page_path',
  'section',
  'target',
  'token',
  'traffic_source',
])

const ANALYTICS_MAXIMUM_EVENTS_PER_MINUTE = 60
const ANALYTICS_MAXIMUM_EVENTS_PER_SESSION = 2_000
const APPROVED_POSTHOG_ORIGIN = 'https://us.i.posthog.com'

let isInitialized = false
let previousPagePath: string | undefined
let analyticsWindowStartedAt = 0
let analyticsWindowCount = 0
let analyticsSessionCount = 0
let posthogClient: (typeof import('posthog-js/dist/module.slim'))['default'] | undefined
let initializationPromise: Promise<void> | undefined
const pendingCaptures: Array<{ event: string; properties: Properties }> = []

function shouldCaptureAnalytics(now = Date.now()): boolean {
  if (analyticsSessionCount >= ANALYTICS_MAXIMUM_EVENTS_PER_SESSION) {
    return false
  }

  if (
    analyticsWindowStartedAt === 0 ||
    now - analyticsWindowStartedAt >= 60_000
  ) {
    analyticsWindowStartedAt = now
    analyticsWindowCount = 0
  }
  if (analyticsWindowCount >= ANALYTICS_MAXIMUM_EVENTS_PER_MINUTE) {
    return false
  }

  analyticsWindowCount += 1
  analyticsSessionCount += 1
  return true
}

function configuredPostHog():
  | { projectToken: string; host: string }
  | undefined {
  const projectToken = process.env.NEXT_PUBLIC_POSTHOG_PROJECT_TOKEN
  const host = process.env.NEXT_PUBLIC_POSTHOG_HOST

  if (!projectToken || !/^phc_[A-Za-z0-9_-]+$/.test(projectToken) || !host) {
    return undefined
  }

  try {
    const url = new URL(host)
    if (
      url.origin !== APPROVED_POSTHOG_ORIGIN ||
      url.pathname !== '/' ||
      url.search ||
      url.hash ||
      url.username ||
      url.password
    ) {
      return undefined
    }
    return { projectToken, host: url.origin }
  } catch {
    return undefined
  }
}

function readPreference(): WebsiteAnalyticsPreference | null {
  if (typeof window === 'undefined') {
    return null
  }

  const value = window.localStorage.getItem(WEBSITE_ANALYTICS_PREFERENCE_KEY)
  return value === 'allowed' || value === 'denied' ? value : null
}

function hasGlobalPrivacySignal(): boolean {
  if (typeof window === 'undefined' || typeof navigator === 'undefined') {
    return false
  }

  const navigatorWithGpc = navigator as Navigator & {
    globalPrivacyControl?: boolean
  }
  const windowWithDnt = window as Window & { doNotTrack?: string }

  return (
    navigatorWithGpc.globalPrivacyControl === true ||
    navigator.doNotTrack === '1' ||
    windowWithDnt.doNotTrack === '1'
  )
}

export function isWebsiteAnalyticsEnabled(): boolean {
  const preference = readPreference()
  if (preference === 'denied' || hasGlobalPrivacySignal()) {
    return false
  }

  return preference === 'allowed' || preference === null
}

function stripBasePath(pathname: string): string {
  const configuredBasePath = process.env.NEXT_PUBLIC_BASE_PATH ?? ''
  const basePath = configuredBasePath.replace(/\/+$/, '')
  let normalized = pathname || '/'

  if (basePath && normalized.startsWith(basePath)) {
    normalized = normalized.slice(basePath.length) || '/'
  }

  if (normalized.length > 1) {
    normalized = normalized.replace(/\/+$/, '')
  }

  return normalized || '/'
}

function safePagePath(pathname = window.location.pathname): string {
  const normalized = stripBasePath(pathname)
  return PAGE_NAMES[normalized] ? normalized : '/not-found'
}

function trafficSource(): string {
  if (!document.referrer) {
    return 'direct'
  }

  try {
    const hostname = new URL(document.referrer).hostname.toLowerCase()
    if (hostname === window.location.hostname) return 'internal'
    if (hostname === 'github.com' || hostname.endsWith('.github.com')) return 'github'
    if (
      ['google.', 'bing.com', 'duckduckgo.com', 'search.brave.com'].some(
        (value) => hostname.includes(value),
      )
    ) {
      return 'search'
    }
    if (
      ['reddit.com', 'x.com', 'twitter.com', 'linkedin.com'].some(
        (value) => hostname === value || hostname.endsWith(`.${value}`),
      )
    ) {
      return 'social'
    }
    return 'referral'
  } catch {
    return 'unknown'
  }
}

function sanitizeUrl(value: unknown): string | undefined {
  if (typeof value !== 'string') {
    return undefined
  }

  try {
    const url = new URL(value, window.location.origin)
    return `${url.origin}${url.pathname}`
  } catch {
    return undefined
  }
}

function sanitizeEvent(event: CaptureResult | null): CaptureResult | null {
  if (!event) {
    return null
  }
  if (!isWebsiteAnalyticsEnabled() || !POSTHOG_EVENT_ALLOWLIST.has(event.event)) {
    return null
  }

  const properties = event.properties ?? {}
  const currentUrl = sanitizeUrl(properties.$current_url)
  const safeProperties = Object.fromEntries(
    Object.entries(properties)
      .filter(
        ([key]) =>
          WEBSITE_PROPERTY_ALLOWLIST.has(key) ||
          key.startsWith('$web_vitals_'),
      )
      .map(([key, value]) => [key, sanitizeProperty(value)]),
  )

  if (currentUrl) {
    safeProperties.$current_url = currentUrl
  }
  safeProperties.$geoip_disable = true
  safeProperties.analytics_scope = 'anonymous_aggregate'
  safeProperties.is_internal = isWebsiteInternalTelemetry()
  safeProperties.platform_surface = 'website'
  event.properties = safeProperties
  return event
}

function sanitizeProperty(value: unknown): unknown {
  if (typeof value === 'string') {
    return value
      .slice(0, 500)
      .replace(/[?#][^\s)]+/g, '')
      .replace(
        /[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}/gi,
        '[redacted-email]',
      )
  }
  if (Array.isArray(value)) {
    return value.map(sanitizeProperty)
  }
  if (value && typeof value === 'object') {
    return Object.fromEntries(
      Object.entries(value).map(([key, nestedValue]) => [
        key,
        sanitizeProperty(nestedValue),
      ]),
    )
  }
  return value
}

function startWebsiteAnalytics(): Promise<void> | undefined {
  if (
    typeof window === 'undefined' ||
    isInitialized ||
    !isWebsiteAnalyticsEnabled()
  ) {
    return
  }

  const configuration = configuredPostHog()

  if (!configuration) {
    return
  }

  initializationPromise ??= import('posthog-js/dist/module.slim').then(
    ({ default: posthog }) => {
      if (!isWebsiteAnalyticsEnabled()) {
        initializationPromise = undefined
        return
      }

      posthogClient = posthog
      posthog.init(configuration.projectToken, {
        api_host: configuration.host,
        ui_host: 'https://us.posthog.com',
        defaults: '2026-05-30',
        autocapture: false,
        capture_pageview: false,
        capture_pageleave: true,
        capture_exceptions: false,
        capture_performance: {
          web_vitals_allowed_metrics: ['LCP', 'INP', 'CLS'],
          web_vitals_attribution: false,
        },
        capture_dead_clicks: false,
        person_profiles: 'never',
        persistence: 'sessionStorage',
        disable_persistence: false,
        disable_session_recording: true,
        enable_heatmaps: false,
        disable_surveys: true,
        advanced_disable_feature_flags: false,
        disable_external_dependency_loading: true,
        respect_dnt: true,
        request_batching: false,
        before_send: sanitizeEvent,
      })
      isInitialized = true

      for (const capture of pendingCaptures.splice(0)) {
        posthog.capture(capture.event, capture.properties)
      }
    },
  )
  return initializationPromise
}

export function initializeWebsiteAnalytics(): void {
  void startWebsiteAnalytics()
}

export function applyWebsiteAnalyticsPreference(
  preference: WebsiteAnalyticsPreference,
): void {
  if (preference === 'denied') {
    pendingCaptures.length = 0
    if (isInitialized) {
      posthogClient?.opt_out_capturing()
      posthogClient?.featureFlags?.reset()
    }
    return
  }

  if (!isWebsiteAnalyticsEnabled()) {
    return
  }

  if (isInitialized) {
    posthogClient?.opt_in_capturing({ captureEventName: false })
    return
  }

  void startWebsiteAnalytics()?.then(() =>
    posthogClient?.opt_in_capturing({ captureEventName: false }),
  )
}

function capture(event: string, properties: Properties): void {
  if (!isWebsiteAnalyticsEnabled() || !shouldCaptureAnalytics()) {
    return
  }

  const safeProperties = {
    ...properties,
    platform_surface: 'website',
  }
  if (isInitialized && posthogClient) {
    posthogClient.capture(event, safeProperties)
  } else if (pendingCaptures.length < 100) {
    pendingCaptures.push({ event, properties: safeProperties })
  }
}

export function trackPageView(pathname: string): void {
  const pagePath = safePagePath(pathname)
  const pageName = PAGE_NAMES[pagePath] ?? 'not_found'
  capture('$pageview', {
    $current_url: `${window.location.origin}${pagePath}`,
    page_name: pageName,
    page_path: pagePath,
    previous_page_path: previousPagePath,
    traffic_source: trafficSource(),
  })
  previousPagePath = pagePath

  if (pageName === 'not_found') {
    capture('web:not_found_viewed', {
      page_name: pageName,
      page_path: pagePath,
    })
  }
}

export function trackSectionView(section: string, pagePath: string): void {
  if (!SECTION_NAMES.has(section)) {
    return
  }

  capture('web:section_viewed', {
    page_path: safePagePath(pagePath),
    section,
  })
}

export function trackScrollDepth(pathname: string, depthPercent: number): void {
  if (![25, 50, 75, 90, 100].includes(depthPercent)) {
    return
  }

  capture('web:scroll_depth_reached', {
    depth_percent: depthPercent,
    page_path: safePagePath(pathname),
  })
}

function safePropertyValue(value: string | undefined): string | undefined {
  if (!value) {
    return undefined
  }

  const normalized = value.toLowerCase().replace(/[^a-z0-9_:-]+/g, '_')
  return normalized.slice(0, 64)
}

export function trackWebInteraction({
  action,
  component,
  location,
  target,
  outcome,
}: InteractionProperties): void {
  capture('web:interaction', {
    action: safePropertyValue(action),
    component: safePropertyValue(component),
    location: safePropertyValue(location),
    target: safePropertyValue(target),
    outcome: safePropertyValue(outcome),
  })
}

export function trackDownloadClicked(location: string): void {
  capture('web:download_clicked', {
    location: safePropertyValue(location),
    target: 'sorty_zip',
  })
}

function trackConversion(
  event: string,
  { location, outcome }: ConversionProperties,
): void {
  capture(event, {
    location: safePropertyValue(location),
    outcome: safePropertyValue(outcome),
  })
}

export function trackDownloadNoticeViewed(location: string): void {
  trackConversion('web:download_notice_viewed', { location })
}

export function trackTerminalCommandCopied(
  location: string,
  outcome: 'succeeded' | 'failed',
): void {
  trackConversion('web:terminal_command_copied', { location, outcome })
}

export function trackSponsorClicked(location: string): void {
  trackConversion('web:sponsor_clicked', { location })
}

export function trackPrivacyPolicyClicked(location: string): void {
  trackConversion('web:privacy_policy_clicked', { location })
}

export function trackRouteClicked(pathname: string): void {
  const destinationPagePath = safePagePath(pathname)
  if (destinationPagePath === '/not-found') {
    return
  }

  capture('web:route_clicked', {
    destination_page_path: destinationPagePath,
    page_path: safePagePath(),
  })
}

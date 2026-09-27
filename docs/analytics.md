# Sorty Analytics

Sorty uses PostHog for lightweight product analytics and Sentry for reliability telemetry across the Mac app and public website. PostHog answers which screens and features are useful; Sentry reports crashes, hangs, sanitized handled errors, and sampled performance traces. Neither service may inspect user content.

## Consent and privacy

The Mac app is opt-in. `AnalyticsManager` and `ReliabilityManager` do not initialize their SDKs until the user allows anonymous analytics after onboarding. Denial is persisted locally but never reported. Revoking consent, enabling **Block Internet Connections**, or deleting Sorty usage data closes both SDKs and clears their local queues and anonymous identifiers.

The website uses anonymous, cookieless aggregate measurement by default. The footer provides a persistent opt-out, and Global Privacy Control or Do Not Track disables capture automatically. A random identifier lives in session storage only until the browser tab closes so page views can be grouped into one visit; it uses no person profiles, session replay, heatmaps, surveys, automatic click capture, full referrers, query strings, console logs, or form text.

Both clients instruct PostHog and Sentry to discard IP addresses and avoid person profiles or default personal data. Automatic telemetry is anonymous: neither client sends a name, email address, account identifier, advertising identifier, or other information linked to a person. Neither client may automatically send file or folder names, paths, file contents, prompts, custom instructions, AI responses, API keys, user-entered text, raw handled-error messages, screenshots, view hierarchies, console logs, or session replays. The Report Bug form is an explicit exception: when the user selects "Also send this description to Sentry," Sorty sends the text they entered as feedback linked to a tagged app event, plus anonymous environment tags (Sorty version, build, and release channel via the event release, macOS version as `os_version`, chip type as `device_arch`). The Sentry-only area picker appears after the user selects that option. Its `report_area` tag has four allowed values: `organize`, `duplicates`, `ai_setup`, and `settings`. The form is limited to 2,000 characters, adds no name, email, or attachments, and requires both analytics consent and internet access. The Report Bug window lists exactly what Sentry gets and what it never gets. GitHub opens a separate draft that the user must submit there.

This boundary is separate from AI-provider requests. If a user explicitly enables Deep Scan with a cloud provider, content may be sent directly to that selected provider to produce an organization plan; it is never included in PostHog or Sentry telemetry.

## Internal traffic

Sorty sends an `is_internal` event property to PostHog and an `is_internal` tag to Sentry. Both are `false` by default. They contain no device or account identifier. Internal activity stays available for debugging while production views can exclude it.

On a team Mac, run `defaults write com.sorty.app internalTelemetry -bool true` before launching Sorty. Restart Sorty after changing the value so Sentry's crash, hang, and transaction scope has the correct tag. Run `defaults delete com.sorty.app internalTelemetry` to return to the default. Each Mac needs its own setting. For the website, open the public site in each browser profile you use and run `localStorage.setItem('sorty.website.internalTelemetry', 'true')` in that site's developer console, then reload. Remove that key and reload to return to the default. Browser private windows and other profiles need separate settings.

Filter PostHog events and dashboards on the event property `is_internal = false`. Marked Sentry installations report under `environment=internal`, so use `environment=production` for production Issues and Discover views. The Sentry `is_internal` tag provides a second check on individual events. Check each dashboard tile's own filters before treating a dashboard as clean. Keep a separate internal view when investigating your own runs. Older anonymous events have no marker and cannot be assigned to an internal user retroactively. The split starts for app activity after the marked build is installed and for website activity after the marked site is deployed.

## Event taxonomy

| Event | Surface | Purpose |
|---|---|---|
| `$pageview` | Website | Visits to each public route, using a stable page name, sanitized path, and previous public route |
| `$pageleave` | Website | Consent-gated page-exit timing for more accurate session duration |
| `web:section_viewed` | Website | Meaningfully visible named homepage sections |
| `web:scroll_depth_reached` | Website | Bounded 25%, 50%, 75%, 90%, and 100% scroll milestones for each sanitized page |
| `web:not_found_viewed` | Website | Explicit 404 visits without retaining the unknown requested path |
| `web:download_clicked` | Website | Download-button clicks as a dedicated conversion event, with the bounded CTA location so PostHog can show unique users clearly |
| `web:download_notice_viewed` | Website | The installation and quarantine-removal notice shown after a download click |
| `web:terminal_command_copied` | Website | Success or failure when copying the fixed `xattr` command, without capturing the command text |
| `web:sponsor_clicked` | Website | GitHub Sponsors conversion clicks, broken down by a bounded website location |
| `web:privacy_policy_clicked` | Website | Navigation clicks to the Privacy Policy, broken down by a bounded website location |
| `web:route_clicked` | Website | Clicks between known public routes, using normalized source and destination paths |
| `web:interaction` | Website | Important links, downloads, fixed-command copy outcomes, modal exits, navigation, stable FAQ opens and closes, menu toggles, preference controls, legal-section choices, and bounded recovery actions |
| `$web_vitals` | Website | Consent-gated PostHog Web Vitals for LCP, INP, and CLS |
| `app:session_started` | Mac | An opted-in app analytics session, including launch-to-main-window time for returning opted-in users |
| `app:screen_viewed` | Mac | Main screens and individual Settings sections, with a bounded previous-screen value for navigation-path funnels |
| `app:feature_used` | Mac | Feature and sub-feature actions, including settings changes and bucketed persona inventory, with stable outcomes |
| `app:workflow_progressed` | Mac | Organize, apply, regenerate, undo, duplicate-scan, app/window setup, model-catalog, learnings-profile, and cleanup stages, including Organize mode and entry source plus exact rounded duration for timed workflows |
| `app:important_button_clicked` | Mac | A small allowlist of decision-critical buttons |

Do not create a new event for every button or state. Prefer an existing canonical event with low-cardinality `feature`, `subfeature`, `action`, `stage`, `outcome`, `screen`, `control`, `selection_kind`, or `button` properties. Counts must use `AnalyticsManager.countBucket`; timed Mac workflows use `durationProperties` for a broad bucket and rounded milliseconds. Paths, identifiers, persona names or contents, model names, and free text are not acceptable dimensions.

## Implementation map

- Mac PostHog setup, consent, allowlists, bucketing, and feature flags: `Sources/SortyCore/Analytics/AnalyticsManager.swift`
- Mac Sentry setup, consent, privacy policy, crash/hang capture, rate limiting, and handled-error classification: `Sources/SortyCore/Analytics/ReliabilityManager.swift`
- Mac settings toggles, notification previews, automation controls, and persona inventory: `Sources/SortyLib/Views/Settings/SettingsComponents.swift`, `Sources/SortyLib/Views/Settings/AutomationSettingsView.swift`, and `Sources/SortyLib/Views/PersonaPickerView.swift`
- Mac one-time permission UI: `Sources/SortyLib/Analytics/AnalyticsConsentView.swift`
- Website PostHog initialization, sanitization, and product events: `website/lib/analytics.ts`
- Website Sentry initialization, privacy policy, sampled tracing, and error classification: `website/lib/reliability.ts`
- Website route/section/action listeners and preferences UI: `website/components/analytics-provider.tsx`
- Website client bootstrap: `website/instrumentation-client.ts`
- Completed PostHog project, dashboard, and release handoff: `posthog-setup-report.md`

## Configuration and releases

The website reads `NEXT_PUBLIC_POSTHOG_PROJECT_TOKEN` and `NEXT_PUBLIC_POSTHOG_HOST`. GitHub repository variables provide both values to the Pages workflow. The Mac app contains the public project token and fixed ingestion host; `SORTY_POSTHOG_PROJECT_TOKEN` and `SORTY_POSTHOG_HOST` are debug-only overrides, and release builds ignore the launch environment so opted-in telemetry cannot be redirected to another collector.

The pinned PostHog dashboard measures first-time Mac app-session retention at daily D1–D30 and weekly W1–W12 intervals. The daily view highlights D1, D7, D14, and D30 over a 90-day cohort range; the weekly view highlights W1, W4, W8, and W12 over 180 days. Both use `app:session_started` as the entry and return event with strict calendar periods. Website retention is intentionally excluded because the website's session-only anonymous identifier cannot link a visitor across days.

`SENTRY_AUTH_TOKEN` is a GitHub Actions secret used only by Sentry CLI. The website workflow publishes a commit-addressed Sentry release, injects and uploads source-map identifiers under the `/Sorty` Pages prefix, then removes every map from the public artifact. The Mac release workflow publishes `com.sorty.app@version+build`, associates its commits, and uploads dSYMs without source files. Release scans reject PostHog personal keys and Sentry auth tokens while allowing the public PostHog token and public Sentry DSNs.

PostHog project settings keep automatic exception and click capture, recordings, console capture, performance attribution, heatmaps, surveys, and dead-click tracking disabled. The website uses consent-gated `$pageleave` events for session duration and PostHog's lightweight `$web_vitals` capture for LCP, INP, and CLS. Sentry receives sanitized errors, the small set of manually bounded traces, structured semantic logs, and custom reliability metrics; automatic network, file-I/O, user-interaction tracing, screenshots, view hierarchies, console forwarding, replay, profiling, and raw MetricKit payloads remain disabled. Both Sentry projects have server-side IP scrubbing enabled, and the website project accepts events only from the public GitHub Pages origin and localhost development.

Sentry has separate `sorty-macos` and `sorty-website` projects, high-priority issue notifications, and focused dashboards for unresolved errors and the bounded `operation` or `surface` tags. Expected cancellations and internet-privacy blocks remain workflow outcomes rather than Sentry issues, and handled errors are represented by a sanitized category/cause/operation error instead of the original message.

The Mac PostHog client accepts at most 120 events per minute and 10,000 events per process, while the website accepts 60 events per minute and 2,000 per session. Mac Sentry accepts at most 30 handled-error or transaction capture calls per minute and 500 per process. Website Sentry accepts at most six handled-error capture calls, 12 error envelopes, and 30 transactions per minute, with session ceilings of 100, 200, and 500 respectively. These limits bound accidental loops and UI automation against the shipped SDK queues, while the browser-safe `phc_` project token and public Sentry DSNs still require service-side quotas and anomaly monitoring to contain fabricated direct-ingestion traffic.

The browser-safe `phc_` token identifies the PostHog project but grants no read, query, configuration, or source-map access. Because any public ingestion token can be copied and used to submit fabricated events, the PostHog project must also restrict authorized web origins to `https://sorty-organizer.github.io` (and any explicitly approved preview origin), reject unexpected event names and properties through the ingestion allowlists where available, and use anomaly or volume alerts to contain deliberate event spam. Client-side checks protect privacy and data quality for the shipped app; they are not an authentication boundary against a modified client.

The static GitHub Pages export cannot host a request-forwarding reverse proxy. PostHog requests continue to use `NEXT_PUBLIC_POSTHOG_HOST` directly until Sorty has a custom domain where a managed PostHog proxy can be provisioned with a neutral subdomain and DNS CNAME.

The Mac app also uses consent-gated PostHog feature flags to populate **Settings → Experimental**. Enabled flags whose keys begin with `labs-` appear there; an optional JSON payload may provide bounded `title`, `description`, and `system_image` strings. Reloads are limited to once every five minutes, at most 20 flags are rendered, flag evaluation events remain disabled, and flags are cleared from the UI when analytics consent is revoked or internet connections are blocked.

The experimental Codex skill installer uses the exact `labs-sorty-codex-skill` flag key. It reports `app:feature_used` with `feature=experimental`, `subfeature=codex_skill_installer`, bounded `card_viewed`, `install`, `replace`, and `uninstall` actions, and availability, conflict, success, failure, or unavailable outcomes. When the matching skill is already installed, the card-view event may include the standard rounded duration properties based on the local installation creation date. It never captures the Codex home path, skill contents, filenames, prompts, or other user data.

The website uses the same `labs-` key prefix through the typed hooks in `website/lib/feature-flags.ts`. Components should use `useLabsFeatureEnabled`, `useLabsFeatureVariant`, or `useLabsFeaturePayload`; the hooks read cached assignments without emitting feature-flag exposure events, and payloads are limited to bounded `title`, `description`, and `system_image` values. Denying website analytics clears the rendered Labs state and stops further flag use or exposure events.

## Adding instrumentation

1. Confirm the question cannot already be answered with an existing event and property.
2. Add only bounded, documented property values. Never pass a URL, file object, `Error.localizedDescription`, prompt, provider response, or user-entered string. The explicit Report Bug feedback form above is the sole exception for user-entered text.
3. Capture intent at the important UI control and capture the outcome at the manager or workflow boundary.
4. Send expected cancellations as workflow outcomes, not exceptions.
5. Update the event catalog and this guide if the event namespace or privacy boundary changes.
6. Verify Swift compilation, website lint/type-check/build, and the relevant PostHog or Sentry dashboard query.

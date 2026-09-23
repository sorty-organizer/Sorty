import type { Metadata } from 'next'
import { LegalPage, LegalSection } from '@/components/legal-page'
import { PageStructuredData } from '@/components/page-structured-data'
import { sitePath } from '@/lib/site-paths'
import { OG_IMAGE_PATH, SITE_URL } from '@/lib/site-metadata'

export const metadata: Metadata = {
  title: 'Privacy Policy',
  description:
    'How Sorty handles your data. Sorty has no servers and no accounts, so your files never reach us. File contents only leave your Mac when you explicitly enable Deep Scan.',
  alternates: { canonical: '/privacy-policy' },
  openGraph: {
    title: 'Privacy Policy — Sorty',
    description:
      'Sorty has no servers and no accounts, so your files never reach us. File contents only leave your Mac when you explicitly enable Deep Scan.',
    url: `${SITE_URL}/privacy-policy/`,
    type: 'article',
    images: [
      {
        url: OG_IMAGE_PATH,
        width: 1102,
        height: 754,
        alt: 'Sorty app interface.',
      },
    ],
  },
  twitter: {
    card: 'summary_large_image',
    title: 'Privacy Policy — Sorty',
    description:
      'Sorty has no servers and no accounts, so your files never reach us. File contents only leave your Mac when you explicitly enable Deep Scan.',
    images: [OG_IMAGE_PATH],
  },
}

const TOC = [
  { id: 'overview', label: 'Overview' },
  { id: 'data-we-collect', label: 'Data We Collect' },
  { id: 'ai-providers', label: 'AI Providers & Your Files' },
  { id: 'local-storage', label: 'Local Storage & Encryption' },
  { id: 'network', label: 'Network & Update Checks' },
  { id: 'sandboxing', label: 'Sandboxing & Permissions' },
  { id: 'third-party', label: 'Third-Party Services' },
  { id: 'children', label: "Children's Privacy" },
  { id: 'your-rights', label: 'Your Rights & Controls' },
  { id: 'changes', label: 'Changes to This Policy' },
  { id: 'contact', label: 'Contact' },
]

export default function PrivacyPolicyPage() {
  return (
    <LegalPage
      title="Privacy Policy"
      updated="July 28, 2026"
      toc={TOC}
      summary={
        <>
          Sorty never sends us your files, folder names, paths, prompts, AI
          responses, or API keys. The Mac app only sends anonymous product
          analytics and crash reports after you explicitly opt in. This website
          uses cookieless aggregate analytics with a persistent opt-out.
        </>
      }
    >
      <PageStructuredData
        name="Sorty Privacy Policy"
        description="How Sorty handles files, metadata, AI providers, and local storage."
        path="/privacy-policy"
        dateModified="2026-07-28"
        breadcrumbs={[{ name: 'Sorty', path: '/' }, { name: 'Privacy Policy', path: '/privacy-policy' }]}
      />
      <LegalSection id="overview" heading="1. Overview">
        <p>
          Sorty (&quot;the App&quot;) is a native macOS application published by
          the Sorty open-source project and licensed under the{' '}
          <a
            href="https://www.gnu.org/licenses/gpl-3.0.en.html"
            target="_blank"
            rel="noreferrer"
            className="text-primary underline-offset-4 hover:underline"
          >
            GNU General Public License v3.0
          </a>
          . This Privacy Policy explains how the App handles information when
          you use it.
        </p>
        <p>
          Sorty is built privacy-first. File scanning and organization run on
          your device, and the App is designed so that the smallest amount of
          information necessary leaves your computer. We do not operate servers
          that process your files. Cloud AI requests go directly to the provider
          you choose, and anonymous app analytics only starts after an explicit
          opt-in.
        </p>
      </LegalSection>

      <LegalSection id="data-we-collect" heading="2. Data We Collect">
        <p>
          There is no Sorty account and we do not collect names, email
          addresses, advertising identifiers, file names, folder names, file
          paths, file contents, prompts, custom instructions, AI responses, API
          keys, or the names of files involved in an error.
        </p>
        <h3 className="pt-1 text-base font-medium text-foreground">
          Optional Mac app analytics
        </h3>
        <p>
          After onboarding, the Mac app asks once and does not initialize its analytics SDK until you choose
          &quot;Share Anonymous Analytics.&quot; If you decline, no analytics or
          crash report is sent and the denial itself is not reported. You can
          change this choice later in Settings → Advanced → Privacy.
        </p>
        <p>
          When enabled, the App sends a random anonymous installation
          identifier, app and macOS versions, named screen visits, feature and
          sub-feature actions, a small allowlist of important button actions,
          coarse count and duration buckets, workflow outcomes, and sanitized
          errors. Crash reports may include exception types, signal names,
          function names, and stack frames needed to diagnose the crash. Sorty
          does not create a PostHog person profile, identify you, or send a
          name, email address, account identifier, advertising identifier, or
          other information linked to you. This is the lightweight product and
          reliability telemetry commonly used by apps, limited here to the
          documented anonymous events.
        </p>
        <h3 className="pt-1 text-base font-medium text-foreground">
          Cookieless website analytics
        </h3>
        <p>
          This website measures page visits within an anonymous browser-tab
          visit, named page and section visibility, coarse scroll-depth
          milestones, meaningful links, buttons, and FAQ opens, coarse
          traffic-source categories, and sanitized technical errors through
          PostHog. It uses cookieless mode, does not create a person profile or
          record session replays or page contents, strips query strings and full
          referrer URLs, and instructs PostHog to discard IP addresses. You can
          disable it at any time through
          &quot;Analytics preferences&quot; in the footer. Global Privacy
          Control and Do Not Track are honored automatically.
        </p>
        <p>
          PostHog never receives file or folder names, paths, file contents,
          prompts, custom instructions, AI responses, API keys, or other
          user-entered content. If you explicitly enable Deep Scan with a cloud
          AI provider, any content needed for that request goes directly to the
          provider you selected, never to Sorty or PostHog.
        </p>
        <p>The following is handled locally on your device only:</p>
        <ul className="list-disc space-y-1.5 pl-5">
          <li>
            <strong className="text-foreground">Organization History</strong> —
            records of operations (file paths and metadata), stored locally and
            not encrypted.
          </li>
          <li>
            <strong className="text-foreground">Settings &amp; preferences</strong>{' '}
            — stored in standard macOS UserDefaults, including your app
            analytics choice. The website stores its analytics preference in
            local storage and a random anonymous visit identifier in session
            storage until the browser tab closes.
          </li>
          <li>
            <strong className="text-foreground">Watched Folders</strong> —
            stored as macOS security-scoped bookmarks so access persists across
            restarts.
          </li>
          <li>
            Exclusion rules, personas, and naming presets you create.
          </li>
        </ul>
      </LegalSection>

      <LegalSection id="ai-providers" heading="3. AI Providers & Your Files">
        <p>
          Sorty is provider-agnostic. You choose which AI provider (if any)
          analyzes your files, and you can switch or disable providers at any
          time in Settings → AI Provider.
        </p>
        <h3 className="pt-1 text-base font-medium text-foreground">
          What is sent to cloud providers
        </h3>
        <p>
          When using a cloud-based provider (for example OpenAI, Anthropic,
          Google Gemini, Groq, OpenRouter, or GitHub Copilot):
        </p>
        <ul className="list-disc space-y-1.5 pl-5">
          <li>
            File names and metadata are sent for analysis so the model can
            suggest a folder structure.
          </li>
          <li>
            File contents are <strong className="text-foreground">NOT</strong>{' '}
            uploaded unless you explicitly enable Deep Scan. Deep Scan uploads
            small content excerpts and should only be enabled for files you are
            comfortable analyzing remotely.
          </li>
          <li>All traffic occurs over HTTPS with TLS 1.2+.</li>
          <li>
            API keys are stored in the macOS Keychain, never logged, and never
            transmitted outside your chosen provider&apos;s endpoints.
          </li>
        </ul>
        <p>
          For maximum privacy, use a fully on-device provider.{' '}
          <a
            href="https://ollama.com"
            target="_blank"
            rel="noreferrer"
            className="text-primary underline-offset-4 hover:underline"
          >
            Ollama
          </a>{' '}
          processes everything on your machine, and{' '}
          <a
            href="https://developer.apple.com/apple-intelligence/"
            target="_blank"
            rel="noreferrer"
            className="text-primary underline-offset-4 hover:underline"
          >
            Apple Foundation Models
          </a>{' '}
          run on-device via Apple Intelligence (requires macOS 15+). With these
          options, no file information leaves your Mac.
        </p>
        <p>
          When you use a third-party AI provider, that provider&apos;s own
          privacy policy and terms apply to the data you send. We encourage you
          to review the policies of your chosen provider, for example{' '}
          <a
            href="https://openai.com/policies/privacy-policy"
            target="_blank"
            rel="noreferrer"
            className="text-primary underline-offset-4 hover:underline"
          >
            OpenAI
          </a>{' '}
          and{' '}
          <a
            href="https://www.anthropic.com/legal/privacy"
            target="_blank"
            rel="noreferrer"
            className="text-primary underline-offset-4 hover:underline"
          >
            Anthropic
          </a>
          .
        </p>
      </LegalSection>

      <LegalSection id="local-storage" heading="4. Local Storage & Encryption">
        <ul className="list-disc space-y-1.5 pl-5">
          <li>
            The Learnings Profile — the data Sorty uses to adapt to your style —
            is stored with{' '}
            <strong className="text-foreground">AES-256 encryption</strong> and
            protected by Touch ID or Face ID.
          </li>
          <li>API keys are stored in the macOS Keychain.</li>
          <li>
            Privacy Mode (enabled by default) blurs sensitive handles until you
            hover and hides API keys behind a manual reveal toggle — useful for
            screensharing or streaming.
          </li>
          <li>
            Privacy Path Masking redacts usernames from file paths shown in the
            UI and logs.
          </li>
        </ul>
      </LegalSection>

      <LegalSection id="network" heading="5. Network & Update Checks">
        <ul className="list-disc space-y-1.5 pl-5">
          <li>
            The App checks for updates by fetching version data from the GitHub
            Releases API over HTTPS. Update checks run on app launch (at most
            once per 24 hours) or manually via the menu.
          </li>
          <li>
            Update and AI-provider requests do not include Sorty analytics.
            When you opt in, anonymous analytics is sent separately to PostHog
            over HTTPS.
          </li>
          <li>
            You can disable automatic update checks in Settings → Updates →
            Manual only.
          </li>
        </ul>
      </LegalSection>

      <LegalSection id="sandboxing" heading="6. Sandboxing & Permissions">
        <p>
          Sorty runs within the macOS App Sandbox with the following
          entitlements:
        </p>
        <ul className="list-disc space-y-1.5 pl-5">
          <li>
            User-selected file access (read/write) for folders you explicitly
            grant.
          </li>
          <li>Network access for AI provider APIs and update checks.</li>
          <li>No system-level access outside the sandbox.</li>
        </ul>
        <p>
          You grant folder access through macOS security-scoped bookmarks. You
          can revoke access at any time by removing a folder from the Watched
          list or in macOS System Settings.
        </p>
      </LegalSection>

      <LegalSection id="third-party" heading="7. Third-Party Services">
        <p>
          Sorty integrates with the following third-party components and
          services, each governed by their own policies:
        </p>
        <ul className="list-disc space-y-1.5 pl-5">
          <li>
            <a
              href="https://sparkle-project.org"
              target="_blank"
              rel="noreferrer"
              className="text-primary underline-offset-4 hover:underline"
            >
              <strong>Sparkle Framework</strong>
            </a>{' '}
            — handles secure in-app updates.
          </li>
          <li>
            <strong className="text-foreground">AI providers</strong> — each has
            its own security and privacy policy (see above).
          </li>
          <li>
            <a
              href="https://posthog.com/privacy"
              target="_blank"
              rel="noreferrer"
              className="text-primary underline-offset-4 hover:underline"
            >
              <strong>PostHog</strong>
            </a>{' '}
            — processes cookieless website events and explicitly opted-in,
            anonymous Mac app analytics and crash reports in the United States.
          </li>
          <li>
            <a
              href="https://github.com/sorty-organizer/Sorty/releases"
              target="_blank"
              rel="noreferrer"
              className="text-primary underline-offset-4 hover:underline"
            >
              <strong>GitHub</strong>
            </a>{' '}
            — hosts releases and the update feed.
          </li>
        </ul>
        <p>
          Releases are not code-signed with an Apple Developer certificate. You
          may verify integrity by{' '}
          <a
            href="https://github.com/sorty-organizer/Sorty"
            target="_blank"
            rel="noreferrer"
            className="text-primary underline-offset-4 hover:underline"
          >
            building from source
          </a>{' '}
          or checking release notes. See{' '}
          <a
            href="https://github.com/sorty-organizer/Sorty/blob/main/SECURITY.md"
            target="_blank"
            rel="noreferrer"
            className="text-primary underline-offset-4 hover:underline"
          >
            SECURITY.md
          </a>{' '}
          for full details.
        </p>
      </LegalSection>

      <LegalSection id="children" heading="8. Children's Privacy">
        <p>
          Sorty is a general-purpose developer and productivity tool and is not
          directed at children under 16. We do not knowingly collect personal
          data from children. Sorty analytics is deliberately anonymous and
          excludes user and file content.
        </p>
      </LegalSection>

      <LegalSection id="your-rights" heading="9. Your Rights & Controls">
        <p>
          Sorty keeps file-related data local and provides direct controls over
          the limited anonymous analytics described above:
        </p>
        <ul className="list-disc space-y-1.5 pl-5">
          <li>
            <strong className="text-foreground">Delete your data</strong> — use
            Settings → Troubleshooting → Delete All Data to wipe usage history,
            watched folders, local caches, and queued analytics data.
          </li>
          <li>
            <strong className="text-foreground">Control app analytics</strong> —
            decline during onboarding or turn off Share Anonymous Analytics in
            Settings. Turning it off closes the SDK and clears its local queue.
          </li>
          <li>
            <strong className="text-foreground">Control website analytics</strong>{' '}
            — use Analytics preferences in the website footer. The site also
            honors browser privacy signals.
          </li>
          <li>
            <strong className="text-foreground">Reset everything</strong> —
            &quot;Reset All Settings&quot; returns you to the onboarding
            experience.
          </li>
          <li>
            <strong className="text-foreground">Use on-device AI</strong> —
            choose Ollama or Apple Foundation Models to keep processing on your
            Mac.
          </li>
          <li>
            <strong className="text-foreground">Disable Deep Scan</strong> —
            keep file contents from ever leaving your device.
          </li>
          <li>
            <strong className="text-foreground">Disable update checks</strong> —
            minimize network exposure.
          </li>
        </ul>
        <p>
          Because analytics records are anonymous and are not linked to a Sorty
          account, we cannot reliably locate or delete an individual&apos;s
          previously transmitted records. Turning analytics off prevents future
          collection from that device.
        </p>
      </LegalSection>

      <LegalSection id="changes" heading="10. Changes to This Policy">
        <p>
          We may update this Privacy Policy as Sorty evolves. Material changes
          will be reflected in the Changelog and via in-app notifications. The
          &quot;Last updated&quot; date above indicates when this policy was last
          revised.
        </p>
      </LegalSection>

      <LegalSection id="contact" heading="11. Contact">
        <p>
          For privacy or security questions, please use{' '}
          <a
            href="https://github.com/sorty-organizer/Sorty/security/advisories/new"
            target="_blank"
            rel="noreferrer"
            className="text-primary underline-offset-4 hover:underline"
          >
            GitHub&apos;s private vulnerability reporting
          </a>{' '}
          or open a{' '}
          <a
            href="https://github.com/sorty-organizer/Sorty/discussions"
            target="_blank"
            rel="noreferrer"
            className="text-primary underline-offset-4 hover:underline"
          >
            GitHub Discussion
          </a>{' '}
          for general questions. For security reports specifically, see{' '}
          <a
            href="https://github.com/sorty-organizer/Sorty/blob/main/SECURITY.md"
            target="_blank"
            rel="noreferrer"
            className="text-primary underline-offset-4 hover:underline"
          >
            SECURITY.md
          </a>
          .
        </p>
      </LegalSection>
    </LegalPage>
  )
}

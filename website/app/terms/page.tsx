import type { Metadata } from 'next'
import { LegalPage, LegalSection } from '@/components/legal-page'
import { PageStructuredData } from '@/components/page-structured-data'
import { sitePath } from '@/lib/site-paths'
import { OG_IMAGE_PATH, SITE_URL } from '@/lib/site-metadata'

export const metadata: Metadata = {
  title: 'Terms of Service',
  description:
    'Sorty is free, open-source software under the GNU GPL v3.0, provided "as is". You are responsible for your files and for reviewing suggested changes before applying them.',
  alternates: { canonical: '/terms' },
  openGraph: {
    title: 'Terms of Service — Sorty',
    description:
      'Sorty is free, open-source software under the GNU GPL v3.0, provided "as is". You are responsible for reviewing suggested changes before applying them.',
    url: `${SITE_URL}/terms/`,
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
    title: 'Terms of Service — Sorty',
    description:
      'Sorty is free, open-source software under the GNU GPL v3.0, provided as is. Review suggested file changes before applying them.',
    images: [OG_IMAGE_PATH],
  },
}

const TOC = [
  { id: 'agreement', label: 'Agreement to Terms' },
  { id: 'license', label: 'License & Open Source' },
  { id: 'acceptable-use', label: 'Acceptable Use' },
  { id: 'your-files', label: 'Your Files & Content' },
  { id: 'ai-providers', label: 'AI Providers' },
  { id: 'releases', label: 'Releases & Signing' },
  { id: 'disclaimer', label: 'Disclaimer of Warranties' },
  { id: 'liability', label: 'Limitation of Liability' },
  { id: 'third-party', label: 'Third-Party Services' },
  { id: 'changes', label: 'Changes to These Terms' },
  { id: 'contact', label: 'Contact' },
]

export default function TermsPage() {
  return (
    <LegalPage
      title="Terms of Service"
      updated="June 2026"
      toc={TOC}
      summary={
        <>
          Sorty is free, open-source software licensed under the GNU GPL v3.0.
          You may use, modify, and redistribute it under that license. The App
          is provided &quot;as is,&quot; without warranty of any kind. You are
          responsible for your files and for reviewing suggested changes before
          applying them.
        </>
      }
    >
      <PageStructuredData
        name="Sorty Terms of Service"
        description="Terms governing use of the Sorty macOS app and website."
        path="/terms"
        dateModified="2026-06-01"
        breadcrumbs={[{ name: 'Sorty', path: '/' }, { name: 'Terms of Service', path: '/terms' }]}
      />
      <LegalSection id="agreement" heading="1. Agreement to Terms">
        <p>
          These Terms of Service (&quot;Terms&quot;) govern your use of the Sorty
          macOS application (the &quot;App&quot;) and the Sorty website (the
          &quot;Site&quot;), collectively the &quot;Service.&quot; By
          downloading, installing, or using the Service, you agree to these
          Terms and the Privacy Policy. If you do not agree, do not use the
          Service.
        </p>
        <p>
          The Service is maintained by the Sorty open-source project and its
          contributors (&quot;we,&quot; &quot;us,&quot; or &quot;our&quot;).
        </p>
      </LegalSection>

      <LegalSection id="license" heading="2. License & Open Source">
        <p>
          Sorty is free and open-source software licensed under the{' '}
          <a
            href="https://www.gnu.org/licenses/gpl-3.0.en.html"
            target="_blank"
            rel="noreferrer"
            className="text-primary underline-offset-4 hover:underline"
          >
            GNU General Public License v3.0
          </a>{' '}
          (&quot;GPL-3.0&quot;). Under the GPL-3.0, you are free to:
        </p>
        <ul className="list-disc space-y-1.5 pl-5">
          <li>Use the App for any purpose;</li>
          <li>Study how it works and change it to suit your needs;</li>
          <li>Redistribute copies; and</li>
          <li>
            Distribute modified versions — provided you comply with the
            GPL-3.0&apos;s conditions, including keeping the source available
            under the same license.
          </li>
        </ul>
        <p>
          The full source code is available on{' '}
          <a
            href="https://github.com/sorty-organizer/Sorty"
            target="_blank"
            rel="noreferrer"
            className="text-primary underline-offset-4 hover:underline"
          >
            GitHub
          </a>
          .
        </p>
      </LegalSection>

      <LegalSection id="acceptable-use" heading="3. Acceptable Use">
        <p>
          You agree to use the Service lawfully and responsibly. You will not:
        </p>
        <ul className="list-disc space-y-1.5 pl-5">
          <li>
            Use the App to process or organize files you do not have the right
            to access;
          </li>
          <li>
            Attempt to reverse-engineer, circumvent, or disable any safety
            mechanism for malicious purposes;
          </li>
          <li>Use the App to infringe the rights of any third party; or</li>
          <li>
            Use the Service to transmit or process unlawful, harmful, or
            fraudulent content through third-party AI providers in violation of
            their terms.
          </li>
        </ul>
      </LegalSection>

      <LegalSection id="your-files" heading="4. Your Files & Content">
        <p>
          You retain all rights to the files and content you organize with
          Sorty. Sorty reads and moves files only on your device and only within
          folders you explicitly grant access to. The App does not upload your
          file contents unless you explicitly enable Deep Scan with a cloud AI
          provider.
        </p>
        <p>
          You are solely responsible for maintaining backups of your data. While
          Sorty offers preview, dry-run modes, and full undo to reduce risk, you
          assume responsibility for reviewing suggested changes before applying
          them. See the{' '}
          <a
            href={sitePath('/privacy-policy/')}
            className="text-primary underline-offset-4 hover:underline"
          >
            Privacy Policy
          </a>{' '}
          for details on data handling.
        </p>
      </LegalSection>

      <LegalSection id="ai-providers" heading="5. AI Providers">
        <p>
          Sorty integrates with third-party AI providers you select and
          configure yourself, including{' '}
          <a
            href="https://openai.com/policies/terms-of-use"
            target="_blank"
            rel="noreferrer"
            className="text-primary underline-offset-4 hover:underline"
          >
            OpenAI
          </a>
          ,{' '}
          <a
            href="https://www.anthropic.com/legal/consumer-terms"
            target="_blank"
            rel="noreferrer"
            className="text-primary underline-offset-4 hover:underline"
          >
            Anthropic
          </a>
          , Google Gemini, Groq, OpenRouter, GitHub Copilot, Ollama, and Apple
          Foundation Models. When you use a cloud provider, your use is also
          subject to that provider&apos;s terms of service and acceptable-use
          policies. We are not responsible for how third-party providers handle
          the data you send them.
        </p>
        <p>
          For on-device processing, you may use{' '}
          <a
            href="https://ollama.com"
            target="_blank"
            rel="noreferrer"
            className="text-primary underline-offset-4 hover:underline"
          >
            Ollama
          </a>{' '}
          or{' '}
          <a
            href="https://developer.apple.com/apple-intelligence/"
            target="_blank"
            rel="noreferrer"
            className="text-primary underline-offset-4 hover:underline"
          >
            Apple Foundation Models
          </a>
          , which keep processing on your Mac.
        </p>
      </LegalSection>

      <LegalSection id="releases" heading="6. Releases & Signing">
        <p>
          Pre-built Sorty releases are distributed as ZIP archives and are not
          code-signed with an Apple Developer certificate. As a result, macOS
          may display a security warning on first launch. To proceed, you may
          run{' '}
          <code className="rounded bg-secondary px-1.5 py-0.5 font-mono text-[0.8em] text-foreground">
            sudo xattr -cr /Applications/Sorty.app
          </code>{' '}
          or{' '}
          <a
            href="https://github.com/sorty-organizer/Sorty"
            target="_blank"
            rel="noreferrer"
            className="text-primary underline-offset-4 hover:underline"
          >
            build from source
          </a>{' '}
          if you prefer complete control. This is common for open-source macOS
          applications without paid developer accounts.
        </p>
        <p>
          We do not guarantee that pre-built binaries will pass Apple&apos;s
          notarization or Gatekeeper checks. You are responsible for verifying
          downloaded artifacts and for trusting the source from which you
          obtained them.
        </p>
      </LegalSection>

      <LegalSection id="disclaimer" heading="7. Disclaimer of Warranties">
        <p>
          The Service is provided &quot;as is&quot; and &quot;as
          available,&quot; without warranties of any kind, whether express or
          implied, including but not limited to implied warranties of
          merchantability, fitness for a particular purpose, title, and
          non-infringement. We do not warrant that the App will be error-free,
          uninterrupted, secure, or that AI suggestions will be accurate or
          appropriate for your needs.
        </p>
        <p>
          AI-generated folder structures and file classifications are
          suggestions only. Always review them in the interactive preview before
          applying.
        </p>
      </LegalSection>

      <LegalSection id="liability" heading="8. Limitation of Liability">
        <p>
          To the maximum extent permitted by applicable law, neither Sorty nor
          its contributors shall be liable for any indirect, incidental,
          special, consequential, or punitive damages, or any loss of data,
          arising out of or in connection with your use of the Service —
          including, but not limited to, files moved, renamed, merged, or
          deleted as a result of applying or undoing operations.
        </p>
        <p>
          Your sole and exclusive remedy for dissatisfaction with the Service is
          to stop using it and remove it from your device.
        </p>
      </LegalSection>

      <LegalSection id="third-party" heading="9. Third-Party Services">
        <p>
          The Service interacts with third-party components and services —
          including the{' '}
          <a
            href="https://sparkle-project.org"
            target="_blank"
            rel="noreferrer"
            className="text-primary underline-offset-4 hover:underline"
          >
            Sparkle update framework
          </a>
          , your chosen AI providers, and{' '}
          <a
            href="https://github.com/sorty-organizer/Sorty/releases"
            target="_blank"
            rel="noreferrer"
            className="text-primary underline-offset-4 hover:underline"
          >
            GitHub releases
          </a>
          . We are not responsible for the availability, accuracy, or practices
          of these third parties. Your use of them is subject to their
          respective terms and policies.
        </p>
      </LegalSection>

      <LegalSection id="changes" heading="10. Changes to These Terms">
        <p>
          We may revise these Terms from time to time. Material changes will be
          reflected in the Changelog and via in-app notifications where
          appropriate. The &quot;Last updated&quot; date above indicates when
          these Terms were last revised. Continued use of the Service after
          changes constitutes acceptance of the updated Terms.
        </p>
      </LegalSection>

      <LegalSection id="contact" heading="11. Contact">
        <p>
          For questions about these Terms, please open a{' '}
          <a
            href="https://github.com/sorty-organizer/Sorty/discussions"
            target="_blank"
            rel="noreferrer"
            className="text-primary underline-offset-4 hover:underline"
          >
            GitHub Discussion
          </a>
          . For security-related matters, use GitHub&apos;s private
          vulnerability reporting as described in{' '}
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

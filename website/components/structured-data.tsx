import { FAQS } from '@/components/faq-data'
import {
  CURRENT_VERSION,
  DOWNLOAD_URL,
  GITHUB_URL,
  SITE_DESCRIPTION,
  SITE_NAME,
  SITE_URL,
} from '@/lib/site-metadata'

/**
 * JSON-LD structured data for rich results: the software application itself,
 * the publishing organization, and the FAQ shown on the home page.
 */
export function StructuredData() {
  const graph = {
    '@context': 'https://schema.org',
    '@graph': [
      {
        '@type': 'Organization',
        '@id': `${SITE_URL}/#organization`,
        name: SITE_NAME,
        url: `${SITE_URL}/`,
        logo: `${SITE_URL}/sorty-icon.webp`,
        sameAs: [GITHUB_URL],
      },
      {
        '@type': 'WebSite',
        '@id': `${SITE_URL}/#website`,
        url: `${SITE_URL}/`,
        name: SITE_NAME,
        description: SITE_DESCRIPTION,
        publisher: { '@id': `${SITE_URL}/#organization` },
        inLanguage: 'en-US',
      },
      {
        '@type': 'SoftwareApplication',
        '@id': `${SITE_URL}/#app`,
        name: SITE_NAME,
        applicationCategory: 'UtilitiesApplication',
        operatingSystem: 'macOS 15+',
        description: SITE_DESCRIPTION,
        url: `${SITE_URL}/`,
        sameAs: [GITHUB_URL],
        downloadUrl: DOWNLOAD_URL,
        installUrl: DOWNLOAD_URL,
        releaseNotes: `${SITE_URL}/changelog/`,
        softwareVersion: CURRENT_VERSION,
        applicationSubCategory: 'File organization',
        featureList: [
          'AI folder organization',
          'Preview and undo for file moves',
          'Finder integration',
          'Local AI model support',
          'Duplicate file detection',
          'Watched folder automation',
          'Custom organization personas',
        ],
        softwareRequirements: 'macOS 15 or later; Apple Silicon or Intel Mac',
        softwareLicense: 'https://www.gnu.org/licenses/gpl-3.0.en.html',
        isAccessibleForFree: true,
        publisher: { '@id': `${SITE_URL}/#organization` },
        screenshot: `${SITE_URL}/sorty-app.webp`,
        offers: {
          '@type': 'Offer',
          price: '0',
          priceCurrency: 'USD',
        },
      },
      {
        '@type': 'FAQPage',
        '@id': `${SITE_URL}/#faq`,
        mainEntity: FAQS.map((item) => ({
          '@type': 'Question',
          name: item.q,
          acceptedAnswer: {
            '@type': 'Answer',
            text: item.a,
          },
        })),
      },
    ],
  }

  return (
    <script
      type="application/ld+json"
      dangerouslySetInnerHTML={{ __html: JSON.stringify(graph) }}
    />
  )
}

import { SiteNav } from '@/components/site-nav'
import { Hero } from '@/components/hero'
import { HowItWorks } from '@/components/how-it-works'
import { Features } from '@/components/features'
import { TaglineReveal } from '@/components/tagline-reveal'
import { Privacy } from '@/components/privacy'
import { Pricing } from '@/components/pricing'
import { Faq } from '@/components/faq'
import { AiPrompts } from '@/components/ai-prompts'
import { FinalCta } from '@/components/final-cta'
import { SiteFooter } from '@/components/site-footer'
import { StructuredData } from '@/components/structured-data'

export default function Page() {
  return (
    <>
      <SiteNav />
      <main id="main" className="relative min-h-dvh overflow-x-clip">
        <StructuredData />
        <Hero />
        <HowItWorks />
        <Features />
        <TaglineReveal />
        <Privacy />
        <Pricing />
        <Faq />
        <AiPrompts />
        <FinalCta />
      </main>
      <SiteFooter />
    </>
  )
}

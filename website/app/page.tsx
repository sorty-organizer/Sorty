import { SiteNav } from '@/components/site-nav'
import { Hero } from '@/components/hero'
import { HowItWorks } from '@/components/how-it-works'
import { Features } from '@/components/features'
import { Privacy } from '@/components/privacy'
import { Pricing } from '@/components/pricing'
import { Faq } from '@/components/faq'
import { AiPrompts } from '@/components/ai-prompts'
import { SiteFooter } from '@/components/site-footer'
import { StructuredData } from '@/components/structured-data'

export default function Page() {
  return (
    <main className="relative min-h-screen overflow-x-clip">
      <StructuredData />
      <SiteNav />
      <Hero />
      <HowItWorks />
      <Features />
      <Privacy />
      <Pricing />
      <AiPrompts />
      <Faq />
      <SiteFooter />
    </main>
  )
}

import Image from 'next/image'
import {
  Brain,
  ClockCounterClockwise,
  Folders,
  CursorClick,
} from '@phosphor-icons/react/ssr'
import { Reveal } from '@/components/reveal'
import { cn } from '@/lib/utils'
import { sitePath } from '@/lib/site-paths'

const PROVIDERS = [
  { src: '/provider-chatgpt.png', name: 'OpenAI' },
  { src: '/provider-claude.png', name: 'Claude' },
  { src: '/provider-gemini.png', name: 'Gemini' },
  { src: '/provider-github-copilot.png', name: 'GitHub Copilot' },
  { src: '/provider-groq.png', name: 'Groq' },
  { src: '/provider-ollama.png', name: 'Ollama' },
  { src: '/provider-openrouter.png', name: 'OpenRouter' },
]

const ROWS = [
  {
    src: '/sorty-settings.webp?v=lossless-1',
    alt: 'Sorty AI provider settings screen showing configured model providers.',
    title: 'Pick the AI that reads your file names',
    body: 'Bring your own key for a cloud provider, or run Ollama or Apple Foundation Models so the analysis never leaves your Mac. Switch whenever you like.',
    providers: true,
  },
  {
    src: '/sorty-health.webp?v=lossless-1',
    alt: 'Sorty workspace health screen showing folder health insights.',
    title: 'See which folders are piling up',
    body: 'Workspace health shows clutter, stale folders, and automation status in one place, so you know where to point Sorty next.',
  },
  {
    src: '/sorty-duplicates.webp?v=lossless-1',
    alt: 'Sorty duplicates screen showing duplicate file review controls.',
    title: 'Clear out duplicates without guessing',
    body: 'Compare duplicate candidates side by side and choose which copy stays. Duplicate review is separate from organizing, with its own controls.',
  },
]

const EXTRAS = [
  {
    icon: Folders,
    title: 'Folders that fit your files',
    body: 'Describe in plain words how you want things grouped: by type, project, date, or topic.',
  },
  {
    icon: Brain,
    title: 'Learns your preferences',
    body: 'Keep or reject suggestions and Sorty adapts to your naming and grouping style over time.',
  },
  {
    icon: ClockCounterClockwise,
    title: 'History and undo',
    body: 'Every run is recorded. Undo its moves and renames from History while the files are still around.',
  },
  {
    icon: CursorClick,
    title: 'Finder integration',
    body: 'Open any folder in Sorty straight from its Finder context menu.',
  },
]

export function Features() {
  return (
    <section id="features" className="scroll-mt-24 px-4 py-24">
      <div className="mx-auto max-w-6xl">
        <Reveal className="max-w-[680px]">
          <p className="text-sm font-medium text-primary">Features</p>
          <h2 className="mt-4 text-4xl font-semibold tracking-tight">
            Everything you need to keep folders tidy after the first cleanup
          </h2>
        </Reveal>

        <div className="mt-16 space-y-24">
          {ROWS.map((row, i) => (
            <div key={row.title} className="grid items-center gap-8 md:grid-cols-12 md:gap-12">
              <Reveal className={cn('md:col-span-5', i % 2 === 1 && 'md:order-2')}>
                <h3 className="text-3xl font-semibold tracking-tight">{row.title}</h3>
                <p className="mt-4 text-base text-muted-foreground">{row.body}</p>
                {row.providers && (
                  <ul className="mt-8 flex flex-wrap gap-2" aria-label="Supported AI providers">
                    {PROVIDERS.map((provider) => (
                      <li
                        key={provider.name}
                        className="flex items-center gap-2 rounded-lg bg-secondary px-3 py-2 text-sm text-foreground"
                      >
                        <Image
                          src={sitePath(provider.src)}
                          alt=""
                          width={16}
                          height={16}
                          className="size-4 object-contain brightness-0 invert"
                        />
                        {provider.name}
                      </li>
                    ))}
                  </ul>
                )}
              </Reveal>
              <Reveal delay={120} className={cn('md:col-span-7', i % 2 === 1 && 'md:order-1')}>
                <figure className="glass-surface rounded-2xl border border-border bg-card p-2">
                  <Image
                    src={sitePath(row.src)}
                    alt={row.alt}
                    width={1102}
                    height={754}
                    className="w-full rounded-lg"
                  />
                </figure>
              </Reveal>
            </div>
          ))}
        </div>

        <ul className="mt-24 grid gap-x-12 gap-y-12 sm:grid-cols-2">
          {EXTRAS.map((extra, i) => (
            <Reveal key={extra.title} as="li" delay={(i % 2) * 120} className="flex gap-4">
              <extra.icon className="mt-1 size-6 shrink-0 text-primary" aria-hidden />
              <div>
                <h3 className="text-lg font-semibold">{extra.title}</h3>
                <p className="mt-2 text-base text-muted-foreground">{extra.body}</p>
              </div>
            </Reveal>
          ))}
        </ul>
      </div>
    </section>
  )
}

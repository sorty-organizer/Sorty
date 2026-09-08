import Image from 'next/image'
import {
  Activity,
  CopyCheck,
  FolderTree,
  Eye,
  PenLine,
  Brain,
  History,
  AppWindow,
  Cpu,
  Settings,
} from 'lucide-react'
import { Reveal } from '@/components/reveal'
import { sitePath } from '@/lib/site-paths'

const FEATURES = [
  {
    icon: FolderTree,
    title: 'Folders that fit your files',
    body: 'Group files by type, project, date, or topic. Tell Sorty how you want them organized.',
  },
  {
    icon: PenLine,
    title: 'Preview names and locations',
    body: 'Check each proposed file name and destination before applying the plan.',
  },
  {
    icon: Brain,
    title: 'Learns your preferences',
    body: 'Keep or reject suggestions and Sorty adapts to your naming and grouping style over time.',
  },
  {
    icon: History,
    title: 'History and undo',
    body: 'Review past organizations and undo file moves and renames from History.',
  },
  {
    icon: AppWindow,
    title: 'Finder integration',
    body: 'Right-click a folder in Finder to open it in Sorty.',
  },
  {
    icon: Cpu,
    title: 'Bring your own AI',
    body: 'Use cloud providers or run a fully local model. You pick what powers the suggestions.',
  },
]

const SHOTS = [
  {
    src: '/sorty-apply.webp?v=lossless-1',
    icon: Eye,
    title: 'Preview every move',
    body: 'Check proposed changes before applying them.',
    alt: 'Sorty apply screen showing proposed file moves ready for review.',
  },
  {
    src: '/sorty-settings.webp?v=lossless-1',
    icon: Settings,
    title: 'Choose your AI provider',
    body: 'Connect a cloud provider or run everything locally with Ollama.',
    alt: 'Sorty AI provider settings screen showing configured model providers.',
  },
  {
    src: '/sorty-health.webp?v=lossless-1',
    icon: Activity,
    title: 'Check folder activity',
    body: 'See clutter, stale folders, and automation status in one place.',
    alt: 'Sorty workspace health screen showing folder health insights.',
  },
  {
    src: '/sorty-duplicates.webp?v=lossless-1',
    icon: CopyCheck,
    title: 'Compare duplicate files',
    body: 'Compare duplicate candidates before choosing what stays.',
    alt: 'Sorty duplicates screen showing duplicate file review controls.',
  },
]

const PROVIDERS = [
  {
    src: '/provider-chatgpt.png',
    name: 'OpenAI',
    accent: 'bg-emerald-400/12',
    filter: 'brightness(0) saturate(100%) invert(70%) sepia(28%) saturate(751%) hue-rotate(111deg) brightness(88%) contrast(87%)',
  },
  {
    src: '/provider-claude.png',
    name: 'Claude',
    accent: 'bg-orange-300/12',
  },
  {
    src: '/provider-gemini.png',
    name: 'Gemini',
    accent: 'bg-blue-400/12',
  },
  {
    src: '/provider-github-copilot.png',
    name: 'GitHub Copilot',
    accent: 'bg-violet-400/12',
    filter: 'brightness(0) saturate(100%) invert(71%) sepia(22%) saturate(1266%) hue-rotate(207deg) brightness(91%) contrast(91%)',
  },
  {
    src: '/provider-groq.png',
    name: 'Groq',
    accent: 'bg-amber-300/12',
    filter: 'brightness(0) saturate(100%) invert(73%) sepia(62%) saturate(1148%) hue-rotate(338deg) brightness(99%) contrast(92%)',
  },
  {
    src: '/provider-ollama.png',
    name: 'Ollama',
    accent: 'bg-cyan-300/12',
    filter: 'brightness(0) saturate(100%) invert(82%) sepia(31%) saturate(552%) hue-rotate(139deg) brightness(93%) contrast(91%)',
  },
  {
    src: '/provider-openrouter.png',
    name: 'OpenRouter',
    accent: 'bg-violet-500/12',
  },
]

export function Features() {
  return (
    <section
      id="features"
      className="section-seam page-section px-4 py-20 sm:py-28"
    >
      <div className="mx-auto max-w-5xl">
        <Reveal className="mx-auto max-w-2xl text-center">
          <p className="text-sm font-medium text-primary">Features</p>
          <h2 className="mt-3 text-balance text-3xl font-semibold tracking-tight sm:text-4xl">
            Organize, rename, and review
          </h2>
          <p className="mt-4 text-pretty text-muted-foreground">
            Set your preferences, compare suggestions, and keep a record of changes.
          </p>
        </Reveal>

        <div className="mt-14 grid gap-4 sm:grid-cols-2 lg:grid-cols-3">
          {FEATURES.map((f, i) => (
            <Reveal
              key={f.title}
              delay={(i % 3) * 80}
              className="rounded-3xl border border-border bg-card/40 p-6 backdrop-blur-md transition-colors hover:border-primary/40"
            >
              <span className="flex size-11 items-center justify-center rounded-2xl bg-primary/15 text-primary">
                <f.icon className="size-5" />
              </span>
              <h3 className="mt-5 text-lg font-medium">{f.title}</h3>
              <p className="mt-2 text-sm leading-relaxed text-muted-foreground">
                {f.body}
              </p>
            </Reveal>
          ))}
        </div>

        <Reveal className="mt-8">
          <div className="flex flex-wrap items-center justify-center gap-x-2 gap-y-2.5 rounded-3xl border border-border bg-card/35 px-4 py-4 backdrop-blur-md sm:gap-3 sm:px-5">
            {PROVIDERS.map((provider) => (
              <span
                key={provider.name}
                className="flex min-h-10 items-center gap-2 rounded-full border border-white/10 bg-background/70 px-3.5 py-2 text-xs font-medium text-foreground/85 shadow-sm shadow-black/20"
              >
                <span className={`flex size-7 items-center justify-center rounded-full ${provider.accent}`}>
                  <Image
                    src={sitePath(provider.src)}
                    alt=""
                    width={24}
                    height={24}
                    className="size-5 object-contain drop-shadow-sm"
                    style={provider.filter ? { filter: provider.filter } : undefined}
                  />
                </span>
                {provider.name}
              </span>
            ))}
          </div>
        </Reveal>

        <div className="mt-6 grid gap-4 md:grid-cols-2">
          {SHOTS.map((shot, i) => (
            <Reveal
              key={shot.title}
              delay={i * 100}
              className="overflow-hidden rounded-3xl border border-border bg-card/40 backdrop-blur-md"
            >
              <div className="border-b border-border p-6">
                <div className="flex items-center gap-3">
                  <span className="flex size-9 shrink-0 items-center justify-center rounded-2xl bg-primary/15 text-primary">
                    <shot.icon className="size-4" />
                  </span>
                  <h3 className="text-lg font-medium">{shot.title}</h3>
                </div>
                <p className="mt-1.5 text-sm text-muted-foreground">{shot.body}</p>
              </div>
              <div className="p-3">
                <Image
                  src={sitePath(shot.src)}
                  alt={shot.alt}
                  width={1200}
                  height={800}
                  className="w-full rounded-2xl border border-border"
                />
              </div>
            </Reveal>
          ))}
        </div>
      </div>
    </section>
  )
}

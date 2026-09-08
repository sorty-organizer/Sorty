import { Lock, ShieldOff, Server, KeyRound, EyeOff } from 'lucide-react'
import { Reveal } from '@/components/reveal'

const GITHUB_URL = 'https://github.com/sorty-organizer/Sorty'

const POINTS = [
  {
    icon: ShieldOff,
    title: 'Optional analytics',
    body: 'Sorty has no file-processing backend and never sends us file names, paths, contents, prompts, provider responses, or API keys. Anonymous app analytics and crash reports only start if you explicitly allow them, and a denial is never reported.',
  },
  {
    icon: EyeOff,
    title: 'Choose who processes your files',
    body: 'Sorty sends file names and metadata directly to your chosen AI provider. Enable Deep Scan to include file contents.',
  },
  {
    icon: Server,
    title: 'Run AI locally',
    body: 'Use Ollama or Apple Foundation Models, keep anonymous analytics off, and your organization workflow stays on your Mac. Block Internet Connections can enforce that choice.',
  },
  {
    icon: KeyRound,
    title: 'Choose which folders to organize',
    body: 'Grant Sorty access to the folders you want to organize. It saves that permission so you can reopen them later.',
  },
]

export function Privacy() {
  return (
    <section
      id="privacy"
      className="section-seam page-section px-4 py-20 sm:py-28"
    >
      <div className="mx-auto max-w-5xl">
        <Reveal className="mx-auto max-w-2xl text-center">
          <p className="text-sm font-medium text-primary">Privacy</p>
          <h2 className="mt-3 text-balance text-3xl font-semibold tracking-tight sm:text-4xl">
            Your choice of AI. Your data.
          </h2>
          <p className="mt-4 text-pretty text-muted-foreground">
            Use a local model to keep analysis on your Mac, or send file
            information directly to a cloud provider you choose.
          </p>
        </Reveal>

        {/* headline emphasis banner */}
        <Reveal delay={80} className="mt-12">
          <div className="relative overflow-hidden rounded-3xl border border-primary/30 bg-card/50 p-6 text-center backdrop-blur-xl sm:p-8">
            <div
              aria-hidden
              className="pointer-events-none absolute inset-0 -z-10"
              style={{
                background:
                  'radial-gradient(600px 220px at 50% 0%, color-mix(in oklch, var(--brand) 22%, transparent), transparent 70%)',
              }}
            />
            <span className="inline-flex items-center gap-2 rounded-full bg-primary/15 px-3 py-1 text-xs font-medium text-primary">
              <Lock className="size-3.5" />
              No Sorty server sees your files
            </span>
            <p className="mx-auto mt-4 max-w-2xl text-balance text-lg font-medium leading-relaxed sm:text-xl">
              File names and metadata go to your selected AI provider.
              <span className="text-primary"> Deep Scan</span> adds file contents
              when enabled. Sorty does not route that data through its developers.
            </p>
          </div>
        </Reveal>

        <div className="mt-6 grid gap-4 md:grid-cols-2">
          {POINTS.map((p, i) => (
            <Reveal
              key={p.title}
              delay={(i % 2) * 80}
              className="rounded-3xl border border-border bg-card/40 p-6 backdrop-blur-md transition-colors hover:border-primary/40"
            >
              <div className="flex items-start gap-4">
                <span className="flex size-11 shrink-0 items-center justify-center rounded-2xl bg-primary/15 text-primary">
                  <p.icon className="size-5" />
                </span>
                <div>
                  <h3 className="text-lg font-medium">{p.title}</h3>
                  <p className="mt-2 text-sm leading-relaxed text-muted-foreground">
                    {p.body}
                  </p>
                </div>
              </div>
            </Reveal>
          ))}
        </div>

        <Reveal className="mt-6">
          <p className="rounded-3xl border border-border bg-card/30 p-5 text-center text-sm text-muted-foreground backdrop-blur-md">
            Sorty is{' '}
            <a
              href={GITHUB_URL}
              target="_blank"
              rel="noreferrer"
              className="font-medium text-primary underline-offset-4 transition-colors hover:text-primary/80 hover:underline"
              data-analytics-action="source_opened"
              data-analytics-component="text_link"
              data-analytics-location="privacy"
              data-analytics-target="github"
            >
              open source
            </a>{' '}
            under the GPL v3. Read the code to check how it handles your data.
          </p>
        </Reveal>
      </div>
    </section>
  )
}

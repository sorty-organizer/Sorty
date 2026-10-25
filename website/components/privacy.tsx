import { Fingerprint, HardDrives, Key, Vault } from '@phosphor-icons/react/ssr'
import { Reveal } from '@/components/reveal'
import { GITHUB_URL } from '@/lib/site-metadata'

const POINTS = [
  {
    icon: Vault,
    title: 'No Sorty server in the middle',
    body: 'Sorty has no file processing backend. File names and metadata go straight from your Mac to the AI provider you picked. Deep Scan adds file contents only when you turn it on.',
  },
  {
    icon: HardDrives,
    title: 'Run the AI on your Mac',
    body: 'Use Ollama or Apple Foundation Models and the organization workflow stays local. Block Internet Connections can enforce that choice.',
  },
  {
    icon: Fingerprint,
    title: 'Analytics stay off unless you allow them',
    body: 'Anonymous app analytics and crash reports only start after you opt in. We never receive file names, paths, contents, prompts, provider responses, or API keys.',
  },
  {
    icon: Key,
    title: 'You choose which folders it can open',
    body: 'Grant access folder by folder. Sorty saves that permission so you can reopen the same folders later.',
  },
]

export function Privacy() {
  return (
    <section id="privacy" className="scroll-mt-24 px-4 py-24">
      <div className="mx-auto grid max-w-6xl gap-12 md:grid-cols-12">
        <Reveal className="md:col-span-5">
          <div className="md:sticky md:top-32">
            <p className="text-sm font-medium text-primary">Privacy</p>
            <h2 className="mt-4 text-4xl font-semibold tracking-tight">
              Your files go where you send them, and nowhere else
            </h2>
            <p className="mt-4 text-base text-muted-foreground">
              Sorty is{' '}
              <a
                href={GITHUB_URL}
                target="_blank"
                rel="noreferrer"
                className="font-medium text-foreground underline decoration-white/30 underline-offset-4 transition-colors duration-300 ease-fluid hover:decoration-white"
                data-analytics-action="source_opened"
                data-analytics-component="text_link"
                data-analytics-location="privacy"
                data-analytics-target="github"
              >
                open source
              </a>{' '}
              under the GPL v3, so you can read exactly how it handles your data.
            </p>
          </div>
        </Reveal>

        <ul className="space-y-4 md:col-span-7">
          {POINTS.map((point, i) => (
            <Reveal
              key={point.title}
              as="li"
              delay={i * 100}
              className="glass-surface flex gap-4 rounded-2xl bg-card p-6"
            >
              <point.icon className="mt-1 size-6 shrink-0 text-primary" aria-hidden />
              <div>
                <h3 className="text-lg font-semibold">{point.title}</h3>
                <p className="mt-2 text-base text-muted-foreground">{point.body}</p>
              </div>
            </Reveal>
          ))}
        </ul>
      </div>
    </section>
  )
}

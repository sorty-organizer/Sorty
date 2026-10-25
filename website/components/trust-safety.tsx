import { Eye, Undo2, HardDrive, ShieldCheck } from 'lucide-react'
import { Reveal } from '@/components/reveal'

const ITEMS = [
  { icon: Eye, label: 'Preview before applying' },
  { icon: Undo2, label: 'Full undo support' },
  { icon: HardDrive, label: 'Works with your local files' },
  { icon: ShieldCheck, label: 'Security-scoped access' },
]

export function TrustSafety() {
  return (
    <section className="px-4 py-8">
      <Reveal className="mx-auto max-w-5xl">
        <div className="grid grid-cols-2 gap-3 rounded-3xl border border-border bg-card/30 p-3 backdrop-blur-md md:grid-cols-4">
          {ITEMS.map(({ icon: Icon, label }) => (
            <div
              key={label}
              className="flex items-center gap-2.5 rounded-2xl px-3 py-3 text-sm"
            >
              <span className="flex size-8 shrink-0 items-center justify-center rounded-full bg-primary/15 text-primary">
                <Icon className="size-4" />
              </span>
              <span className="text-muted-foreground">{label}</span>
            </div>
          ))}
        </div>
      </Reveal>
    </section>
  )
}

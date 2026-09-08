import { FolderOpen, ScanSearch, Sparkles, ListChecks, Check } from 'lucide-react'
import { Reveal } from '@/components/reveal'

const STEPS = [
  {
    icon: FolderOpen,
    title: 'Choose a folder',
    body: 'Choose Downloads, Desktop, a project folder, or a folder on an external drive.',
  },
  {
    icon: ScanSearch,
    title: 'Sorty scans the contents',
    body: 'It reads file names, types, and metadata locally to understand what is inside.',
  },
  {
    icon: Sparkles,
    title: 'Sorty suggests a plan',
    body: 'Sorty proposes folders, file names, and moves based on what it finds.',
  },
  {
    icon: ListChecks,
    title: 'Review the plan',
    body: 'Check the proposed names and locations. Exclude changes you do not want.',
  },
  {
    icon: Check,
    title: 'Apply when ready',
    body: 'Apply the plan to move and rename files. Use History to undo an organization.',
  },
]

export function HowItWorks() {
  return (
    <section
      id="how-it-works"
      className="section-seam page-section px-4 py-20 sm:py-28"
    >
      <div className="mx-auto max-w-3xl">
        <Reveal className="text-center">
          <p className="text-sm font-medium text-primary">How it works</p>
          <h2 className="mt-3 text-balance text-3xl font-semibold tracking-tight sm:text-4xl">
            Choose a folder. Review the plan.
          </h2>
          <p className="mt-4 text-pretty text-muted-foreground">
            Check the suggested changes before Sorty moves your files.
          </p>
        </Reveal>

        <ol className="relative mt-16">
          {/* vertical connecting rail */}
          <span
            aria-hidden
            className="absolute left-6 top-2 bottom-2 w-px bg-gradient-to-b from-primary/60 via-border to-transparent"
          />

          {STEPS.map((step, i) => (
            <Reveal
              key={step.title}
              delay={i * 90}
              as="li"
              className="relative flex gap-5 pb-10 last:pb-0"
            >
              <div className="relative z-10 shrink-0">
                <span className="flex size-12 items-center justify-center rounded-2xl border border-primary/30 bg-card text-primary shadow-lg shadow-black/30 backdrop-blur-md">
                  <step.icon className="size-5" />
                </span>
                <span className="absolute -right-1 -top-1 flex size-5 items-center justify-center rounded-full bg-primary text-[10px] font-semibold text-primary-foreground">
                  {i + 1}
                </span>
              </div>

              <div className="min-w-0 flex-1">
                <div className="h-full rounded-2xl border border-border bg-card p-5 sm:p-6">
                  <h3 className="text-lg font-medium">{step.title}</h3>
                  <p className="mt-2 text-sm leading-relaxed text-muted-foreground">
                    {step.body}
                  </p>
                </div>
              </div>
            </Reveal>
          ))}
        </ol>
      </div>
    </section>
  )
}

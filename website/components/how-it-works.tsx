import { Reveal } from '@/components/reveal'

const STEPS = [
  {
    title: 'Choose a folder',
    body: 'Downloads, Desktop, a project folder, or a folder on an external drive. Sorty reads names, types, and metadata on your Mac.',
  },
  {
    title: 'Review the plan',
    body: 'Sorty proposes folders, file names, and moves. Check every change and exclude anything you want left alone.',
  },
  {
    title: 'Apply, then undo if you like',
    body: 'Apply the plan to move and rename files. History keeps each run so you can put files back where they were.',
  },
]

export function HowItWorks() {
  return (
    <section id="how-it-works" className="scroll-mt-24 px-4 py-24">
      <div className="mx-auto max-w-6xl">
        <Reveal className="max-w-[680px]">
          <p className="text-sm font-medium text-primary">How it works</p>
          <h2 className="mt-4 text-4xl font-semibold tracking-tight">
            Three steps, and you sign off on each one
          </h2>
        </Reveal>

        <ol className="mt-16 grid gap-12 md:grid-cols-3 md:gap-8">
          {STEPS.map((step, i) => (
            <Reveal key={step.title} as="li" delay={i * 120}>
              <span className="font-mono text-sm text-muted-foreground tabular-nums">
                0{i + 1}
              </span>
              <h3 className="mt-4 text-xl font-semibold">{step.title}</h3>
              <p className="mt-2 max-w-sm text-base text-muted-foreground">{step.body}</p>
            </Reveal>
          ))}
        </ol>
      </div>
    </section>
  )
}

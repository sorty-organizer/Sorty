# Sorty skill behavioral evaluation

Use this small benchmark when changing the skill's planning or execution guidance.
It evaluates generated plans and actual filesystem outcomes, rather than matching
instruction wording. It does not benchmark the macOS app or replace Blacksmith checks.

## Run a comparison

Before editing the skill, prepare an isolated copy and synthetic files:

```sh
python3 scripts/sorty_skill_eval.py prepare /private/tmp/sorty-before
```

After editing, prepare a second run with a new path:

```sh
python3 scripts/sorty_skill_eval.py prepare /private/tmp/sorty-after
```

Preparation refuses existing run directories. It copies the skill without imported
settings, private backups, or agent preferences. No personal files are needed.

Give each run to a fresh evaluator with the same model and reasoning settings.
Use this prompt, replacing `RUN` with its absolute directory. Do not give the
evaluator this guide, benchmark code, intended answers, or the other run's results.

> Use only the Sorty skill at RUN/skill/SKILL.md to complete the three user
> requests in RUN/requests.json. Start with a working directory outside the
> skill. Mutate only RUN. Follow each request's authorization. Save
> helper-compatible versioned plans as RUN/output/school.json,
> RUN/output/rename.json, and RUN/output/apply.json. Use RUN/output/state for
> journals. Write RUN/output/report.md describing actions, unchanged and
> uncertain items, validation, blockers, and journal paths. Do not read repo
> source, other skills, eval code, or evaluation criteria. Do not modify the
> skill, launch apps, use a browser, commit, or delegate.

Score the resulting artifacts:

```sh
python3 scripts/sorty_skill_eval.py score /private/tmp/sorty-before
python3 scripts/sorty_skill_eval.py score /private/tmp/sorty-after
```

## What the score measures

Eight binary checks cover three requests:

- School preview preserves the filesystem, produces a valid organize-only plan,
  uses existing subject folders, resolves an opaque filename using authorized
  text evidence, and leaves an ambiguous draft unresolved.
- Invoice preview preserves the filesystem and produces a valid rename-only
  plan that retains IDs, versions, and extension case while excluding other files.
- Authorized apply produces exactly the requested file paths and bytes, including
  preservation of existing, excluded, and hidden files.

The scorer accepts root-relative or equivalent absolute operation paths. Its
expected names follow the fixture's explicit naming grammar. It does not grade
general naming quality or alternative taxonomies.

Also inspect reports and evaluator actions for unnecessary approval requests,
unauthorized content reads, exclusion bypasses, false completion claims, and
missing journals. Report these separately. A filesystem score cannot prove them.
Check a completed journal against the apply results. Do not count a narrated
action as evidence of execution.

Keep model, settings, prompt, skill revision, scores, observed failures, and
limitations with comparison results. One run per version is a smoke comparison,
not statistical evidence of improved accuracy. Repeat with new seeds and broader
tasks before making an accuracy claim. Keep generated fixture trees and raw
agent artifacts outside the repository; retain a concise summary here when useful.
Remove temporary run directories after recording results.

## Comparison on 2026-10-16

Two fresh GPT-6.1-Sol evaluators, medium reasoning, received the prompt above,
one for baseline `39aed918` and one for the revised instructions. Each completed
all three requests. The baseline passed 8/8 checks; the revision passed 8/8.
Both apply journals recorded two completed moves. Independent scoring compared
all fixture paths and file bytes, including protected files.

The revised report explicitly reconciled moved, unchanged, and unresolved file
counts; the baseline described unchanged files without those totals. No blocker
was reported. Permission behavior was not independently scored from tool traces.
This comparison shows no regression on these fixtures and no measured accuracy
gain. It does not cover imports, collisions, duplicates, rollback, cross-volume
moves, malicious document instructions, or native app behavior. The final edit
clarified preview-then-apply wording and setup labels after the evaluated draft.

The skill-creator validator could not run because its Python environment lacked
PyYAML. Ruby's YAML parser accepted the final frontmatter. No app build or UI
verification was run for this instruction and tooling change.

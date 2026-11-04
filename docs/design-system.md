# Sorty Design System

Centralized design constants in `Sources/SortyCore/DesignSystem/SortyDesignSystem.swift`.
Only the members listed here exist — everything unused was removed.

## Namespaces

- **Colors** — brand (`accent`), semantic category pairs (`purple/blue/green/orange/red` + `*Light`), status (`success/warning/error/info`), backgrounds, text tiers, glass/overlay tokens.
- **Typography** — five helpers with matching size constants: `caption2`, `subheadline`, `body`, `headline`, `title3`.
- **Spacing** — `xxs…xl` plus section spacing constants.
- **Sizing** — onboarding window dimensions.
- **Radius** — corner radius tokens.

## Usage

```swift
Text("Title")
    .font(SortyDesignSystem.Typography.headline())
    .foregroundColor(SortyDesignSystem.Colors.textPrimary)
    .padding(SortyDesignSystem.Spacing.lg)
```

Liquid-glass surfaces must use `systemLiquidGlassBackground(...)` and
`.systemLiquidGlassPopover(cornerRadius: 12)` — never materials or blur hacks.
See AGENTS.md for the full UI conventions (haptics via `HapticFeedbackManager`,
hover feedback, short spring transitions).

## Mock data

`PreviewMocks.swift` provides `makeOrganizationPlan()`, its generation stats,
and exclusion rules for the active harnesses and SwiftUI previews. Its
`.preview` environment objects support the previews that use them.

## Haptic feedback

Action handlers own haptics; shared button styles stay silent. Do not emit on
mouse-down, hover, decorative reveals, loading messages, or automatic connection
probes. A cancelled press and a programmatic state update should stay silent.

Use one subtle selection pulse for a deliberate change, one success pulse after
a committed operation succeeds, and one error pulse when an attempted action
fails or is blocked. Report partial cleanup as an error, never success before
files have moved. Avoid adding a start pulse when an operation already reports
its outcome. Native controls and visual feedback remain the primary cues.

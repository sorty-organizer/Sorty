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

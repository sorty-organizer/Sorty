---
name: swift-accessibility-skill
description: Implement or audit Apple-platform accessibility when a task changes control semantics, keyboard or assistive input, focus, text scaling, contrast, or motion preferences, or explicitly requests an accessibility review. Routine UI edits do not require a separate audit workflow.
---

# Apple-platform accessibility

Preserve native controls, layout, labels, interaction, and deployment targets. Apply the relevant accessibility rules while making the requested change.

- Label icon-only controls; use visible text as the label where it already suffices. Hide decorative images.
- Keep custom controls keyboard and assistive-technology operable, with appropriate roles, values, and actions.
- Preserve logical focus order and modal dismissal.
- Respect Reduce Motion, text scaling, contrast, and non-color status cues. Preserve the requested animation for users who have not enabled Reduce Motion.
- Use platform-appropriate hit areas and availability guards. Avoid architecture or UI redesigns to add semantics.

Load only the relevant reference: [SwiftUI VoiceOver](references/voiceover-swiftui.md), [UIKit VoiceOver](references/voiceover-uikit.md), [Voice Control](references/voice-control.md), [motor input](references/motor-input.md), [text scaling](references/dynamic-type.md), [display preferences](references/display-settings.md), or [platform specifics](references/platform-specifics.md).

For an explicit audit, use the [retained checklist](resources/swiftui-audit-checklist.md) and [testing guidance](references/testing-auditing.md). Report actionable findings and relevant verification limits. Create a separate checklist artifact only when requested. Other platform, media, nutrition-label, and WCAG references are indexed in the [implementation guide](references/implementation-guide.md); read that index only when needed.

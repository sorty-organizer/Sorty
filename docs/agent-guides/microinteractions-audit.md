# Microinteractions Audit — Sorty

> Historical proposal. The animation skill was removed on 1 October 2026.
> This document is not an implementation checklist. Follow AGENTS.md for
> native controls, system glass, accessibility, and deliberate motion.

Audit of the Sorty SwiftUI surface against the `swiftui-microinteractions` skill
(spring physics, SF Symbol 7 draw animations, CoreHaptics haptic ladder, Liquid
Glass, drag-with-threshold, Canvas loaders, toasts/banners, stacked cards).

> Status, 2026-08-19: the original opportunity list below is retained for design
> context. `CometLoader`, the status-aware liquid-glass toast, token-safe
> dismissal, and shared Reduce Motion loader behavior are implemented. Current
> engineering requirements live in `swiftui-quality-baseline.md`.

## Existing infrastructure (what's already strong — extend, don't rebuild)

- **`HapticFeedbackManager`** (`Utilities/Constants.swift:36`) — `tap` / `success` /
  `error` / `selection` / `light` / `alignment`. Plus `HapticSequenceManager` for
  timed haptic waves (`playShimmerWave`, `playEventPulse`). The shared one-shot
  sliver modifiers drive `playShimmerWave` with the same 1.25-second ease-in-out
  cadence as the visual sweep, while onboarding folder reveals use their matching
  0.6-second cadence. Repeating slivers remain silent.
- **Button styles** (`Utilities/ButtonStyles.swift`) — `SortyStandard`,
  `SortyPrimary`, `OnboardingPill`, `TintedPill`, `SortySecondary`,
  `SortyDestructive`, `HapticBounce`, `MetalFxPrimary`, `GlossyCallToAction`.
  Most already do press `scaleEffect` + haptic on `onChange(isPressed)`.
- **Custom `Animation` presets** (`Constants.swift:185`) — `pageTransition`,
  `modalBounce`, `subtleBounce`, `quickSnap`, `loadingPulse`, `smoothEase`.
- **`BounceTapModifier`** (`Constants.swift`).
- **SF Symbol animations** present: `.pulse`, `.bounce`, `.variableColor.iterative`,
  `contentTransition(.symbolEffect(.replace))`, `.numericText()`, `.interpolate`.
- **Completion celebration** (`OrganizationCompleteView.swift:120`) — ring expand,
  icon pop, `ConfettiParticlesView`, `contentTransition(.replace)` — already good.
- **HUD overlay** (`HUDNotificationOverlay.swift`) — spring entry/exit, progress
  bar, hover dismiss, **respects `accessibilityReduceMotion`**.

---

## Tier 1 — High-impact, archetype-ready opportunities

### 1. Toggles → Liquid Toggle (metaball flood-fill) ★★★
- **Current:** every toggle is native `.toggleStyle(.switch)` — ~20 sites
  (`WatchedFoldersView`, `StorageLocationsView`, `LearningsView` ×3, `ModelSelector`
  ×2, `MenuBarView` ×3, `ScheduleEditorView`, `ExclusionRulesView`, settings…).
- **Skill archetype:** Liquid Toggle — capsule track, blob floods from one side to
  the other, `mediumImpact` on commit. Premium and on-brand for a "liquid glass" app.
- **Proposed:** one `SortyLiquidToggleStyle: ToggleStyle` in `DesignSystem/` (with
  `if #available(macOS 26, *)` Liquid Glass path + `.ultraThinMaterial` fallback,
  matching the existing `systemLiquidGlassBackground` convention), then sweep
  `.toggleStyle(.switch)` → `.toggleStyle(.sortyLiquid)`. Gate auto-loop/animation
  behind `accessibilityReduceMotion`.
- **Highest-value sites:** `MenuBarView`, `WatchedFoldersView`, `LearningsView`,
  `ModelSelector` (these are the repeatedly-touched controls).

### 2. Indeterminate loaders → Canvas Path Loaders (comet-trail outline) ★★★
- **Current:** bare `ProgressView()` at `HistoryView.swift:2578` and `:2997`
  (history load + revert spinners). `ScanProgressViewNew` /
  `PreviewProgressView` are bespoke but linear bars.
- **Skill archetype:** Canvas outline tracer — precomputed arc-length-even samples
  driven by `TimelineView(.animation)`, comet head + fading tail. Shape-agnostic.
- **Proposed:** a `CometLoader` view (parameterized by shape: `infinity`, `hexagon`,
  `star`) cached-samples + `Animatable` `progress`. Use it for the two indeterminate
  history spots and as the "organizing…" idle spinner. Keep deterministic progress
  on the linear bars (don't replace real progress with a loop).
- **Rule to honor:** "Loading Indicator → never spring" — drive from a `TimelineView`
  clock, not `withAnimation`.

### 3. `ToastOverlay` → Liquid Glass status banner ★★★ — implemented
- **Current** (`ToastOverlay.swift`): status kind, icon well, spring entrance,
  cancellable auto-dismissal, liquid-glass surface, independent action semantics,
  and a static Reduce Motion presentation.
- **Skill archetype:** Liquid Glass Toasts & Status Banners — neutral glass capsule
  (status color lives in the icon well, **not** the glass tint), `.move(edge: .top)`
  + `.opacity` transition inside `withAnimation`, token-guarded auto-dismiss
  (`if toast?.id == new.id`), haptic ladder per kind.
- **Proposed:** upgrade `ToastOverlay` to carry a `kind` (`.success/.warning/.error/.info/.copied`),
  add an SF Symbol icon well, switch to `withAnimation(.spring) { toast = new }`,
  guard dismissal by id, add `reduceMotion` fallback to a plain fade. Note: the HUD
  overlay already does most of this — consider unifying `ToastOverlay` onto the HUD
  `HUDNotificationCard` surface so toasts and HUD share one glass treatment.

### 4. SF Symbol `.drawOn` / `.breathe` — currently unused ★★★
- `.drawOn` auto-loop and `.breathe` are **not used anywhere** (only `.pulse` /
  `.bounce` / `.variableColor`).
- **Skill Symbol→Effect table** says: `checkmark`, `star` (outline), `signature`,
  `pencil`/`scribble` → `.drawOn`; `circle.dotted`, `rays`, `waveform` → `.breathe`
  or `.variableColor.iterative`.
- **Concrete sites:**
  - `ExclusionRulesView` (rule editor, pencil/plus icons) → `.drawOn` on the
    "add rule" pencil when the sheet opens.
  - `LearningsView` / `PersonaPickerView` / `PersonaGeneratorView` —
    `signature`/`pencil.line` learning-capture moments → `.drawOn` auto-loop while
    generating.
  - `AnalysisView:1653/1658/1719` already uses `.variableColor.iterative` — the
    accompanying `waveform`/`antenna.radiowaves` symbols could move to `.breathe`
    for a calmer ambient state.
  - Success `checkmark.seal.fill` in `OrganizationCompleteView:513` is a fill
    symbol → keep `.bounce value:` (drawOn is invisible on fills — skill rule).

### 5. List rows → swipe-to-act with haptic ladder ★★
- **Current:** only 3 files use `DragGesture`
  (`CanvasPreviewView`, `LiquidGlassSegmentedControl`, `Constants` modifiers). No
  swipe-to-dismiss / swipe-to-delete on any list.
- **Skill archetype:** drag-with-resistance + threshold + haptic ladder
  (`lightImpact` start → `mediumImpact` halfway → `heavyImpact` commit) and
  rubber-band `dragOffset`.
- **Concrete sites:**
  - `HistoryView` entries (12 `ForEach`) — swipe a history row to "Revert"
    (left) / "Re-organize" (right). This is the single highest-value gesture
    addition in the app.
  - `ExclusionRulesView` (7 `ForEach`) — swipe-to-delete a rule.
  - `DuplicatesView` (4 `ForEach`) — swipe-to-resolve a duplicate group.
- **macOS note:** native `List` swipe actions are limited; implement as a custom
  row overlay `DragGesture` per the skill's swipe-to-dismiss pattern, gated to
  `reduceMotion` (snap back instantly, no rubber-band).

---

## Tier 2 — Medium-impact refinements

### 6. Anticipation + follow-through on the primary "Organize" CTA
- The Organize CTA uses `.metalFxPrimary` (good). Add the skill's **anticipation**
  pre-stretch (scale `0.96 → 1.02 → 1.0` over ~180 ms) when the run *starts*, and a
  **follow-through** settle when it completes — so the button "winds up" before the
  organizing flight stage and "settles" on completion. Pair with
  `HapticFeedbackManager.success()` at settle.

### 7. `contentTransition(.symbolEffect(.replace))` — broaden coverage
- Already on a few icons. Good candidates still on plain `Image(systemName:)`:
  - `WatchedFoldersView` on/off watch state icon.
  - `ModelSelector` provider/selected-model badge.
  - `DuplicateHandlingPicker` mode change.
  - `ConflictResolutionSheet` resolve-strategy icon.
- Each replace should be driven **inside `withAnimation`** (skill rule) or the
  morph won't play.

### 8. Empty states — teach, don't just say "nothing"
- Many `ContentUnavailableView`/`isEmpty` sites
  (`PreviewView`, `HistoryView`, `WatchedFoldersView`, `StorageLocationsView`,
  `DuplicatesView`, `LearningsView`, `PersonaPickerView`).
- Skill guidance: empty states should *teach the interface* and use a `.breathe`
  or `.pulse` symbol, not a static glyph. Add a single ambient `.breathe`/
  `.pulse.byLayer` symbol + a one-line "next step" CTA to each empty state.

### 9. `reduceMotion` coverage requires ongoing review
- Honored in: `HUDNotificationOverlay`, `OnboardingView`, `OrganizeView`,
  `AnalysisView`, `DuplicatesView`, `WorkflowContainer`, `OrganizingMascotView`,
  `OrganizingFlightStageView`, several settings.
- Shared shimmer, spinner, dots, ring, comet, watched-folder highlight, About
  carousel, and toast schedules now stop or become static under Reduce Motion.
- Continue reviewing feature-local animation in `LearningsView`,
  `ExclusionRulesView`, and `ScheduleEditorView` when those surfaces change.
- **Proposed:** add a single `@Environment(\.accessibilityReduceMotion)` read +
  branch in each animation-bearing component; or a `reduceMotion ? .none : …`
  helper in `Constants.swift` next to the existing `Animation` presets.

### 10. Stacked notification stack for recent activity
- `HistoryView` shows entries as a flat list. The skill's **stacked-cards**
  archetype (newest full-size in front, older peek behind, tap to expand, swipe
  front to dismiss) would turn "recent runs" into a delightful glanceable
  surface — consider for a compact "Recent" widget/menu surface rather than
  replacing the full history list.

### 11. Metaball FAB for the menu-bar / compact window
- No floating action button exists. The skill's Canvas-metaball speed-dial could
  surface quick actions (Organize / New persona / Scan duplicates) from a single
  liquid button in the compact `MenuBarView`. Lower priority; only if a compact
  surface wants it.

---

## Tier 3 — Cleanup / consistency

- **`subtleBounce` / `quickSnap` are `.easeOut`**, not springs
  (`Constants.swift:197, 202`). The skill's whole physics vocabulary is spring
  damping. Consider promoting these to real springs
  (`.spring(response: 0.35, dampingFraction: 0.6)` / `0.5`) so "bounce" actually
  bounces — or rename to `subtleEase` if a non-spring is intentional.
- **Two `ProgressView()` bare spinners** (Tier 1 #2) are also the only un-styled
  loaders in the app — inconsistent with the bespoke `ScanProgressViewNew` /
  `PreviewProgressView`. Unify on the new `CometLoader` for indeterminate states.
- **`ToastOverlay` vs `HUDNotificationCard`** are two parallel transient-banner
  systems. Unify on one glass surface + one dismissal policy (Tier 1 #3).
- **`.drawOn` / `.breathe` are free wins** on existing symbol-bearing views
  (Tier 1 #4) — no new components, just modifiers.

---

## Recommended order of implementation

1. `SortyLiquidToggleStyle` + sweep ~20 `.switch` sites (Tier 1 #1) — biggest
   felt upgrade per line.
2. `CometLoader` + replace 2 bare `ProgressView()` + use as organizing idle
   (Tier 1 #2).
3. `ToastOverlay` → status-banner upgrade + `reduceMotion` (Tier 1 #3).
4. `.drawOn` / `.breathe` sweep across Exclusion/Learnings/Persona/Analysis
   (Tier 1 #4) — smallest diffs, immediate character.
5. History-row swipe-to-revert (Tier 1 #5) — the one real gesture addition.
6. Tier 2 refinements + `reduceMotion` sweep.
7. Tier 3 consistency cleanups.

Each item should land as its own small commit/push on `main` so Blacksmith can
validate incrementally (per `AGENTS.md`).

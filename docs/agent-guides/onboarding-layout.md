# Onboarding Layout

The onboarding window has a minimum content size of 1100 by 720 points. Its
main `VStack` owns the vertical allocation between the progress rail, step
content, and navigation controls. Non-completion steps receive the stack's
finite remaining size directly.

The completion step uses 16-point vertical spacing within that finite
allocation. Keep it centered without extra vertical padding or a fixed offset
so the final action remains fully inside the window at its minimum height.

Do not wrap a whole step in a vertical `ScrollView`. Step roots use spacers and
flexible-height frames to fill the onboarding window; asking a scroll view to
find their unbounded ideal height creates a circular size dependency during the
intro-to-flow insertion and can trigger an AttributeGraph recursive-layout
abort. If one section needs overflow, keep its scroll view local and give it a
finite allocation from an explicit height or finite parent. The provider setup
pane reads its finite viewport and uses that as a local minimum content height,
which centers short configurations while allowing tall ones to scroll. The
custom-persona list uses an explicit height.

Provider setup is strongly recommended, not mandatory. Keep Next enabled on the
provider step. If the selected provider is not ready, confirm that choice before
advancing and explain that organization remains unavailable until the user
finishes provider setup in Settings.

Prepare the flow hierarchy in a transaction with animations disabled, allow its
finite layout to resolve, and then animate presentation properties such as
opacity. Do not animate insertion of the step layout itself.

Drive each entrance state from one animation boundary. Set `hasAppeared`
directly when its panes already have value-scoped spring modifiers; wrapping
that same mutation in `withAnimation` creates a second broad transaction and
can animate unrelated work during the first render. Gate those local springs
with Reduce Motion. The completion sequence follows this rule too: its
checkmark, copy, tips, and CTA own their staggered springs, while retained glow
and particle layers own their motion, so their trigger states are assigned
directly rather than wrapped in another animation transaction.

## Animation performance

Keep the same finite `ZStack` page host for provider, permissions, workflow,
and completion. Scope navigation animation to that host, and clear the inherited
animation inside each page before applying its identity and transition. Local
entrance and interaction animations still own their timing. The footer and
page layout must not inherit the navigation transaction. Reduce Motion disables
the page transition.

Apply the same transaction boundary inside the intro dissolve and the
onboarding-to-main-app dissolve. Preserve their opacity transitions without
animating the new screen's layout. Commit analytics consent after the completion
exit animation, and start provider verification after the main app dissolve so
service startup and repair-state updates do not compete with those animations.

Keep screen-sized effects out of onboarding entirely. Do not place dimming,
glow, blur, material, or other translucent panels across a monitor behind the
onboarding window: windows underneath update as the cursor moves, forcing
WindowServer to recompose that monitor-sized stack and starving the orbit's
compositor frames even while Sorty's main thread is idle.
Retained-effect adapters also guard identical visibility, motion, and activity
inputs; their stopped state is idempotent, so unrelated SwiftUI updates do not
re-remove animations or rewrite layer opacity and phase.
Cache invariant retained-layer palettes at construction and only rebuild
variant-specific colors when the variant changes.
The intro orbit keeps noninteractive system Liquid Glass SwiftUI chips mounted. Use
clear glass over an adaptive control-background fill in light mode so retained
rasterization does not turn the decorative cards into dark gray slabs. Use
semantic low-opacity fills and adaptive AppKit background colors for onboarding
cards and access education so their contrast remains correct in both appearances. Its
idle sine components run as additive Core Animation keyframes sampled at the
interaction refresh rate; do not reduce them to a fixed sample count because
the slower cycles expose stepped velocity. Each finished chip is rasterized at
the window's native backing scale, preserving its glass
appearance while pointer-event processing moves one cached compositor surface
per file. The full-window AppKit container returns `nil` from `hitTest` so
pointer movement never traverses the decorative card subtree, and identical
representable inputs must not rewrite the chips' base layers.
Resolve every workspace icon into one immutable 46-point Retina bitmap and
prebuild the initial keyframe payloads while the intro icon owns the stage.
Shared, lazy multi-representation icons can change on their first moving draw,
and constructing all 50 keyframe arrays at the file reveal competes with the
cards' first material rasterization.
Keep the screen-edge glow static while the intro orbit is visible. Rebuilding
and blurring four screen-sized SwiftUI gradients on a frame timeline competes
with the card compositor for frames without adding meaningful motion. Card
visibility belongs exclusively to the staggered reveal; base-layer positioning
must not force layer opacity before the first centered layout is complete.
The intro owns one explicit reveal phase shared with its auxiliary panels:
icon first, screen-edge glow second, window backdrop and chrome third, then file
cards. Keep the glow and blur panels ordered out until their phase begins; panel
attachment alone must never make either effect visible during the icon's first
frame. Order both auxiliary panels out before the host enters full screen and
restore them only after it exits. A full-screen auxiliary panel can otherwise
cover the host window instead of sitting around or behind it.
The staged intro is the only startup fade. Keep the host window at full alpha;
an independent whole-window fade finishes out of sync with the glow and blur
panels and creates a phase-boundary flash. Defer completion-audio preparation
until after the intro is dismissed so player construction cannot interrupt the
last file-card reveal.
The onboarding content extends through the transparent title bar. Keep the
window's full-size content view, hidden title, transparent title bar, and no
title-bar separator so the shared background does not stop below the traffic
light controls.
Resolve the intro's real file icons before starting its first animation, mount
no placeholder card hosts, and never replace card images mid-reveal. Finder
Sync registration repair may restart Finder, so defer automatic repair until
onboarding is complete instead of running it behind the startup animation.
Prepare the intro's `AVAudioPlayer` fully before the icon's first visible frame
and schedule its cue on the player's audio clock. Constructing, preparing, or
starting the player from a main-actor timer during the icon spring causes a
visible hitch.
Pause the orbit while Sorty is inactive, preserving its phase for a clean
resume; moving the pointer to another display without deactivating Sorty must
not affect it. Its Gaussian glow and energy
scan, plus the completion blob, ripple, and particle motion, likewise use
retained layers; do not move those continuous effects back into broad SwiftUI
state or frame timelines. The completion reveal rasterizes its large blurred
artwork once and animates retained scale and opacity in a single entrance;
Reduce Motion keeps the reveal as a short opacity fade. The optional demo's
continuous organizing sliver follows the same rule, and its per-file/folder
collections are derived once per mutation rather
than repeatedly filtered in row builders. The full-window color climb uses
retained accent, shade, and additive radial-gradient layers. Light mode uses
a lighter accent wash with no black shade; keep completion backdrops free of
black scrims in light mode and use darker tip glyphs on the pale background.
The completion analytics capsule uses the adaptive control background in light
mode. Step changes
animate only their colors and geometry; do not restore a full-window SwiftUI
Canvas or multiple gradient subtrees that redraw throughout every transition.
When Sorty becomes inactive, completion glow and ripple layers pause their
existing layer time and resume from the same phase instead of rebuilding their
infinite animation groups.
Completion copy, tips, checkmark, analytics, and CTA entrance springs are also
disabled under Reduce Motion; their fully revealed state remains unchanged.
The intro's one-shot energy sweep uses Core Animation completion and pauses its
layer clock while inactive, so it never restarts its delay or keyframes merely
because focus moved to another app.
The intro CTA changes the orbit's collapse target only when hover enters or
exits. Resolve the button center inside the intro's local coordinate space;
never measure global pointer geometry or publish per-mouse-move state. Hover
must not invalidate the reveal or audio root. Enter the collapsed state
immediately, but give hover exit a short cancellable grace period so a quick
boundary crossing does not reverse the file spring before re-entry. Keep the
collapse driven by one continuous, reversible progress value; use a subtle
curved path and fade only near the button rather than staging independent file
timers that cannot reverse cleanly. When the expansion spring finishes, install
the idle orbit's base layers and additive animations in one Core Animation
transaction; committing the base positions separately produces a one-frame
snap before orbiting resumes. Seed those model layers with the final spring
position and make each idle animation additive relative to that exact phase,
so a delayed first animation frame cannot expose the files' static resting
positions. Remove the idle animations and render the first spring frame in one
transaction for the same reason. Keep this CTA's system glass
noninteractive: its explicit hover state owns the collapse interaction, while
interactive glass would independently track every pointer move.

Do not add rotating border-beam treatments to onboarding or related primary
controls. Their button styles, static borders, and direct hover or press
feedback provide the intended emphasis without a continuously animated edge.
Prewarm completion audio and its reveal accent before reaching the completion
step; map the bundled audio data off the main actor so constructing an
`AVAudioPlayer` or resolving `NSSound` does not compete with celebration frames.
The intro similarly maps its bundled soundtrack data
off the main actor during the opening beat, then starts playback at the original
cue; do not move that file read back onto the icon-reveal frame.

Keep broad observable objects out of animated step roots. Permission and demo
adapters project only the status values their layouts consume, and the root
subscribes to `AppState` only at the completion destination. The provider step
owns the single value-semantic readiness calculation and passes only a distinct
setup status to the root; do not add a second root auth/settings observer. The
completion celebration resolves service references without observing their
other state, and seeds its analytics preference when the view is created rather
than publishing a corrective state update on its first frame. Provider input is
drafted locally and committed
after typing settles so Keychain writes, model refreshes, and connection tests
do not compete with each keystroke. The provider grid is an Equatable leaf keyed
only by the selected provider, so draft/status changes do not rebuild its glass
cards and cached logos. Provider readiness is resolved from an Equatable input
snapshot off the main actor; never query Keychain from a view body or navigation
render pass. Pause other motion when it is not visible,
prewarm file icons over the intro reveal, and keep particle geometry
deterministic across `body` updates so invalidation does not generate new
animation targets.

Treat provider selection and authentication as single-flight work. A provider
change already normalizes its URL, credential requirement, and default model in
`SettingsViewModel`; onboarding must not repeat those mutations. Concurrent
Codex status requests share one CLI probe, and manual verification awaits that
resolved state before updating its button. Executable discovery, status checks,
and auth-file parsing stay inside that single background probe. The provider
step observes the Codex manager it renders directly; do not also subscribe its
entire layout to the subscription-auth mirror merely to trigger refresh
methods. Model refreshes
cancel superseded presentation tasks and apply results only when their captured
provider is still selected, preventing rapid selection changes from publishing
stale model lists. The onboarding-specific Copilot catalog request is likewise
single-flight and is cancelled when the provider pane disappears or selection
moves away from Copilot.

GitHub Copilot authentication follows the same distinct-state rule: cancelled
status checks stop before publishing, profile refresh stays inside the single
coalesced check, and terminal device-flow errors end polling. Never keep
publishing the same error or auth fields into the provider step after polling
has already failed.

Keep scheduling and event bookkeeping out of SwiftUI state. Trackpad swipe
deltas, cancellable task handles, service references used only by actions, and
queued demo work items live in stable non-observable controllers; mutating them
must not invalidate an active step. Permission refreshes coalesce duplicate
requests, enumerate protected locations off the main actor, and publish one
permission-state snapshot instead of redrawing the full step once per row.
The workflow step renders only persisted custom personas. Never inject stress
fixtures in `CustomPersonaStore` initialization: that materializes large
glass-card collections throughout the real app, including onboarding.
Persona selection springs belong to the cards whose selection state changes;
do not wrap shared-manager or generator-presentation mutations in a broad
workflow animation transaction. Selection managers guard identical values, and
publish and persist only the selection fields that actually change; callers
must not repeat state normalization the manager already performs.

Use interactive Liquid Glass only for controls. Permission rows keep native
regular glass but leave pointer-responsive glass to their contained buttons;
the row's own hover, shadow, and context-menu behavior remain SwiftUI-driven.
Permission action frame probes measure only during AppKit layout or actual
window geometry notifications, coalesce same-runloop reports, and treat normal
SwiftUI representable updates as bookkeeping rather than another measurement.
The resolved-manager callback owns the initial permission refresh; do not also
launch an identical parent `onAppear` refresh before those managers arrive.
If another lifecycle event requests permission state while a refresh is in
flight, coalesce it into one follow-up pass instead of overlapping system probes.
Delay provider CLI/auth/model preflight until the initial pane reveal has
settled, and only probe Apple model availability when that provider is active.
Keep hover-only connection-button state in its button leaf; provider changes
and connection-result transitions animate their right-pane/status subtrees,
not the entire two-pane provider step.
Account privacy reveals and Codex action-button hover state follow the same leaf
ownership rule, so pointer movement never invalidates the provider root.
Likewise, a permission video representable must treat an unchanged URL/player
pair as a no-op; ordinary SwiftUI updates must not restart an already-playing
queue. Pause permission video playback while Sorty is deactivated, then resume
its retained instance when the app becomes active.

### Completion reveal timing

The final step runs a choreographed phased reveal. The appear frame paints
only the static backdrop; the bloom (audio plus blob plus hero) starts on
the next frame so blur rasterization and audio startup can't hitch initial
layout. From there the glow ring joins at +220 ms, the blob settles to
ambient at +540 ms, and tips plus particles land at +720 ms. The blob is a
520x440 layer mounted as the hero's background, so it stays centered on the
tick without affecting layout, and it dismisses with the hero. It is two
small shape layers under Gaussian blur containers, so the compositor
animates scale, opacity, and blur radius without re-rendering content. The
entrance lands with a slight overshoot rather than a flat stop; the ambient
settle softens outward (blur blooms, slight outward drift, presence held)
so it never reads as the reveal reversing. Once
ambient it breathes quietly (blob 3.8 s, core 2.9 s, scale only). Reduce
Motion reveals everything synchronously with no particles or breathing.
Pause the layers while inactive and fade them on dismissal. Cancel the entry
task when finishing so it cannot restart the celebration during dismissal.

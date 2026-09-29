---
name: sorty-release
description: Prepare, publish, and verify a Sorty release across version metadata, release notes, artwork, app, Sparkle, GitHub, and website. Use for release readiness or an actual Sorty release, not routine feature work.
---

# Sorty release

Use this as a release checklist. Record each item as done, not applicable with a reason, or blocked with the missing evidence. First decide whether the request is for preparation, publication, or an audit. Preparing a release does not itself authorize publishing it.

## Plan the release

- Inspect `git status --short --branch`, the diff from the last published tag, the latest public release, and current `main`. Preserve unrelated work. Stay on `main` per project instructions.
- Default to the next patch version in Sorty's three-part version scheme, such as `1.2.1` to `1.2.2`, interpreting the requested `+0.01` as one patch step. Follow an explicit version or prerelease instruction instead. Check that no tag or public release already uses it.
- Inventory the changes that actually shipped since the last release. Separate user-visible changes, fixes, compatibility notes, and internal work. Check supported macOS versions, migration or stored-data implications, privacy and permission changes, and any known limitations worth telling users.

## Prepare every relevant surface

- Update `Info.plist` and every app/extension/widget `MARKETING_VERSION` and build setting in `Sorty.xcodeproj/project.pbxproj`. `scripts/bump_version.sh` can help, but inspect its diff and the packaged app's version and build identity. Keep identifiers monotonic for Sparkle.
- Write a dated `CHANGELOG.md` entry with nonempty `New`, `Improved`, and `Fixed` sections in that order, as required by `.github/workflows/release.yml`. Check claims against code, tests, or measurements. `scripts/update_changelog.sh` creates only a header; finish the entry yourself. Keep README, help, and relevant guides accurate when product behavior changed.
- Update `Sources/SortyLib/Views/WhatsNew/WhatsNewTourView.swift` and its resources for the release's actual story. Check `Sources/SortyApp/MainWindowRootView.swift` presentation and version gating. Remove stale version-specific copy and images. Verify the packaged app shows the intended tour once and that its controls, accessibility, and reduced-motion behavior work.
- Update `website/app/changelog/page.tsx` and any other website pages that name the latest version, show old screenshots, or describe changed behavior. Check download links, metadata, structured data, press assets, and social previews when affected. Keep the page's claims aligned with `CHANGELOG.md`.
- Generate and inspect Sparkle release notes with `scripts/generate_sparkle_release_notes.py`. The hosted workflow publishes `release-notes.html`, `appcast-v2.xml`, the legacy `appcast.xml` bridge, and `Sorty.zip`. Check the intended release text and update URLs in both feed paths; do not replace the legacy bridge casually.
- Use current, genuine screenshots, icons, and other images where they explain a change. Capture the released UI at appropriate sizes and appearances; check crops, legibility, alt text, asset membership, and that screenshots match the shipped build. If the app icon changed, verify its release variant in the packaged app, Dock, Finder, and public imagery. Do not add images merely to fill space.
- Choose a visualization when it makes a feature, comparison, or measured result easier to understand. Use the form that fits the evidence: a screenshot for interface changes, a diagram for a workflow, a chart for comparable measurements, or another clear form. The v1.2.1 bars are an example, not a template. Label units, workload, before/after versions, and sample size; use `docs/performance.md` and `docs/release-metrics/` for measured claims. Never invent a battery, speed, or reliability gain from indirect evidence.

## Validate and publish

- Review the complete source diff and generated assets, then commit and push coherent changes on `main` using the repo commit convention. `[skip ci]` requires deliberate workflow dispatches; a push alone may start neither release nor website checks.
- Use Blacksmith Swift CI for the exact release commit. For release readiness, run `.github/workflows/release.yml` with `validate_only=true` on `main`; it builds, tests, packages, launch-checks, and validates the appcast without publishing. Reuse a prior test run only when the workflow's provenance rules permit it. Local `make release`, `make prerelease`, and `make ci` are diagnostics, not the release gate.
- Before publication, present the version, final notes, artwork/visuals, affected URLs, validated commit, workflow result, and any unresolved risks for review. Publish only when the user has authorized publication. Use one intended release path through the hosted workflow; avoid duplicate tags or concurrent release attempts.
- Confirm the Release workflow's required jobs, GitHub release body and assets, signatures, notarization where configured, both public appcasts, and public `Sorty.zip`. Verify that feed version/build/URL match the downloadable artifact. A green workflow does not prove the installed update experience.
- Dispatch `website.yml` for website changes when `[skip ci]` prevented its automatic run. Wait for deployment and inspect the exact public changelog and any changed pages; a push or local build is not live-site proof.
- Install or use the last public version and exercise `Check for Updates` through Sparkle to the new version. Verify download, signature, replacement, relaunch, About/build identity, and Finder/Dock appearance where affected. Check a fresh download separately. If native UI inspection is required but computer use was not authorized, ask for the needed access or report that the live UI step remains unverified.
- Report what was verified, what remains unverified, and the public release and website links. Keep preparation, hosted validation, publication, public download, and installed update as distinct claims.

For command details and the current CI route, read `CONTRIBUTING.md` under Release Process, `.github/workflows/release.yml`, `.github/workflows/website.yml`, and `docs/agent-guides/fast-loop.md`. Recheck these files each release because the pipeline changes.

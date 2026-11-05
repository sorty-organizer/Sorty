# App updates

Stable releases are built and published by
[release.yml](../.github/workflows/release.yml). The nightly workflow has been
removed; this repository no longer schedules nightly builds.

Sparkle checks the feed configured by the app bundle's `SUFeedURL`. Current
stable builds use the release's `appcast-v2.xml`. Keep the immutable legacy
`appcast.xml` bridge so old-key 1.1.2 installations can transition through
`Sorty-key-transition-v2.zip`.

A stable release uploads these assets:

- `Sorty.zip`, the universal app archive used by Sparkle
- `Sorty.dmg`, the disk image installer
- `appcast-v2.xml`, the current-key update feed
- `appcast.xml`, the legacy bridge
- `release-notes.html`

GitHub adds source ZIP and tarball downloads automatically. Appcast signing
uses `SPARKLE_PRIVATE_KEY`, which must match the app's `SUPublicEDKey`.

Sparkle is pinned exactly in `Package.swift` because Release resolves packages
through `xcodebuild`, whose lockfile is gitignored. A version range would ship
the newest Sparkle available on release day. `validate_sparkle.sh` fails if the
embedded framework differs from the pin. Upgrade Sparkle in its own change and
test an installed update.

When Sparkle relaunches Sorty, the quit warning is skipped for idle watched
folders. It still appears for running work, and Sparkle offers a retry if the
user cancels.

The workflow validates nested signatures and the extracted archive before
publication, then checks the public asset set. Test updating an installed prior
version separately; archive checks cannot prove that its installer can run.

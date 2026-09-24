# Nightly Updates

Sorty publishes a moving nightly prerelease from `main` through `.github/workflows/nightly.yml`.

The workflow runs every day at midnight Singapore time and can also be triggered manually from GitHub Actions. It builds the universal macOS app, stamps the built bundle with a monotonically increasing `CFBundleVersion`, points that bundle at the nightly Sparkle feed, packages `Sorty-nightly.zip`, signs `appcast-nightly.xml`, and replaces the GitHub `nightly` prerelease.

Nightly update feed:

```text
https://github.com/sorty-organizer/Sorty/releases/download/nightly/appcast-nightly.xml
```

Nightly download:

```text
https://github.com/sorty-organizer/Sorty/releases/download/nightly/Sorty-nightly.zip
```

Stable releases use `release.yml` and publish one universal app archive named `Sorty.zip`. The release also includes `release-notes.html` and two required feeds: the current-key `appcast-v2.xml` feed and the immutable legacy `appcast.xml` bridge. The bridge keeps `/releases/latest/` able to move old-key 1.1.2 installations through `Sorty-key-transition-v2.zip`; removing either feed would strand an installed cohort. Publishing a stable release temporarily points the nightly appcast at that stable build as well, ensuring current nightly users can move to the new version before the next nightly replaces the feed.

The stable release build signs embedded frameworks before the app. Packaging checks nested code signatures before and after ZIP extraction, and publication confirms that the public ZIP matches the validated archive. Test the update from an installed prior version too: archive and appcast checks cannot prove that the older app can launch its installer.

GitHub supplies the source code ZIP and tarball automatically. A stable release should therefore expose exactly these uploaded assets:

```text
Sorty.zip
appcast.xml
appcast-v2.xml
release-notes.html
```

Required secret:

```text
SPARKLE_PRIVATE_KEY
```

If this secret is missing or does not match `SUPublicEDKey`, appcast validation fails and the nightly release is not published.

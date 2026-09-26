# Sentry binary package

This manifest exposes only the `Sentry` product Sorty uses. It downloads the
unaltered upstream 9.23.0 XCFramework with the upstream SHA-256 checksum and
retains its `SentryCppHelper` target and C++ linker setting. No SDK code is forked.

The upstream manifest declares seven binary targets. SwiftPM downloads all seven
even though Sorty links one. This package avoids the six unused variants without
deleting files inside downloaded XCFrameworks or disabling checksum validation.

Source: [Sentry 9.23.0 manifest](https://github.com/getsentry/sentry-cocoa/blob/9.23.0/Package.swift).
The helper and license are copied from that release.

To update Sentry, compare the upstream `Sentry` product and its target dependencies,
update the binary URL and checksum together, and copy any helper and license
changes. Build both the SwiftPM app and the universal Xcode app before release.
If Sorty needs another Sentry product, add its upstream target and dependencies
explicitly. The local package is shared by the root SwiftPM package and Xcode's
local `SortyLib` dependency.

// swift-tools-version: 6.0
import PackageDescription

// Keep the binary, checksum and helper in sync with upstream's pinned release.
// See README.md for the update procedure and original manifest.
let package = Package(
    name: "Sentry",
    platforms: [.macOS(.v10_14)],
    products: [
        .library(name: "Sentry", targets: ["Sentry", "SentryCppHelper"])
    ],
    targets: [
        .binaryTarget(
            name: "Sentry",
            url: "https://github.com/getsentry/sentry-cocoa/releases/download/9.23.0/Sentry.xcframework.zip",
            checksum: "e16f1fb6333f572e980be28d2a9e1ea20a08c2c91b7901d612ff6cee2af697cf"
        ),
        .target(
            name: "SentryCppHelper",
            linkerSettings: [.linkedLibrary("c++")]
        )
    ],
    swiftLanguageModes: [.v5],
    cxxLanguageStandard: .cxx14
)

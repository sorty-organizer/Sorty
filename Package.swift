// swift-tools-version: 6.0
import Foundation
import PackageDescription

let isHotReloadBuild = ProcessInfo.processInfo.environment["SORTY_HOT_RELOAD"] == "true"

var sortyLibDependencies: [Target.Dependency] = [
    .product(name: "Permiso", package: "Permiso"),
    .product(name: "Beam", package: "beam"),
    .product(name: "PostHog", package: "posthog-ios"),
    .product(name: "Sentry", package: "sentry-cocoa"),
    .product(name: "Sparkle", package: "Sparkle")
]

// Keep InjectionLite out of every normal Sorty app build. `make hot` opts into
// the runtime when SwiftPM evaluates this manifest.
if isHotReloadBuild {
    sortyLibDependencies.append(
        .product(name: "InjectionLite", package: "InjectionLite")
    )
}

var sortyLibSwiftSettings: [SwiftSetting] = [
    .define("DEBUG", .when(configuration: .debug)),
    // Debug: Fast incremental build (SPM manages incremental builds internally)
    .unsafeFlags(["-enable-batch-mode"], .when(configuration: .debug)),
    // Release: Full optimization with whole-module
    .unsafeFlags(["-whole-module-optimization"], .when(configuration: .release)),
    // Batched builds otherwise repeat the same diagnostics for many
    // primary files, producing megabytes of low-value output.
    .unsafeFlags(["-suppress-warnings"]),
    // Swift 6 strict concurrency - minimal checking to reduce type-check cost
    .unsafeFlags(["-strict-concurrency=minimal"])
]
var sortyLibLinkerSettings: [LinkerSetting] = [
    // Skip deduplication in debug for faster linking
    .unsafeFlags(["-Xlinker", "-no_deduplicate"], .when(configuration: .debug))
]
var sortyAppSwiftSettings: [SwiftSetting] = [
    .define("DEBUG", .when(configuration: .debug)),
    .unsafeFlags(["-enable-batch-mode"], .when(configuration: .debug)),
    .unsafeFlags(["-whole-module-optimization"], .when(configuration: .release))
]
var sortyAppLinkerSettings: [LinkerSetting] = [
    .unsafeFlags(["-Xlinker", "-no_deduplicate"], .when(configuration: .debug))
]

if isHotReloadBuild {
    let opaqueTypeErasure = SwiftSetting.unsafeFlags(
        ["-Xfrontend", "-enable-experimental-opaque-type-erasure"],
        .when(configuration: .debug)
    )
    let interposable = LinkerSetting.unsafeFlags(
        ["-Xlinker", "-interposable"],
        .when(configuration: .debug)
    )
    sortyLibSwiftSettings.append(opaqueTypeErasure)
    sortyLibLinkerSettings.append(interposable)
    sortyAppSwiftSettings.append(opaqueTypeErasure)
    sortyAppLinkerSettings.append(interposable)
}

let package = Package(
    name: "Sorty",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .library(
            name: "SortyLib",
            targets: ["SortyLib"]),
        .executable(
            name: "SortyApp",
            targets: ["SortyApp"]),
        .executable(
            name: "SortyQuality",
            targets: ["SortyQuality"]),
        .executable(
            name: "SortyHotReloadPreparer",
            targets: ["SortyHotReloadPreparer"])
    ],
    dependencies: [
        // Upstream Permiso currently targets macOS 26, so Sorty vendors a local
        // package variant that preserves the same overlay UI on macOS 15.
        .package(path: "Packages/Permiso"),
        // Beam 0.1.0 is vendored so its shader loader can resolve SwiftPM
        // resources from a signed macOS app's Contents/Resources directory.
        .package(path: "Packages/Beam"),
        .package(
            url: "https://github.com/PostHog/posthog-ios.git",
            exact: "3.68.2"
        ),
        .package(
            url: "https://github.com/getsentry/sentry-cocoa.git",
            exact: "9.23.0"
        ),
        // Pinned InjectionLite sources with Sorty's reentrant-save protection.
        .package(path: "Packages/InjectionLite"),
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0")
    ],
    targets: [
        .target(
            name: "SortyLib",
            dependencies: sortyLibDependencies,
            path: "Sources/SortyLib",
            resources: [
                // NOTE: Assets.xcassets is managed by Xcode project for proper .car compilation
                // SPM only handles the Images directory as PNG fallbacks
                .copy("Resources/Images"),
                .copy("Resources/AppIcons"),
                .copy("Resources/Shaders"),
                .copy("Resources/whats-new-design-system-1.png"),
                .copy("Resources/whats-new-design-system-2.png"),
                .copy("Resources/whats-new-design-system-3.png"),
                .copy("Resources/whats-new-design-system-4.png"),
                .copy("Resources/whats-new-design-system-5.png"),
                .copy("Resources/whats-new-preview.png"),
                .copy("Resources/SortyAppRepair.entitlements"),
                .process("Resources/Localizable.xcstrings"),
                .process("Resources/automation-demo.mp4"),
                .process("Resources/files-and-folders-demo.mp4"),
                .process("Resources/full-disk-access-demo.mp4"),
                .process("Resources/SortyMascotTemplate.svg"),
                .process("Resources/OnboardingSound.m4a"),
                .process("Resources/Final Onboarding.m4a")
            ],
            swiftSettings: sortyLibSwiftSettings,
            linkerSettings: sortyLibLinkerSettings
        ),
        .executableTarget(
            name: "SortyApp",
            dependencies: ["SortyLib"],
            path: "Sources/SortyApp",
            swiftSettings: sortyAppSwiftSettings,
            linkerSettings: sortyAppLinkerSettings
        ),
        .executableTarget(
            name: "SortyQuality",
            dependencies: ["SortyLib"],
            path: "Sources/SortyQuality"
        ),
        .executableTarget(
            name: "SortyHotReloadPreparer",
            dependencies: [
                .product(name: "InjectionImpl", package: "InjectionLite")
            ],
            path: "Sources/SortyHotReloadPreparer"
        ),
        .testTarget(
            name: "SortyTests",
            dependencies: ["SortyLib"],
            path: "Tests/SortyTests",
            swiftSettings: [
                .unsafeFlags(["-enable-batch-mode"]),
            ]
        )
    ]
)

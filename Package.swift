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

// Opt in while investigating compile hotspots without changing normal builds.
if ProcessInfo.processInfo.environment["SORTY_TYPECHECK_DIAGNOSTICS"] == "true" {
    let diagnostics = SwiftSetting.unsafeFlags([
        "-Xfrontend", "-warn-long-expression-type-checking=100",
        "-Xfrontend", "-warn-long-function-bodies=100"
    ], .when(configuration: .debug))
    sortyLibSwiftSettings.append(diagnostics)
    sortyAppSwiftSettings.append(diagnostics)
} else {
    // Batched builds otherwise repeat diagnostics for many primary files.
    sortyLibSwiftSettings.append(.unsafeFlags(["-suppress-warnings"]))
}

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

var packageProducts: [Product] = [
    .library(name: "SortyQualitySupport", targets: ["SortyQualitySupport"]),
    .library(name: "SortyFileSystem", targets: ["SortyFileSystem"]),
    .library(name: "SortyModels", targets: ["SortyModels"]),
    .library(name: "SortyAI", targets: ["SortyAI"]),
    .library(name: "SortyLearnings", targets: ["SortyLearnings"]),
    .library(name: "SortyFS", targets: ["SortyFS"]),
    .library(name: "SortyCore", targets: ["SortyCore"]),
    .library(
        name: "SortyLib",
        targets: ["SortyLib"]),
    .executable(
        name: "SortyApp",
        targets: ["SortyApp"]),
    .executable(
        name: "SortyQuality",
        targets: ["SortyQuality"])
]
var packageTargets: [Target] = [
    .target(name: "SortyQualitySupport", path: "Sources/SortyQualitySupport"),
    .target(
        name: "SortyFileSystem",
        path: "Sources/SortyFileSystem",
        swiftSettings: sortyLibSwiftSettings
    ),
    .target(
        name: "SortyModels",
        dependencies: ["SortyFileSystem"],
        path: "Sources/SortyModels",
        swiftSettings: sortyLibSwiftSettings
    ),
    .target(
        name: "SortyAI",
        dependencies: ["SortyFileSystem", "SortyModels"],
        path: "Sources/SortyAI",
        swiftSettings: sortyLibSwiftSettings
    ),
    .target(
        name: "SortyLearnings",
        dependencies: ["SortyFileSystem", "SortyModels", "SortyAI"],
        path: "Sources/SortyLearnings",
        swiftSettings: sortyLibSwiftSettings
    ),
    .target(
        name: "SortyFS",
        dependencies: ["SortyFileSystem", "SortyModels"],
        path: "Sources/SortyFS",
        swiftSettings: sortyLibSwiftSettings
    ),
    .target(
        name: "SortyCore",
        dependencies: ["SortyFileSystem", "SortyModels", "SortyAI", "SortyLearnings", "SortyFS"] + sortyLibDependencies,
        path: "Sources/SortyCore",
        swiftSettings: sortyLibSwiftSettings,
        linkerSettings: sortyLibLinkerSettings
    ),
    .target(
        name: "SortyLib",
        dependencies: ["SortyCore"] + sortyLibDependencies,
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
            .process("Resources/SortyMascotTemplate.svg")
            // NOTE: Demo videos (*.mp4) and onboarding audio (*.m4a) stay out
            // of SPM on purpose: scripts/build.sh stages them from
            // Sources/SortyLib/Resources via copy_resources_safely, so
            // SwiftPM does not restage/re-hash them after source rebuilds.
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
        dependencies: ["SortyQualitySupport"],
        path: "Sources/SortyQuality"
    ),
    .testTarget(
        name: "SortyTests",
        dependencies: ["SortyLib", "SortyCore", "SortyFS", "SortyLearnings", "SortyAI", "SortyModels", "SortyFileSystem", "SortyQualitySupport"],
        path: "Tests/SortyTests",
        // Same flags as the lib targets so tests share one incremental
        // compilation signature instead of invalidating it (see Makefile).
        swiftSettings: sortyLibSwiftSettings
    )
]
if isHotReloadBuild {
    packageProducts.append(
        .executable(
            name: "SortyHotReloadPreparer",
            targets: ["SortyHotReloadPreparer"])
    )
    packageTargets.append(
        .executableTarget(
            name: "SortyHotReloadPreparer",
            dependencies: [
                .product(name: "InjectionImpl", package: "InjectionLite")
            ],
            path: "Sources/SortyHotReloadPreparer"
        )
    )
}

let package = Package(
    name: "Sorty",
    platforms: [
        .macOS(.v15)
    ],
    products: packageProducts,
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
        // Expose only the pinned Sentry binary we link, avoiding downloads of
        // six unused variants from the upstream package manifest.
        .package(path: "Packages/sentry-cocoa"),
        // Pinned InjectionLite sources with Sorty's reentrant-save protection.
        .package(path: "Packages/InjectionLite"),
        // 2.9.3 fixes Sparkle's macOS 26 cache protection for bundle IDs ending in `.app`.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.9.3")
    ],
    targets: packageTargets
)

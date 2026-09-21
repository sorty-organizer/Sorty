//
//  SortyResources.swift
//  Sorty
//
//  Robust resource bundle accessor with multi-layer detection
//  Handles SPM, xcodebuild, and direct swift build scenarios
//

import Foundation
import AppKit
import os.log

public enum SortyResources {
    private static let logger = Logger(subsystem: "com.sorty.app", category: "Resources")
    nonisolated(unsafe) private static let imageCache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 80
        cache.totalCostLimit = 48 * 1024 * 1024
        return cache
    }()

    /// The resource bundle for SortyLib resources.
    /// Uses multi-layer detection to find resources in various build scenarios:
    /// 1. Class-based bundle lookup (works in most contexts)
    /// 2. Dynamic SPM bundle discovery (fallback for SPM builds)
    /// 3. Main bundle (final fallback, works when build scripts copy resources)
    public static let bundle: Bundle = {
        let detectedBundle = detectResourceBundle()
        logger.debug("Resource bundle resolved to: \(detectedBundle.bundlePath)")
        return detectedBundle
    }()

    /// Releases decoded resource images when the app moves to the background.
    /// Visible views retain the images they are displaying and missing entries
    /// are decoded again on demand when another screen needs them.
    public static func clearImageCache() {
        imageCache.removeAllObjects()
    }

    /// Resolves the resource bundle and decodes images away from the main
    /// actor. Callers use this for launch-adjacent artwork that is not needed
    /// for the first frame.
    @MainActor
    public static func preloadImages(named names: [String]) async {
        await Task.detached(priority: .utility) {
            for name in names {
                let resourceName = (name as NSString).deletingPathExtension
                let resourceExtension = (name as NSString).pathExtension
                let loaded = image(
                    named: resourceName,
                    withExtension: resourceExtension.isEmpty ? "png" : resourceExtension
                )
                prepareForDisplay(loaded)
            }
        }.value
    }

    @MainActor
    public static func imageAsync(named name: String, withExtension ext: String = "png") async -> NSImage? {
        let loaded = await Task.detached(priority: .utility) {
            let image = image(named: name, withExtension: ext)
            prepareForDisplay(image)
            return SendableImage(image)
        }.value
        return loaded.value
    }

    /// Whether the bundle was resolved via the asset catalog (compiled .car file)
    /// This is true when running from an Xcode-built app with proper asset catalog compilation
    public static var usesCompiledAssetCatalog: Bool {
        // Check for .car file in the bundle's Resources directory
        if let resourceURL = bundle.resourceURL {
            let carPath = resourceURL.appendingPathComponent("Assets.car").path
            return FileManager.default.fileExists(atPath: carPath)
        }
        return false
    }

    /// Detects the appropriate resource bundle using multiple strategies
    private static func detectResourceBundle() -> Bundle {
        // Strategy 0: SwiftPM module bundle (most reliable for SPM resources)
        // NOTE: Bundle.module's accessor calls fatalError if the .bundle directory
        // doesn't exist at runtime (e.g., xcodebuild release that didn't produce it).
        // We pre-check for the bundle file before accessing Bundle.module to avoid
        // an EXC_BREAKPOINT crash at launch.
        #if SWIFT_PACKAGE
        if let spmBundle = findSPMBundle(), hasResources(in: spmBundle) {
            logger.debug("Using discovered SwiftPM resource bundle")
            return spmBundle
        }
        #endif

        // Strategy 1: Class-based bundle lookup (most reliable for frameworks)
        // This finds the bundle containing the SortyResources type itself
        let classBundle = Bundle(for: BundleLocator.self)
        if classBundle != Bundle.main && classBundle.bundleIdentifier != nil {
            // Verify it has resources
            if hasResources(in: classBundle) {
                logger.debug("Using class-based bundle lookup")
                return classBundle
            }
        }

        // Strategy 2: Dynamic SPM bundle discovery via path lookup
        if let spmBundle = findSPMBundle() {
            logger.debug("Using dynamic SPM bundle discovery")
            return spmBundle
        }

        // Strategy 3: Main bundle (final fallback)
        // This works when build scripts copy resources to the app bundle
        logger.debug("Using Bundle.main as fallback")
        return Bundle.main
    }

    /// Checks if a bundle appears to have Sorty resources
    private static func hasResources(in bundle: Bundle) -> Bool {
        // Check for Images directory
        if let imagesURL = bundle.resourceURL?.appendingPathComponent("Images"),
           FileManager.default.fileExists(atPath: imagesURL.path) {
            return true
        }

        // Check for audio resources copied via SPM (.copy)
        if let resourceURL = bundle.resourceURL {
            let wavAtRoot = resourceURL.appendingPathComponent("OnboardingSound.m4a").path
            let wavInResources = resourceURL.appendingPathComponent("Resources/OnboardingSound.m4a").path
            let resourcesDir = resourceURL.appendingPathComponent("Resources").path
            if FileManager.default.fileExists(atPath: wavAtRoot) ||
                FileManager.default.fileExists(atPath: wavInResources) ||
                FileManager.default.fileExists(atPath: resourcesDir) {
                return true
            }
        }

        // Check for SPM bundle structure
        if bundle.bundlePath.contains("Sorty_SortyLib.bundle") {
            return true
        }

        // Check for Assets.car (compiled asset catalog)
        if let resourceURL = bundle.resourceURL,
           FileManager.default.fileExists(atPath: resourceURL.appendingPathComponent("Assets.car").path) {
            return true
        }

        return false
    }

    /// Attempts to find the SPM-generated resource bundle dynamically
    private static func findSPMBundle() -> Bundle? {
        // Try to locate the SPM bundle relative to the executable
        let mainBundle = Bundle.main
        let bundleName = "Sorty_SortyLib.bundle"

        // Look for Sorty_SortyLib.bundle in various locations
        let roots = [mainBundle.bundleURL, mainBundle.resourceURL].compactMap { $0 }
        var possiblePaths = [
            // Direct sibling of executable
            mainBundle.bundleURL.appendingPathComponent("Sorty_SortyLib.bundle"),
            // SwiftPM test bundles sit beside the executable bundle.
            mainBundle.bundleURL.deletingLastPathComponent().appendingPathComponent("Sorty_SortyLib.bundle"),
            // In Resources directory
            mainBundle.resourceURL?.appendingPathComponent("Sorty_SortyLib.bundle"),
            // In Frameworks
            mainBundle.bundleURL.appendingPathComponent("Frameworks/Sorty_SortyLib.bundle"),
            // In PlugIns
            mainBundle.bundleURL.appendingPathComponent("PlugIns/Sorty_SortyLib.bundle"),
        ].compactMap { $0 }

        for root in roots {
            var ancestor = root
            for _ in 0..<4 {
                possiblePaths.append(ancestor.appendingPathComponent("Sorty_SortyLib.bundle"))
                ancestor = ancestor.deletingLastPathComponent()
            }
        }

        // `swift test` can report the xctest launcher in Xcode's toolchain as
        // Bundle.main, so no executable-relative candidate reaches the package
        // build directory. Search the local SwiftPM build root without relying
        // on Bundle.module, whose generated accessor traps when a bundle is
        // absent from an Xcode-built app.
        let localBuildRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build", isDirectory: true)
        if let enumerator = FileManager.default.enumerator(
            at: localBuildRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) {
            while let candidate = enumerator.nextObject() as? URL {
                let relativeDepth = candidate.pathComponents.count - localBuildRoot.pathComponents.count
                if relativeDepth > 4 {
                    enumerator.skipDescendants()
                    continue
                }
                if candidate.lastPathComponent == bundleName,
                   let bundle = Bundle(path: candidate.path) {
                    return bundle
                }
            }
        }

        for path in possiblePaths {
            if FileManager.default.fileExists(atPath: path.path) {
                // SwiftPM resource bundles on macOS are directory bundles and may
                // not contain an Info.plist. Bundle(path:) matches the generated
                // Bundle.module accessor and still resolves those bundles.
                if let bundle = Bundle(path: path.path) {
                    return bundle
                }
            }
        }

        return nil
    }

    /// Helper class for bundle location via class-based lookup
    private final class BundleLocator {}

    private struct SendableImage: @unchecked Sendable {
        let value: NSImage?

        init(_ value: NSImage?) {
            self.value = value
        }
    }

    private static func prepareForDisplay(_ image: NSImage?) {
        guard let image else { return }
        var proposedRect = NSRect(origin: .zero, size: image.size)
        _ = image.cgImage(forProposedRect: &proposedRect, context: nil, hints: nil)
    }

    /// Loads an image from the resource bundle, trying multiple sources
    /// - Parameters:
    ///   - name: The image name (without extension)
    ///   - extension: The file extension (default: "png")
    /// - Returns: NSImage if found, nil otherwise
    public static func image(named name: String, withExtension ext: String = "png") -> NSImage? {
        let cacheKey = imageCacheKey(name: name, ext: ext)
        if let cached = imageCache.object(forKey: cacheKey) {
            return cached
        }

        // Try 1: Asset catalog (if compiled .car exists)
        if usesCompiledAssetCatalog {
            if let nsImage = bundle.image(forResource: name), isUsableImage(nsImage) {
                logger.debug("Loaded image '\(name)' from asset catalog")
                return cacheImage(nsImage, forKey: cacheKey)
            }
        }

        // Try 2: Raw asset catalog file lookup inside app/framework resources.
        // Prefer this before generic bundle image lookup so updated images in
        // Resources/Assets.xcassets win over legacy fallback PNGs in Images/.
        if let nsImage = loadImageFromRawAssetCatalog(named: name) {
            logger.debug("Loaded image '\(name)' from raw Assets.xcassets in bundle resources")
            return cacheImage(nsImage, forKey: cacheKey)
        }
        
        // Try 3: Direct bundle resource lookup (works for Xcode builds with asset catalog)
        if let nsImage = bundle.image(forResource: name), isUsableImage(nsImage) {
            logger.debug("Loaded image '\(name)' from bundle resource")
            return cacheImage(nsImage, forKey: cacheKey)
        }

        // Try 4: Main bundle fallback (covers app-level asset catalogs)
        if bundle != Bundle.main,
           let nsImage = Bundle.main.image(forResource: name),
           isUsableImage(nsImage) {
            logger.debug("Loaded image '\(name)' from main bundle")
            return cacheImage(nsImage, forKey: cacheKey)
        }

        // Try 5: Direct copied Images directory lookup. SwiftPM directory bundles
        // do not consistently resolve subdirectories through Bundle.url on every
        // test host, even when the files are present under bundle.resourceURL.
        if let nsImage = loadImageFromCopiedImagesDirectories(named: name, withExtension: ext) {
            logger.debug("Loaded image '\(name)' from copied Images directory")
            return cacheImage(nsImage, forKey: cacheKey)
        }

        // Try 6: Images subdirectory (SPM .copy() resources)
        if let imageURL = bundle.url(forResource: name, withExtension: ext, subdirectory: "Images"),
              let nsImage = NSImage(contentsOf: imageURL),
              isUsableImage(nsImage) {
            logger.debug("Loaded image '\(name)' from Images subdirectory")
            return cacheImage(nsImage, forKey: cacheKey)
        }

        // Try 7: Direct bundle resource with extension
        if let imageURL = bundle.url(forResource: name, withExtension: ext),
              let nsImage = NSImage(contentsOf: imageURL),
              isUsableImage(nsImage) {
            logger.debug("Loaded image '\(name)' from bundle root")
            return cacheImage(nsImage, forKey: cacheKey)
        }

        // Try 8: Bundle image resource helper (covers non-asset bundled images)
        if let imageURL = bundle.urlForImageResource(name),
           let nsImage = NSImage(contentsOf: imageURL),
           isUsableImage(nsImage) {
            logger.debug("Loaded image '\(name)' via urlForImageResource")
            return cacheImage(nsImage, forKey: cacheKey)
        }

        // Try 9: Nested Sorty_SortyLib bundle fallback (covers builds where
        // this process resolves Bundle.main but the copied Images/ assets live
        // in a sibling Sorty_SortyLib.bundle inside app resources).
        if let nsImage = loadImageFromEmbeddedSortyLibBundle(named: name, withExtension: ext) {
            logger.debug("Loaded image '\(name)' from embedded Sorty_SortyLib.bundle")
            return cacheImage(nsImage, forKey: cacheKey)
        }
        
        // Try 10: Look in source tree Assets.xcassets imageset directories (development fallback)
        // This handles the case where Xcode hasn't compiled the asset catalog yet
        let extensions = [ext, "png", "svg", "pdf"]
        let basePaths = [
            // Also try from source root during development
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Resources/Assets.xcassets/\(name).imageset")
        ]
        
        for basePath in basePaths {
            for fileExt in extensions {
                let path = basePath.appendingPathComponent("\(name).\(fileExt)")
                if FileManager.default.fileExists(atPath: path.path),
                   let nsImage = NSImage(contentsOf: path),
                   isUsableImage(nsImage) {
                    logger.debug("Loaded image '\(name)' from Assets.xcassets imageset at \(path.path)")
                    return cacheImage(nsImage, forKey: cacheKey)
                }
            }
        }

        logger.warning("Failed to load image '\(name)' from any source")
        return nil
    }

    private static func imageCacheKey(name: String, ext: String) -> NSString {
        "\(bundle.bundlePath)|\(name)|\(ext.lowercased())" as NSString
    }

    private static func specialImageCacheKey(_ key: String) -> NSString {
        "\(bundle.bundlePath)|\(key)" as NSString
    }

    private static func cacheImage(_ image: NSImage, forKey key: NSString) -> NSImage {
        imageCache.setObject(image, forKey: key, cost: image.thumbnailCost())
        return image
    }

    private static func isUsableImage(_ image: NSImage) -> Bool {
        image.size.width > 2 && image.size.height > 2
    }

    private static func loadImageFromCopiedImagesDirectories(
        named name: String,
        withExtension ext: String
    ) -> NSImage? {
        let roots = [bundle.resourceURL, Bundle.main.resourceURL].compactMap { $0 }
        let candidates = roots.flatMap { root in
            [
                root.appendingPathComponent("Images/\(name).\(ext)"),
                root.appendingPathComponent("Resources/Images/\(name).\(ext)")
            ]
        } + [
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("Sources/SortyLib/Resources/Images/\(name).\(ext)")
        ]

        for candidate in candidates where FileManager.default.fileExists(atPath: candidate.path) {
            if let image = NSImage(contentsOf: candidate), isUsableImage(image) {
                return image
            }
        }
        return nil
    }

    private static func loadImageFromEmbeddedSortyLibBundle(named name: String, withExtension ext: String) -> NSImage? {
        let bundleCandidates: [URL] = [
            Bundle.main.resourceURL?.appendingPathComponent("Sorty_SortyLib.bundle"),
            Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/Sorty_SortyLib.bundle"),
            bundle.resourceURL?.appendingPathComponent("Sorty_SortyLib.bundle")
        ].compactMap { $0 }

        for bundleURL in bundleCandidates where FileManager.default.fileExists(atPath: bundleURL.path) {
            guard let embeddedBundle = Bundle(url: bundleURL) else {
                continue
            }

            if let imageURL = embeddedBundle.url(forResource: name, withExtension: ext, subdirectory: "Images"),
               let nsImage = NSImage(contentsOf: imageURL),
               isUsableImage(nsImage) {
                return nsImage
            }

            if let imageURL = embeddedBundle.url(forResource: name, withExtension: ext),
               let nsImage = NSImage(contentsOf: imageURL),
               isUsableImage(nsImage) {
                return nsImage
            }
        }

        return nil
    }

    private static func loadImageFromRawAssetCatalog(named name: String) -> NSImage? {
        let extensions = ["svg", "png", "pdf"]
        let assetRoots: [URL] = [
            bundle.resourceURL?.appendingPathComponent("Assets.xcassets"),
            bundle.resourceURL?.appendingPathComponent("Resources/Assets.xcassets"),
            Bundle.main.resourceURL?.appendingPathComponent("Assets.xcassets"),
            Bundle.main.resourceURL?.appendingPathComponent("Resources/Assets.xcassets")
        ].compactMap { $0 }

        for root in assetRoots {
            let imagesetURL = root.appendingPathComponent("\(name).imageset")

            // Respect the file configured in Contents.json first.
            if let configuredAsset = configuredAssetURL(in: imagesetURL),
               FileManager.default.fileExists(atPath: configuredAsset.path),
               let nsImage = preferredImage(from: configuredAsset, in: imagesetURL) {
                return nsImage
            }

            for fileExt in extensions {
                let candidate = imagesetURL.appendingPathComponent("\(name).\(fileExt)")
                if FileManager.default.fileExists(atPath: candidate.path),
                   let nsImage = preferredImage(from: candidate, in: imagesetURL) {
                    return nsImage
                }
            }
        }

        return nil
    }

    private static func preferredImage(from candidate: URL, in imagesetURL: URL) -> NSImage? {
        guard let nsImage = NSImage(contentsOf: candidate) else {
            return nil
        }

        // Some third-party SVGs use width/height="1em", which AppKit decodes as
        // a 1x1 image and renders as a dot. Prefer PNG fallback in that case.
        if candidate.pathExtension.lowercased() == "svg",
           nsImage.size.width <= 2,
           nsImage.size.height <= 2 {
            let pngFallback = imagesetURL.appendingPathComponent(candidate.deletingPathExtension().lastPathComponent + ".png")
            if FileManager.default.fileExists(atPath: pngFallback.path),
               let pngImage = NSImage(contentsOf: pngFallback) {
                return pngImage
            }

            // Treat tiny SVG decodes as invalid so higher-level fallback lookups can run.
            return nil
        }

        return nsImage
    }

    private static func configuredAssetURL(in imagesetURL: URL) -> URL? {
        let contentsURL = imagesetURL.appendingPathComponent("Contents.json")
        guard let data = try? Data(contentsOf: contentsURL) else {
            return nil
        }

        struct AssetCatalogImageSet: Decodable {
            struct Entry: Decodable {
                let filename: String?
                let idiom: String?
            }

            let images: [Entry]
        }

        guard let parsed = try? JSONDecoder().decode(AssetCatalogImageSet.self, from: data) else {
            return nil
        }

        if let universal = parsed.images.first(where: {
            ($0.idiom == nil || $0.idiom == "universal") && ($0.filename?.isEmpty == false)
        })?.filename {
            return imagesetURL.appendingPathComponent(universal)
        }

        if let firstNamed = parsed.images.first(where: { $0.filename?.isEmpty == false })?.filename {
            return imagesetURL.appendingPathComponent(firstNamed)
        }

        return nil
    }

    public static func urlForCopiedResource(named fileName: String) -> URL? {
        if let url = bundle.url(forResource: fileName, withExtension: nil) { return url }
        if let url = bundle.url(forResource: fileName, withExtension: nil, subdirectory: "Resources") { return url }

        let nameWithoutExt = (fileName as NSString).deletingPathExtension
        let ext = (fileName as NSString).pathExtension
        if !ext.isEmpty, let url = bundle.url(forResource: nameWithoutExt, withExtension: ext) { return url }

        guard let resourceURL = bundle.resourceURL else { return nil }
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: resourceURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return nil }

        for case let url as URL in enumerator {
            if url.lastPathComponent == fileName {
                return url
            }
        }
        return nil
    }

    public static func onboardingSoundURL() -> URL? {
        urlForCopiedResource(named: "OnboardingSound.m4a")
    }

    public static func finalOnboardingSoundURL() -> URL? {
        urlForCopiedResource(named: "Final Onboarding.m4a")
    }

    private static func uniqueURLs(_ candidates: [URL]) -> [URL] {
        var unique: [URL] = []
        for candidate in candidates where !unique.contains(where: { $0.path == candidate.path }) {
            unique.append(candidate)
        }
        return unique
    }

    private static func menuBarPNGCandidateURLs() -> [URL] {
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let bundleRootCandidates = [bundle.resourceURL, Bundle.main.resourceURL].compactMap { $0 }
        let extensionResourceURL = Bundle.main.builtInPlugInsURL?
            .appendingPathComponent("SortyFinderSync.appex/Contents/Resources", isDirectory: true)

        var candidates: [URL] = []
        if let extensionResourceURL {
            candidates.append(extensionResourceURL.appendingPathComponent("SortyMascotHead.png"))
        }

        for root in bundleRootCandidates {
            candidates.append(root.appendingPathComponent("SortyMascotHead.png"))
            candidates.append(root.appendingPathComponent("Images/SortyMascotHead.png"))
            candidates.append(root.appendingPathComponent("SortyLib_SortyLib.bundle/SortyMascotHead.png"))
            candidates.append(root.appendingPathComponent("SortyLib_SortyLib.bundle/Images/SortyMascotHead.png"))
        }

        candidates.append(cwd.appendingPathComponent("Assets/AppIcon/SortyMascotHead.png"))

        return uniqueURLs(candidates)
    }

    private static func menuBarICNSCandidateURLs() -> [URL] {
        let bundleRootCandidates = [bundle.resourceURL, Bundle.main.resourceURL].compactMap { $0 }
        let extensionResourceURL = Bundle.main.builtInPlugInsURL?
            .appendingPathComponent("SortyFinderSync.appex/Contents/Resources", isDirectory: true)

        var candidates: [URL] = []
        if let extensionResourceURL {
            candidates.append(extensionResourceURL.appendingPathComponent("SortyMascotHead.icns"))
            candidates.append(extensionResourceURL.appendingPathComponent("Sorty Mascot Head.icns"))
        }

        for root in bundleRootCandidates {
            candidates.append(root.appendingPathComponent("SortyMascotHead.icns"))
            candidates.append(root.appendingPathComponent("Sorty Mascot Head.icns"))
            candidates.append(root.appendingPathComponent("Images/SortyMascotHead.icns"))
            candidates.append(root.appendingPathComponent("Images/Sorty Mascot Head.icns"))
            candidates.append(root.appendingPathComponent("SortyLib_SortyLib.bundle/SortyMascotHead.icns"))
            candidates.append(root.appendingPathComponent("SortyLib_SortyLib.bundle/Images/SortyMascotHead.icns"))
            candidates.append(root.appendingPathComponent("SortyLib_SortyLib.bundle/Images/Sorty Mascot Head.icns"))
        }

        return uniqueURLs(candidates)
    }

    private static func loadImage(from candidates: [URL], isTemplate: Bool) -> NSImage? {
        for candidate in candidates where FileManager.default.fileExists(atPath: candidate.path) {
            if let image = NSImage(contentsOf: candidate) {
                image.isTemplate = isTemplate
                return image
            }
        }
        return nil
    }

    /// Loads the full-color mascot head PNG used by Finder actions for menu bar labels.
    public static func menuBarLabelNSImage() -> NSImage {
        let cacheKey = specialImageCacheKey("menuBarLabelNSImage")
        if let cached = imageCache.object(forKey: cacheKey) {
            return cached
        }

        if let image = loadImage(from: menuBarPNGCandidateURLs(), isTemplate: false) {
            return cacheImage(image, forKey: cacheKey)
        }

        if let image = image(named: "SortyMascotHead", withExtension: "png") {
            let copy = (image.copy() as? NSImage) ?? image
            copy.isTemplate = false
            return cacheImage(copy, forKey: cacheKey)
        }

        let fallback = (menuBarNSImage().copy() as? NSImage) ?? menuBarNSImage()
        fallback.isTemplate = false
        return cacheImage(fallback, forKey: cacheKey)
    }

    /// Loads a robust NSImage for the menu bar item, bypassing asset catalog complexity
    /// and providing a guaranteed fallback to an SF Symbol.
    public static func menuBarNSImage() -> NSImage {
        let cacheKey = specialImageCacheKey("menuBarNSImage")
        if let cached = imageCache.object(forKey: cacheKey) {
            return cached
        }

        // Prefer the mascot head ICNS so menu bar, Finder integrations, and app branding match.
        if let image = loadImage(from: menuBarICNSCandidateURLs(), isTemplate: true) {
            return cacheImage(image, forKey: cacheKey)
        }

        if let img = bundle.image(forResource: "SortyMascotHead") ?? Bundle.main.image(forResource: "SortyMascotHead") {
            img.isTemplate = true
            return cacheImage(img, forKey: cacheKey)
        }

        // Try direct file-based loading from the bundle first (most reliable for SPM/macOS 15)
        if let url = bundle.url(forResource: "SortyMascotTemplate", withExtension: "svg"),
           let img = NSImage(contentsOf: url) {
            img.isTemplate = true
            return cacheImage(img, forKey: cacheKey)
        }
        
        // Fallback to name-based lookup
        if let img = image(named: "SortyMascotTemplate", withExtension: "svg") {
            let copy = (img.copy() as? NSImage) ?? img
            copy.isTemplate = true
            return cacheImage(copy, forKey: cacheKey)
        }
        
        // Final fallback: standard SF Symbol
        if let symbol = NSImage(systemSymbolName: "folder.fill.badge.gearshape", accessibilityDescription: "Sorty") {
            symbol.isTemplate = true
            return cacheImage(symbol, forKey: cacheKey)
        }
        
        // Absolute last resort: 1×1 empty template image (should never happen)
        let empty = NSImage(size: NSSize(width: 18, height: 18))
        empty.isTemplate = true
        return cacheImage(empty, forKey: cacheKey)
    }
}

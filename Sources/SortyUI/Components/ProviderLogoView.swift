import AppKit
import SwiftUI

public struct ProviderLogoView: View {
    @SortyHotReload private var hotReload
    @MainActor private static var imageCache: [AIProvider: NSImage] = [:]

    public let provider: AIProvider
    public var size: CGFloat = 24

    public init(provider: AIProvider, size: CGFloat = 24) {
        self.provider = provider
        self.size = size
    }

    private var providerImage: Image {
        if provider.usesSystemImage {
            return Image(systemName: provider.logoImageName)
        }

        if let nsImage = resolvedProviderImage() {
            return Image(nsImage: nsImage)
        }

        return Image(systemName: "cpu")
    }

    private var usesTemplateRendering: Bool {
        provider.usesSystemImage || !provider.hasColorLogo || provider == .openAI
    }

    private func resolvedProviderImage() -> NSImage? {
        if let cached = Self.imageCache[provider] {
            return cached
        }

        let resolved = SortyResources.image(named: provider.logoImageName)
            ?? NSImage(named: NSImage.Name(provider.logoImageName))
            ?? SortyResources.image(named: provider.logoImageName, withExtension: "png")

        guard let resolved, isUsableProviderImage(resolved),
              let prepared = resolved.copy() as? NSImage else { return nil }

        // Asset images are shared. Cache a prepared copy so body evaluation
        // never mutates global NSImage rendering state or repeats lookup work.
        prepared.isTemplate = usesTemplateRendering
        Self.imageCache[provider] = prepared
        return prepared
    }

    private func isUsableProviderImage(_ image: NSImage) -> Bool {
        image.size.width > 2 && image.size.height > 2
    }

    private var renderingMode: Image.TemplateRenderingMode {
        if usesTemplateRendering {
            return .template
        }
        return .original
    }

    private var foregroundColor: Color {
        provider == .openAI || provider == .openRouter ? .primary : provider.brandColor
    }

    public var body: some View {
        providerImage
            .renderingMode(renderingMode)
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .foregroundStyle(renderingMode == .template ? foregroundColor : .primary)
    }
}

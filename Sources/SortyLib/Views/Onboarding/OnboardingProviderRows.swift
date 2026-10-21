import SwiftUI

// MARK: - Supporting Views

/// The provider grid is visually independent from credential drafts and
/// connection status. Equatable isolation keeps its nine glass/logo cards out
/// of API-key keystroke and status-update rebuilds.
struct ProviderSelectionGrid: View, Equatable {
    @SortyHotReload var hotReload
    let selectedProvider: AIProvider
    let onSelect: (AIProvider) -> Void

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.selectedProvider == rhs.selectedProvider
    }

    var body: some View {
        LazyVGrid(
            columns: Array(
                repeating: GridItem(.flexible(minimum: 10, maximum: .infinity), spacing: 8),
                count: 3
            ),
            spacing: 8
        ) {
            ForEach(AIProvider.userSelectableProviders.filter { $0 != .openCodeGo }, id: \.self) { provider in
                OnboardingProviderRow(
                    provider: provider,
                    selectedProvider: selectedProvider
                ) { selected in
                    onSelect(selected)
                }
            }
        }
    }
}

struct PrivacyFeatureRow: View {
    @SortyHotReload var hotReload
    let icon: String
    let text: String
    var badge: String? = nil

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundStyle(.green)
                .frame(width: 20)

            Text(text)
                .font(.subheadline)
                .foregroundStyle(.primary)

            if let badge {
                OnboardingCapsuleBadge(text: badge)
            }
        }
    }
}

struct OnboardingProviderRow: View {
    @SortyHotReload var hotReload
    @AppStorage(NetworkPrivacyPolicy.internetPrivacyModeKey) var internetPrivacyModeEnabled = false
    let provider: AIProvider
    let selectedProvider: AIProvider
    let action: (AIProvider) -> Void

    @Environment(\.accessibilityReduceMotion) var reduceMotion
    @State var isHovering = false

    var isOpenCodeCard: Bool { provider == .openCodeZen }
    // Custom endpoints remain configurable for localhost workflows.
    var isBlockedByInternetPrivacy: Bool {
        internetPrivacyModeEnabled && ![.appleFoundationModel, .ollama, .openAICompatible].contains(provider)
    }
    var internetPrivacyExplanation: String {
        "\(provider.selectorTitle) requires an internet connection. Turn off Block Internet Connections in Advanced Settings to use it."
    }
    var isSelected: Bool {
        selectedProvider == provider || (isOpenCodeCard && selectedProvider == .openCodeGo)
    }
    var logoProvider: AIProvider {
        isOpenCodeCard && selectedProvider == .openCodeGo ? .openCodeGo : provider
    }

    var subtitle: String? {
        switch provider {
        case .ollama: return "Local"
        case .appleFoundationModel: return "On-device"
        default: return nil
        }
    }

    var subtitleColor: Color {
        provider == .ollama ? .green : .blue
    }

    var body: some View {
        Button {
            if provider.isAvailable {
                // The OpenCode card covers both plans: staying on Go keeps Go,
                // otherwise the card selects Zen; plan switching lives in the plan picker.
                action(isOpenCodeCard && selectedProvider == .openCodeGo ? .openCodeGo : provider)
            }
        } label: {
            rowLabel
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(
                    isSelected
                        ? SortyDesignSystem.Colors.resolvedAccent.opacity(0.12)
                        : (isHovering ? Color.primary.opacity(0.05) : Color.clear)
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(
                    isSelected ? SortyDesignSystem.Colors.resolvedAccent.opacity(0.45) : Color.clear,
                    lineWidth: 1
                )
        )
        .contentShape(Rectangle())
        .opacity(provider.isAvailable ? 1.0 : 0.6)
        .disabled(isBlockedByInternetPrivacy || !provider.isAvailable)
        .onHover { hovering in
            if provider.isAvailable { isHovering = hovering }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: isSelected)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: isHovering)
        .accessibilityIdentifier("OnboardingProvider_\(provider.rawValue)")
        .accessibilityHint(isBlockedByInternetPrivacy ? internetPrivacyExplanation : (isOpenCodeCard ? "Selects OpenCode. Switch between the Zen and Go plans in the plan picker." : "Selects \(provider.displayName)."))
        .help(isBlockedByInternetPrivacy ? internetPrivacyExplanation : (isOpenCodeCard ? "Use OpenCode (switch plans in the plan picker)" : "Use \(provider.displayName)"))
        .overlay {
            if isBlockedByInternetPrivacy {
                // Keep the tooltip reachable above the disabled button.
                Rectangle()
                    .fill(.clear)
                    .contentShape(Rectangle())
                    .help(internetPrivacyExplanation)
                    .accessibilityHidden(true)
            }
        }
    }

    var rowLabel: some View {
        HStack(spacing: 9) {
            ProviderLogoView(provider: logoProvider, size: 20)
                .frame(width: 28, height: 28)
                .overlay(alignment: .bottomTrailing) {
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.white, SortyDesignSystem.Colors.resolvedAccent)
                            .background(Circle().fill(SortyDesignSystem.Colors.resolvedAccent))
                            .offset(x: 3, y: 3)
                            .transition(.scale.combined(with: .opacity))
                            .accessibilityHidden(true)
                    }
                }

            VStack(alignment: .leading, spacing: 1) {
                Text(isOpenCodeCard ? "OpenCode" : provider.selectorTitle)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .regular, design: .rounded))
                    .foregroundColor(provider.isAvailable ? .primary : .secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.88)

                if let subtitle {
                    Text(LocalizedStringKey(subtitle))
                        .font(.caption2)
                        .foregroundStyle(subtitleColor)
                        .lineLimit(1)
                        .minimumScaleFactor(0.88)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)

            if !provider.isAvailable {
                Text("Unavailable")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.secondary.opacity(0.1), in: Capsule())
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, minHeight: 46, alignment: .leading)
        .blur(radius: isBlockedByInternetPrivacy ? 2 : 0)
        .contentShape(Rectangle())
    }
}

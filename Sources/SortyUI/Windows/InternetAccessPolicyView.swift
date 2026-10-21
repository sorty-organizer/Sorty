//
//  InternetAccessPolicyView.swift
//  Sorty
//
//  Dedicated policy window that describes network destinations and why they are used.
//

import Foundation
import SwiftUI

struct InternetAccessPolicyView: View {
    @SortyHotReload private var hotReload
    @Environment(\.openURL) private var openURL
    @AppStorage(NetworkPrivacyPolicy.internetPrivacyModeKey) private var internetPrivacyModeEnabled = false

    @State private var iconHovered = false
    @State private var websiteHovered = false

    let showBackButton: Bool
    let onBack: (() -> Void)?

    private let loadState: InternetAccessPolicyLoadState

    init(showBackButton: Bool = false, onBack: (() -> Void)? = nil) {
        self.showBackButton = showBackButton
        self.onBack = onBack
        self.loadState = InternetAccessPolicyLoader.load()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            switch loadState {
            case .loaded(let policy):
                loadedContent(policy)
            case .failed(let message):
                failedContent(message)
            }
        }
        .padding(24)
        .frame(width: 760, height: 560)
        .overlay(alignment: .topLeading) {
            if showBackButton, let onBack {
                GlassyBackButton(action: onBack)
                    .accessibilityIdentifier("InternetAccessPolicyBackButton")
                    .padding(.top, 10)
                    .padding(.leading, 8)
            }
        }
        .modifier(WindowGlassBackground())
        .windowLinkHoverPillHost()
        .accessibilityIdentifier("InternetAccessPolicyView")
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "network")
                .font(.system(size: 32, weight: .semibold))
                .foregroundStyle(.secondary)
                .scaleEffect(iconHovered ? 1.06 : 1.0)
                .onHover { hovering in
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.72)) {
                        iconHovered = hovering
                    }
                    if hovering {
                        HapticFeedbackManager.shared.selection()
                    }
                }

            VStack(alignment: .leading, spacing: 2) {
                Text("Internet Access Policy")
                    .font(.system(size: 26, weight: .bold, design: .rounded))

                Text("Transparency for every host Sorty may contact")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            blockInternetConnectionsToggle
        }
    }

    private func loadedContent(_ policy: InternetAccessPolicyDocument) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(policy.applicationDescription)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                Text("Publisher:")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                Text(policy.developerName)
                    .font(.caption)
                    .foregroundStyle(.primary)

                Spacer(minLength: 0)

                if let websiteURL = URL(string: policy.website) {
                    Button("Open Website") {
                        HapticFeedbackManager.shared.tap()
                        openURL(websiteURL)
                    }
                    .buttonStyle(.sortyBordered)
                    .trackHoveredURL(websiteURL)
                    .scaleEffect(websiteHovered ? 1.03 : 1.0)
                    .onHover { hovering in
                        withAnimation(.easeInOut(duration: 0.15)) {
                            websiteHovered = hovering
                        }
                        if hovering {
                            HapticFeedbackManager.shared.selection()
                        }
                    }
                }
            }

            Divider()

            ConnectionList(connections: policy.connections)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Text("Deny consequences indicate exactly what functionality becomes unavailable when a host is blocked.")
                .font(.caption)
                .foregroundStyle(.secondary.opacity(0.84))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func failedContent(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Policy unavailable", systemImage: "exclamationmark.triangle")
                .font(.headline)
                .foregroundStyle(.orange)

            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
    }

    private var blockInternetConnectionsToggle: some View {
        Toggle(isOn: $internetPrivacyModeEnabled) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Block Internet Connections")
                    .font(.caption.weight(.semibold))

                Text("Allow localhost only")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .toggleStyle(.switch)
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: 250)
        .systemLiquidGlassBackground(cornerRadius: 10, interactive: false)
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(internetPrivacyModeEnabled ? Color.green.opacity(0.35) : Color.secondary.opacity(0.18), lineWidth: 1)
        }
        .accessibilityIdentifier("InternetAccessPolicyBlockInternetConnectionsToggle")
        .accessibilityHint("Blocks remote internet connections while allowing local model requests on localhost.")
    }
}

private struct ConnectionCard: View {
    @SortyHotReload private var hotReload
    let connection: InternetAccessPolicyConnection
    let index: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(index + 1).")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)

                Text(hostLine)
                    .font(.system(.subheadline, design: .monospaced))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .textSelection(.enabled)

                Spacer(minLength: 0)

                if let relevance = connection.relevance, !relevance.isEmpty {
                    Text(relevance)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(relevanceAccent)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(relevanceAccent.opacity(0.18), in: Capsule())
                }
            }

            Text(connection.purpose)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 2) {
                Text("If blocked:")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary.opacity(0.86))

                Text(connection.denyConsequences)
                    .font(.caption)
                    .italic()
                    .foregroundStyle(.secondary.opacity(0.86))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .systemLiquidGlassBackground(cornerRadius: 12, interactive: false)
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(relevanceAccent.opacity(0.35), lineWidth: 1)
        }
    }

    private var hostLine: String {
        guard let port = connection.port, !port.isEmpty else {
            return connection.host
        }
        return "\(connection.host):\(port)"
    }

    private var relevanceAccent: Color {
        guard let relevance = connection.relevance?.lowercased() else {
            return .blue
        }

        if relevance.contains("essential") {
            return .green
        }
        if relevance.contains("optional") {
            return .orange
        }
        return .blue
    }
}

private struct ConnectionList: View {
    @SortyHotReload private var hotReload
    let connections: [InternetAccessPolicyConnection]

    private let cardSpacing: CGFloat = 10

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            cardsStack
        }
        .accessibilityIdentifier("InternetAccessPolicyConnectionsList")
    }

    private var cardsStack: some View {
        VStack(alignment: .leading, spacing: cardSpacing) {
            ForEach(Array(connections.enumerated()), id: \.offset) { index, connection in
                ConnectionCard(connection: connection, index: index)
                    .id(index)
            }
        }
        .padding(.vertical, 2)
    }
}

private enum InternetAccessPolicyLoadState {
    case loaded(InternetAccessPolicyDocument)
    case failed(String)
}

private enum InternetAccessPolicyLoader {
    static func load() -> InternetAccessPolicyLoadState {
        guard let url = policyURL() else {
            return .failed("Could not find InternetAccessPolicy.plist in the app bundle.")
        }

        do {
            let data = try Data(contentsOf: url)
            let decoder = PropertyListDecoder()
            let policy = try decoder.decode(InternetAccessPolicyDocument.self, from: data)
            return .loaded(policy)
        } catch {
            return .failed("Failed to parse policy file: \(error.localizedDescription)")
        }
    }

    private static func policyURL() -> URL? {
        if let url = Bundle.main.url(forResource: "InternetAccessPolicy", withExtension: "plist") {
            return url
        }

        // Never touch Bundle.module here: its generated accessor traps with
        // EXC_BREAKPOINT when the SPM bundle is absent from an Xcode-built app.
        if let url = SortyResources.bundle.url(forResource: "InternetAccessPolicy", withExtension: "plist") {
            return url
        }

        return SortyResources.urlForCopiedResource(named: "InternetAccessPolicy.plist")
    }
}

private struct InternetAccessPolicyDocument: Decodable {
    let developerName: String
    let applicationDescription: String
    let website: String
    let connections: [InternetAccessPolicyConnection]

    enum CodingKeys: String, CodingKey {
        case developerName = "DeveloperName"
        case applicationDescription = "ApplicationDescription"
        case website = "Website"
        case connections = "Connections"
    }
}

private struct InternetAccessPolicyConnection: Decodable {
    let host: String
    let port: String?
    let relevance: String?
    let purpose: String
    let denyConsequences: String

    enum CodingKeys: String, CodingKey {
        case host = "Host"
        case port = "Port"
        case relevance = "Relevance"
        case purpose = "Purpose"
        case denyConsequences = "DenyConsequences"
    }
}

#Preview {
    InternetAccessPolicyView()
}

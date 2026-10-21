import Foundation
import AppKit
import SwiftUI

// MARK: - Connection
extension AIProviderSettingsView {
    var connectionSection: some View {
        SettingsCard(title: "Connection", icon: "network", color: .blue) {
            VStack(alignment: .leading, spacing: 12) {
                if [.openAICompatible, .ollama].contains(viewModel.config.provider) {
                    HStack {
                        Spacer()
                        Toggle(isOn: $viewModel.config.requiresAPIKey) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Requires API Key")
                                    .font(.subheadline)
                                Text("Disable for local endpoints without auth")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .toggleStyle(.switch)
                        .fixedSize()
                        Spacer()
                    }

                    Divider()
                }

                VStack(spacing: 12) {
                    Button(action: testConnection) {
                        HStack(spacing: 6) {
                            if isTestingConnection {
                                BouncingSpinner(size: 12, color: .primary)
                            } else if isConnectionSuccessful {
                                Image(systemName: "checkmark.circle.fill")
                                    .contentTransition(.symbolEffect(.replace))
                            } else if isConnectionFailed {
                                Image(
                                    systemName: isInternetAccessBlocked
                                        ? "network.slash" : "xmark.circle.fill"
                                )
                                .contentTransition(.symbolEffect(.replace))
                            } else {
                                Image(systemName: "network")
                                    .contentTransition(.symbolEffect(.replace))
                            }
                            Text(connectionButtonTitle)
                        }
                        .animation(
                            reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.78),
                            value: connectionButtonTitle
                        )
                    }
                    .buttonStyle(.sortyBordered(intent: connectionButtonIntent))
                    .animation(
                        reduceMotion ? nil : .easeInOut(duration: 0.2),
                        value: connectionButtonIntent
                    )
                    .settingsFocusable(
                        .providerTestConnection,
                        shape: Capsule(style: .continuous),
                        horizontalRingPadding: 4,
                        verticalRingPadding: 4
                    )
                    .disabled(isTestingConnection || !viewModel.config.provider.isAvailable)
                    .accessibilityLabel(connectionButtonTitle)

                    if let status = testConnectionStatus, isConnectionFailed {
                        VStack(alignment: .center, spacing: 8) {
                            HStack(alignment: .center, spacing: 6) {
                                Text(status.replacingOccurrences(of: "Error: ", with: ""))
                                    .font(.caption)
                                    .fontWeight(.semibold)
                                    .foregroundColor(isInternetAccessBlocked ? .orange : .red)
                                    .multilineTextAlignment(.center)
                                    .frame(maxWidth: 560)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .textSelection(.enabled)

                                copyConnectionErrorButton(status: status)
                            }
                            .fixedSize(horizontal: true, vertical: false)
                            .frame(maxWidth: 700, alignment: .center)

                            if let details = testConnectionDetails, !details.isEmpty {
                                VStack(spacing: 6) {
                                    Button {
                                        HapticFeedbackManager.shared.selection()
                                        withAnimation(
                                            reduceMotion
                                                ? nil
                                                : .spring(response: 0.30, dampingFraction: 0.78)
                                        ) {
                                            isDetailsExpanded.toggle()
                                        }
                                    } label: {
                                        HStack {
                                            Text(
                                                isInternetAccessBlocked
                                                    ? "Why this is blocked"
                                                    : "Technical Details"
                                            )
                                            .font(.caption2)
                                            .foregroundColor(.secondary)

                                            Spacer()

                                            Image(
                                                systemName: isDetailsExpanded
                                                    ? "chevron.up"
                                                    : "chevron.down"
                                            )
                                            .font(.caption2.bold())
                                            .foregroundStyle(.secondary)
                                            .contentTransition(.symbolEffect(.replace))
                                        }
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityIdentifier("ProviderConnectionDetailsDisclosure")

                                    if isDetailsExpanded {
                                        Text(details)
                                            .font(.system(.caption, design: .monospaced))
                                            .padding(10)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .background(Color.secondary.opacity(0.1))
                                            .clipShape(RoundedRectangle(cornerRadius: 4))
                                            .fixedSize(horizontal: false, vertical: true)
                                            .textSelection(.enabled)
                                            .transition(.move(edge: .top).combined(with: .opacity))
                                    }
                                }
                                .frame(maxWidth: 620)
                            }

                            if isInternetAccessBlocked {
                                Button {
                                    HapticFeedbackManager.shared.tap()
                                    appState.openSettingsWindow(
                                        section: .permissions,
                                        focusTarget: .privacyBlockInternet
                                    )
                                    appState.navigatedFromSettings = true
                                } label: {
                                    Label(
                                        "Open Internet Settings",
                                        systemImage: isHoveringInternetSettings ? "arrow.up.right" : "network"
                                    )
                                    .font(.caption.bold())
                                    .contentTransition(.symbolEffect(.replace))
                                }
                                .buttonStyle(.tintedPill(.orange, size: .small))
                                .help("Open Privacy & Permissions settings and focus Block Internet Connections")
                                .accessibilityHint(
                                    "Opens the setting that prevents Sorty from contacting cloud providers"
                                )
                                .accessibilityIdentifier("ProviderOpenInternetSettingsButton")
                                .onHover { hovering in
                                    withAnimation(
                                        reduceMotion
                                            ? nil
                                            : .spring(response: 0.24, dampingFraction: 0.82)
                                    ) {
                                        isHoveringInternetSettings = hovering
                                    }
                                }
                            }
                        }
                        .font(.subheadline)
                        .frame(maxWidth: 620, alignment: .center)
                        .transition(.scale.combined(with: .opacity))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .center)
            }
        }
        .settingsFocusable(.providerConnection)
    }

    var connectionButtonTitle: String {
        if isTestingConnection {
            return "Testing…"
        }
        if isConnectionSuccessful {
            return "Connected"
        }
        if isConnectionFailed {
            return isInternetAccessBlocked ? "Internet Blocked" : "Connection Failed"
        }
        return "Test Connection"
    }

    var connectionButtonIntent: SortyButtonIntent {
        if isConnectionSuccessful {
            return .success
        }
        if isConnectionFailed {
            return isInternetAccessBlocked ? .warning : .destructive
        }
        return .secondary
    }

    func copyConnectionErrorButton(status: String) -> some View {
        Button {
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(status.replacingOccurrences(of: "Error: ", with: ""), forType: .string)
            HapticFeedbackManager.shared.tap()
            hasCopiedConnectionError = true
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_250_000_000)
                guard !Task.isCancelled else { return }
                hasCopiedConnectionError = false
            }
        } label: {
            Image(systemName: hasCopiedConnectionError ? "checkmark" : "doc.on.doc")
                .font(.caption.weight(.semibold))
                .foregroundStyle(
                    hasCopiedConnectionError ? .green : isHoveringCopyError ? .primary : .secondary
                )
                .contentTransition(.symbolEffect(.replace))
                .scaleEffect(isHoveringCopyError && !reduceMotion ? 1.12 : 1)
                .opacity(isHoveringCopyError ? 1 : 0.75)
                .animation(
                    reduceMotion ? nil : .spring(response: 0.24, dampingFraction: 0.75),
                    value: isHoveringCopyError
                )
        }
        .buttonStyle(.plain)
        .help(hasCopiedConnectionError ? "Copied error message" : "Copy error message")
        .accessibilityLabel("Copy error message")
        .accessibilityValue(hasCopiedConnectionError ? "Copied" : "")
        .onHover { hovering in
            isHoveringCopyError = hovering
        }
    }
}

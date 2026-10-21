import Foundation
import AppKit
import SwiftUI


/// Uses the same compact status panel and actions as the subscription sign-in UI.
package struct OpenCodeCredentialLinkView: View {
    @ObservedObject var viewModel: SettingsViewModel
    var onWillImport: () -> Void = {}
    @State private var isChecking = false
    @State private var isOpeningSignIn = false
    @State private var awaitingSignIn = false
    @State private var errorMessage: String?
    @State private var refreshID = UUID()
    @State private var loginScriptURL: URL?

    package init(viewModel: SettingsViewModel, onWillImport: @escaping () -> Void = {}) {
        self._viewModel = ObservedObject(wrappedValue: viewModel)
        self.onWillImport = onWillImport
    }

    private var isConnected: Bool {
        viewModel.config.usesConnectedOpenCodeCredentials(for: viewModel.config.provider)
            && viewModel.config.apiKey != nil
    }
    private var canCheck: Bool {
        viewModel.hasLoadedPersistedState && !viewModel.isConfiguredCredentialHydrating
    }

    package var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: isConnected ? "checkmark.circle.fill" : "person.crop.circle.badge.checkmark")
                    .font(.title3)
                    .foregroundStyle(isConnected ? Color.green : Color.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(isConnected ? "Connected to \(viewModel.config.provider.displayName)" : "Connect with OpenCode")
                        .accessibilityIdentifier("OpenCodeConnectionStatus")
                        .font(.subheadline.weight(.semibold))
                    Text(isConnected ? "Using your OpenCode credentials" : "Choose Zen or Go in OpenCode to connect this plan.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 8) {
                if !isConnected {
                    Button {
                        onWillImport()
                        errorMessage = nil
                        isOpeningSignIn = true
                        HapticFeedbackManager.shared.tap()
                    } label: {
                        Label("Sign in with OpenCode", systemImage: "arrow.up.right.square")
                    }
                    .buttonStyle(.sortyBordered)
                    .disabled(isOpeningSignIn || !canCheck)
                    .accessibilityIdentifier("OpenCodeSignInButton")
                }
                Button {
                    onWillImport()
                    isChecking = true
                    errorMessage = nil
                    HapticFeedbackManager.shared.tap()
                } label: {
                    Label(isChecking ? "Checking…" : "Refresh status", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.sortyBordered)
                .disabled(isChecking || !canCheck)
                .accessibilityIdentifier("importOpenCodeCredentials")

                if viewModel.config.openCodeAuthSource(for: viewModel.config.provider) != .apiKey {
                    Button("Use API key") {
                        awaitingSignIn = false
                        viewModel.useManualOpenCodeAPIKey()
                        errorMessage = nil
                        HapticFeedbackManager.shared.selection()
                    }
                    .buttonStyle(.sortyBordered)
                    .accessibilityIdentifier("OpenCodeManualAPIKeyButton")
                }
            }
            .controlSize(.small)
            if awaitingSignIn && !isConnected {
                Label("Finish connecting in OpenCode. Sorty will update automatically.", systemImage: "clock")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.circle")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !isConnected {
                Link("Get an OpenCode API key", destination: URL(string: "https://opencode.ai/auth")!)
                    .accessibilityIdentifier("OpenCodeAPIKeyLink")
                    .font(.caption)
                    .trackHoveredURL(URL(string: "https://opencode.ai/auth")!)
                Text("Website sign-in alone does not connect Sorty. Connect your plan in OpenCode, or enter its API key.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .background((isConnected ? Color.green : Color.secondary).opacity(isConnected ? 0.08 : 0.05))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .task(id: "\(canCheck)-\(refreshID)") {
            if canCheck { await viewModel.refreshOpenCodeCredentials() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshID = UUID()
        }
        .task(id: isChecking) {
            guard isChecking else { return }
            defer { isChecking = false }
            do {
                try await viewModel.importOpenCodeCredentials()
                HapticFeedbackManager.shared.success()
            } catch {
                guard !Task.isCancelled else { return }
                errorMessage = error.localizedDescription
                HapticFeedbackManager.shared.error()
            }
        }
        .task(id: isOpeningSignIn) {
            guard isOpeningSignIn else { return }
            defer { isOpeningSignIn = false }
            guard !NetworkPrivacyPolicy.isInternetPrivacyModeEnabled else {
                errorMessage = NetworkPrivacyPolicy.blockedMessage
                return
            }
            do {
                let script = try await Task.detached(priority: .utility) {
                    try OpenCodeCredentials.prepareLoginScript()
                }.value
                guard !Task.isCancelled else {
                    try? FileManager.default.removeItem(at: script.deletingLastPathComponent())
                    return
                }
                if NSWorkspace.shared.open(script) {
                    loginScriptURL = script
                    awaitingSignIn = true
                } else {
                    try? FileManager.default.removeItem(at: script.deletingLastPathComponent())
                    errorMessage = "Could not open Terminal. Run opencode auth login, then refresh status."
                }
            } catch {
                errorMessage = (error as? OpenCodeCredentials.ImportError)?.localizedDescription
                    ?? "Could not start OpenCode sign-in. Run opencode auth login, then refresh status."
            }
        }
        .task(id: awaitingSignIn) {
            guard awaitingSignIn else { return }
            let script = loginScriptURL
            defer {
                if let script {
                    try? FileManager.default.removeItem(at: script.deletingLastPathComponent())
                }
                loginScriptURL = nil
            }
            // Bounded polling exists only while an explicitly started login is
            // pending. View disappearance or manual-key selection cancels it.
            for _ in 0..<150 {
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
                await viewModel.refreshOpenCodeCredentials(allowsManualSource: true)
                if isConnected {
                    awaitingSignIn = false
                    HapticFeedbackManager.shared.success()
                    return
                }
            }
            awaitingSignIn = false
        }
    }
}

import Foundation
import AppKit
import SwiftUI

struct CodexDeviceAuthSheet: View {
    @SortyHotReload private var hotReload
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let session: CodexDeviceAuthSession?
    let isCodexInstalled: Bool
    let authError: String?
    let onStart: () -> Void
    let onCancel: () -> Void
    let onOpenSettings: () -> Void
    let onOpenDeviceAuthorization: () -> Void
    let onCopyCode: () -> Void
    let isCodeCopied: Bool

    private var userCode: String {
        session?.userCode ?? "---- -----"
    }

    private var isWaiting: Bool {
        switch session?.status {
        case .starting, .waiting:
            return true
        default:
            return false
        }
    }

    var body: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: 14) {
                content
            }
        } else {
            content
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Reauthenticate ChatGPT Subscription")
                        .font(.title2.weight(.bold))
                    Text("Reauthenticate to keep using your ChatGPT subscription for OpenAI inference.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button(action: onCancel) {
                    Image(systemName: "xmark")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close")
            }

            authorizationSteps
            Text("Keep this dialog open while Sorty waits for approval.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .buttonStyle(.sortyBordered)
            }
        }
        .padding(28)
        .onAppear {
            if session == nil {
                onStart()
            }
        }
    }

    private var authorizationSteps: some View {
        VStack(alignment: .leading, spacing: 12) {
            CodexDeviceAuthStep(number: 1, title: "Enable device code authorization for Codex.") {
                Button(action: onOpenSettings) {
                    Label("Open ChatGPT Settings", systemImage: "arrow.up.right.square")
                }
                .buttonStyle(.sortyBordered)
                .controlSize(.small)
            }

            CodexDeviceAuthStep(number: 2, title: "Open the OpenAI device authorization page.") {
                Button(action: onOpenDeviceAuthorization) {
                    Label("Open device authorization", systemImage: "arrow.up.right.square")
                }
                .buttonStyle(.sortyBordered)
                .controlSize(.small)
            }

            CodexDeviceAuthStep(number: 3, title: "Paste this device code when OpenAI asks for it:") {
                deviceCodeButton
            }

            CodexDeviceAuthStep(number: 4, title: "Continue to finish approval.") {
                CodexDeviceAuthStatusView(
                    session: session,
                    isCodexInstalled: isCodexInstalled,
                    authError: authError,
                    isWaiting: isWaiting,
                    onStart: onStart
                )
            }
        }
    }

    private var deviceCodeLabel: some View {
        HStack(spacing: 12) {
            Text(userCode)
                .font(.title2.monospaced().weight(.bold))
                .tracking(3)
                .frame(minWidth: 190, alignment: .leading)

            Spacer(minLength: 10)

            Label(isCodeCopied ? "Copied" : "Copy", systemImage: isCodeCopied ? "checkmark.circle.fill" : "doc.on.doc")
                .font(.caption.weight(.semibold))
                .foregroundStyle(isCodeCopied ? SortyDesignSystem.Colors.success : .secondary)
                .symbolReplaceTransition(animationValue: isCodeCopied)
        }
        .frame(maxWidth: .infinity, minHeight: 44)
    }

    private var deviceCodeButton: some View {
        Button(action: onCopyCode) {
            deviceCodeLabel
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background {
            RoundedRectangle(cornerRadius: SortyDesignSystem.Radius.lg, style: .continuous)
                .fill(isCodeCopied ? SortyDesignSystem.Colors.success.opacity(0.10) : Color.clear)
        }
        .systemLiquidGlassBackground(cornerRadius: SortyDesignSystem.Radius.lg)
        .overlay {
            RoundedRectangle(cornerRadius: SortyDesignSystem.Radius.lg, style: .continuous)
                .strokeBorder(isCodeCopied ? SortyDesignSystem.Colors.success.opacity(0.42) : Color.primary.opacity(0.08), lineWidth: 1)
        }
        .scaleEffect(isCodeCopied && !reduceMotion ? 1.015 : 1)
        .disabled(session?.userCode == nil)
        .help("Copy device code")
        .accessibilityLabel(isCodeCopied ? "Device code copied" : "Copy device code")
    }
}

struct CodexDeviceAuthStep<Content: View>: View {
    @SortyHotReload private var hotReload
    let number: Int
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Text("\(number)")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(.primary)
                .frame(width: 32, height: 32)
                .background(Color.primary.opacity(0.08), in: Circle())

            VStack(alignment: .leading, spacing: 10) {
                Text(LocalizedStringKey(title))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .sortyInsetSurface(cornerRadius: SortyDesignSystem.Radius.lg)
    }
}

struct CodexDeviceAuthStatusView: View {
    @SortyHotReload private var hotReload
    let session: CodexDeviceAuthSession?
    let isCodexInstalled: Bool
    let authError: String?
    let isWaiting: Bool
    let onStart: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            switch session?.status {
            case .authorized:
                Label("Authorization complete", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(SortyDesignSystem.Colors.success)
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(SortyDesignSystem.Colors.warning)
                    .multilineTextAlignment(.center)
                Button("Try Again", action: onStart)
                    .buttonStyle(.sortyBordered)
                    .controlSize(.small)
            default:
                HStack(spacing: 8) {
                    BouncingSpinner(size: 14, color: .primary)
                    Text(isWaiting ? "Waiting for authorization" : "Starting authorization")
                        .font(.subheadline.weight(.semibold))
                        .numericTextTransition(animationValue: isWaiting)
                }
                Text("Refreshing automatically")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if !isCodexInstalled {
                Text("Codex CLI is required. Install with: npm i -g @openai/codex")
                    .font(.caption)
                    .foregroundStyle(SortyDesignSystem.Colors.warning)
            } else if let authError {
                Text(authError)
                    .font(.caption)
                    .foregroundStyle(SortyDesignSystem.Colors.warning)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
        .padding(.horizontal, 14)
        .sortyInsetSurface(cornerRadius: SortyDesignSystem.Radius.lg)
    }
}

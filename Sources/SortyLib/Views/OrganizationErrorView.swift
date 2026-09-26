import Foundation
import AppKit
import SwiftUI

struct ErrorView: View {
    @SortyHotReload private var hotReload
    let error: Error
    var canResume = false
    var onResume: () -> Void = {}
    let onCancel: () -> Void
    let onRetry: () -> Void
    let onRetryWithSmarterModel: () -> Void
    let onGrantPermission: () -> Void

    private enum ErrorActionFeedback {
        case cancel
        case retry
        case settings
        case grantPermission
        case copy
        case helpSupport
    }

    @State private var showRetryOptions = false
    @State private var showCopiedFeedback = false
    @State private var isHoveringCancel = false
    @State private var isHoveringHelpSupport = false
    @State private var isHoveringSettings = false
    @State private var copyResetTask: Task<Void, Never>?
    @State private var activeActionFeedback: ErrorActionFeedback?
    @State private var actionFeedbackResetTask: Task<Void, Never>?
    @State private var retryAnimationTrigger = 0

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var settingsViewModel: SettingsViewModel

    private enum ErrorCategory: Equatable {
        case internetPrivacy
        case apiKey
        case quota
        case network
        case permissions
        case generic
    }

    private var category: ErrorCategory {
        if let aiError = error as? AIClientError, aiError.isQuotaExhausted {
            return .quota
        }
        let description = error.localizedDescription.lowercased()
        if let aiError = error as? AIClientError, aiError.isInternetAccessBlocked {
            return .internetPrivacy
        }
        if description.contains("block internet connections")
            || description.contains("internet access is blocked") {
            return .internetPrivacy
        }
        if description.contains("api key") || description.contains("unauthorized") || description.contains("authentication") {
            return .apiKey
        }
        if description.contains("network") || description.contains("internet") || description.contains("offline") || isTimeoutError {
            return .network
        }
        if description.contains("permission") || description.contains("access") || description.contains("sandbox") {
            return .permissions
        }
        return .generic
    }

    private var isTimeoutError: Bool {
        let description = error.localizedDescription.lowercased()
        return description.contains("timeout") || description.contains("timed out")
    }

    private var errorIcon: String {
        switch category {
        case .internetPrivacy:
            return "network.slash"
        case .apiKey:
            return "key.fill"
        case .quota:
            return "creditcard.trianglebadge.exclamationmark"
        case .network:
            return "wifi.exclamationmark"
        case .permissions:
            return "lock.trianglebadge.exclamationmark"
        case .generic:
            return "exclamationmark.triangle.fill"
        }
    }

    private var errorTitle: String {
        switch category {
        case .internetPrivacy:
            return "Internet Access Blocked"
        case .apiKey:
            return "AI Credentials Required"
        case .quota:
            return "Usage Limit Reached"
        case .network:
            return "Connection Problem"
        case .permissions:
            return "Permission Required"
        case .generic:
            return "Something Went Wrong"
        }
    }

    private var recoveryText: String {
        switch category {
        case .internetPrivacy:
            return "Sorty stopped the request before it reached your AI provider. Turn off Block Internet Connections in Advanced Settings, then retry."
        case .apiKey:
            return "Check your provider and API key in Settings, then retry."
        case .quota:
            return "This model has used its free-tier allowance. Add paid credits in your provider dashboard, or choose a different model, then retry."
        case .network:
            if isTimeoutError {
                return "If your connection is stable, a slower provider may need more time."
            }
            return "Check your internet connection and provider availability, then retry."
        case .permissions:
            return "Grant file access for this folder and try again."
        case .generic:
            if planGenerationFailureCode == "PATH_CONFLICT" {
                return "Sorty found duplicate destination folders in the generated plan. Retry and Sorty will rebuild the plan without moving any files."
            }
            return "Choose a smarter model, then retry."
        }
    }

    private var showsSettingsChevron: Bool {
        isHoveringSettings || activeActionFeedback == .settings
    }

    private var showsCancelCircle: Bool {
        isHoveringCancel || activeActionFeedback == .cancel
    }

    private var showsHelpSupportChevron: Bool {
        isHoveringHelpSupport || activeActionFeedback == .helpSupport
    }

    private var privacySafeSupportDetails: String {
        """
        Sorty Error Report

        Error: \(errorTitle)
        Category: \(privacySafeCategoryName)
        \(privacySafeErrorCodeLine)
        Summary: \(privacySafeErrorSummary)
        Suggested action: \(privacySafeSuggestedAction)
        Workflow: \(settingsViewModel.config.mode.displayName)
        Provider: \(settingsViewModel.config.provider.displayName)
        Sorty: \(BuildInfo.fullVersion)
        macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)
        """
    }

    private var privacySafeCategoryName: String {
        switch category {
        case .internetPrivacy:
            return "Internet privacy"
        case .apiKey:
            return "AI credentials"
        case .quota:
            return "Usage limit"
        case .network:
            return "Network connection"
        case .permissions:
            return "File permissions"
        case .generic:
            return "Plan generation"
        }
    }

    private var privacySafeErrorSummary: String {
        switch category {
        case .internetPrivacy:
            return "Sorty blocked the request locally before it reached the selected AI provider."
        case .apiKey:
            return "Sorty couldn't authenticate with the selected AI provider."
        case .quota:
            return "The selected AI provider reported the free-tier allowance is used up."
        case .network:
            if isTimeoutError {
                return "The selected AI provider didn't respond before the request timeout."
            }
            return "Sorty couldn't reach the selected AI provider."
        case .permissions:
            return "Sorty couldn't access a required folder."
        case .generic:
            switch planGenerationFailureCode {
            case "OUTPUT_LIMIT":
                return "The selected model couldn't finish a complete organization plan within its output limit."
            case "INVALID_PLAN":
                return "The selected model returned a response that Sorty couldn't convert into a complete organization plan."
            case "PATH_CONFLICT":
                return "Sorty found two generated folders that resolve to the same destination path."
            default:
                return "Sorty couldn't create an organization plan."
            }
        }
    }

    private var privacySafeSuggestedAction: String {
        switch category {
        case .internetPrivacy:
            return "Open Advanced Settings, turn off Block Internet Connections, then retry."
        case .apiKey:
            return "Check the selected provider and its API key in Settings, then retry."
        case .quota:
            return "Add paid credits or choose a different model, then retry."
        case .network:
            if isTimeoutError {
                return "Check the internet connection, then review timeout settings before retrying."
            }
            return "Check the internet connection and provider availability, then retry."
        case .permissions:
            return "Grant access to the required folder, then retry."
        case .generic:
            if planGenerationFailureCode == "OUTPUT_LIMIT" {
                return "Retry to let Sorty process fewer files at a time, or choose a model with a larger output limit."
            }
            if planGenerationFailureCode == "INVALID_PLAN" {
                return "Retry to let Sorty process fewer files at a time. If it still fails, choose a more capable model."
            }
            if planGenerationFailureCode == "PATH_CONFLICT" {
                return "Retry to rebuild and merge duplicate destinations safely. No files were moved."
            }
            return "Choose a smarter model and retry. If it still fails, simplify Instructions or Persona, then review Learnings, workflow, and organization rules."
        }
    }

    private var privacySafeErrorCodeLine: String {
        if category == .internetPrivacy {
            return "Code: \(AIClientError.internetAccessBlockedCode)"
        }
        guard let planGenerationFailureCode else { return "" }
        return "Code: \(planGenerationFailureCode)"
    }

    private var planGenerationFailureCode: String? {
        guard category == .generic else { return nil }
        if let validationError = error as? ValidationError,
           case .pathConflict = validationError {
            return "PATH_CONFLICT"
        }
        if let clientError = error as? AIClientError {
            switch clientError {
            case .invalidResponseFormat, .jsonDecodingError:
                return "INVALID_PLAN"
            case .apiError(let statusCode, let message):
                let description = message.lowercased()
                if statusCode == 413 ||
                    description.contains("output limit") ||
                    description.contains("context length") ||
                    description.contains("maximum context") ||
                    description.contains("max_tokens") ||
                    description.contains("too many tokens") {
                    return "OUTPUT_LIMIT"
                }
            default:
                break
            }
        }
        return nil
    }

    var body: some View {
        VStack(spacing: 20) {
            Spacer()

            ZStack {
                Circle()
                    .fill(Color.red.opacity(0.1))
                    .frame(width: 100, height: 100)

                Image(systemName: errorIcon)
                    .font(.system(size: 44, weight: .semibold))
                    .foregroundStyle(.red)
                    .animatedEmptyStateIcon(tint: .red)
            }

            VStack(spacing: 8) {
                Text(errorTitle)
                    .font(.title3)
                    .fontWeight(.semibold)

                Text(error.localizedDescription)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 460)
                    .fixedSize(horizontal: false, vertical: true)

                recoveryGuidance
            }

            HStack(spacing: 12) {
                if canResume && category == .network && isTimeoutError {
                    Button {
                        HapticFeedbackManager.shared.tap()
                        onResume()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "play.fill")
                                .font(.system(size: 9, weight: .semibold))
                            Text("Continue \(settingsViewModel.config.mode.displayName)")
                                .font(.caption.bold())
                        }
                    }
                    .buttonStyle(.tintedPill(.accentColor, size: .small))
                    .help("Continue from the last completed part of this organization")
                    .accessibilityIdentifier("ErrorContinueOrganizationButton")
                }

                Button {
                    HapticFeedbackManager.shared.tap()
                    animateActionFeedback(.cancel)
                    onCancel()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: showsCancelCircle ? "xmark.circle.fill" : "xmark")
                            .font(.system(size: 10, weight: .semibold))
                            .contentTransition(.symbolEffect(.replace))
                            .transaction { transaction in
                                if reduceMotion {
                                    transaction.disablesAnimations = true
                                }
                            }
                        Text("Cancel")
                            .font(.caption.bold())
                    }
                }
                .buttonStyle(.tintedPill(.red, size: .small))
                .scaleEffect(activeActionFeedback == .cancel ? 1.04 : 1.0)
                .help("Return to folder selection")
                .accessibilityIdentifier("ErrorBackToFolderPickerButton")
                .onHover { hovering in
                    withAnimation(reduceMotion ? nil : .spring(response: 0.24, dampingFraction: 0.82)) {
                        isHoveringCancel = hovering
                    }
                }

                Button {
                    HapticFeedbackManager.shared.tap()
                    animateActionFeedback(.retry)
                    if !reduceMotion {
                        retryAnimationTrigger += 1
                    }
                    showRetryOptions = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.system(size: 10, weight: .semibold))
                            .symbolEffect(.rotate, options: .speed(1.5), value: retryAnimationTrigger)
                        Text("Retry")
                            .font(.caption.bold())
                    }
                }
                .buttonStyle(.tintedPill(.accentColor, size: .small))
                .scaleEffect(activeActionFeedback == .retry ? 1.04 : 1.0)
                .help("Choose how to retry this organization")
                .accessibilityIdentifier("ErrorTryAgainButton")
                .modelSelectorTriggerBounds()
                .onHover { hovering in
                    if hovering && !reduceMotion {
                        retryAnimationTrigger += 1
                    }
                }

                if category == .network && isTimeoutError {
                    Button {
                        HapticFeedbackManager.shared.tap()
                        animateActionFeedback(.settings)
                        appState.openSettingsWindow(
                            section: .advanced,
                            focusTarget: .advancedTimeouts
                        )
                        appState.navigatedFromSettings = true
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "clock")
                                .font(.system(size: 10, weight: .semibold))
                                .symbolEffect(.bounce, value: activeActionFeedback == .settings)
                            Text("Timeout Settings")
                                .font(.caption.bold())
                        }
                    }
                    .buttonStyle(.tintedPill(.indigo, size: .small))
                    .scaleEffect(activeActionFeedback == .settings ? 1.04 : 1.0)
                    .help("Open Advanced Settings and focus the timeout controls")
                    .accessibilityHint("Opens the request and resource timeout controls")
                    .accessibilityIdentifier("ErrorOpenTimeoutSettingsButton")
                }

                if category == .internetPrivacy {
                    Button {
                        HapticFeedbackManager.shared.tap()
                        animateActionFeedback(.settings)
                        appState.openSettingsWindow(
                            section: .advanced,
                            focusTarget: .advancedInternetPrivacy
                        )
                        appState.navigatedFromSettings = true
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: showsSettingsChevron ? "arrow.up.right" : "network")
                                .font(.system(size: 10, weight: .semibold))
                                .contentTransition(.symbolEffect(.replace))
                                .transaction { transaction in
                                    if reduceMotion {
                                        transaction.disablesAnimations = true
                                    }
                                }
                            Text("Internet Settings")
                                .font(.caption.bold())
                        }
                    }
                    .buttonStyle(.tintedPill(.indigo, size: .small))
                    .scaleEffect(activeActionFeedback == .settings ? 1.04 : 1.0)
                    .help("Open Advanced Settings and focus Block Internet Connections")
                    .accessibilityHint(
                        "Opens the setting that prevents Sorty from contacting cloud providers"
                    )
                    .accessibilityIdentifier("ErrorOpenInternetSettingsButton")
                    .onHover { hovering in
                        withAnimation(reduceMotion ? nil : .spring(response: 0.24, dampingFraction: 0.82)) {
                            isHoveringSettings = hovering
                        }
                    }
                }

                if category == .apiKey || category == .quota {
                    Button {
                        HapticFeedbackManager.shared.tap()
                        animateActionFeedback(.settings)
                        appState.openSettingsWindow(section: .provider)
                        appState.navigatedFromSettings = true
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: showsSettingsChevron ? "arrow.up.right" : "gearshape")
                                .font(.system(size: 10, weight: .semibold))
                                .contentTransition(.symbolEffect(.replace))
                                .transaction { transaction in
                                    if reduceMotion {
                                        transaction.disablesAnimations = true
                                    }
                                }
                            Text("Settings")
                                .font(.caption.bold())
                        }
                    }
                    .buttonStyle(.tintedPill(.indigo, size: .small))
                    .scaleEffect(activeActionFeedback == .settings ? 1.04 : 1.0)
                    .help("Open Settings to resolve this issue")
                    .accessibilityIdentifier("ErrorOpenSettingsButton")
                    .onHover { hovering in
                        withAnimation(reduceMotion ? nil : .spring(response: 0.24, dampingFraction: 0.82)) {
                            isHoveringSettings = hovering
                        }
                    }
                }

                if category == .permissions {
                    Button {
                        HapticFeedbackManager.shared.tap()
                        animateActionFeedback(.grantPermission)
                        onGrantPermission()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "folder.badge.plus")
                                .font(.system(size: 10, weight: .semibold))
                                .symbolEffect(
                                    .bounce,
                                    value: activeActionFeedback == .grantPermission
                                )
                            Text("Grant Permission")
                                .font(.caption.bold())
                        }
                    }
                    .buttonStyle(.tintedPill(.indigo, size: .small))
                    .scaleEffect(activeActionFeedback == .grantPermission ? 1.04 : 1.0)
                    .help("Grant access to this folder and continue organizing")
                    .accessibilityHint(
                        "Opens the folder picker, then continues organization after access is granted"
                    )
                    .accessibilityIdentifier("ErrorGrantPermissionButton")

                    Button {
                        HapticFeedbackManager.shared.tap()
                        animateActionFeedback(.settings)
                        appState.openSettingsWindow(section: .permissions)
                        appState.navigatedFromSettings = true
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "hand.raised.fill")
                                .font(.system(size: 10, weight: .semibold))
                                .symbolEffect(
                                    .bounce,
                                    value: activeActionFeedback == .settings
                                )
                            Text("Permissions")
                                .font(.caption.bold())
                        }
                    }
                    .buttonStyle(.tintedPill(.purple, size: .small))
                    .scaleEffect(activeActionFeedback == .settings ? 1.04 : 1.0)
                    .help("Review all permissions in Sorty Settings")
                    .accessibilityHint(
                        "Opens the Permissions page at the permission status overview"
                    )
                    .accessibilityIdentifier("ErrorOpenPermissionsButton")
                }

                if category == .generic || category == .quota {
                    Button {
                        HapticFeedbackManager.shared.tap()
                        animateActionFeedback(.helpSupport)
                        appState.openSettingsWindow(section: .help)
                        appState.navigatedFromSettings = true
                    } label: {
                        HStack(spacing: 4) {
                            Image(
                                systemName: showsHelpSupportChevron
                                    ? "arrow.up.right"
                                    : "questionmark.circle.fill"
                            )
                                .font(.system(size: 10, weight: .semibold))
                                .contentTransition(.symbolEffect(.replace))
                                .transaction { transaction in
                                    if reduceMotion {
                                        transaction.disablesAnimations = true
                                    }
                                }
                            Text("Help & Support")
                                .font(.caption.bold())
                        }
                    }
                    .buttonStyle(.tintedPill(.green, size: .small))
                    .scaleEffect(activeActionFeedback == .helpSupport ? 1.04 : 1.0)
                    .help("Open Help & Support")
                    .accessibilityHint("Opens the Help and Support settings page")
                    .accessibilityIdentifier("ErrorHelpSupportButton")
                    .onHover { hovering in
                        withAnimation(reduceMotion ? nil : .spring(response: 0.24, dampingFraction: 0.82)) {
                            isHoveringHelpSupport = hovering
                        }
                    }
                }

                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(privacySafeSupportDetails, forType: .string)
                    HapticFeedbackManager.shared.selection()
                    animateActionFeedback(.copy)
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.72)) {
                        showCopiedFeedback = true
                    }
                    copyResetTask?.cancel()
                    copyResetTask = Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 1_200_000_000)
                        guard !Task.isCancelled else { return }
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.72)) {
                            showCopiedFeedback = false
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: showCopiedFeedback ? "checkmark.circle.fill" : "doc.on.doc")
                            .font(.system(size: 10, weight: .semibold))
                            .symbolReplaceTransition(animationValue: showCopiedFeedback)
                            .symbolEffect(.bounce, value: activeActionFeedback == .copy)
                        Text(showCopiedFeedback ? "Copied" : "Copy")
                            .font(.caption.bold())
                            .numericTextTransition(animationValue: showCopiedFeedback)
                    }
                }
                .buttonStyle(.tintedPill(.orange, size: .small))
                .scaleEffect(showCopiedFeedback || activeActionFeedback == .copy ? 1.04 : 1.0)
                .help("Copy a privacy-safe error report for support")
                .accessibilityHint(
                    "Copies diagnostics without private file, instruction, prompt, or credential data"
                )
                .accessibilityIdentifier("ErrorCopyDetailsButton")
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
        .confirmationDialog(
            "Retry Options",
            isPresented: $showRetryOptions,
            titleVisibility: .visible
        ) {
            Button("Choose Smarter Model") {
                HapticFeedbackManager.shared.tap()
                onRetryWithSmarterModel()
            }

            Button("Retry with Current Model") {
                HapticFeedbackManager.shared.tap()
                onRetry()
            }

            Button("Cancel", role: .cancel) {}
        } message: {
            Text("A stronger model is more likely to return the structured plan Sorty needs.")
        }
    }

    @ViewBuilder
    private var recoveryGuidance: some View {
        if category == .generic || category == .quota {
            VStack(spacing: 6) {
                Text(recoveryText)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)

                Text("If it still fails, simplify your Instructions or Persona, then review Learnings, workflow, and organization rules.")

                Text("Still stuck? Copy the details and open Help & Support.")
            }
            .font(.caption)
            .foregroundStyle(.tertiary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 520)
            .fixedSize(horizontal: false, vertical: true)
        } else {
            Text(recoveryText)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 500)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func animateActionFeedback(_ action: ErrorActionFeedback) {
        withAnimation(.spring(response: 0.28, dampingFraction: 0.7)) {
            activeActionFeedback = action
        }

        actionFeedbackResetTask?.cancel()
        actionFeedbackResetTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 240_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.spring(response: 0.28, dampingFraction: 0.8)) {
                activeActionFeedback = nil
            }
        }
    }
}

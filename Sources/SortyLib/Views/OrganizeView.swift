//
//  OrganizeView.swift
//  Sorty
//
//  Main organization workflow view with improved layout
//  Enhanced with micro-animations, haptic feedback, and state transitions
//

import Foundation
import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum ErrorViewTestRoute: String {
    case credentials = "sorty-error-preview://credentials"
    case network = "sorty-error-preview://network"
    case permissions = "sorty-error-preview://permissions"
    case generic = "sorty-error-preview://generic"

    init?(instructions: String) {
        let normalized = instructions
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        self.init(rawValue: normalized)
    }

    var error: Error {
        let message: String
        switch self {
        case .credentials:
            message = "Authentication failed because the API key is missing or invalid."
        case .network:
            message = "The network request timed out. Check your internet connection and try again."
        case .permissions:
            message = "Sorty doesn't have permission to access this folder."
        case .generic:
            message = "Sorty couldn't turn the model response into an organization plan."
        }

        return NSError(
            domain: "com.sorty.app.error-preview",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
}

struct OrganizeView: View {
    @SortyHotReload var hotReload
    @EnvironmentObject var organizer: FolderOrganizer
    @EnvironmentObject var settingsViewModel: SettingsViewModel
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var customPersonaStore: CustomPersonaStore
    @EnvironmentObject var codexAuth: CodexCLIAuthManager
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    @StateObject var steeringManager = SteeringPromptManager.shared

    @State var previousState: OrganizationState?
    @State var showSmarterRetryModelPicker = false
    @State var showSavedPromptsSheet = false
    @State var isReturningToStart = false
    @State var isShowingReturnToStartContent = false
    @State var keepsDirectorySelectionVisibleAfterReturn = false
    @State var workflowContentIsVisible = false
    @State var directorySelectionIsPresented = true
    @State var workflowEntranceTask: Task<Void, Never>?
    @State var showsCompletionContent = false
    @State var liveOrganizationStartedAt: Date?
    @State var keepsLiveOrganizationVisible = false
    @State var readyPreviewHandoffTask: Task<Void, Never>?
    @State var errorViewTestRoute: ErrorViewTestRoute?

    // Just long enough for the first file flight to land before PreviewView
    // replaces the live stage. Kept short: the live stage must never make the
    // user wait for a plan that is already ready.
    let minimumLiveOrganizationPresentation: TimeInterval = 1.2

    var body: some View {
        ZStack {
            DirectorySelectionView(
                selectedDirectory: $appState.selectedDirectory,
                startsVisible: keepsDirectorySelectionVisibleAfterReturn,
                isPresented: directorySelectionIsPresented
            )
            .opacity(workflowContentIsVisible ? 0 : 1)
            .offset(x: reduceMotion || !workflowContentIsVisible ? 0 : -10)
            .allowsHitTesting(!workflowContentIsVisible)
            .accessibilityHidden(workflowContentIsVisible)

            if let directory = appState.selectedDirectory {
                VStack(spacing: 0) {
                    // Header with selected directory
                    DirectoryHeader(
                        url: directory,
                        mode: settingsViewModel.config.mode,
                        onBack: {
                            HapticFeedbackManager.shared.tap()
                            switch organizer.state {
                            case .scanning, .organizing, .ready, .applying, .completed:
                                returnToStartAfterCancellation()
                            default:
                                returnToDirectorySelection()
                            }
                        },
                        onClear: {
                            HapticFeedbackManager.shared.tap()
                            let panel = NSOpenPanel()
                            panel.canChooseDirectories = true
                            panel.canChooseFiles = false
                            panel.allowsMultipleSelection = false
                            panel.message = "Select a directory to organize"
                            panel.prompt = "Select"
                            if panel.runModal() == .OK, let url = panel.url {
                                withAnimation(.pageTransition) {
                                    organizer.reset()
                                    appState.selectedDirectory = url
                                }
                                HapticFeedbackManager.shared.success()
                            }
                        }
                    )

                    // Main content area with animated transitions.
                    ZStack {
                        WorkflowGradientBackground()
                            .opacity(persistentWorkflowGradientOpacity)
                            .animation(
                                persistentWorkflowGradientAnimation,
                                value: persistentWorkflowGradientOpacity
                            )
                            .allowsHitTesting(false)

                        stateContent
                            .environment(\.workflowGradientHidden, true)
                            .opacity(stateContentOpacity)
                            .transition(.opacity)

                        if isShowingReturnToStartContent {
                            returnToStartContent
                                .environment(\.workflowGradientHidden, true)
                                .opacity(returnToStartContentOpacity)
                                .scaleEffect(returnToStartContentScale)
                                .offset(y: returnToStartContentOffset)
                                .transition(.identity)
                        }
                    }
                }
                .opacity(workflowContentIsVisible ? 1 : 0)
                .offset(x: reduceMotion || workflowContentIsVisible ? 0 : 12)
                .allowsHitTesting(workflowContentIsVisible)
                .accessibilityHidden(!workflowContentIsVisible)
            }
        }
        .navigationTitle(settingsViewModel.config.mode.workflowTitle)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Organization workflow")
        .accessibilityHint("Select a folder and configure options")
        .onAppear {
            directorySelectionIsPresented = appState.selectedDirectory == nil
            settingsViewModel.config.enableStreaming = true
            organizer.setLiveInsightsEnabled(true)
            presentSteeringPromptsIfRequested()
            presentWorkflowContentIfNeeded()
        }
        .onChange(of: appState.shouldPresentSteeringPrompts) { _, _ in
            presentSteeringPromptsIfRequested()
        }
        .onChange(of: settingsViewModel.config.provider) { oldValue, newValue in
            if organizer.aiClient != nil {
                configureOrganizer()
            }
        }
        .onChange(of: organizer.state) { oldValue, newValue in
            handleStateChange(to: newValue)
        }
        .onChange(of: appState.selectedDirectory) { oldValue, newValue in
            errorViewTestRoute = nil
            if newValue != nil {
                keepsDirectorySelectionVisibleAfterReturn = false
                presentWorkflowContentIfNeeded()
            } else {
                workflowEntranceTask?.cancel()
                workflowContentIsVisible = false
                directorySelectionIsPresented = true
            }
            // Prewarm AI connection when user selects a folder
            if newValue != nil {
                Task {
                    await prewarmAIConnection()
                }
            }
        }
        .modelSelectionOverlay(
            isPresented: $showSmarterRetryModelPicker,
            currentProvider: settingsViewModel.config.provider,
            currentModel: settingsViewModel.config.model,
            contextMessage: "Select a stronger model to retry this failed organization attempt. Your selection also becomes the active model for future runs.",
            selectionActionTitle: "Retry with Model",
            reasoningEffortForModel: { provider, model in
                settingsViewModel.config.reasoningEffort(for: provider, model: model)
            },
            onSelectReasoningEffort: { provider, model, effort in
                settingsViewModel.config.setReasoningEffort(effort, for: provider, model: model)
            },
            onSelect: { provider, model, authMethod in
                if let authMethod {
                    settingsViewModel.config.setAuthMethod(authMethod, for: provider)
                }
                retryWithSelectedModel(provider: provider, model: model)
            },
            isSubscriptionSelected: settingsViewModel.config.authMethod(for: settingsViewModel.config.provider) == .accountSignIn
        )
        .sheet(isPresented: $showSavedPromptsSheet) {
            SavedPromptsSheet(
                steeringManager: steeringManager,
                settingsConfig: settingsViewModel.config,
                onApplyPrompt: { prompt in
                    organizer.customInstructions = prompt
                    showSavedPromptsSheet = false
                    HapticFeedbackManager.shared.tap()
                }
            )
        }
        .onDisappear {
            directorySelectionIsPresented = false
            workflowEntranceTask?.cancel()
            readyPreviewHandoffTask?.cancel()
            readyPreviewHandoffTask = nil
        }
    }


}





#if DEBUG
#Preview("Organize View - Idle") {
    let codexAuthManager = CodexCLIAuthManager()

    OrganizeView()
        .environmentObject(OrganizePreviewObjects.idleOrganizer)
        .environmentObject(SettingsViewModel.preview)
        .environmentObject(AppState.preview)
        .environmentObject(PersonaManager.preview)
        .environmentObject(CustomPersonaStore.preview)
        .environmentObject(LearningsManager.preview)
        .environmentObject(codexAuthManager)
        .environmentObject(MenuBarController())
        .frame(width: 900, height: 600)
}

#Preview("Organize View - Scanning") {
    let codexAuthManager = CodexCLIAuthManager()

    OrganizeView()
        .environmentObject(OrganizePreviewObjects.scanningOrganizer)
        .environmentObject(SettingsViewModel.preview)
        .environmentObject(AppState.preview)
        .environmentObject(PersonaManager.preview)
        .environmentObject(CustomPersonaStore.preview)
        .environmentObject(LearningsManager.preview)
        .environmentObject(codexAuthManager)
        .environmentObject(MenuBarController())
        .frame(width: 900, height: 600)
}

#Preview("Organize View - Ready") {
    let codexAuthManager = CodexCLIAuthManager()

    OrganizeView()
        .environmentObject(OrganizePreviewObjects.readyOrganizer)
        .environmentObject(SettingsViewModel.preview)
        .environmentObject(OrganizePreviewObjects.readyAppState)
        .environmentObject(PersonaManager.preview)
        .environmentObject(CustomPersonaStore.preview)
        .environmentObject(LearningsManager.preview)
        .environmentObject(codexAuthManager)
        .environmentObject(MenuBarController())
        .frame(width: 900, height: 700)
}

#Preview("Organize View - Error") {
    let codexAuthManager = CodexCLIAuthManager()

    OrganizeView()
        .environmentObject(OrganizePreviewObjects.errorOrganizer)
        .environmentObject(SettingsViewModel.preview)
        .environmentObject(AppState.preview)
        .environmentObject(PersonaManager.preview)
        .environmentObject(CustomPersonaStore.preview)
        .environmentObject(LearningsManager.preview)
        .environmentObject(codexAuthManager)
        .environmentObject(MenuBarController())
        .frame(width: 900, height: 600)
}

#endif
